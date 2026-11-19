#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<'EOF'
fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
lifecycle verbs addressed to an exact task id.

Usage: fm-control.sh <task-id> interrupt
       fm-control.sh <task-id> exit
       fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
                                        [--effort <level>]
                                        (--note <text> | --note-file <path>)

Use `fm-send.sh` for text and these verbs for lifecycle commands.

  interrupt  Send the harness's interrupt key. The agent keeps running.
             Postcondition: delivery succeeded, the endpoint still exists,
             and the agent is still alive. Cancellation is reported
             unconfirmed, and busy state is never rewritten as proof of it.
  exit       Stop the agent, preserving its terminal endpoint, worktree, and
             every uncommitted change. Interrupts first when the task reads
             busy, then submits the harness's exit command, and succeeds once
             the backend's recovery-grade classifier reports the agent gone.
             Already-stopped is success (idempotent). An endpoint that reads
             `missing` is put through the control plane's absence proof
             (fm_control_endpoint_absence_verdict) before anything is claimed
             about it, because `missing` also covers an endpoint that is
             merely unreachable from this seat. Herdr proves absence by
             reading the session the record names. Proven gone reports
             `endpoint-gone` rather than `already-stopped`, because the
             endpoint this verb normally preserves did not survive; a pane
             that turns out to be there and idle is the ordinary
             `already-stopped`; one whose agent is back takes the ordinary
             interrupt-then-exit path.
  relaunch   Transactionally replace the running agent with a new one, in the
             SAME worktree - and the same endpoint whenever that endpoint
             still exists - on the same or a newly chosen
             harness/model/effort. When the recorded Herdr pane or workspace
             is instead proven gone, the launch owner re-creates one in that
             worktree, in the herdr session the record names, and the task's
             record rebinds to it; that is how a task whose terminal was
             destroyed is reclaimed by the home that owns it.
             An explicit `default` model or effort clears that
             axis for the replacement. Otherwise the replacement keeps the
             recorded adapter, model, and effort.
             A prefixed raw-command basename cannot reconstruct its launch
             command, so relaunch requires an explicit --harness for it.
             A replacement profile must also pass this home's worker account
             pin (bin/fm-worker-account-lib.sh) here, so a pin that no longer
             resolves or is signed out refuses before the old agent stops.
             A recorded Claude account (claude_account=) follows a relaunch
             that keeps the same harness and model, under the same pre-stop
             sign-in check; any other profile relaunches without it.
             The same pre-stop refusal applies to this home's worker tool
             exclusions (bin/fm-exclude-tools-lib.sh): a malformed list, or a
             replacement runtime that cannot hide the listed tools.
             --note is required. The replacement keeps the worktree but
             does not inherit the conversation.
             Records a durable checkpoint and that note, exits the old agent,
             then delegates the launch to its single owner,
             bin/fm-spawn.sh --relaunch. A failure before publication keeps
             the prior durable record in place and reports the concrete
             state; it never leaves a half-transitioned task claiming to be
             running.

Teardown and discard are NOT verbs here and never will be. `exit` stops an
agent and preserves everything else; removing a worktree, killing an
endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
landed-work test.

`resume` is not a verb: Pi has no verified pane-resume contract.
`relaunch` covers the same need because the brief on disk, not a
harness-private session, is the durable instruction.

Targeting is EXACT: only a bare task id with a state/<id>.meta record in
THIS home is accepted, and the record must pass the shared endpoint-identity
validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
fm-<id> label, an explicit session:window endpoint, and a bare window name
are all refused - a lifecycle command delivered to the wrong endpoint is far
worse than a loud refusal.

A worker on another host is controlled through its recorded execution route.

Fail-closed boundaries:
  - An unverified harness is refused rather than guessed at.
  - An ambiguous or unreadable endpoint state refuses; only a positively
    classified state acts.
  - A composer that visibly holds pending text refuses before an exit command
    is typed, so existing text is preserved instead of being concatenated.

Environment knobs (all bounded waits, seconds):
  FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
  FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
  FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
  FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$SCRIPT_DIR/fm-exclude-tools-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  # Remove the dialog file while the lock is still held: once it is released,
  # the next lifecycle command for this task writes the same path.
  if [ -n "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    rm -f "$FM_COMPOSER_DIALOG_SINK"
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: Pi has no verified pane-resume contract. Use 'relaunch', which carries the brief plus a progress note into a fresh agent."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NEW_CLAUDE_ACCOUNT=
CLAUDE_ACCOUNT_SET=0
NOTE=
NOTE_SET=0
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      claude-account) NEW_CLAUDE_ACCOUNT=$control_arg; CLAUDE_ACCOUNT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --claude-account) control_want_value=claude-account ;;
    --claude-account=*) NEW_CLAUDE_ACCOUNT=${control_arg#--claude-account=}; CLAUDE_ACCOUNT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] \
    && [ "$CLAUDE_ACCOUNT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, --claude-account, and --note apply to 'relaunch' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
[ "$CLAUDE_ACCOUNT_SET" = 0 ] || [ -n "$NEW_CLAUDE_ACCOUNT" ] || die "--claude-account requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
# do_exit runs in a command substitution. That subshell does not run this
# EXIT trap, so the parent has to hold the path the trap removes. Set it
# only once the lock is held: a process that loses the lock runs the same
# trap, and would remove the file the lock holder is reading.
FM_COMPOSER_DIALOG_SINK=$STATE/$ID.composer-dialog
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
fm_control_remote_worker() {
  local route hop_out hop_rc hop_target hop_session line key value
  local -a hop_args
  route=$(fm_meta_get "$META" remote_route)
  case "$VERB" in
    interrupt|exit) ;;
    relaunch)
      [ "$HARNESS_SET" = 1 ] && hop_args+=(--harness "$NEW_HARNESS")
      [ "$MODEL_SET" = 1 ] && hop_args+=(--model "$NEW_MODEL")
      [ "$EFFORT_SET" = 1 ] && hop_args+=(--effort "$NEW_EFFORT")
      [ "$CLAUDE_ACCOUNT_SET" = 1 ] && hop_args+=(--claude-account "$NEW_CLAUDE_ACCOUNT")
      [ "$NOTE_SET" = 1 ] && hop_args+=(--note "$NOTE")
      ;;
  esac
  FM_CONTROL_REMOTE_BUDGET=${FM_CONTROL_REMOTE_BUDGET:-180}
  case "$FM_CONTROL_REMOTE_BUDGET" in ''|*[!0-9]*|0)
    die "FM_CONTROL_REMOTE_BUDGET must be a positive integer: $FM_CONTROL_REMOTE_BUDGET" ;;
  esac
  [ -n "$route" ] || die "task $ID is a remote worker with no recorded route; refusing a lifecycle hop with no destination"
  hop_rc=0
  hop_out=$(fm_run_timed "$FM_CONTROL_REMOTE_BUDGET" "$SCRIPT_DIR/fm-on.sh" "$route" \
    fm-remote-worker-control.sh "$VERB" "$ID" ${hop_args[@]+"${hop_args[@]}"} 2>&1) || hop_rc=$?
  if [ "$hop_rc" -ne 0 ]; then
    printf '%s\n' "$hop_out" >&2
    case "$hop_out" in
      *'unknown remote worker command'*) die "task $ID runs on a remote code root older than this home; update that host before driving worker lifecycle from here (hop exit $hop_rc)" ;;
    esac
    case "$hop_rc" in
      124) die "task $ID remote $VERB did not complete within ${FM_CONTROL_REMOTE_BUDGET}s; completion unknown - verify with bin/fm-crew-state.sh before retrying" ;;
      255) die "task $ID remote $VERB lost its transport; completion unknown - verify with bin/fm-crew-state.sh before retrying" ;;
    esac
    die "task $ID remote $VERB refused on $(fm_meta_get "$META" remote_host) (hop exit $hop_rc; the hop stderr above has the reason)"
  fi
  hop_target=
  hop_session=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      target=*) hop_target=${line#target=} ;;
      herdr_session=*) hop_session=${line#herdr_session=} ;;
    esac
  done <<EOF
$hop_out
EOF
  [ -n "$hop_target" ] || die "task $ID remote $VERB reported success without a route readback; refusing to trust a hop with no endpoint to republish"
  for key in remote_target remote_herdr_session; do
    case "$key" in
      remote_target) value=$hop_target ;;
      remote_herdr_session) value=$hop_session; [ -n "$value" ] || continue ;;
    esac
    awk -v k="$key" -v v="$value" '{ if (!done && substr($0, 1, length(k)+1) == k "=") { print k "=" v; done=1; next } print } END{ if (!done) print k "=" v }' "$META" > "$META.tmp" \
      && mv "$META.tmp" "$META"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*|backend=*|target=*|kind=*|harness=*|model=*|effort=*|claude_account=*|worktree=*|project=*|herdr_session=*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$hop_out
EOF
}

KIND=$(fm_meta_get "$META" kind)
case "${KIND:-ship}" in ship|scout) ;; *) die "task $ID has an unsupported recorded kind" ;; esac
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  [ -n "$(fm_meta_get "$META" remote_route)" ] || die "task $ID has no execution-home route"
  fm_control_remote_worker
  exit "$?"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

composer_state() {
  local verdict
  verdict=$(fm_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) || verdict=unknown
  printf '%s' "$verdict"
}

# settle_secondmate_turn: wait, bounded, until the secondmate is not busy and
# its composer is proven empty, its composer holds text, or its agent is gone.
# Interrupting a Pi turn instead moves its queued follow-ups into the composer
# and leaves Herdr reporting the turn as running for a moment afterwards, so
# the exit could prove neither that the composer was empty nor what it held.

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# refuse_blocking_prompt: the screen is a dialog a confirming Enter would
# answer. Name it and stop. Do not type Escape or an option: both dismiss
# or choose.
refuse_blocking_prompt() {  # <dialog-name>
  die "task $ID is blocked on a prompt: $1. Refusing to type Enter into it."
}

# Pi emits no cancellation acknowledgement, so the claim stays unconfirmed.
deliver_interrupt() {
  local key
  key=$(fm_control_interrupt_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "interrupt key $key was not delivered to task $ID on $BACKEND"
  printf 'unconfirmed'
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof='agent-alive'
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

# Drop busy_gen from the task record when it still names <gen>.
# fm-busy-event.sh owns the sidecar and the record; fm_backlog_atomic_transition
# publish owns the task record. Clearing the line inside the busy writer would
# take the task-record lock that teardown and spawn already hold; the busy
# writer is their child process, so it would wait on a live holder that is
# itself waiting on the child, and neither would ever proceed.
clear_retired_meta_busy_gen() {  # <gen>
  local gen=$1 meta="$STATE/$ID.meta" lock tmp current line
  [ -n "$gen" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  if ! declare -F fm_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  fi
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock"
  current=$(fm_meta_get "$meta" busy_gen)
  if [ "$current" != "$gen" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.retire.XXXXXX") || {
    fm_lock_release "$lock"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      busy_gen=*) ;;
      *)
        printf '%s\n' "$line" >> "$tmp" || {
          rm -f "$tmp"
          fm_lock_release "$lock"
          return 1
        }
        ;;
    esac
  done < "$meta" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

retire_busy_incarnation() {
  local gen=
  if [ -f "$STATE/$ID.busy-gen" ]; then
    gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
    if [ -n "$gen" ] \
      && "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$gen" >/dev/null 2>&1; then
      clear_retired_meta_busy_gen "$gen" || true
    fi
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd verdict composer cancel absence interrupt_result=not-needed dialog
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    *)
      fm_control_absence_recheck_applies "$BACKEND" "$state" \
        || die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint"
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(fm_control_endpoint_absence_verdict "$BACKEND" "$T")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads '$state', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  : > "$FM_COMPOSER_DIALOG_SINK" \
    || die "task $ID's dialog check could not be recorded"
  composer=$(composer_state)
  # The classify that filled the sink ran in a subshell, so read the file
  # rather than a function that subshell sourced.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    refuse_blocking_prompt "$dialog"
  fi
  case "$composer" in
    empty) ;;
    pending)
      die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Clear or submit the pending text, then retry '$VERB'"
      ;;
    *)
      die "task $ID's composer state is '$composer', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'"
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  # The submitting Enter can open a dialog while the agent is still alive, and
  # another Enter would confirm its selected row. A dead agent may leave the
  # same text behind; that is not a prompt still waiting.
  if [ -s "${FM_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$FM_COMPOSER_DIALOG_SINK")
    if [ "$(agent_state)" != dead ]; then
      refuse_blocking_prompt "$dialog"
    fi
  fi
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    # A submit can return before any read sees the picker: a native busy
    # verdict needs no composer read, and a cleared composer can be read
    # before the picker renders. Read the screen once more here.
    : > "$FM_COMPOSER_DIALOG_SINK" || true
    fm_backend_composer_state "$BACKEND" "$T" "$LABEL" >/dev/null 2>&1 || true
    if [ -s "$FM_COMPOSER_DIALOG_SINK" ]; then
      refuse_blocking_prompt "$(cat "$FM_COMPOSER_DIALOG_SINK")"
    fi
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=
TARGET_CLAUDE_ACCOUNT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          # The old agent was NOT proven stopped, so no replacement is coming
          # and the agent that may still be reading these instructions is the
          # original one. The note exists to brief a replacement; leaving it in
          # a possibly-live agent's brief would be an unrequested edit to a
          # running task. Restore byte-exact, exactly as the alive case does.
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      elif [ "$(agent_state 2>/dev/null)" != dead ] \
         || ! state=$(fm_backend_launch_pane_refusal "$BACKEND" "$T" 2>/dev/null); then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-unproven" || true
        echo "error: $ID's replacement did not launch, and its endpoint is not proven agent-free (${state:-its agent reads alive or unreadable}); an agent may still be running there, and its work plus the recorded progress note are preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
  # The launch owner applies this home's worker account pin too, but only after
  # the old agent has been stopped, so a pin that no longer resolves or is
  # signed out must refuse here, while nothing has changed yet.
  local account_model=$TARGET_MODEL
  [ "$account_model" != default ] || account_model=
  TARGET_CLAUDE_ACCOUNT=
  if [ "$CLAUDE_ACCOUNT_SET" = 1 ]; then
    [ "$NEW_CLAUDE_ACCOUNT" = default ] || TARGET_CLAUDE_ACCOUNT=$NEW_CLAUDE_ACCOUNT
  elif { [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ] && [ "$TARGET_MODEL" = "$PRIOR_MODEL" ]; } \
     || fm_claude_bridge_model "$TARGET_HARNESS" "$account_model"; then
    TARGET_CLAUDE_ACCOUNT=$(fm_meta_get "$META" claude_account)
  fi
  if [ -n "$TARGET_CLAUDE_ACCOUNT" ]; then
    fm_claude_account_select "$TARGET_HARNESS" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
      "$account_model" "$TARGET_CLAUDE_ACCOUNT" >/dev/null || return 1
  else
    fm_claude_bridge_account_required "$TARGET_HARNESS" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
      "$account_model" || return 1
  fi
  fm_worker_account_select "$TARGET_HARNESS" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
    "$account_model" "$TARGET_HARNESS" >/dev/null || return 1
  # Likewise config/crew-exclude-tools: a malformed file, or a replacement
  # runtime that cannot hide the listed tools, refuses here, before the old
  # agent stops. Secondmate agents are not covered.
  fm_exclude_tools_check "$TARGET_HARNESS" 0 "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" >/dev/null || return 1
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty marker other_rc=0
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  fm_worktree_other_record "$STATE" "$META" "$WT" || other_rc=$?
  case "$other_rc" in
    0) die "task $ID's recorded worktree $WT is also task $FM_WORKTREE_OTHER_ID's recorded $FM_WORKTREE_OTHER_FIELD ($FM_WORKTREE_OTHER_META), so it may now hold $FM_WORKTREE_OTHER_ID's work rather than $ID's; refusing to relaunch $ID into it. Reconcile whichever record is wrong (bin/fm-crew-state.sh $ID; bin/fm-crew-state.sh $FM_WORKTREE_OTHER_ID), then relaunch" ;;
    1) ;;
    *) die "could not prove no other task records task $ID's worktree $WT ($FM_LOCAL_FIRSTMATE_ERROR); refusing to relaunch" ;;
  esac
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp inbox_q
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        inbox_q=$(printf '%s' "$STATE/$ID.inbox" | sed "s/'/'\\\\''/g")
        echo "First, check your instruction inbox: list it with"
        echo "\`find '$inbox_q' -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V\`, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "'$inbox_q/handled/'. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line refusal
  local -a spawn_args

  require_state_verified_backend relaunch
  fm_control_backend_relaunch_supported "$BACKEND" \
    || die "task $ID runs on the $BACKEND backend, where a thread keeps its conversation and a new turn or provider change continues the same agent, so no fresh replacement can be launched into its endpoint; 'interrupt' ends its turn, and a fresh task needs a teardown and a new dispatch"
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  if [ "$(agent_state)" = dead ] && ! refusal=$(fm_backend_launch_pane_refusal "$BACKEND" "$T"); then
    die "task $ID's endpoint $T reads 'dead', but $refusal; relaunch refuses to type a launch command into it, which could start a second agent inside the first. Nothing changed"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  [ -z "$TARGET_CLAUDE_ACCOUNT" ] || spawn_args+=(--claude-account "$TARGET_CLAUDE_ACCOUNT")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
    # $T was resolved from the record before the launch. When the recorded
    # endpoint was gone, the launch owner created a fresh one and republished
    # the record pointing at it, so every postcondition below must be read from
    # the endpoint the task now HAS, not the one it had. Re-resolving through
    # the same shared validation is what makes that safe: a record that no
    # longer passes it refuses here rather than leaving this transaction
    # polling an address nothing owns.
    # stdout is dropped (it is only the resolved target), but the refusal on
    # stderr names the exact row that failed - and in this one branch the record
    # was just rewritten by the launch owner, so that row is the whole
    # diagnostic. Let it through rather than dying with nothing to act on.
    if fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
       && [ -n "$FM_BACKEND_VALIDATED_TARGET" ]; then
      T=$FM_BACKEND_VALIDATED_TARGET
    else
      die "the replacement agent for $ID was launched, but task $ID's republished record no longer passes endpoint validation (the refusal above names the row), so this transaction cannot say which endpoint to confirm it on; reconcile $META before any further control action"
    fi
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
esac
