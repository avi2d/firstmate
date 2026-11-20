#!/usr/bin/env bash
FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_BACKEND_KNOWN="herdr"
FM_BACKEND_SPAWN="herdr"

# fm_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. fm-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
fm_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

fm_backend_detect() {
  if [ "${HERDR_ENV:-}" = "1" ]; then
    printf 'herdr'
    return 0
  fi
  return 1
}

fm_backend_explicit_name() {
  local line v
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  [ -f "$FM_BACKEND_CONFIG_DIR/backend" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    v=$(printf '%s' "$line" | tr -d '[:space:]')
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done < "$FM_BACKEND_CONFIG_DIR/backend"
  return 1
}

fm_backend_resolve() {
  FM_BACKEND_RESOLVED=$(fm_backend_explicit_name) && return 0
  FM_BACKEND_RESOLVED=herdr
}

# fm_backend_name: fm_backend_resolve for callers that only need the name.
fm_backend_name() {
  fm_backend_resolve
  printf '%s' "$FM_BACKEND_RESOLVED"
}

# fm_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
fm_backend_validate() {  # <name>
  local name=$1
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

fm_backend_validate_spawn() {  # <name>
  local name=$1
  fm_backend_validate "$name" || return 1
  fm_backend_list_contains "$FM_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $FM_BACKEND_SPAWN)" >&2
  return 1
}

fm_backend_required_tools() {
  [ "$1" = herdr ] || return 1
  printf '%s' 'herdr jq treehouse'
}

fm_backend_required_tool_available() {
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 line value=''
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta" 2>/dev/null || true
  printf '%s' "$value"
}

fm_backend_of_meta() {  # <meta-file>
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-unknown}"
}

fm_backend_target_of_meta() {
  local window
  window=$(fm_meta_get "$1" window)
  [ -n "$window" ] && printf '%s' "$window"
}

# fm_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. New non-tmux records carry endpoint_task_id because their
# opaque runtime ids do not encode the task label. Legacy tmux records remain
# valid only when their window name itself is exactly fm-<task-id>.
# On success, sets FM_BACKEND_VALIDATED_BACKEND and
# FM_BACKEND_VALIDATED_TARGET. On failure, prints one refusal and returns 1.
fm_backend_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_backend_endpoint_atom_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

# The repair path printed with the worktree-identity refusal below, so a record
# that cannot name its copy is a repairable state rather than a dead end.
# One path serves all three refused shapes, because each one ends in the same
# place: the record has to carry exactly one worktree= line, whether that means
# adding it, filling it in, or dropping all but the right one of several.
# It names only evidence this system writes by itself: the project's own
# worktree list, which maps the task's recorded branch back to its copy, and the
# record snapshot bin/fm-control.sh preserves before a relaunch.
# No command here restores the line: only the operator can say which copy a task
# holds, and a one-shot rewrite would make a damaged record convenient to keep.
# Restoring it stays safe when the pool slot has since been handed to another
# task: bin/fm-teardown.sh reads that slot's own claim (bin/fm-wake-lib.sh's
# fm_treehouse_slot_owner_marker) and then touches nothing under it, while a
# slot carrying no claim carries no such proof and leaves the worktree listing
# as the only evidence.
fm_backend_worktree_identity_repair_hint() {  # <meta-file>
  local meta=$1 prior project branch
  prior="${meta%.meta}.control-relaunch.meta-prior"
  project=$(fm_meta_get "$meta" project)
  branch=$(fm_meta_get "$meta" branch)
  echo "The record needs exactly one worktree= line naming the copy this task holds: add it, fill it in, or keep only the right one of several, then re-run."
  if [ -n "$project" ]; then
    # Quoted, so the printed command survives a project path with spaces and
    # can be copied and run exactly as it reads.
    echo "Find the copy checked out on this task's recorded branch${branch:+ $branch} with:"
    echo "git -C $(printf '%q' "$project") worktree list"
  fi
  if [ -f "$prior" ] && [ ! -L "$prior" ]; then
    echo "The record as it stood before the last relaunch still carries that line at $prior."
  fi
  echo "A pool slot handed on to another task since is still safe to name: cleanup reads that slot's own .fm-slot-owner claim and then leaves the slot untouched, while a slot with no claim is proved only by that worktree listing."
}

fm_backend_validate_task_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend_count backend window worktree project binding_count binding
  local pane recorded_session workspace tab
  FM_BACKEND_VALIDATED_BACKEND=
  FM_BACKEND_VALIDATED_TARGET=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id has no regular endpoint metadata at $meta; preserving task state." >&2
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    echo "REFUSED: task endpoint identity has an invalid task id; preserving task state." >&2
    return 1
  esac
  window=$(fm_backend_meta_exact_value "$meta" window) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous window endpoint; preserving task state." >&2
    return 1
  }
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." >&2
    fm_backend_worktree_identity_repair_hint "$meta" >&2
    return 1
  }
  project=$(fm_backend_meta_exact_value "$meta" project) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous project identity; preserving task state." >&2
    return 1
  }
  case "$worktree$project$window" in *$'\n'*|*$'\r'*|*$'\t'*)
    echo "REFUSED: task $id has malformed endpoint metadata; preserving task state." >&2
    return 1
  esac
  if [ "$window" = "remote:$id" ]; then
    local remote_host remote_route remote_target remote_backend remote_session remote_kind
    remote_host=$(fm_backend_meta_exact_value "$meta" remote_host) || return 1
    remote_route=$(fm_backend_meta_exact_value "$meta" remote_route) || return 1
    remote_target=$(fm_backend_meta_exact_value "$meta" remote_target) || return 1
    remote_backend=$(fm_backend_meta_exact_value "$meta" remote_backend) || return 1
    remote_session=$(fm_backend_meta_exact_value "$meta" remote_herdr_session) || return 1
    remote_kind=$(fm_backend_meta_exact_value "$meta" kind) || return 1
    [ "$(fm_backend_meta_exact_value "$meta" endpoint_task_id)" = "$id" ] || return 1
    fm_backend_endpoint_atom_valid "$remote_host" && fm_backend_endpoint_atom_valid "$remote_route" && fm_backend_endpoint_atom_valid "$remote_session" || return 1
    [ "$remote_backend" = herdr ] || return 1
    case "$remote_kind" in ship|scout) ;; *) return 1 ;; esac
    case "$remote_target" in "$remote_session":?*) ;; *) return 1 ;; esac
    local remote_pane=${remote_target#*:}
    fm_backend_endpoint_atom_valid "${remote_pane//:/_}" || return 1
    case "$worktree:$project" in /*:/*) ;; *) return 1 ;; esac
    FM_BACKEND_VALIDATED_BACKEND=remote
    FM_BACKEND_VALIDATED_TARGET=$remote_target
    return 0
  fi
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    1) backend=$(fm_backend_meta_exact_value "$meta" backend) || backend= ;;
    *) backend= ;;
  esac
  if [ -z "$backend" ] || ! fm_backend_is_known "$backend"; then
    echo "REFUSED: task $id has a missing, ambiguous, or unknown backend identity; preserving task state." >&2
    return 1
  fi
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) binding= ;;
    1)
      binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || {
        echo "REFUSED: task $id has an empty endpoint task binding; preserving task state." >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: task $id has an ambiguous endpoint task binding; preserving task state." >&2
      return 1
      ;;
  esac
  if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
    echo "REFUSED: endpoint metadata belongs to task $binding, not $id; preserving task state." >&2
    return 1
  fi

  [ "$binding" = "$id" ] || {
    echo "REFUSED: legacy Herdr endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
    return 1
  }
  recorded_session=$(fm_backend_meta_exact_value "$meta" herdr_session) || recorded_session=
  workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
  tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
  pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
  if [ -z "$recorded_session" ] || [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ] \
    || [ "$window" != "$recorded_session:$pane" ] \
    || ! fm_backend_endpoint_atom_valid "$recorded_session" \
    || ! fm_backend_endpoint_atom_valid "$workspace" \
    || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
    || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
    echo "REFUSED: Herdr endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_TARGET=$window
  return 0
}

fm_backend_meta_for_window() {
  local target=$1 state=$2 meta window
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] && [ "$window" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

fm_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'herdr'
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# Bash 3.2 can enter an EXIT trap with status 0 after `set -e` aborts on a
# missing or unreadable dot-sourced file, and a newer Bash can print that
# diagnostic and keep going. Both report a successful teardown. Prove the
# adapter and the siblings it sources are readable regular files before `.`.
fm_backend_source_readable() {  # <path>
  [ -f "$1" ] && [ -r "$1" ]
}

fm_backend_source() {
  local name=$1 adapter rel sibling
  fm_backend_validate "$name" || return 1
  adapter="$FM_BACKEND_LIB_DIR/backends/herdr.sh"
  set -- fm-composer-lib.sh fm-transition-lib.sh fm-agent-process-lib.sh fm-session-lock-lib.sh fm-shell-line-lib.sh
  fm_backend_source_readable "$adapter" || return 1
  for rel in "$@"; do
    sibling="$FM_BACKEND_LIB_DIR/$rel"
    fm_backend_source_readable "$sibling" || return 1
  done
  if [ -z "${_FM_BACKEND_HERDR_SOURCED:-}" ]; then
    . "$FM_BACKEND_DEFAULT_ROOT/bin/backends/herdr.sh" || return 1
    _FM_BACKEND_HERDR_SOURCED=1
  fi
}

fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    fm-*)
      echo "error: no metadata for $raw in $state; pass session:window to target a window outside this firstmate home" >&2
      return 1
      ;;
    *)
      meta=$(fm_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      echo "error: no metadata for $raw in $state" >&2
      return 1
      ;;
  esac
}

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_capture "$@"
}

# Precondition: an operator asked for this read. On herdr it scrolls an idle
# alternate-screen agent, so it never runs on a timer. Every other backend's
# bounded capture already reaches its history.
fm_backend_scrollback_capture() {  # <backend> <target> <lines> [expected-label]
  [ "$1" = herdr ] || { fm_backend_capture "$@"; return; }
  fm_backend_source herdr || return 1
  shift
  fm_backend_herdr_scrollback_capture "$@"
}

FM_BACKEND_VISIBLE_CAPTURE="herdr"

# fm_backend_visible_capture_supported: whether <backend> can read the visible
# viewport WITHOUT scrollback. Callers that must not mistake a scrolled-away
# frame for the live screen ask this first and fail closed on a no.
fm_backend_visible_capture_supported() {  # <backend>
  fm_backend_list_contains "$FM_BACKEND_VISIBLE_CAPTURE" "$1"
}

# fm_backend_visible_capture: the visible viewport, never scrollback. A backend
# outside FM_BACKEND_VISIBLE_CAPTURE declines here rather than answering with a
# history-backed capture the caller would read as the live screen.
fm_backend_visible_capture() {  # <backend> <target> [expected-label]
  local backend=$1
  shift
  fm_backend_visible_capture_supported "$backend" || {
    echo "error: backend '$backend' has no verified viewport-bounded capture primitive" >&2
    return 1
  }
  fm_backend_source "$backend" || return 1
  "fm_backend_${backend}_visible_capture" "$@"
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_send_key "$@"
}

# fm_backend_send_text_submit: submit and verify through the selected adapter.
# Pane backends type once and retry only submission; T3 uses a native send.
# Echoes the backend's verdict; callers require exact empty for confirmed delivery.
# A pane that already shows the recognised dialog is refused before any
# adapter types, so that submit neither types the text nor sends Enter.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1 rc=0 target label dialog
  shift
  target=$1
  label=${6:-}
  fm_backend_source "$backend" || return 1
  # Every Enter loop below reads the dialog sink, so it must exist before
  # any adapter types: a sink that fails here leaves the composer untouched.
  fm_composer_dialog_sink_prepare || {
    echo "error: the dialog check for a $backend submit could not be recorded" >&2
    return 1
  }
  # One composer read after the sink exists and before the adapter types.
  # The classify writes the sink; a named dialog means the next Enter would
  # answer it.
  if [ -n "$label" ]; then
    fm_backend_composer_state "$backend" "$target" "$label" >/dev/null || true
  else
    fm_backend_composer_state "$backend" "$target" >/dev/null || true
  fi
  if dialog=$(fm_composer_blocking_dialog_noted); then
    fm_composer_dialog_sink_release
    echo "error: blocked on a prompt: $dialog" >&2
    return 1
  fi
  fm_backend_herdr_send_text_submit "$@" || rc=$?
  fm_composer_dialog_sink_release
  return "$rc"
}

# fm_backend_kill: remove the task's session endpoint. An already-gone target
# is NOT an error and returns 0 silently, so ordinary cleanup of an
# already-exited session stays quiet. A nonzero return means the close could
# not do its job and the endpoint may still be live: the caller owns that
# refusal and must not delete the durable records that are the only thing
# naming the endpoint (bin/fm-teardown.sh's retain-and-stop path).
fm_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_kill "$@"
}

fm_backend_remove_worktree() {
  echo "error: backend '$1' does not own task worktrees" >&2
  return 1
}

fm_backend_worktree_path() {
  echo "error: backend '$1' does not own task worktrees" >&2
  return 1
}

fm_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  fm_backend_herdr_busy_state "$@"
}

fm_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local backend=$1
  shift
  fm_backend_source "$backend" || { printf 'unknown'; return 0; }
  fm_backend_herdr_composer_state "$@"
}

# A liveness read must not start the Herdr server.
fm_backend_target_exists() {
  local backend=$1 target=$2 session pane
  fm_backend_source "$backend" || return 1
  session=${target%%:*}
  pane=${target#*:}
  [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
  fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
}

fm_backend_agent_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  fm_backend_herdr_agent_state "$target"
}

# fm_backend_launch_pane_state: shell|occupied|unreadable|unverified for the
# endpoint a launch command is about to be typed into. It is read from the
# operating system's process view, independently of fm_backend_agent_state's
# verdict, because typing a launch into a pane whose agent is in fact alive
# starts a second agent inside the first: only `shell` licenses typing.
fm_backend_launch_pane_state() {  # <backend> <target>
  local backend=$1 target=$2
  fm_backend_source "$backend" || { printf 'unverified'; return 0; }
  fm_backend_herdr_launch_pane_state "$target"
}

# Succeeds silently when fm_backend_launch_pane_state proves a bare shell;
# otherwise prints why a launch must not be typed into the endpoint.
fm_backend_launch_pane_refusal() {  # <backend> <target>
  local state
  state=$(fm_backend_launch_pane_state "$1" "$2")
  case "$state" in
    shell) return 0 ;;
    occupied) printf 'its pane runs something other than a bare shell, so its agent may still be alive' ;;
    *) printf 'its pane'"'"'s processes could not be read (%s), so its agent may still be alive' "$state" ;;
  esac
  return 1
}

# Only Herdr resumes an agent into a restored pane, so every other backend
# prints `unverified` rather than a verdict.
fm_backend_task_isolation() {  # <backend> <target> <worktree> <task-id>
  local backend=$1
  case "$backend" in
    herdr)
      fm_backend_source herdr || { printf 'unverified'; return 0; }
      fm_backend_herdr_task_isolation "$2" "$3" "$4"
      ;;
    *) printf 'unverified' ;;
  esac
}

# Backward-compatible three-state view for existing callers. An
# authoritatively missing endpoint is confidently not a live agent, while every
# ambiguous, unreadable, or unverified result stays unknown.
fm_backend_agent_alive() {  # <backend> <target>
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_has_push: 0 if <backend> exposes a native transition push stream.
fm_backend_has_push() {  # <backend>
  case "$1" in
    herdr) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now (version/schema/reader gate). Non-push backends are never capable.
# The watcher memoizes this per session so the potentially heavy capability
# probe is not repeated every poll.
fm_backend_events_capable() {  # <backend> <session>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_events_capable "$@"
}

# fm_backend_wait_transition: bounded wait for a fresh actionable (blocked)
# transition on one of <pane_window...> in <session>, up to <timeout_secs>.
# Prints the normalized transition record and returns 0 on a fresh actionable
# edge; returns 1 on a clean timeout (the caller has effectively already slept);
# returns 2 when the event path is unusable (the caller sleeps the budget
# itself). Non-push backends always return 2.
fm_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <pane_window...>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 2
  fm_backend_source "$backend" || return 2
  fm_backend_herdr_wait_transition "$@"
}

fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 1
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_commit_transition "$@"
}

fm_backend_clear_transition() {  # <backend> <state_dir> <window>
  local backend=$1
  shift
  fm_backend_has_push "$backend" || return 0
  fm_backend_source "$backend" || return 1
  fm_backend_herdr_clear_transition "$@"
}

fm_backend_event_session() {
  printf '%s' "${2%%:*}"
}

fm_backend_transition_target() {
  printf '%s:%s' "$2" "$3"
}

# fm_backend_transition_note: optional backend detail appended to an
# escalated transition's wake reason; empty for backends with nothing to add.
fm_backend_transition_note() {
  return 0
}

fm_backend_runtime_check() {
  fm_backend_source "$1"
}

fm_backend_validate_harness() {
  fm_backend_source "$1"
}
