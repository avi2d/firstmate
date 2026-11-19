#!/usr/bin/env bash
# Spawn a Pi worker for a ship or scout task in an isolated treehouse worktree on herdr.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--branch-prefix <prefix>] [--base-branch <branch>] [--harness pi|pi-signed] [--model <name>] [--effort <level>] [--dispatch-override <reason>] [--claude-account <name>] [--herdr-resume-lock-wait]
#        fm-spawn.sh <task-id> <project-dir> --scout [--base-branch <branch>] [--harness pi|pi-signed] [--model <name>] [--effort <level>] [--dispatch-override <reason>] [--claude-account <name>] [--herdr-resume-lock-wait]
#        fm-spawn.sh <task-id> --relaunch [--harness pi|pi-signed] [--model <name>] [--effort <level>] [--claude-account <name>]
#        fm-spawn.sh <id>=<project-dir> [<id>=<project-dir> ...] [shared flags]
#   --mode and --yolo are required on every ship and refused on a scout.
#   --relaunch starts a replacement agent in the task's recorded worktree and endpoint.
#   A pair list re-runs this script once per pair with the shared flags.
#   docs/scripts.md and docs/configuration.md own the flags and config files.
# Exits 75 when project capacity is full and the task stays queued.
# On success prints: spawned <id> harness=<name> kind=<ship|scout> [mode=<mode> yolo=<on|off>] window=<target> worktree=<path>
set -eu

# Template replacements must stay literal on Bash 5.2+ and stock macOS Bash.
shopt -u patsub_replacement 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
  /*)
    printf '%s\n' "$path"
    return 0
    ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_HOME=$(resolve_directory_input FM_HOME "$FM_HOME") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  FM_STATE_OVERRIDE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_DATA_OVERRIDE=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$SCRIPT_DIR/fm-exclude-tools-lib.sh"

fm_config_source_present() {
  perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect configuration source at $ARGV[0]: $!\n" }
  ' -- "$1"
}

if ! LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-allowlist"); then
  exit 1
fi
LAUNCH_ENV_NAMES=
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  if [ ! -f "$CONFIG/launch-env-allowlist" ] || [ ! -r "$CONFIG/launch-env-allowlist" ]; then
    echo "error: config/launch-env-allowlist must be a readable regular file" >&2
    exit 1
  fi
  if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
    split("\n") | map(select(. != "" and (startswith("#") | not))) |
    if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
    else error("expected environment names only") end
  ' "$CONFIG/launch-env-allowlist" 2>/dev/null); then
    echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
    exit 1
  fi
fi
# config/lavish-axi-host is the primary-owned per-machine address for the
# shared Lavish server. Read it once per launch and refuse malformed values so
# every worker reaches the same server instead of starting a second one.
if ! LAVISH_AXI_HOST_CONFIG_PRESENT=$(fm_config_source_present "$CONFIG/lavish-axi-host"); then
  exit 1
fi
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/lavish-axi-host" ] || [ ! -r "$CONFIG/lavish-axi-host" ]; then
    echo "error: config/lavish-axi-host must be a readable regular file" >&2
    exit 1
  fi
  LAVISH_AXI_HOST=$(cat "$CONFIG/lavish-axi-host") || exit 1
  case "$LAVISH_AXI_HOST" in
    ''|*[[:space:][:cntrl:]]*)
      echo "error: config/lavish-axi-host must contain one non-empty address without whitespace" >&2
      exit 1
      ;;
  esac
fi
if ! KEEP_AI_TRAILERS=$(fm_config_source_present "$CONFIG/keep-ai-trailers"); then
  exit 1
fi
# Set by the forge agreement below for a forge=external ship.
EXTERNAL_REVIEW=0
EXTERNAL_BACKUP_REMOTE=
EXTERNAL_BACKUP_PREFIX=
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
fi
# shellcheck source=bin/fm-remote-registry-lib.sh
. "$SCRIPT_DIR/fm-remote-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-shell-line-lib.sh
. "$SCRIPT_DIR/fm-shell-line-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$SCRIPT_DIR/fm-mac-load-lib.sh"
# shellcheck source=bin/fm-core-budget-lib.sh
. "$SCRIPT_DIR/fm-core-budget-lib.sh"
# shellcheck source=bin/fm-browser-suite-lib.sh
. "$SCRIPT_DIR/fm-browser-suite-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-quota-assessment-lib.sh
. "$SCRIPT_DIR/fm-quota-assessment-lib.sh"
# shellcheck source=bin/fm-clauth-lib.sh
. "$SCRIPT_DIR/fm-clauth-lib.sh"
# shellcheck source=bin/fm-quota-spawn-lib.sh
. "$SCRIPT_DIR/fm-quota-spawn-lib.sh"
# shellcheck source=bin/fm-dispatch-proof-lib.sh
. "$SCRIPT_DIR/fm-dispatch-proof-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
KIND_SET=0
LOCAL_OVERRIDE=0
HARNESS_ARG=
MODEL=
EFFORT=
DISPATCH_OVERRIDE=
BACKEND_ARG=
MODE=
YOLO=
BRANCH_PREFIX=fm/
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
WEIGHT=heavy
WEIGHT_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
BRANCH_PREFIX_SET=0
BASE_BRANCH=
BASE_BRANCH_SET=0
UPSTREAM_CONSENT=
UPSTREAM_CONSENT_SET=0
CLAUDE_ACCOUNT=
CLAUDE_ACCOUNT_SET=0
QUOTA_OVERRIDE_REASON=
QUOTA_OVERRIDE_SET=0
RELAUNCH=0
# Opt-in only: exact-resume presentation-order lock waits instead of refusing.
# Absent/unset keeps upstream refuse-on-contention. See header.
HERDR_RESUME_LOCK_WAIT=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
    --*)
      echo "error: --$want_value requires a value" >&2
      exit 1
      ;;
    esac
    case "$want_value" in
    harness)
      HARNESS_ARG=$a
      HARNESS_SET=1
      ;;
    model)
      MODEL=$a
      MODEL_SET=1
      ;;
    effort)
      EFFORT=$a
      EFFORT_SET=1
      ;;
    weight)
      WEIGHT=$a
      WEIGHT_SET=1
      ;;
    dispatch-override) DISPATCH_OVERRIDE=$a ;;
    backend)
      BACKEND_ARG=$a
      BACKEND_SET=1
      ;;
    mode)
      MODE=$a
      MODE_SET=1
      ;;
    yolo)
      YOLO=$a
      YOLO_SET=1
      ;;
    branch-prefix)
      BRANCH_PREFIX=$a
      BRANCH_PREFIX_SET=1
      ;;
    base-branch)
      BASE_BRANCH=$a
      BASE_BRANCH_SET=1
      ;;
    upstream-consent)
      UPSTREAM_CONSENT=$a
      UPSTREAM_CONSENT_SET=1
      ;;
    claude-account)
      CLAUDE_ACCOUNT=$a
      CLAUDE_ACCOUNT_SET=1
      ;;
    quota-override-reason)
      QUOTA_OVERRIDE_REASON=$a
      QUOTA_OVERRIDE_SET=1
      ;;
    *)
      echo "error: internal parser state for --$want_value" >&2
      exit 1
      ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
  --scout)
    KIND=scout
    KIND_SET=1
    ;;
  --local) LOCAL_OVERRIDE=1 ;;
  --relaunch) RELAUNCH=1 ;;
  --herdr-resume-lock-wait) HERDR_RESUME_LOCK_WAIT=1 ;;
  --harness) want_value=harness ;;
  --harness=*)
    HARNESS_ARG=${a#--harness=}
    HARNESS_SET=1
    ;;
  --model) want_value=model ;;
  --model=*)
    MODEL=${a#--model=}
    MODEL_SET=1
    ;;
  --effort) want_value=effort ;;
  --effort=*)
    EFFORT=${a#--effort=}
    EFFORT_SET=1
    ;;
  --weight) want_value=weight ;;
  --weight=*)
    WEIGHT=${a#--weight=}
    WEIGHT_SET=1
    ;;
  --dispatch-override) want_value=dispatch-override ;;
  --dispatch-override=*) DISPATCH_OVERRIDE=${a#--dispatch-override=} ;;
  --backend) want_value=backend ;;
  --backend=*)
    BACKEND_ARG=${a#--backend=}
    BACKEND_SET=1
    ;;
  --mode) want_value=mode ;;
  --mode=*)
    MODE=${a#--mode=}
    MODE_SET=1
    ;;
  --yolo) want_value=yolo ;;
  --yolo=*)
    YOLO=${a#--yolo=}
    YOLO_SET=1
    ;;
  --branch-prefix) want_value="branch-prefix" ;;
  --branch-prefix=*)
    BRANCH_PREFIX=${a#--branch-prefix=}
    BRANCH_PREFIX_SET=1
    ;;
  --base-branch) want_value="base-branch" ;;
  --base-branch=*)
    BASE_BRANCH=${a#--base-branch=}
    BASE_BRANCH_SET=1
    ;;
  --upstream-consent) want_value="upstream-consent" ;;
  --upstream-consent=*)
    UPSTREAM_CONSENT=${a#--upstream-consent=}
    UPSTREAM_CONSENT_SET=1
    ;;
  --claude-account) want_value=claude-account ;;
  --claude-account=*)
    CLAUDE_ACCOUNT=${a#--claude-account=}
    CLAUDE_ACCOUNT_SET=1
    ;;
  --quota-override-reason) want_value=quota-override-reason ;;
  --quota-override-reason=*)
    QUOTA_OVERRIDE_REASON=${a#--quota-override-reason=}
    QUOTA_OVERRIDE_SET=1
    ;;
  *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || {
  echo "error: --$want_value requires a value" >&2
  exit 1
}
if [ "$LOCAL_OVERRIDE" -eq 1 ] && [ "$RELAUNCH" -eq 1 ]; then
  echo 'error: --local applies only to fresh ship and scout workers' >&2
  exit 1
fi
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || {
  echo "error: --harness requires a non-empty value" >&2
  exit 1
}
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || {
  echo "error: --model requires a non-empty value" >&2
  exit 1
}
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || {
  echo "error: --effort requires a non-empty value" >&2
  exit 1
}
[ "$WEIGHT_SET" -eq 0 ] || [ -n "$WEIGHT" ] || {
  echo "error: --weight requires a non-empty value" >&2
  exit 1
}
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || {
  echo "error: --backend requires a non-empty value" >&2
  exit 1
}
[ "$MODE_SET" -eq 0 ] || [ -n "$MODE" ] || {
  echo "error: --mode requires a non-empty value" >&2
  exit 1
}
[ "$YOLO_SET" -eq 0 ] || [ -n "$YOLO" ] || {
  echo "error: --yolo requires a non-empty value" >&2
  exit 1
}
[ "$UPSTREAM_CONSENT_SET" -eq 0 ] || [ -n "$UPSTREAM_CONSENT" ] || {
  echo "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value" >&2
  exit 1
}
[ "$CLAUDE_ACCOUNT_SET" -eq 0 ] || [ -n "$CLAUDE_ACCOUNT" ] || {
  echo "error: --claude-account requires a non-empty value" >&2
  exit 1
}
[ "$QUOTA_OVERRIDE_SET" -eq 0 ] || [ -n "$QUOTA_OVERRIDE_REASON" ] || {
  echo "error: --quota-override-reason requires a non-empty value" >&2
  exit 1
}
if [ "$QUOTA_OVERRIDE_SET" -eq 1 ] && [ -z "$(printf '%s' "$QUOTA_OVERRIDE_REASON" | tr -d '[:space:]')" ]; then
  echo "error: --quota-override-reason requires a stated reason" >&2
  exit 1
fi
case "$QUOTA_OVERRIDE_REASON" in *$'\n'*|*$'\r'*)
  echo "error: --quota-override-reason must be one line" >&2
  exit 1
  ;;
esac
case "$EFFORT" in
'' | low | medium | high | xhigh | max | ultra) ;;
*)
  echo "error: --effort must be one of low, medium, high, xhigh, max, ultra" >&2
  exit 1
  ;;
esac
case "$WEIGHT" in
heavy | light) ;;
*)
  echo "error: --weight must be heavy or light" >&2
  exit 1
  ;;
esac

# --relaunch reuses an existing task's endpoint, worktree, project, and kind,
# so every axis this block resolves for a fresh spawn instead comes from that
# task's own durable record below. Contradicting it on the command line is a
# refusal rather than a silently-ignored flag.
if [ "$RELAUNCH" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded backend; --backend cannot override it" >&2
    exit 1
  }
  [ "$KIND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded kind; --scout cannot override it" >&2
    exit 1
  }
  [ "$MODE_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it" >&2
    exit 1
  }
  [ "$YOLO_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it" >&2
    exit 1
  }
  [ "$BRANCH_PREFIX_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded ship branch; --branch-prefix cannot override it" >&2
    exit 1
  }
  [ "$BASE_BRANCH_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded base branch; --base-branch cannot override it" >&2
    exit 1
  }
  [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded upstream consent; --upstream-consent cannot override it" >&2
    exit 1
  }
  [ "$WEIGHT_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded weight; --weight cannot override it" >&2
    exit 1
  }
else
  # Delivery contract (AGENTS.md section 7). A ship task's mode and yolo are
  # firstmate's per-task decision, so they are required and closed-set validated
  # here rather than resolved from the project registry. Scouts deliver a report
  # and record no delivery posture.
  if [ "$KIND" = ship ]; then
    [ "$MODE_SET" -eq 1 ] || {
      echo "error: ship spawns require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 1 ] || {
      echo "error: ship spawns require --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
      exit 1
    }
    case "$MODE" in
    no-mistakes | direct-PR | local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1
      ;;
    *)
      echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2
      exit 1
      ;;
    esac
    case "$YOLO" in
    on | off) ;;
    *)
      echo "error: --yolo must be on or off (got '$YOLO')" >&2
      exit 1
      ;;
    esac
    if [ "$UPSTREAM_CONSENT_SET" -eq 1 ]; then
      if [ "$MODE" = local-only ]; then
        echo "error: --upstream-consent is meaningless on local-only, which publishes nothing; drop it" >&2
        exit 1
      fi
      fm_role_scope_valid "$UPSTREAM_CONSENT" || {
        echo "error: --upstream-consent must be <host>/<owner>/<repo> (got '$UPSTREAM_CONSENT')" >&2
        exit 1
      }
      UPSTREAM_CONSENT=$(fm_role_scope_norm "$UPSTREAM_CONSENT")
    fi
  else
    [ "$MODE_SET" -eq 0 ] || {
      echo "error: --mode applies only to ship spawns; a scout delivers a report" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 0 ] || {
      echo "error: --yolo applies only to ship spawns; a scout delivers a report" >&2
      exit 1
    }
    [ "$BRANCH_PREFIX_SET" -eq 0 ] || {
      echo "error: --branch-prefix applies only to ship spawns; a scout makes no branch" >&2
      exit 1
    }
    [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
      echo "error: --upstream-consent applies only to ship spawns; a scout publishes nothing" >&2
      exit 1
    }
  fi
fi


# Mirrors admit_heavy_gates: a machine that reports room is one its admit accepts.
spawn_choose_machine() {  # <route> <host> <project>
  local route=$1 host=$2 project=$3 room_config out rc rload rlimit rfree why pick
  local lok=0 rok=0 rmeasured=0 use_remote=0
  local lfree=0 lfrac=1 rfrac=1 lwhy='' rwhy=''
  room_config=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || return 1
  if fm_host_room "$STATE" "$ID" "$room_config"; then
    lfree=$FM_HOST_ROOM_FREE
    lfrac=$(awk -v a="$FM_HOST_ROOM_LOAD" -v b="$FM_HOST_ROOM_LOAD_LIMIT" 'BEGIN { printf "%.2f", a / b }')
    if [ "$lfree" -gt 0 ] && awk -v a="$FM_HOST_ROOM_LOAD" -v b="$FM_HOST_ROOM_LOAD_LIMIT" 'BEGIN { exit !(a < b) }'; then
      lok=1
    else
      lwhy="load $FM_HOST_ROOM_LOAD of $FM_HOST_ROOM_LOAD_LIMIT, $lfree heavy slot(s) free"
    fi
  else
    lwhy=$FM_HOST_ROOM_ERROR
  fi
  rc=0
  out=$("$SCRIPT_DIR/fm-on.sh" "$route" fm-remote-worker-control.sh admit "$ID" "$project" </dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rok=1
    rload=$(printf '%s\n' "$out" | sed -n 's/.* load=\([^ ]*\).*/\1/p')
    rlimit=$(printf '%s\n' "$out" | sed -n 's/.* load_limit=\([^ ]*\).*/\1/p')
    rfree=$(printf '%s\n' "$out" | sed -n 's/.* heavy_free=\([0-9]*\).*/\1/p')
    if [ -n "$rload" ] && [ -n "$rlimit" ] && [ -n "$rfree" ]; then
      rmeasured=1
      rfrac=$(awk -v a="$rload" -v b="$rlimit" 'BEGIN { printf "%.2f", a / b }')
    fi
  else
    rwhy=$(printf '%s\n' "$out" | head -n 1)
    rwhy=${rwhy:-no answer from $host}
  fi
  if [ "$lok" = 1 ] && [ "$rok" = 1 ] && [ "$rmeasured" = 1 ]; then
    if [ "$rfree" -gt "$lfree" ] || { [ "$rfree" -eq "$lfree" ] && awk -v r="$rfrac" -v l="$lfrac" 'BEGIN { exit !(r < l) }'; }; then
      use_remote=1
      why="$host has more room: $rfree free heavy slot(s), load at $rfrac of its limit, against $lfree and $lfrac here"
    else
      why="this machine has more room: $lfree free heavy slot(s), load at $lfrac of its limit, against $rfree and $rfrac on $host"
    fi
  elif [ "$lok" = 1 ] && [ "$rok" = 1 ]; then
    why="$host reported no room figures"
  elif [ "$lok" = 1 ]; then
    why="$host refused: $rwhy"
  elif [ "$rok" = 1 ]; then
    use_remote=1
    why="this machine refused: $lwhy"
  else
    why="neither machine has room: this machine ($lwhy); $host ($rwhy)"
  fi
  pick="this machine"
  [ "$use_remote" = 0 ] || pick=$host
  printf 'machine: %s picked - %s\n' "$pick" "$why" >&2
  [ "$use_remote" = 1 ]
}

spawn_remote_worker() {
  local route=$1 project=$2 host=$3 root home session harness backend brief meta tmp out rc target remote_kind remote_harness remote_session worktree remote_project
  local mode_arg yolo_arg base_arg model_arg effort_arg transition=0 started_row=0 contract token forge=none pr=auto standing_forge standing_pr brief_branch remote_spawn_gen remote_account
  local -a contract_fields launch_args
  [ "${#POS[@]}" -eq 2 ] || { echo "error: remote workers require one project argument" >&2; return 1; }
  case "$project" in ''|*[!A-Za-z0-9._-]*|*..*) echo "error: invalid remote project name" >&2; return 1 ;; esac
  [ "$KIND" != ship ] || [ "$MODE" != local-only ] || { echo "error: local-only work cannot run remotely" >&2; return 1; }
  if [ "$UPSTREAM_CONSENT_SET" -eq 1 ] || [ "$QUOTA_OVERRIDE_SET" -eq 1 ] || [ "$WEIGHT_SET" -eq 1 ]; then
    echo "error: selected launch flags are not supported for remote workers" >&2
    return 1
  fi
  root=$(fm_remote_registry_field "$DATA/remote-homes.md" "$route" root) || return 1
  home=$(fm_remote_registry_field "$DATA/remote-homes.md" "$route" home) || return 1
  session=$(fm_remote_registry_field "$DATA/remote-homes.md" "$route" session) || return 1
  case "$host:$session" in *[!A-Za-z0-9._:-]*) echo "error: invalid remote placement" >&2; return 1 ;; esac
  backend=${BACKEND_ARG:-herdr}
  [ "$backend" = herdr ] || { echo "error: remote worker launch currently requires herdr" >&2; return 1; }
  harness=$HARNESS_ARG
  if [ -z "$harness" ]; then harness=$("$SCRIPT_DIR/fm-harness.sh" crew) || return 1; fi
  case "$harness" in pi|pi-signed) ;; *) echo "error: unverified remote worker harness $harness" >&2; return 1 ;; esac
  brief="$DATA/$ID/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || { echo "error: remote worker brief is unavailable" >&2; return 1; }
  if ! fm_brief_task_content_valid "$brief" || fm_brief_task_placeholders_present "$brief"; then
    echo "error: remote worker task sections are incomplete" >&2
    return 1
  fi
  if fm_brief_intent_address_line "$brief" >/dev/null; then echo "error: remote worker intent has a direct address" >&2; return 1; fi
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    [ -f "$DATA/$ID/dispatch-resolution.json" ] || { echo "error: remote worker requires dispatch resolution" >&2; return 1; }
    if ! jq -e --arg id "$ID" --arg h "$harness" --arg m "$MODEL" --arg e "$EFFORT" --arg a "$CLAUDE_ACCOUNT" --arg override "$DISPATCH_OVERRIDE" '
      .task == $id and (.status | IN("clear","ambiguous","escalate","error","off")) and
      (if .status == "clear" and $override == "" then .profile.harness == $h and ((.profile.model // "") == "" or .profile.model == $m) and ((.profile.effort // "") == "" or .profile.effort == $e) and ((.profile.claude_account // "") == "" or .profile.claude_account == $a) else true end)
    ' "$DATA/$ID/dispatch-resolution.json" >/dev/null 2>&1; then
      echo "error: remote worker dispatch selection is invalid or does not match" >&2
      return 1
    fi
  fi
  if [ "$KIND" = ship ]; then
    contract=$(grep '^Delivery contract: mode=' "$brief" || true)
    case "$contract" in *$'\n'*|'') echo "error: remote worker delivery contract is missing or ambiguous" >&2; return 1 ;; esac
    read -r -a contract_fields <<< "$contract"
    [ "${contract_fields[2]:-}" = "mode=$MODE" ] || { echo "error: remote worker delivery contract does not match" >&2; return 1; }
    for token in "${contract_fields[@]:3}"; do
      case "$token" in forge=*) forge=${token#forge=} ;; pr=*) pr=${token#pr=} ;; shape=*) ;; *) echo "error: unsupported remote delivery field" >&2; return 1 ;; esac
    done
    standing_forge=$("$SCRIPT_DIR/fm-project-mode.sh" --forge "$project") || return 1
    standing_pr=$("$SCRIPT_DIR/fm-project-mode.sh" --pr "$project") || return 1
    [ "$forge" = "${standing_forge:-none}" ] && [ "$pr" = "${standing_pr:-auto}" ] || { echo "error: remote worker forge or PR contract does not match the project" >&2; return 1; }
    fm_forge_valid_for_mode "$forge" "$MODE" fm-spawn || return 1
    fm_base_branch_valid "$BASE_BRANCH" "$MODE" "$forge" fm-spawn || return 1
    if [ "$YOLO" = on ] && { [ "$forge" = gerrit ] || [ "$forge" = external ]; }; then echo "error: remote forge does not support yolo" >&2; return 1; fi
    brief_branch=$(sed -n 's/^Ship branch: //p' "$brief")
    [ "$brief_branch" = "$BRANCH_PREFIX$ID" ] || { echo "error: remote worker branch does not match the brief" >&2; return 1; }
    mode_arg=$MODE; yolo_arg=$YOLO
  else
    mode_arg=-; yolo_arg=-
  fi
  if [ -n "$BASE_BRANCH" ]; then
    fm_brief_base_branches "$brief" | grep -qxF -- "$BASE_BRANCH" || { echo "error: remote worker base branch does not match the brief" >&2; return 1; }
  elif fm_brief_base_branches "$brief" >/dev/null; then
    echo "error: remote worker brief requires a base branch" >&2
    return 1
  fi
  base_arg=${BASE_BRANCH:--}; model_arg=${MODEL:--}; effort_arg=${EFFORT:--}
  SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
  fm_lock_try_acquire "$SPAWN_TASK_LOCK" || { echo "error: another spawn is creating task $ID" >&2; return 1; }
  SPAWN_TASK_LOCK_HELD=1
  meta="$STATE/$ID.meta"
  [ ! -e "$meta" ] && [ ! -L "$meta" ] || { echo "error: task $ID already has metadata" >&2; return 1; }
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    transition=1
    if ! fm_backlog_row_probe "$DATA" "$ID" || ! fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE"; then
      echo "error: task $ID has no dispatchable backlog item" >&2
      return 1
    fi
    [ "$FM_BACKLOG_ROW_STATE" != 'queued no no' ] || started_row=1
  else
    rc=$?
    [ "$rc" -ne 2 ] || { echo "error: backlog is inaccessible: $FM_BACKLOG_TRANSITION_ERROR" >&2; return 1; }
  fi
  out=$("$SCRIPT_DIR/fm-on.sh" "$route" fm-remote-worker-control.sh capabilities </dev/null) || return $?
  [ "$out" = fm-remote-worker-control.v2 ] || { echo "error: remote worker protocol v2 is unavailable (the remote code root is older than this home; update that host before dispatching workers to it)" >&2; return 1; }
  if [ -n "$CLAUDE_ACCOUNT" ]; then
    rc=0
    out=$("$SCRIPT_DIR/fm-on.sh" "$route" fm-remote-worker-control.sh claude-account-check "$harness" "$model_arg" "$CLAUDE_ACCOUNT" </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out" >&2
      case "$out" in
        *'unknown remote worker command'*) echo "error: remote launch refused for task $ID: the host's code root is older than this home and cannot apply --claude-account $CLAUDE_ACCOUNT; update that host before dispatching to it, and nothing was published" >&2; return 1 ;;
      esac
      echo "error: remote launch refused for task $ID: the host cannot launch on Claude account $CLAUDE_ACCOUNT, and nothing was published" >&2
      return 1
    fi
  fi
  rc=0
  out=$("$SCRIPT_DIR/fm-on.sh" "$route" fm-remote-worker-control.sh admit "$ID" "$project" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    case "$out" in
      *'unknown remote worker command'*) echo "error: remote worker protocol v2 is unavailable (the remote code root is older than this home; update that host before dispatching workers to it)" >&2; return 1 ;;
    esac
    if [ "$rc" -eq 75 ]; then
      echo "error: remote launch deferred for task $ID; its backlog item stays queued - dispatch it again once the host has room" >&2
      return 75
    fi
    echo "error: remote launch refused for task $ID: the host could not admit it, and nothing was published" >&2
    return "$rc"
  fi
  SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK" || return 1
  SPAWN_META_LOCK_HELD=1
  tmp="$STATE/.$ID.remote-meta.$$"
  remote_spawn_gen="s$(date +%s).${BASHPID:-$$}.$RANDOM"
  {
    printf 'window=remote:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s/projects/%s\n' "$ID" "$ID" "$home" "$home" "$project"
    printf 'kind=%s\nharness=%s\nmodel=%s\neffort=%s\nspawn_gen=%s\n' "$KIND" "$harness" "${MODEL:-default}" "${EFFORT:-default}" "$remote_spawn_gen"
    if [ "$KIND" = ship ]; then
      printf 'mode=%s\nyolo=%s\nbranch=%s\n' "$MODE" "$YOLO" "$BRANCH_PREFIX$ID"
      [ "$forge" != external ] || printf 'forge=external\n'
    fi
    [ -z "$BASE_BRANCH" ] || printf 'base_branch=%s\n' "$BASE_BRANCH"
    [ -z "$DISPATCH_OVERRIDE" ] || printf 'dispatch_override=%s\n' "$DISPATCH_OVERRIDE"
    [ -z "$CLAUDE_ACCOUNT" ] || printf 'claude_account=%s\n' "$CLAUDE_ACCOUNT"
    printf 'remote_host=%s\nremote_route=%s\nremote_root=%s\nremote_backend=%s\nremote_target=pending\n' "$host" "$route" "$root" "$backend"
  } > "$tmp"
  fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE" || { echo "error: cannot publish remote task record: $FM_BACKLOG_TRANSITION_ERROR" >&2; return 1; }
  if [ "$transition" -eq 1 ] && ! fm_backlog_atomic_transition dispatch "$meta" "$DATA" "$ID" "$STATE"; then
    fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" || true
    echo "error: cannot start backlog item: $FM_BACKLOG_TRANSITION_ERROR" >&2
    return 1
  fi
  rc=0
  launch_args=("$ID" "$project" "$KIND" "$mode_arg" "$yolo_arg" "$BRANCH_PREFIX" "$base_arg" "$harness" "$model_arg" "$effort_arg" "$backend")
  [ -z "$CLAUDE_ACCOUNT" ] || launch_args+=("$CLAUDE_ACCOUNT")
  out=$("$SCRIPT_DIR/fm-on.sh" --stdin "$route" fm-remote-worker-control.sh launch "${launch_args[@]}" < "$brief" 2>&1) || rc=$?
  if [ "$rc" -eq 75 ]; then
    printf '%s\n' "$out" >&2
    if ! fm_backlog_atomic_transition remove "$meta" "task record" "$STATE"; then
      echo "error: remote launch deferred for task $ID, but its pending task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 1
    fi
    if [ "$started_row" -eq 1 ] && ! fm_backlog_mutate "$DATA" reopen "$ID"; then
      echo "error: remote launch deferred for task $ID, but its backlog item could not return to Queued ($FM_BACKLOG_TRANSITION_ERROR); it can be dispatched again as it stands" >&2
      return 1
    fi
    echo "error: remote launch deferred for task $ID; its backlog item stays queued - dispatch it again once the host has room" >&2
    return 75
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    echo "error: remote launch outcome is unconfirmed; task record and backlog are preserved" >&2
    return "$rc"
  fi
  target=$(printf '%s\n' "$out" | sed -n 's/^target=//p')
  remote_session=$(printf '%s\n' "$out" | sed -n 's/^herdr_session=//p')
  remote_kind=$(printf '%s\n' "$out" | sed -n 's/^kind=//p')
  remote_harness=$(printf '%s\n' "$out" | sed -n 's/^harness=//p')
  worktree=$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')
  remote_project=$(printf '%s\n' "$out" | sed -n 's/^project=//p')
  remote_account=$(printf '%s\n' "$out" | sed -n 's/^claude_account=//p')
  case "$target" in "$session":?*) ;; *) echo "error: remote launch returned an invalid target; record preserved" >&2; return 1 ;; esac
  [ "$remote_session" = "$session" ] && [ "$remote_kind" = "$KIND" ] && [ "$remote_harness" = "$harness" ] && [ "$remote_account" = "$CLAUDE_ACCOUNT" ] || { echo "error: remote launch returned inconsistent identity; record preserved" >&2; return 1; }
  case "$worktree:$remote_project" in /*:/*) ;; *) echo "error: remote launch returned invalid project paths; record preserved" >&2; return 1 ;; esac
  {
    printf 'window=remote:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' "$ID" "$ID" "$worktree" "$remote_project"
    printf 'kind=%s\nharness=%s\nmodel=%s\neffort=%s\nspawn_gen=%s\n' "$KIND" "$harness" "${MODEL:-default}" "${EFFORT:-default}" "$remote_spawn_gen"
    if [ "$KIND" = ship ]; then
      printf 'mode=%s\nyolo=%s\nbranch=%s\n' "$MODE" "$YOLO" "$BRANCH_PREFIX$ID"
      [ "$forge" != external ] || printf 'forge=external\n'
    fi
    [ -z "$BASE_BRANCH" ] || printf 'base_branch=%s\n' "$BASE_BRANCH"
    [ -z "$DISPATCH_OVERRIDE" ] || printf 'dispatch_override=%s\n' "$DISPATCH_OVERRIDE"
    [ -z "$CLAUDE_ACCOUNT" ] || printf 'claude_account=%s\n' "$CLAUDE_ACCOUNT"
    printf 'remote_host=%s\nremote_route=%s\nremote_root=%s\nremote_backend=%s\nremote_target=%s\nremote_herdr_session=%s\n' "$host" "$route" "$root" "$backend" "$target" "$session"
  } > "$tmp"
  if ! fm_backend_validate_task_endpoint "$tmp" "$ID"; then
    rm -f -- "$tmp"
    echo "error: remote launch returned an invalid endpoint; record preserved" >&2
    return 1
  fi
  fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE" || { echo "error: remote worker launched but its final route could not be published" >&2; return 1; }
  [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" dispatched "$ID" "$KIND" "$project" "$harness" "$MODEL" || true
  if ! "$SCRIPT_DIR/fm-procevent-remote-feed.sh" ensure-armed "$route" >/dev/null; then
    echo "error: remote worker $ID launched, but its status feed could not be armed; endpoint metadata is preserved" >&2
    return 1
  fi
  printf 'spawned %s kind=%s window=remote:%s remote=%s%s\n' "$ID" "$KIND" "$ID" "$host" "${CLAUDE_ACCOUNT:+ claude_account=$CLAUDE_ACCOUNT}"
}

BACKEND=
HERDR_LEASED=0
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_CONTROL_LOCK=
SPAWN_CONTROL_LOCK_HELD=0
SPAWN_CONTROL_PARENT=0
SPAWN_META_TMP=
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_FRESH_COMMIT_PENDING=0
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
SPAWN_TREEHOUSE_PROJECT_LOCK=
SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
SPAWN_SLOT_CLAIMED=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=
GIT_HOOKS_DIR=
SPAWN_LAUNCH_SENT=0
SPAWN_ENDPOINT_CLOSED=0
SPAWN_HOME_SNAPSHOT=

spawn_fresh_commit_rollback() {
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
    "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}

spawn_abort_cleanup() {
  local status=$?
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] &&
    [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] &&
    [ -n "$SPAWN_META_TMP" ] &&
    [ ! -e "$SPAWN_META_TMP" ] &&
    [ ! -L "$SPAWN_META_TMP" ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
      "$RELAUNCH_REPLACEMENT_HARNESS" \
      "$RELAUNCH_REPLACEMENT_WT" \
      "$RELAUNCH_REPLACEMENT_STATE" \
      "$ID" \
      "$KIND"; then
      echo "warning: could not remove replacement wiring after aborted relaunch of $ID" >&2
    fi
    if [ -n "$RELAUNCH_REPLACEMENT_BUSY_GEN" ]; then
      if ! "$FM_ROOT/bin/fm-busy-event.sh" retire \
        "$RELAUNCH_REPLACEMENT_STATE" "$ID" \
        --gen "$RELAUNCH_REPLACEMENT_BUSY_GEN"; then
        echo "warning: could not retire replacement busy generation after aborted relaunch of $ID" >&2
      fi
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] &&
    [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    if fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE"; then
      SPAWN_ENDPOINT_CLOSED=1
    fi
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    if ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
  fi
  # A durable Herdr lease outlives the pane, unlike the process lease the
  # interactive command used to take, so an abort that leaves no record returns
  # it, whether or not the launch was sent. Only a pane Herdr reports gone and a
  # copy with no uncommitted work prove nothing is left to inspect there; any
  # other keeps the lease and names the command, as the pane used to hold the
  # slot for the operator.
  if [ "$HERDR_LEASED" = 1 ] && [ "$status" -ne 0 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    HERDR_LEASED=0
    local herdr_slot_status
    if [ "$SPAWN_ENDPOINT_CLOSED" = 1 ] && fm_backend_herdr_endpoint_confirmed_gone "${T:-}" &&
      herdr_slot_status=$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null) &&
      [ -z "$herdr_slot_status" ] &&
      (cd "$PROJ_ABS" && treehouse return --force "$WT") >/dev/null 2>&1; then
      :
    else
      echo "warning: the worktree $WT stays leased to $ID after the failed spawn; once inspected, run 'treehouse return --force $WT' from $PROJ_ABS" >&2
    fi
  fi
  # A spawn that aborts after claiming its slot but before its record survives
  # must not leave a claim naming a task no record describes. The release is a
  # read-then-remove, so it runs only while the project lock that wrote the
  # claim is still held (aborts before metadata publication); a later abort has
  # already released that lock and leaves the claim for the next spawn's
  # atomic replacement rather than racing it. The release itself never removes
  # another task's claim.
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] &&
    fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    SPAWN_SLOT_CLAIMED=0
    if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
    else
      echo "warning: leaving task $ID's slot claim on $WT in place; the Treehouse project lock is no longer held, so the next spawn's claim replaces it" >&2
    fi
  fi
  if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
    fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
  fi
  if [ "$SPAWN_CONTROL_LOCK_HELD" = 1 ]; then
    SPAWN_CONTROL_LOCK_HELD=0
    fm_lock_release "$SPAWN_CONTROL_LOCK" || true
  fi
  [ -z "$SPAWN_META_TMP" ] || rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ -n "$SPAWN_HOME_SNAPSHOT" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    rm -f "$SPAWN_HOME_SNAPSHOT" 2>/dev/null || true
  fi
  # The per-id spawn lock is retaken so a concurrent spawn of the same id, which
  # reinstalls this hooks dir, is never undone. A launched agent whose endpoint
  # was not closed may still be committing, so it keeps its hooks.
  if [ "$status" -ne 0 ] && [ -n "$GIT_HOOKS_DIR" ] &&
    { [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; } &&
    fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    if [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
      chmod u+w "$GIT_HOOKS_DIR" 2>/dev/null || true
      rm -rf "$GIT_HOOKS_DIR" 2>/dev/null || true
    fi
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  return "$status"
}
trap spawn_abort_cleanup EXIT

# One lock per live Herdr session/socket, shared across all homes, so spawns
# from different homes serialize without writing another home's state directory.
#
# Default mode is one BOUNDED attempt. A clean create uses that default and
# falls back to the ordinary flat layout on contention. An exact resume also
# defaults to the bounded attempt and hard-refuses on contention (it does not
# degrade flat). Passing mode `wait` makes this call WAIT for the lock instead
# (`fm_lock_acquire_wait`, the same unbounded-wait idiom this file already uses
# for its other fleet-shared locks). Only the recovery path under the explicit
# --herdr-resume-lock-wait opt-in passes `wait`, so unbounded blocking on a
# third-party session lock never becomes the default for every caller.
# Dead-owner reclaim inside `fm_lock_try_acquire` still bounds a wait against a
# holder that crashed mid-hold.
spawn_herdr_presentation_order_lock_acquire() {
  local session=${1:-} mode=${2:-} max_attempts=${3:-50} attempt lock_path
  [ -n "$session" ] || session=$(fm_backend_herdr_session)
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  HERDR_PRESENTATION_ORDER_LOCK="$lock_path"
  if [ "$mode" = wait ]; then
    fm_lock_acquire_wait "$HERDR_PRESENTATION_ORDER_LOCK"
    HERDR_PRESENTATION_ORDER_LOCK_HELD=1
    return 0
  fi
  attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if fm_lock_try_acquire "$HERDR_PRESENTATION_ORDER_LOCK"; then
      HERDR_PRESENTATION_ORDER_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

clear_relaunch_harness_wiring() {
  local harness=$1 wt=$2 state=$3 id=$4 kind=${5-} token_path token auth_path path
  # A raw launch records its command basename, so resolve that to the adapter first.
  harness=$(fm_control_harness_family "$harness") || harness=
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state" "$id") || return 1
  token=
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token <"$token_path" || [ -n "$token" ] || return 1
  fi
  auth_path=$(fm_control_harness_turnend_auth_path "$harness" "$token") || return 1
  if [ -n "$auth_path" ]; then
    rm -f -- "$auth_path" || return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_paths "$harness" "$wt" "$state" "$id" "$kind")
EOF
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf -- "$path" || return 1
  done <<EOF
$(fm_control_harness_wiring_dirs "$harness" "$state" "$id")
EOF
}

spawn_herdr_presentation_order_lock_release() {
  [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ] || return 0
  HERDR_PRESENTATION_ORDER_LOCK_HELD=0
  fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
}

# A relaunch rebind may project only once the task's previous journal is
# retired, and only an orphan of its proven-gone endpoint may be retired.
# Returns 1 after a warning when the journal still names something else.
spawn_herdr_rebind_journal_retire() {  # <session>
  local session=$1
  [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ] || return 0
  if fm_backend_herdr_projection_journal_orphaned \
    "$HERDR_PRESENTATION_JOURNAL" "$ID" "$session" "$RELAUNCH_TARGET" &&
    rm -f "$HERDR_PRESENTATION_JOURNAL"; then
    return 0
  fi
  echo "warning: herdr presentation journal for $ID names a projected workspace other than its gone endpoint; leaving it untouched and using the ordinary flat layout without projection" >&2
  return 1
}

# Project one task endpoint into its own disposable presentation workspace in
# <session>, opened in <cwd>, under the exact parent workspace of
# <launcher-pane> (empty for a launcher outside Herdr, whose parent is the
# home's labelled workspace if one exists, else none). Sets HERDR_PROJECTED=1
# and the endpoint ids, or leaves HERDR_PROJECTED untouched after a warning when
# the ordinary flat layout must be used instead. A hard failure exits.
# Expects HERDR_LABEL_HOME, HERDR_PARENT_LABEL and HERDR_PRESENTATION_JOURNAL.
spawn_herdr_project_task() {  # <session> <cwd> <launcher-pane> [project-path]
  local session=$1 cwd=$2 launcher_pane=$3 project_path=${4:-} launcher_status parent_workspace projection_id projection_label home_id order_key
  if ! fm_backend_herdr_server_ensure "$session"; then
    echo "warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection" >&2
    return 0
  fi
  if [ "${FM_BACKEND_HERDR_PRESENTATION_PREFERENCE:-default}" = default ] &&
    ! fm_backend_herdr_presentation_default_supported "$STATE" "$session"; then
    return 0
  fi
  if ! spawn_herdr_presentation_order_lock_acquire "$session"; then
    echo "warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection" >&2
    return 0
  fi
  if [ "$RELAUNCH_REBIND" -eq 1 ] && ! spawn_herdr_rebind_journal_retire "$session"; then
    spawn_herdr_presentation_order_lock_release
    return 0
  fi
  # The projected child is placed and bound UNDER this launcher's exact
  # parent workspace. A launcher with no herdr ancestry (a remote execution
  # home) has no pane to inherit, so its parent is the home's own labelled
  # workspace when one already exists. None is created for it: a parent made
  # only to head projected rows would hold nothing but Herdr's seeded idle
  # shell, so without one the projected workspace stays top-level. A
  # claimed-but-broken identity refuses here rather than projecting under a
  # guessed parent.
  set +e
  HERDR_PANE_ID=$launcher_pane fm_backend_herdr_launcher_identity "$session"
  launcher_status=$?
  set -e
  case "$launcher_status" in
  0) parent_workspace=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID ;;
  2)
    if ! parent_workspace=$(fm_backend_herdr_home_workspace_existing "$session"); then
      echo "warning: herdr presentation parent is unreadable or ambiguous; using the ordinary flat layout without projection" >&2
      spawn_herdr_presentation_order_lock_release
      return 0
    fi
    ;;
  *)
    spawn_herdr_presentation_order_lock_release
    exit 1
    ;;
  esac
  projection_id=$(fm_backend_herdr_projection_journal_create "$STATE" "$ID") || exit 1
  projection_label=$(fm_backend_herdr_projection_workspace_label "$ID" "$projection_id")
  if ! FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_create_task \
    "$cwd" "$projection_label" "$W" "$session"; then
    if [ "${FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE:-0}" = 1 ]; then
      HERDR_PROJECTION_ABORT_CLEANUP=1
      HERDR_PROJECTION_ABORT_SESSION=$FM_BACKEND_HERDR_PROJECTION_SESSION
      HERDR_PROJECTION_ABORT_TASK_PANE=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
      HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
    fi
    exit 1
  fi
  HERDR_PROJECTED=1
  HERDR_SES=$FM_BACKEND_HERDR_PROJECTION_SESSION
  HERDR_WORKSPACE_ID=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
  HERDR_SEEDED_DEFAULT_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
  HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
  HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
  HERDR_PROJECTION_ABORT_CLEANUP=1
  HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
  HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
  HERDR_PROJECTION_ABORT_SEEDED_PANE=$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
  # Opt-in project groups (docs/herdr-backend.md "Project groups"): an empty
  # key keeps the block-end placement. Off costs one file test.
  order_key=
  [ -z "$project_path" ] || [ ! -e "$CONFIG/herdr-project-groups" ] || order_key=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-herdr-groups.sh" order-key "$ID" "$project_path" 2>/dev/null) || order_key=
  [ -z "$parent_workspace" ] || fm_backend_herdr_projection_order_best_effort \
    "$HERDR_SES" "$HERDR_WORKSPACE_ID" "$HERDR_PARENT_LABEL" "$parent_workspace" "$order_key"
  home_id=$(fm_backend_herdr_projection_home_identity "$HERDR_LABEL_HOME" 2>/dev/null || true)
  if [ -n "$home_id" ] &&
    fm_backend_herdr_projection_live_binding_matches \
      "$HERDR_SES" "$projection_id" "$HERDR_WORKSPACE_ID" \
      "$HERDR_TAB_ID" "$HERDR_PANE_ID" "$parent_workspace" \
      "$HERDR_PARENT_LABEL" "$projection_label" "$W" &&
    fm_backend_herdr_projection_journal_bind \
      "$HERDR_PRESENTATION_JOURNAL" "$ID" "$home_id" "$HERDR_SES" \
      "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID" \
      "$parent_workspace" "$HERDR_PARENT_LABEL" "$projection_label" "$W"; then
    return 0
  fi
  echo "warning: herdr presentation could not publish an exact restart binding; this task will use flat fallback after a restart" >&2
  return 0
}

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "$RELAUNCH" -eq 1 ] && [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ]; then
  echo "error: --relaunch is single-task only; relaunch each task explicitly" >&2
  exit 1
fi
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac then
  if [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$CLAUDE_ACCOUNT" ] || shared_args+=(--claude-account "$CLAUDE_ACCOUNT")
  [ "$QUOTA_OVERRIDE_SET" -eq 0 ] || shared_args+=(--quota-override-reason "$QUOTA_OVERRIDE_REASON")
  [ -z "$DISPATCH_OVERRIDE" ] || shared_args+=(--dispatch-override "$DISPATCH_OVERRIDE")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  # One delivery contract applies to every pair in a batch, exactly like the shared
  # harness. Each pair still re-validates it against its own brief, so a batch
  # spanning several modes is two invocations rather than a silent mixed dispatch.
  [ "$MODE_SET" -eq 0 ] || shared_args+=(--mode "$MODE")
  [ "$YOLO_SET" -eq 0 ] || shared_args+=(--yolo "$YOLO")
  [ "$BRANCH_PREFIX_SET" -eq 0 ] || shared_args+=(--branch-prefix "$BRANCH_PREFIX")
  [ "$BASE_BRANCH_SET" -eq 0 ] || shared_args+=(--base-branch "$BASE_BRANCH")
  [ "$HERDR_RESUME_LOCK_WAIT" -eq 0 ] || shared_args+=(--herdr-resume-lock-wait)
  for pair in "${POS[@]}"; do
    case "$pair" in
    *=*) : ;;
    *)
      echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2
      rc=2
      continue
      ;;
    esac
    pair_args=("${pair%%=*}" "${pair#*=}" "${shared_args[@]+"${shared_args[@]}"}")
    [ "$KIND" != scout ] || pair_args+=(--scout)
    pair_rc=0
    FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair_args[@]}" || pair_rc=$?
    if [ "$pair_rc" -eq "$FM_PROJECT_CAPACITY_DEFER_EXIT" ]; then
      echo "batch: DEFERRED ${pair%%=*} (${pair#*=}) - its project is at capacity, so it stays queued" >&2
      [ "$rc" -ne 0 ] || rc=$FM_PROJECT_CAPACITY_DEFER_EXIT
    elif [ "$pair_rc" -ne 0 ]; then
      echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2
      rc=1
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || {
  echo "error: invalid task id" >&2
  exit 2
}
if [ "$RELAUNCH" -eq 0 ] && [ "$KIND" = ship ]; then
  BRANCH="$BRANCH_PREFIX$ID"
  if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
    echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
    exit 1
  fi
fi
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
elif [ "$RELAUNCH" -eq 1 ]; then
  echo "error: spawn refused: state directory does not exist at $STATE" >&2
  exit 1
fi
# The branch may relaunch a worker, but only MAIN may start new work.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ "$RELAUNCH" -ne 1 ]; then
  fm_lease_forbid_branch "new-task spawn (fm-spawn)"
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_CONTROL_LOCK="$STATE/.control-$ID.lock"
  control_owner=$(cat "$SPAWN_CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ "$control_owner" = "$PPID" ] && fm_pid_alive "$control_owner"; then
    SPAWN_CONTROL_PARENT=1
  elif [ "$(fm_lease_actor)" = branch ]; then
    # Role partition refinement: branch recovery relaunches only through the
    # fm-control transaction that owns the control lock, never by invoking
    # this entrypoint directly (contract: bin/fm-lease-lib.sh).
    echo "error: relaunch (fm-spawn) refused - the supervision branch must relaunch through fm-control" >&2
    exit "$FM_LEASE_REFUSE_EXIT"
  elif fm_lock_try_acquire "$SPAWN_CONTROL_LOCK"; then
    SPAWN_CONTROL_LOCK_HELD=1
  else
    echo "error: another lifecycle action is already running for task $ID" >&2
    exit 1
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  mkdir -p "$STATE" || {
    echo "error: could not create parent state directory" >&2
    exit 1
  }
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  # A FRESH spawn changes which tasks this home has, so it must not interleave
  # with a forced teardown that has already enumerated that set: a record
  # published inside the enumerate-then-remove window is invisible to the
  # teardown's per-task preflight but visible to its cleanup, and gets mutated
  # while never lifecycle-locked (bin/fm-wake-lib.sh's fm_task_set_lock_path
  # owns the evidence; bin/fm-teardown.sh holds the same lock from enumeration
  # through cleanup). Taken before this task's own locks, matching the
  # acquisition order documented there, and held through publication.
  #
  # A relaunch is exempt: it republishes a task that already exists, so it is
  # already covered by that task's control lock, which the teardown preflight
  # tests.
  #
  # Refusing rather than waiting is the fail-closed direction: the home may be
  # moments from removal, so there is nothing worth waiting for.
  SPAWN_TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
    echo "error: could not resolve the task-set lock for $STATE" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TASK_SET_LOCK"; then
    case "$(fm_lock_role "$SPAWN_TASK_SET_LOCK" 2>/dev/null || true)" in
      task-spawn)
        echo "error: this home's task set is locked by another spawn; refusing to create task $ID rather than racing it" >&2
        ;;
      forced-teardown)
        echo "error: this home's task set is locked by a forced teardown; refusing to create task $ID rather than racing it" >&2
        ;;
      *)
        echo "error: this home's task set is locked by another operation; refusing to create task $ID rather than racing it" >&2
        ;;
    esac
    exit 1
  fi
  if ! fm_lock_set_role "$SPAWN_TASK_SET_LOCK" task-spawn; then
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
    echo "error: could not record task-set lock holder for spawn of $ID" >&2
    exit 1
  fi
  SPAWN_TASK_SET_LOCK_HELD=1
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$LOCAL_OVERRIDE" -eq 0 ] && [ "${#POS[@]}" -ge 2 ]; then
  remote_project=${POS[1]##*/}
  remote_placement=$("$SCRIPT_DIR/fm-project-mode.sh" --placement "$remote_project") || exit 1
  if [ -n "$remote_placement" ]; then
    remote_host=$(fm_remote_registry_field "$DATA/remote-homes.md" "$remote_placement" host 2>/dev/null || true)
    [ -n "$remote_host" ] || { echo "error: no execution-home route for $remote_placement" >&2; exit 1; }
    if [ -d "$PROJECTS/$remote_project" ] && ! spawn_choose_machine "$remote_placement" "$remote_host" "$remote_project"; then
      remote_placement=
    fi
  fi
  if [ -n "$remote_placement" ]; then
    remote_rc=0
    spawn_remote_worker "$remote_placement" "$remote_project" "$remote_host" || remote_rc=$?
    [ "$remote_rc" -eq 75 ] && [ -d "$PROJECTS/$remote_project" ] || exit "$remote_rc"
    if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
      SPAWN_TASK_LOCK_HELD=0
      fm_lock_release "$SPAWN_TASK_LOCK" || true
    fi
    echo "machine: this machine picked - $remote_host deferred the launch after the room check; launching here" >&2
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  if [ "$BACKEND_SET" -eq 1 ]; then
    BACKEND=$BACKEND_ARG
  else
    fm_backend_resolve
    BACKEND=$FM_BACKEND_RESOLVED
  fi
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  fm_backend_runtime_check "$BACKEND" || exit 1
fi
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
  echo "error: another spawn is already creating task $ID" >&2
  exit 1
fi
SPAWN_TASK_LOCK_HELD=1
PROJ=
ARG3=
RAW_LAUNCH=0

# --relaunch adoption: every identity axis comes from the task's own validated
# durable record, never from the command line, so a relaunch can only ever
# re-launch the task it names. The endpoint identity check is the same shared
# validation teardown uses, so a malformed, ambiguous, or foreign record
# refuses here exactly as it refuses there.
RELAUNCH_PRIOR_HARNESS=
# 1 when the recorded endpoint is authoritatively gone and this relaunch must
# create a fresh one for the task rather than adopt its recorded address.
RELAUNCH_REBIND=0
if [ "$RELAUNCH" -eq 1 ]; then
  [ "${#POS[@]}" -eq 1 ] || {
    echo "error: --relaunch takes the task id only; its project or home comes from the task's own record" >&2
    exit 1
  }
  RELAUNCH_META="$STATE/$ID.meta"
  if [ ! -e "$RELAUNCH_META" ] && [ ! -L "$RELAUNCH_META" ]; then
    echo "error: --relaunch needs an existing task record; no $RELAUNCH_META" >&2
    exit 1
  fi
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  SPAWN_META_LOCK=$(fm_meta_lock_path "$RELAUNCH_META") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
  fm_backlog_record_present "$RELAUNCH_META" "task record" "$STATE" || {
    echo "error: --relaunch refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
  fm_backend_validate_task_endpoint "$RELAUNCH_META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  RELAUNCH_TARGET=$FM_BACKEND_VALIDATED_TARGET
  fm_backend_validate_spawn "$BACKEND" || exit 1
  fm_backend_source "$BACKEND" || exit 1
  # A relaunch must PROVE the previous agent is gone before it launches another
  # one into the same endpoint, and only a backend with a recovery-grade
  # classifier can (bin/fm-control-lib.sh owns that capability table).
  fm_control_backend_state_verified "$BACKEND" || {
    echo "error: backend '$BACKEND' has no recovery-grade agent-state classifier, so a relaunch cannot prove the previous agent exited; refusing rather than risking two agents in one endpoint" >&2
    exit 1
  }
  # The same table refuses a backend that cannot host a REPLACEMENT at all:
  # a T3 thread keeps its conversation, so a turn or a provider change on it
  # continues the same agent instead of launching a new one.
  fm_control_backend_relaunch_supported "$BACKEND" || {
    echo "error: backend '$BACKEND' cannot launch a replacement agent into an existing endpoint (a T3 thread keeps its conversation, so a turn or a provider change on it continues the same agent); refusing to relaunch $ID" >&2
    exit 1
  }
  # Two states are agent-free, and both license a relaunch:
  #   dead    - the endpoint exists and confidently holds no agent. The
  #             endpoint is ADOPTED, so the task keeps its exact address.
  #   missing - the endpoint itself is gone. There is no endpoint AND therefore
  #             no agent, so a relaunch cannot adopt it: it CREATES a fresh
  #             endpoint in the recorded worktree and the published record
  #             rebinds to it.
  # `missing` is NOT one state, and that is what the duplicate-agent argument
  # turns on. fm_backend_agent_state's per-backend `missing` conflates "the
  # endpoint was DESTROYED" with "the endpoint is UNREACHABLE from here right
  # now", and an unreachable endpoint can still hold the live agent this
  # relaunch would duplicate. So absence is PROVEN before it may rebind, never
  # inferred from a failed read:
  #   herdr - the recorded session's server is started, and the recorded pane is
  #           RE-READ through that session's own socket. `dead` means the pane
  #           survived the restart and is adopted after all; `alive` means the
  #           agent came back and refuses; only a second `missing` proves the
  #           pane itself did not survive.
  # Every transient or self-contradicting read stays `unreadable`/`ambiguous`
  # and refuses as it always did (bin/fm-backend.sh's fm_backend_agent_state
  # owns that vocabulary). The proof itself lives in one place for the whole
  # control plane - fm_control_endpoint_absence_verdict - so `exit` and
  # `relaunch` cannot reach two different answers about one endpoint.
  RELAUNCH_STATE=$(fm_backend_agent_state "$BACKEND" "$RELAUNCH_TARGET")
  if fm_control_absence_recheck_applies "$BACKEND" "$RELAUNCH_STATE"; then
    RELAUNCH_ABSENCE=$(fm_control_endpoint_absence_verdict "$BACKEND" "$RELAUNCH_TARGET" "$RELAUNCH_META")
    case "${RELAUNCH_ABSENCE%%$'\t'*}" in
      gone) RELAUNCH_STATE=missing ;;
      dead) RELAUNCH_STATE=dead ;;
      alive) RELAUNCH_STATE=alive ;;
      *)
        echo "error: task $ID's recorded endpoint $RELAUNCH_TARGET reads '$RELAUNCH_STATE', but ${RELAUNCH_ABSENCE#*$'\t'}. An endpoint that cannot be proven absent may still hold a live agent on this task's worktree; refusing rather than launching a second agent into it" >&2
        exit 1
        ;;
    esac
  fi
  case "$RELAUNCH_STATE" in
    dead)
      # The launch is typed into the adopted pane, so a live agent the
      # classifier missed would receive it as a prompt.
      if ! RELAUNCH_PANE_REFUSAL=$(fm_backend_launch_pane_refusal "$BACKEND" "$RELAUNCH_TARGET"); then
        echo "error: task $ID's endpoint $RELAUNCH_TARGET reads 'dead', but $RELAUNCH_PANE_REFUSAL; refusing to type a launch command into it, which could start a second agent inside the first" >&2
        exit 1
      fi
      ;;
    missing) RELAUNCH_REBIND=1 ;;
    *)
      echo "error: task $ID's endpoint reads '$RELAUNCH_STATE'; a relaunch requires a positively agent-free endpoint (stop the agent first with bin/fm-control.sh $ID exit)" >&2
      exit 1
      ;;
  esac
  RELAUNCH_PRIOR_HARNESS=$(fm_meta_get "$RELAUNCH_META" harness)
  KIND=$(fm_meta_get "$RELAUNCH_META" kind)
  [ -n "$KIND" ] || KIND=ship
  case "$KIND" in ship|scout) ;; *) echo "error: task $ID has an unsupported recorded kind" >&2; exit 1 ;; esac
  MODE=$(fm_meta_get "$RELAUNCH_META" mode)
  YOLO=$(fm_meta_get "$RELAUNCH_META" yolo)
  UPSTREAM_CONSENT=$(fm_meta_get "$RELAUNCH_META" upstream_consent)
  if [ "$KIND" = ship ]; then
    BRANCH=$(fm_meta_get "$RELAUNCH_META" branch)
    [ -n "$BRANCH" ] || BRANCH="fm/$ID"
    if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
      echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
      exit 1
    fi
  fi
  RELAUNCH_WT=$(fm_meta_get "$RELAUNCH_META" worktree)
  [ -n "$RELAUNCH_WT" ] && [ -d "$RELAUNCH_WT" ] || {
    echo "error: task $ID's recorded worktree '${RELAUNCH_WT:-none}' is missing; refusing to relaunch without the local copy its work lives in" >&2
    exit 1
  }
  RELAUNCH_WT_OTHER_RC=0
  fm_worktree_other_record "$STATE" "$RELAUNCH_META" "$RELAUNCH_WT" || RELAUNCH_WT_OTHER_RC=$?
  case "$RELAUNCH_WT_OTHER_RC" in
    0)
      echo "error: task $ID's recorded worktree $RELAUNCH_WT is also task $FM_WORKTREE_OTHER_ID's recorded $FM_WORKTREE_OTHER_FIELD ($FM_WORKTREE_OTHER_META); refusing to relaunch $ID into a copy that may hold $FM_WORKTREE_OTHER_ID's work" >&2
      exit 1
      ;;
    1) ;;
    *)
      echo "error: could not prove no other task records task $ID's worktree $RELAUNCH_WT ($FM_LOCAL_FIRSTMATE_ERROR); refusing to relaunch" >&2
      exit 1
      ;;
  esac
  # A worker must come back in its own disposable worktree, never in a
  # primary home or a repository's primary checkout: refuse
  # rather than fall back to wherever the restored pane happens to sit.
  relaunch_wt_real=$(cd "$RELAUNCH_WT" 2>/dev/null && pwd -P) || relaunch_wt_real=$RELAUNCH_WT
  relaunch_primary=
  for relaunch_cand in "$FM_HOME" "$FM_ROOT"; do
    relaunch_cand_real=$(cd "$relaunch_cand" 2>/dev/null && pwd -P) || continue
    [ "$relaunch_wt_real" = "$relaunch_cand_real" ] && relaunch_primary=$relaunch_cand
  done
  if [ -z "$relaunch_primary" ]; then
    # Probe the directory's own layout: an inherited GIT_DIR naming a linked
    # worktree with GIT_WORK_TREE naming the primary checkout would otherwise
    # make the two answers differ and pass the primary checkout.
    relaunch_gdc=$(
      unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
        GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
        GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT
      git -C "$RELAUNCH_WT" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null
    ) || relaunch_gdc=
    relaunch_gd=${relaunch_gdc%%$'\n'*}
    relaunch_gc=${relaunch_gdc#*$'\n'}
    [ -z "$relaunch_gd" ] || [ "$relaunch_gd" != "$relaunch_gc" ] || relaunch_primary="its repository's primary checkout"
  fi
  [ -z "$relaunch_primary" ] || {
    echo "error: task $ID's recorded worktree '$RELAUNCH_WT' is the primary home or checkout ($relaunch_primary), not an isolated task worktree; refusing to relaunch a worker there" >&2
    exit 1
  }
  PROJ=$(fm_meta_get "$RELAUNCH_META" project)
  [ -n "$PROJ" ] || {
    echo "error: task $ID has no recorded project; refusing to relaunch" >&2
    exit 1
  }
  if [ "$BACKEND" = herdr ]; then
    # fm-spawn uses HERDR_PANE_ID for the TASK's pane, while the herdr adapter
    # reads that SAME name as the pane THIS process is itself running in
    # (fm_backend_herdr_launcher_identity). The record is about to overwrite it,
    # so keep what herdr actually injected: a rebind still has to prove its own
    # launcher identity, and a task's recorded pane is not it.
    RELAUNCH_LAUNCHER_PANE_ID=${HERDR_PANE_ID:-}
    HERDR_SES=$(fm_meta_get "$RELAUNCH_META" herdr_session)
    HERDR_WORKSPACE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_workspace_id)
    HERDR_TAB_ID=$(fm_meta_get "$RELAUNCH_META" herdr_tab_id)
    HERDR_PANE_ID=$(fm_meta_get "$RELAUNCH_META" herdr_pane_id)
  fi
  # With no explicit harness, a relaunch reuses the harness already recorded
  # for this task. It must NOT fall through to the fresh-spawn config
  # resolution, which would silently move an existing task onto whatever the
  # crew default currently says. Choosing a different harness is the caller's
  # explicit decision, made with --harness.
  ARG3=${HARNESS_ARG:-$RELAUNCH_PRIOR_HARNESS}
  [ -n "$ARG3" ] || {
    echo "error: task $ID has no recorded harness; pass --harness to relaunch it" >&2
    exit 1
  }
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

spawn_heavy_queue_path() {
  local dir skip=
  # A sandboxed worker cannot reach pueue, so a stand-in it calls would fail
  # instead of running the tool.
  if [ -n "${FM_SANDBOX_PROFILE:-}" ]; then
    skip="the worker is sandboxed"
  elif ! command -v orc >/dev/null 2>&1; then
    skip="orc is not installed"
  elif ! dir=$(fm_run_timed "${FM_HEAVY_PATH_TIMEOUT:-20}" orc heavy path </dev/null 2>/dev/null); then
    skip="\`orc heavy path\` failed"
  else
    case "$dir" in
      /*) ;;
      *) dir= ;;
    esac
    case "$dir" in *:*|*$'\n'*) dir= ;; esac
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    skip="\`orc heavy path\` printed no folder"
  fi
  echo "note: $ID launches without the heavy queue on its PATH: $skip" >&2
  return 1
}

resolve_pi_executable() {
  local candidate dir
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
  /*) printf '%s\n' "$candidate" ;;
  *)
    dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$dir" "$(basename "$candidate")"
    ;;
  esac
}

# Pi's CLI surface is version-dependent, so probe the resolved executable's help
# before composing the session-scoped project trust flag; an absent or
# inconclusive probe omits it so older Pi versions can still spawn. Any
# not-yet-trusted launch directory holding project-local Pi resources gates Pi
# behind "Trust project folder?" on first launch; --approve trusts that launch
# cwd for the run without rewriting ~/.pi/agent/trust.json.
pi_supports_approve() {
  local executable=$1 help
  help=$("$executable" --help 2>&1) || return 1
  # Pi prints "--approve, -a"; allow comma (and any non-token char) after the name.
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--approve([^[:alnum:]_-]|$)'
}

launch_template() {
  local harness=$1
  # shellcheck disable=SC2016  # $(...) expands in the worker pane, not here
  case "$harness" in
  pi | pi-signed)
    printf '%s' '__PIBIN____PIAPPROVE____PIEXCLUDE__'
    printf '%s' ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
    ;;
  *) return 1 ;;
  esac
}

case "$ARG3" in
*' '*) # raw launch command (unverified-adapter escape hatch)
  RAW_LAUNCH=1
  LAUNCH=$ARG3
  HARNESS=""
  for word in $LAUNCH; do
    case "$word" in [A-Za-z_]*=*) continue ;; *)
      HARNESS=$(basename "$word")
      break
      ;;
    esac
  done
  ;;
'')
  # The crew harness applies only when no dispatch profile file is active.
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
  harness_src='config/crew-harness'
  LAUNCH=$(launch_template "$HARNESS") || {
    echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2
    exit 1
  }
  ;;
*)
  HARNESS=$ARG3
  LAUNCH=$(launch_template "$HARNESS") || {
    echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2
    exit 1
  }
  ;;
esac

case "$DISPATCH_OVERRIDE" in *[![:print:]]*) echo 'error: --dispatch-override must be a printable reason' >&2; exit 1 ;; esac
DISPATCH_RECORD="$DATA/$ID/dispatch-resolution.json"
dispatch_status='' selected_account=''
if [ "$RELAUNCH" -eq 0 ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
  if [ ! -e "$DISPATCH_RECORD" ]; then
    echo "error: config/crew-dispatch.json is active and task $ID has no recorded dispatch resolution; run bin/fm-dispatch-resolve.sh $DATA/$ID/brief.md --project <name> first" >&2
    exit 1
  fi
  dispatch_fields=$(jq -r --arg id "$ID" '
    select(.task == $id and (.status | IN("clear", "ambiguous", "escalate", "error", "off"))
      and (if .status == "clear" then (.profile.harness | type) == "string" and .profile.harness != "" else true end))
    | .status, (.profile.harness // ""), (.profile.model // ""), (.profile.effort // ""), (.profile.claude_account // "")' "$DISPATCH_RECORD" 2>/dev/null) || dispatch_fields=
  { read -r dispatch_status; read -r selected_harness; read -r selected_model; read -r selected_effort; read -r selected_account; } <<<"$dispatch_fields" || true
  if [ -z "$dispatch_status" ]; then
    echo "error: malformed dispatch resolution $DISPATCH_RECORD for task $ID; rerun bin/fm-dispatch-resolve.sh $DATA/$ID/brief.md --project <name>" >&2
    exit 1
  fi
  if [ "$dispatch_status" = clear ] && [ -z "$DISPATCH_OVERRIDE" ] \
    && { [ "$RAW_LAUNCH" -eq 1 ] || [ "$HARNESS" != "$selected_harness" ] \
      || { [ -n "$selected_model" ] && [ "${MODEL:-}" != "$selected_model" ]; } \
      || { [ -n "$selected_effort" ] && [ "${EFFORT:-}" != "$selected_effort" ]; }; }; then
    echo "error: launch flags do not match the clear dispatch selection --harness $selected_harness${selected_model:+ --model $selected_model}${selected_effort:+ --effort $selected_effort} recorded in $DISPATCH_RECORD; pass those flags with no raw launch command, or record this task's override with --dispatch-override <reason>" >&2
    exit 1
  fi
fi

# config/crew-exclude-tools (header above): refuse before worker provisioning
# if this launch cannot honor the list.
EXCLUDE_TOOLS=
EXCLUDE_TOOLS=$(fm_exclude_tools_check "$HARNESS" "$RAW_LAUNCH" "$CONFIG") || exit 1

if [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; then
  PI_BIN=$(resolve_pi_executable "$HARNESS") || {
    echo "error: $HARNESS executable not found on PATH; install it or select a different verified harness" >&2
    exit 1
  }
  # Session-only --approve for the launch cwd; never a parent path or a trust-store rewrite.
  PI_APPROVE=
  if pi_supports_approve "$PI_BIN"; then
    PI_APPROVE=' --approve'
  fi
  LAUNCH=${LAUNCH//__PIAPPROVE__/$PI_APPROVE}
  PI_EXCLUDE=
  [ -z "$EXCLUDE_TOOLS" ] || PI_EXCLUDE=" --exclude-tools $(shell_quote "$EXCLUDE_TOOLS")"
  LAUNCH=${LAUNCH//__PIEXCLUDE__/$PI_EXCLUDE}
  LAUNCH="FM_PI_HARNESS=$HARNESS $LAUNCH"
fi

fm_backend_validate_harness "$BACKEND" "$HARNESS" || exit 1
# Ultra is an explicit native capability, never a Pi thinking-level alias.
# Validate the fully resolved profile before worktree or endpoint provisioning.
if [ "$EFFORT" = ultra ]; then
  "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$HARNESS" "$MODEL" "$EFFORT" || exit 1
  [ "$RAW_LAUNCH" = 0 ] || {
    echo "error: --effort ultra requires the canonical --harness pi or pi-signed launch so its native flag cannot be omitted" >&2
    exit 1
  }
fi
# Worker account pin (header above): resolved before any endpoint, worktree, or
# record exists. An absent pin selects nothing and leaves every later launch
# step exactly as it was. A pinned Claude root is exported here as well, so the
# trust registration below writes the store the worker will actually read.
RAW_COMMAND=
[ "$RAW_LAUNCH" = 0 ] || RAW_COMMAND=$ARG3
CLAUDE_ACCOUNT_SELECTION=
CLAUDE_ACCOUNT_ROOT=
if [ -n "$CLAUDE_ACCOUNT" ]; then
  CLAUDE_ACCOUNT_SELECTION=$(fm_claude_account_select "$HARNESS" "$CONFIG" "$MODEL" "$CLAUDE_ACCOUNT" "$RAW_COMMAND") || exit 1
  CLAUDE_ACCOUNT_ROOT=${CLAUDE_ACCOUNT_SELECTION#*$'\t'}
elif [ -z "$RAW_COMMAND" ]; then
  fm_claude_bridge_account_required "$HARNESS" "$CONFIG" "$MODEL" || exit 1
fi
WORKER_ACCOUNT=
if [ -z "$CLAUDE_ACCOUNT_SELECTION" ]; then
  WORKER_ACCOUNT=$(fm_worker_account_select "$HARNESS" "$CONFIG" "$MODEL" "${PI_BIN:-$HARNESS}" "$RAW_COMMAND") || exit 1
fi
WORKER_ACCOUNT_DECLARED=${WORKER_ACCOUNT%%$'\t'*}
WORKER_ACCOUNT_ROOT=${WORKER_ACCOUNT#*$'\t'}
WORKER_ACCOUNT_PROVIDER=${WORKER_ACCOUNT_ROOT#*$'\t'}
WORKER_ACCOUNT_ROOT=${WORKER_ACCOUNT_ROOT%%$'\t'*}
if [ "$RELAUNCH" -eq 0 ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
  if [ "$dispatch_status" = clear ] && [ -z "$DISPATCH_OVERRIDE" ]; then
    if [ -n "$selected_account" ] && [ "$CLAUDE_ACCOUNT" != "$selected_account" ]; then
      echo "error: launch account '${CLAUDE_ACCOUNT:-none}' does not match the clear dispatch selection --claude-account $selected_account recorded in $DISPATCH_RECORD; pass that account, or record this task's override with --dispatch-override <reason>" >&2
      exit 1
    fi
    FM_DISPATCH_PROOF_NOTE="resolve:clear"
  elif ! fm_dispatch_proof_gate "$CONFIG/crew-dispatch.json" "$DATA" "$ID" "$HARNESS" "${MODEL:-}" "${EFFORT:-}" "$CLAUDE_ACCOUNT"; then
    exit 1
  fi
fi
if ! fm_quota_spawn_gate "$CONFIG/crew-dispatch.json" "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" "$CLAUDE_ACCOUNT" "$QUOTA_OVERRIDE_REASON"; then
  exit 1
fi


model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
  pi | pi-signed) printf -- '--model %s ' "$(shell_quote "$model")" ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2 model=${3:-}
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
  pi | pi-signed)
    case "$effort" in
    ultra)
      "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
      printf -- '--codex-effort %s ' "$(shell_quote ultra)"
      ;;
    low | medium | high | xhigh | max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
    esac
    ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
  projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
  *) printf '%s\n' "$path" ;;
  esac
}


PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
WT=""
BRIEF="$DATA/$ID/brief.md"
if [ "$RELAUNCH" -eq 0 ] && git -C "$PROJ_ABS" rev-parse --git-dir >/dev/null 2>&1 &&
  ! git -C "$PROJ_ABS" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  echo "error: spawn refused: project $PROJ_ABS has no commit yet (unborn HEAD), so there is nothing to branch a worktree from; make one commit in the project, for example 'git -C $PROJ_ABS commit --allow-empty -m \"chore: initial commit\"', then spawn again" >&2
  exit 1
fi
# Project capacity admission (bin/fm-project-capacity-lib.sh owns the
# declaration, what holds a place, and why this is race-safe). A fresh worker
# for a project whose declared capacity is already held is deferred here, before
# any brief render, endpoint, worktree, record, or backlog move exists, so the
# deferral leaves the task exactly as queued as it was. A relaunch replaces a
# worker that already holds a place.
SPAWN_PROJECT_CAPACITY=
if [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || {
    echo "error: could not resolve the root Firstmate home that declares project capacity for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_project_capacity_lookup "$SPAWN_CAPACITY_CONFIG" "$(basename "$PROJ_ABS")"; then
    echo "error: spawn refused: the project capacity declaration is unreadable ($FM_PROJECT_CAPACITY_ERROR); fix it so the captain's worker limits are known (docs/configuration.md \"Project capacity\")" >&2
    exit 1
  fi
  SPAWN_PROJECT_CAPACITY=$FM_PROJECT_CAPACITY
fi
if [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ_ABS") || {
    echo "error: could not resolve the shared Treehouse project lock for $PROJ_ABS" >&2
    exit 1
  }
  if ! fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
    echo "error: another Treehouse slot allocation or return is in progress for $PROJ_ABS; refusing to race it" >&2
    exit 1
  fi
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=1
fi
if [ -n "$SPAWN_PROJECT_CAPACITY" ]; then
  if ! fm_project_capacity_occupants "$SPAWN_TREEHOUSE_PROJECT_LOCK" "$PROJ_ABS" "$STATE" "$ID"; then
    echo "error: spawn refused: project $(basename "$PROJ_ABS") declares a capacity of $SPAWN_PROJECT_CAPACITY, but this machine's task records cannot all be read to count it ($FM_PROJECT_CAPACITY_ERROR)" >&2
    exit 1
  fi
  if [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -ge "$SPAWN_PROJECT_CAPACITY" ]; then
    echo "deferred: project $(basename "$PROJ_ABS") admits $SPAWN_PROJECT_CAPACITY worker(s) at once on this machine ($FM_PROJECT_CAPACITY_FILE) and $FM_PROJECT_CAPACITY_OCCUPANTS already hold a place ($FM_PROJECT_CAPACITY_OCCUPANT_IDS); task $ID was not launched and its backlog item stays queued - dispatch it again once one of them records its ready PR or is cleaned up" >&2
    exit "$FM_PROJECT_CAPACITY_DEFER_EXIT"
  fi
fi
SPAWN_BROWSER_SUITE=0
if [ "$RELAUNCH" -eq 0 ]; then
  if ! fm_browser_suite_config "$SPAWN_CAPACITY_CONFIG"; then
    echo "error: spawn refused: the browser-suite declaration is unreadable ($FM_BROWSER_SUITE_ERROR); fix it so browser-suite starts stay staggered (docs/configuration.md \"Browser suites\")" >&2
    exit 1
  fi
  if fm_browser_suite_task "$(basename "$PROJ_ABS")" "$BRIEF"; then
    SPAWN_BROWSER_SUITE=1
    [ "$WEIGHT" != light ] || echo "note: task $ID runs a browser suite, so it starts heavy despite --weight light" >&2
    WEIGHT=heavy
  fi
fi
# The Mac load gate extends the capacity path above: a heavy start waits while
# the five-minute average is high or the standing heavy cap for the hour is full.
# A relaunch replaces a worker that already holds a heavy place, so it skips the gate rather than stranding the task with no agent running.
if [ "$RELAUNCH" -eq 0 ] && fm_mac_load_gate_active; then
  if [ -z "${SPAWN_CAPACITY_CONFIG:-}" ]; then
    SPAWN_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || {
      echo "error: could not resolve the root Firstmate home that declares machine limits for $PROJ_ABS" >&2
      exit 1
    }
  fi
  if ! fm_mac_load_config "$SPAWN_CAPACITY_CONFIG"; then
    echo "error: spawn refused: the machine load declaration is unreadable ($FM_MAC_LOAD_ERROR)" >&2
    exit 1
  fi
  if ! SPAWN_LOADAVG=$(fm_mac_loadavg_5min); then
    echo "error: spawn refused: the five-minute load average cannot be read; refusing a heavy start rather than guessing it" >&2
    exit 1
  fi
  if fm_mac_load_high "$SPAWN_LOADAVG"; then
    echo "deferred: five-minute load average is $SPAWN_LOADAVG (limit $FM_MAC_LOAD_LIMIT); task $ID was not launched and its backlog item stays queued - dispatch it again once the average drops" >&2
    exit "$FM_MAC_LOAD_DEFER_EXIT"
  fi
  if ! fm_mac_heavy_count "$STATE" "$ID"; then
    echo "error: spawn refused: this machine's task records cannot all be read to count heavy workers ($FM_MAC_LOAD_ERROR)" >&2
    exit 1
  fi
  if [ "$FM_MAC_HEAVY_COUNT" -ge "$FM_MAC_HEAVY_LIMIT" ]; then
    echo "deferred: $FM_MAC_HEAVY_COUNT heavy worker(s) already run on this machine (limit $FM_MAC_HEAVY_LIMIT: $FM_MAC_HEAVY_IDS); task $ID was not launched and its backlog item stays queued - dispatch it again once one of them records its ready PR or is cleaned up" >&2
    exit "$FM_MAC_LOAD_DEFER_EXIT"
  fi
fi
# The linux load gate extends the capacity path above on a Linux host that two
# Firstmate homes share without a common local root. Each home lists the other
# in config/linux-load-siblings, so a heavy start waits while the five-minute
# average is high or the standing heavy cap for the hour is full across both homes.
# A relaunch replaces a worker that already holds a heavy place, so it skips the gate rather than stranding the task with no agent running.
if [ "$RELAUNCH" -eq 0 ] && fm_linux_load_gate_active "${SPAWN_CAPACITY_CONFIG:-}"; then
  if [ -z "${SPAWN_CAPACITY_CONFIG:-}" ]; then
    SPAWN_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || {
      echo "error: could not resolve the root Firstmate home that declares machine limits for $PROJ_ABS" >&2
      exit 1
    }
  fi
  if ! fm_linux_load_config "$SPAWN_CAPACITY_CONFIG"; then
    echo "error: spawn refused: the machine load declaration is unreadable ($FM_LINUX_LOAD_ERROR)" >&2
    exit 1
  fi
  if ! SPAWN_LOADAVG=$(fm_mac_loadavg_5min); then
    echo "error: spawn refused: the five-minute load average cannot be read; refusing a heavy start rather than guessing it" >&2
    exit 1
  fi
  if fm_linux_load_high "$SPAWN_LOADAVG"; then
    echo "deferred: five-minute load average is $SPAWN_LOADAVG (limit $FM_LINUX_LOAD_LIMIT); task $ID was not launched and its backlog item stays queued - dispatch it again once the average drops" >&2
    exit "$FM_LINUX_LOAD_DEFER_EXIT"
  fi
  if ! fm_linux_heavy_count "$STATE" "$ID" "$SPAWN_CAPACITY_CONFIG"; then
    echo "error: spawn refused: this machine's task records cannot all be read to count heavy workers ($FM_LINUX_LOAD_ERROR)" >&2
    exit 1
  fi
  if [ "$FM_LINUX_HEAVY_COUNT" -ge "$FM_LINUX_HEAVY_LIMIT" ]; then
    echo "deferred: $FM_LINUX_HEAVY_COUNT heavy worker(s) already run on this machine (limit $FM_LINUX_HEAVY_LIMIT: $FM_LINUX_HEAVY_IDS); task $ID was not launched and its backlog item stays queued - dispatch it again once one of them records its ready PR or is cleaned up" >&2
    exit "$FM_LINUX_LOAD_DEFER_EXIT"
  fi
fi
if [ "$RELAUNCH" -eq 0 ] && [ "$WEIGHT" = heavy ] && fm_mac_core_budget_gate_active; then
  if [ -z "${SPAWN_CAPACITY_CONFIG:-}" ]; then
    SPAWN_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") || {
      echo "error: could not resolve the root Firstmate home that declares machine limits for $PROJ_ABS" >&2
      exit 1
    }
  fi
  if ! fm_mac_load_config "$SPAWN_CAPACITY_CONFIG"; then
    echo "error: spawn refused: the machine load declaration is unreadable ($FM_MAC_LOAD_ERROR)" >&2
    exit 1
  fi
  SPAWN_BUDGET_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    echo "error: spawn refused: the spawning home cannot be resolved" >&2
    exit 1
  }
  SPAWN_BUDGET_SAMPLES=$(fm_machine_core_budget_samples_file "$FM_HOME" "$STATE") || {
    echo "error: spawn refused: the machine-shared core sample log cannot be resolved" >&2
    exit 1
  }
  if ! fm_machine_core_budget_record "$SPAWN_BUDGET_SAMPLES"; then
    echo "error: spawn refused: the core sample cannot be recorded; refusing a heavy start rather than guessing it" >&2
    exit 1
  fi
  if ! SPAWN_BUDGET_USAGE=$(fm_machine_core_budget_usage "$SPAWN_BUDGET_SAMPLES"); then
    echo "error: spawn refused: the core sample log cannot be read ($FM_MACHINE_CORE_BUDGET_ERROR)" >&2
    exit 1
  fi
  if fm_machine_core_budget_over "$SPAWN_BUDGET_USAGE" "$FM_MAC_CORE_BUDGET"; then
    if ! "$SCRIPT_DIR/fm-mac-core-budget.sh" hold "$ID" "$(pwd -P)" "$SPAWN_BUDGET_HOME" -- "$@" >/dev/null; then
      echo "error: spawn refused: the trailing hour burned $SPAWN_BUDGET_USAGE core-hours (budget $FM_MAC_CORE_BUDGET), and the paused start cannot be recorded" >&2
      exit 1
    fi
    SPAWN_BUDGET_WATCH=$("$SCRIPT_DIR/fm-mac-core-budget.sh" watch-name) || SPAWN_BUDGET_WATCH=mac-core-budget
    SPAWN_BUDGET_ARM_OUT=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-when.sh" arm "$SPAWN_BUDGET_WATCH" --interval 60 --stable 2 --condition "$SCRIPT_DIR/fm-mac-core-budget.sh" check --clear --action "$SCRIPT_DIR/fm-mac-core-budget.sh" release 2>&1) || {
      case "$SPAWN_BUDGET_ARM_OUT" in
        *already\ exists*|*unhandled\ captured\ result*)
          echo "note: the budget wake is already pending" >&2
          ;;
        *)
          echo "warning: the budget wake did not arm ($SPAWN_BUDGET_ARM_OUT); task $ID stays queued for a hand retry" >&2
          ;;
      esac
    }
    echo "deferred: trailing-hour CPU use is $SPAWN_BUDGET_USAGE core-hours (budget $FM_MAC_CORE_BUDGET); task $ID was not launched and its backlog item stays queued - it resumes on its own once use drops under budget" >&2
    exit "$FM_CORE_BUDGET_DEFER_EXIT"
  fi
fi
[ -f "$BRIEF" ] || {
  echo "error: task $ID has no brief at inaccessible data path $BRIEF" >&2
  exit 1
}
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  HERDR_LIFECYCLE_BRIEF_GUARD=$(fm_config_source_present "$CONFIG/herdr-lifecycle-spawn-guard") || exit 1
  if [ "$HERDR_LIFECYCLE_BRIEF_GUARD" = 1 ]; then
    HERDR_LIFECYCLE_COMMAND=$(perl -ne '
      if (m{(bin/fm-herdr-lab\.sh|(?<![[:alnum:]_])herdr[[:space:]]+(?:session|server)[[:space:]]+(?:start|stop|delete|restart|reload-config|live-handoff)(?![[:alnum:]_-]))}) { print $1; exit }
    ' -- "$BRIEF")
    if [ -n "$HERDR_LIFECYCLE_COMMAND" ] && ! grep -Fq '# Herdr isolation - HARD SAFETY CONTRACT' "$BRIEF"; then
      echo "error: $BRIEF names the Herdr lifecycle command \`$HERDR_LIFECYCLE_COMMAND\` but lacks the Herdr isolation contract; regenerate it with bin/fm-brief.sh --herdr-lab" >&2
      exit 1
    fi
  fi
  if fm_brief_task_placeholders_present "$BRIEF"; then
    echo "error: $BRIEF still contains {TASK} or {FIRSTMATE_SPEC}; fill ## Captain's intent and ## Firstmate spec before spawn" >&2
    exit 1
  fi
  if ! fm_brief_task_content_valid "$BRIEF"; then
    echo "error: $BRIEF must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before spawn" >&2
    exit 1
  fi
  if ADDRESS_LINE=$(fm_brief_intent_address_line "$BRIEF"); then
    echo "error: $BRIEF ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before spawn, since the heading already records provenance" >&2
    exit 1
  fi
  if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
    if fm_brief_task_heading_present "$BRIEF" "## Captain's intent"; then
      CAPTAIN_INTENT=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
    else
      LEGACY_TASK_BODY=$(fm_brief_heading_body "$BRIEF" "# Task")
      CAPTAIN_INTENT=$(fm_brief_marked_captain_words "$LEGACY_TASK_BODY")
      if [ -z "$(printf '%s' "$CAPTAIN_INTENT" | tr -d '[:space:]')" ]; then
        echo "error: legacy mixed # Task brief has no provenance-marked captain words for no-mistakes --intent; add [captain] lines or migrate to ## Captain's intent and ## Firstmate spec" >&2
        exit 1
      fi
    fi
  fi
  if [ "$RELAUNCH" -eq 1 ]; then
    BASE_BRANCH=$(fm_meta_get "$RELAUNCH_META" base_branch)
  elif [ "$BASE_BRANCH_SET" -eq 1 ]; then
    [ -n "$BASE_BRANCH" ] || {
      echo "error: --base-branch requires a branch name" >&2
      exit 1
    }
    BASE_FORGE=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$(basename "$PROJ_ABS")") || exit 1
    fm_base_branch_valid "$BASE_BRANCH" "$MODE" "${BASE_FORGE:-none}" "fm-spawn.sh --base-branch" || exit 1
    if ! fm_brief_base_branches "$BRIEF" >/dev/null || fm_brief_base_branches "$BRIEF" | grep -vxF -- "$BASE_BRANCH" >/dev/null; then
      echo "error: $BRIEF must record Base branch: $BASE_BRANCH and no other Base branch line to spawn with --base-branch $BASE_BRANCH; scaffold it with bin/fm-brief.sh --base-branch $BASE_BRANCH" >&2
      exit 1
    fi
  elif fm_brief_base_branches "$BRIEF" >/dev/null; then
    echo "error: $BRIEF records a Base branch line but the spawn has no --base-branch; pass the brief's base with --base-branch or re-scaffold the brief without one" >&2
    exit 1
  fi
  # Runs after the admission gates and brief checks, because an admitted start
  # claims the stagger gap and a later deferral or refusal would leave it
  # claimed by a worker that never started.
  if [ "$SPAWN_BROWSER_SUITE" = 1 ]; then
    SPAWN_BROWSER_STAMP=$(fm_browser_suite_stamp_file "$FM_HOME") || {
      echo "error: spawn refused: the machine-shared browser-suite start record cannot be resolved" >&2
      exit 1
    }
    SPAWN_BROWSER_RC=0
    fm_browser_suite_stagger_admit "$SPAWN_BROWSER_STAMP" "$FM_BROWSER_SUITE_STAGGER_SECS" || SPAWN_BROWSER_RC=$?
    if [ "$SPAWN_BROWSER_RC" = 1 ]; then
      echo "deferred: another browser-suite worker started inside the $((FM_BROWSER_SUITE_STAGGER_SECS / 60))-minute stagger gap ($FM_BROWSER_SUITE_FILE); task $ID was not launched and its backlog item stays queued - dispatch it again in $(((FM_BROWSER_SUITE_WAIT_SECS + 59) / 60)) minute(s)" >&2
      exit "$FM_BROWSER_SUITE_DEFER_EXIT"
    elif [ "$SPAWN_BROWSER_RC" != 0 ]; then
      echo "error: spawn refused: the browser-suite stagger cannot be checked ($FM_BROWSER_SUITE_ERROR)" >&2
      exit 1
    fi
  fi
  # Use the existing launch-brief overlay for every worker kind, including
  # pre-scope briefs and relaunches. Charters never enter this worker path.
  SOURCE_BRIEF=$BRIEF
  BRIEF="$DATA/$ID/launch-brief.md"
  BRIEF_TMP="$DATA/$ID/.launch-brief.md.${BASHPID:-$$}"
  SPAWN_BRIEF_MODEL=$MODEL
  if [ -z "$SPAWN_BRIEF_MODEL" ] && [ "$RELAUNCH" = 1 ]; then
    SPAWN_BRIEF_MODEL=$(fm_meta_get "$RELAUNCH_META" model) || SPAWN_BRIEF_MODEL=
  fi
  {
    fm_brief_worker_role "$STATE" "$ID" "$FM_ROOT" &&
      fm_brief_haiku_scope_line "$SPAWN_BRIEF_MODEL" &&
      printf '\n' &&
      cat "$SOURCE_BRIEF" &&
      if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
        fm_brief_intent_overlay "$CAPTAIN_INTENT"
      fi
  } >"$BRIEF_TMP" || {
    rm -f -- "$BRIEF_TMP"
    echo "error: could not render current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  }
  if ! mv "$BRIEF_TMP" "$BRIEF"; then
    rm -f -- "$BRIEF_TMP"
    echo "error: could not publish current launch contract for $SOURCE_BRIEF" >&2
    exit 1
  fi
fi

delivery_rigor_rank() { # <mode> -> 3 (most rigor) .. 1 (least); 0 = not a task mode
  case "$1" in
  no-mistakes) echo 3 ;;
  direct-PR) echo 2 ;;
  local-only) echo 1 ;;
  *) echo 0 ;;
  esac
}

# Brief/spawn delivery agreement, checked before any endpoint exists.
# fm-brief.sh records a ship brief's mode as a fixed "Delivery contract: mode=<mode>"
# line, with " forge=<forge>" appended on a bound forge. A spawn that disagrees
# would launch a worker whose instructions and whose recorded task delivery
# differ, which is the exact drift this contract prevents.
if [ "$KIND" = ship ]; then
  PROJ_NAME=$(basename "$PROJ_ABS")
  # The parser's own refusal reaches the operator here rather than being
  # discarded: an entry it refuses (an unknown forge token, or a forge on
  # local-only) resolves to no posture at all, and launching on the silent
  # default is how a mistyped forge would hand a Gerrit project the
  # pull-request contract.
  if ! STANDING_FORGE=$("$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    exit 1
  fi
  [ -n "$STANDING_FORGE" ] || STANDING_FORGE=none
  STANDING_MODE=$("$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJ_NAME" 2>/dev/null | cut -d' ' -f1) || STANDING_MODE=
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  BRIEF_FORGE=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]forge=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ -n "$BRIEF_FORGE" ] || BRIEF_FORGE=none
  BRIEF_BRANCH=$(sed -n 's/^Ship branch: //p' "$BRIEF" | head -n 1)
  if [ -n "$BRIEF_BRANCH" ]; then
    [ "$BRIEF_BRANCH" = "$BRANCH" ] || {
      echo "error: branch mismatch for $ID: the brief says branch=$BRIEF_BRANCH but this spawn selected branch=$BRANCH" >&2
      exit 1
    }
  elif [ "$BRANCH" != "fm/$ID" ]; then
    # A relaunch's branch comes from the meta record (--branch-prefix is refused
    # there), so a promoted scout whose brief never carried a Ship branch line
    # must relaunch on that recorded branch rather than be refused.
    if [ "$RELAUNCH" -eq 1 ]; then
      echo "warning: $BRIEF records no ship branch; relaunching on the task's recorded branch $BRANCH" >&2
    else
      echo "error: $BRIEF records no ship branch; regenerate it with --branch-prefix before spawning $BRANCH" >&2
      exit 1
    fi
  else
    echo "warning: $BRIEF records no ship branch; defaulting to legacy branch $BRANCH" >&2
  fi
  if [ -z "$BRIEF_MODE" ]; then
    echo "warning: $BRIEF records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode $MODE - confirm its definition of done matches" >&2
  elif [ "$BRIEF_MODE" != "$MODE" ]; then
    echo "error: delivery mismatch for $ID: the brief says mode=$BRIEF_MODE but this spawn passed --mode $MODE; correct the flag or re-scaffold the brief so the worker's instructions and the task record agree" >&2
    exit 1
  fi
  # A firstmate-repository contribution records its one-task publication consent
  # as an upstream-consent= token on that same line; like mode and forge, the
  # brief and the spawn flag must agree so the worker's contract and the task
  # record carry the same authority.
  BRIEF_CONSENT=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]upstream-consent=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  if [ "$BRIEF_CONSENT" != "$UPSTREAM_CONSENT" ]; then
    echo "error: upstream-consent mismatch for $ID: $BRIEF records upstream-consent=${BRIEF_CONSENT:-none} but this spawn passed ${UPSTREAM_CONSENT:-none}; correct the flag or re-scaffold the brief so the worker's contract and the task record agree" >&2
    exit 1
  fi
  # The registered forge is the captain's confirmed binding (bin/fm-project-mode.sh)
  # and is never inferred here from a remote, host, or protocol. A brief that
  # disagrees with it would tell the worker to open a pull request a Gerrit
  # server does not have, or to publish a change to a forge that is not Gerrit.
  if [ "$BRIEF_FORGE" != "$STANDING_FORGE" ]; then
    if [ "$STANDING_FORGE" = none ]; then
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    else
      forge_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE --forge $STANDING_FORGE"
    fi
    echo "error: forge mismatch for $ID: $PROJ_NAME is registered forge=$STANDING_FORGE but $SOURCE_BRIEF records forge=$BRIEF_FORGE; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $SOURCE_BRIEF, re-scaffold it with $forge_scaffold, then re-fill those two subsections, so the worker's publication matches the project's forge" >&2
    exit 1
  fi
  # The registered PR-text binding is read the same way: a brief that disagrees
  # would hand the pipeline's pr step the text a person owns, or the worker text
  # the pipeline owns. direct-PR already leaves the text to the worker, so a
  # conditional-policy project's direct-PR task expects none.
  if ! STANDING_PR=$("$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" 2>/dev/null); then
    "$FM_ROOT/bin/fm-project-mode.sh" --pr "$PROJ_NAME" >/dev/null || true
    echo "error: $ID cannot launch: the registry entry for $PROJ_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and spawn again" >&2
    exit 1
  fi
  [ -n "$STANDING_PR" ] || STANDING_PR=auto
  [ "$MODE" = no-mistakes ] || STANDING_PR=auto
  BRIEF_PR=$(sed -n 's/^Delivery contract: mode=[^ ]*.*[[:space:]]pr=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ -n "$BRIEF_PR" ] || BRIEF_PR=auto
  if [ "$BRIEF_PR" != "$STANDING_PR" ]; then
    pr_scaffold="fm-brief.sh $ID $PROJ_NAME --mode $MODE"
    [ "$STANDING_FORGE" = none ] || pr_scaffold="$pr_scaffold --forge $STANDING_FORGE"
    [ "$STANDING_PR" = auto ] || pr_scaffold="$pr_scaffold --pr $STANDING_PR"
    echo "error: PR-text mismatch for $ID: $PROJ_NAME is registered pr=$STANDING_PR but $SOURCE_BRIEF records pr=$BRIEF_PR; keep the filled ## Captain's intent and ## Firstmate spec bodies, remove $SOURCE_BRIEF, re-scaffold it with $pr_scaffold, then re-fill those two subsections, so the worker owns the PR text exactly when the project says so" >&2
    exit 1
  fi
  # Merge authority on a Gerrit forge is refused rather than quietly dropped, on
  # the captain's decision of 2026-09-15: a Code-Review+2 is a positive
  # attributed claim that a named human approved, and firstmate must not
  # manufacture one.
  if [ "$STANDING_FORGE" = gerrit ] && [ "$YOLO" = on ]; then
    echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=gerrit, where yolo is inactive because a Code-Review+2 is a positive attributed claim that a named human approved and firstmate must not manufacture one (captain's decision 2026-09-15); spawn with --yolo off" >&2
    exit 1
  fi
  # An external review tool uploads its own snapshot, so this task must never
  # push a task branch to the shared origin (docs/external-review-forge.md).
  # Every protection the captain configured is validated before any endpoint
  # exists, so a worker never launches without it.
  if [ "$STANDING_FORGE" = external ]; then
    if [ "$YOLO" = on ]; then
      echo "error: --yolo on is refused for $ID: $PROJ_NAME is registered forge=external, where firstmate can neither observe nor perform the review tool's approval or merge; spawn with --yolo off" >&2
      exit 1
    fi
    fm_external_review_adapter_body "$CONFIG" >/dev/null || exit 1
    fm_external_review_backup "$CONFIG" || exit 1
    EXTERNAL_REVIEW=1
    EXTERNAL_BACKUP_REMOTE=$FM_REVIEW_BACKUP_REMOTE
    EXTERNAL_BACKUP_PREFIX=$FM_REVIEW_BACKUP_PREFIX
    if [ -n "$EXTERNAL_BACKUP_REMOTE" ]; then
      fm_external_review_prefix_disjoint "$EXTERNAL_BACKUP_PREFIX" "$(fm_ship_branch_prefix "$BRANCH" "$ID")" || exit 1
      backup_urls=$(fm_external_review_remote_urls "$PROJ_ABS" "$EXTERNAL_BACKUP_REMOTE")
      if [ -z "$backup_urls" ]; then
        echo "error: $ID cannot launch: config/external-review-backup names the remote $EXTERNAL_BACKUP_REMOTE, which $PROJ_ABS does not have; add it with git remote add, or remove the file to ship without a backup" >&2
        exit 1
      fi
      shared_urls=$(fm_external_review_remote_urls "$PROJ_ABS" origin)
      if [ -n "$shared_urls" ] && printf '%s\n' "$backup_urls" | grep -Fqx -f <(printf '%s\n' "$shared_urls"); then
        echo "error: $ID cannot launch: the backup remote $EXTERNAL_BACKUP_REMOTE points at the project's shared origin; a durable copy must go to storage only the captain controls" >&2
        exit 1
      fi
    fi
  fi
  # Self-repository publication gate (bin/fm-role-lib.sh): a ship task whose
  # project is firstmate's own repository may launch a publishing contract only
  # under an explicit grant - this home's maintainer scope in
  # config/firstmate-role, or this one task's recorded upstream consent. Every
  # other project passes through unchanged; local-only publishes nothing and
  # never reaches this gate.
  if [ "$MODE" != local-only ]; then
    gate_rc=0
    fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$PROJ_ABS" "$FM_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
    case $gate_rc in
    0 | 2) ;;
    *)
      echo "error: spawn refused for $ID: $FM_ROLE_PUB_DENIAL" >&2
      echo "error: to let this home publish to ${FM_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/firstmate-role (docs/configuration.md \"Firstmate role\"), or pass --upstream-consent ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      exit 1
      ;;
    esac
  fi
  # The registry holds the captain's standing posture, so dropping below it is
  # allowed (a current explicit captain instruction wins) but never silent. An
  # unregistered project resolves to the same no-mistakes standing default, which
  # is why the notice names the standing posture rather than the registry line. A
  # conditional policy is excluded: both of its legs are legitimate classifications.
  if [ -n "$STANDING_MODE" ] && [ "$STANDING_MODE" != no-mistakes-prod-only ] &&
    [ "$(delivery_rigor_rank "$MODE")" -lt "$(delivery_rigor_rank "$STANDING_MODE")" ]; then
    echo "notice: $ID ships mode=$MODE while the standing posture for $PROJ_NAME is $STANDING_MODE - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
  # The registered ship-branch prefix (bin/fm-project-mode.sh) is the captain's
  # answer to "should this project's branches read as firstmate-authored", so a
  # spawn that ships the legacy fm/ prefix past a registered override is
  # announced, not refused: the brief-vs-spawn agreement above already
  # guarantees the worker's instructions match the branch this spawn selected.
  STANDING_BRANCH=$("$FM_ROOT/bin/fm-project-mode.sh" --branch-prefix "$PROJ_NAME" 2>/dev/null) || STANDING_BRANCH=
  if [ "$BRANCH" != "$STANDING_BRANCH$ID" ]; then
    echo "notice: $ID ships branch=$BRANCH while $PROJ_NAME registers the ship-branch prefix '$STANDING_BRANCH' (branch $STANDING_BRANCH$ID) - the task's branch and PR will read as firstmate-authored; proceed only on a current explicit captain instruction or an intake judgment you can state" >&2
  fi
fi


# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Herdr's foreground_cwd reports the physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

real_path_or_raw() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

# True when <path> is an isolated worktree of the spawning project: a real
# directory that is its own worktree root, is not the spawning project itself,
# and does not share the project repository's common git dir. SPAWN_WT_TOP is
# left holding the worktree root the check read, and SPAWN_WT_REASON a short
# phrase naming why a rejected path failed, both for the refusal messages.
SPAWN_WT_TOP=
SPAWN_WT_REASON=
spawn_worktree_isolated() { # <path>
  local path=$1 wt_real wt_top_real wt_git_dir proj_common
  SPAWN_WT_TOP=
  SPAWN_WT_REASON=
  wt_real=
  if ! wt_real=$(cd "$path" 2>/dev/null && pwd -P); then
    wt_real=
  fi
  if [ -z "$wt_real" ]; then
    SPAWN_WT_REASON="it is not a readable directory"
    return 1
  fi
  SPAWN_WT_TOP=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  # A path in no repository leaves the toplevel empty, and that empty value must
  # never reach `cd`: bash before 5.3 accepts `cd ""` as a successful no-op, so
  # it would resolve to fm-spawn's OWN cwd and report the path as a subdirectory
  # of whatever checkout firstmate happens to be running from.
  wt_top_real=
  if [ -n "$SPAWN_WT_TOP" ] && ! wt_top_real=$(cd "$SPAWN_WT_TOP" 2>/dev/null && pwd -P); then
    wt_top_real=
  fi
  if [ -z "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is not inside a git worktree"
    return 1
  fi
  if [ "$wt_real" != "$wt_top_real" ]; then
    SPAWN_WT_REASON="it is a subdirectory of worktree root '$wt_top_real', not a worktree root"
    return 1
  fi
  if [ "$wt_real" = "$PROJ_ABS_REAL" ]; then
    SPAWN_WT_REASON="it is the spawning project itself"
    return 1
  fi
  # The primary checkout uses the repository's common git dir as its own git
  # dir. A linked spawning home has a different top-level, but the same common
  # dir, so comparing only the two working directories cannot protect primary.
  wt_git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) &&
    wt_git_dir=$(cd "$wt_git_dir" 2>/dev/null && pwd -P) || wt_git_dir=
  proj_common=$(git -C "$PROJ_ABS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
    proj_common=$(cd "$proj_common" 2>/dev/null && pwd -P) || proj_common=
  if [ -z "$wt_git_dir" ] || [ -z "$proj_common" ]; then
    SPAWN_WT_REASON="its git directory could not be resolved"
    return 1
  fi
  if [ "$wt_git_dir" = "$proj_common" ]; then
    SPAWN_WT_REASON="it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
    return 1
  fi
  return 0
}

validate_spawn_worktree() { # <source> <inspect-target>
  local source=$1 inspect_target=$2
  if ! spawn_worktree_isolated "$WT"; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT': $SPAWN_WT_REASON; worktree root '${SPAWN_WT_TOP:-none}'; spawning project '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

# A pooled slot whose only deviation is a submodule gitlink is stale, not dirty:
# an earlier refresh moved the superproject and left the submodule checkout on
# the pin the previous base recorded. The refusal still stands and this gate
# never touches the slot; it only names the cause, because "is not clean" while
# the operator's own `git status` reads clean gives neither a cause nor a remedy.
# A pin is only reported as stale when the commit the slot holds is already
# contained in one of the submodule's remotes. Anything that cannot be proven
# contained - an unpushed commit, a submodule with no remote, a git error - falls
# through to the conservative uncommitted-work refusal, as does any entry that is
# not exactly a clean submodule sitting on a different pin. The diagnosis is
# buffered and only emitted once every entry qualifies, so it can never
# contradict the verdict.
#
# No remedy command is printed, deliberately. That containment check reads local
# refs only and never fetches, because this gate has to stay usable offline. A
# remote-tracking ref that has gone stale - its upstream branch deleted or
# force-pushed, and never pruned - therefore still reads as containment, so a
# commit that is really unpushed can look contained. Naming the submodule and both
# pins is what the operator actually needs; printing a checkout command on a
# judgement that can be fooled could cost them that commit, so the remedy is left
# to the operator, who can see the whole picture.
describe_stale_submodule_pins() { # <worktree> <status>
  local worktree=$1 status=$2 line path want have unpushed lines=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in ' M '*) path=${line#' M '} ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" ls-files --stage -- "$path" 2>/dev/null | cut -c1-6)" = 160000 ] || return 1
    [ -z "$(git -C "$worktree/$path" status --porcelain 2>/dev/null)" ] || return 1
    want=$(git -C "$worktree" rev-parse --verify --quiet "HEAD:$path" 2>/dev/null) || return 1
    have=$(git -C "$worktree/$path" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ "$want" != "$have" ] || return 1
    unpushed=$(git -C "$worktree/$path" log --format=%H --max-count=1 "$have" --not --remotes -- 2>/dev/null) || return 1
    [ -z "$unpushed" ] || return 1
    lines+="error: submodule '$path' is checked out at $have, but this base records $want"$'\n'
  done <<EOF
$status
EOF
  [ -n "$lines" ] || return 1
  printf '%s' "$lines" >&2
}

spawn_worktree_has_origin_config() { # <worktree>
  # Resolved remote.origin.* variables cover Git's effective include/includeIf chain; raw headers are also detected in the worktree config and any included file Git names through another variable. Git cannot enumerate a variable-less included file, so an empty origin section that is its only content remains indistinguishable from absence and intentionally proceeds rather than reimplementing Git's config parser.
  local worktree=$1 config origin key seen=$'\n'
  git -C "$worktree" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r origin key; do
    case $origin in file:*) config=${origin#file:} ;; *) continue ;; esac
    [ -f "$config" ] || continue
    case $seen in *$'\n'"$config"$'\n'*) continue ;; esac
    seen+="$config"$'\n'
    awk '/^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee][[:space:]]+"origin"[[:space:]]*\][[:space:]]*([#;].*)?$/ || /^[[:space:]]*\[[[:space:]]*[Rr][Ee][Mm][Oo][Tt][Ee]\.origin[[:space:]]*\][[:space:]]*([#;].*)?$/ { found=1 } END { exit !found }' "$config" && return 0
  done < <(git -C "$worktree" config --list --show-origin 2>/dev/null || true)
  return 1
}

# The opt-in half of the base rule the header owns: return 0 and set
# SPAWN_PRIMARY_BASE_REV when <project>'s own <default> should be this fresh
# slot's base instead of origin's tip <origin-rev>. A pool slot shares the
# primary checkout's object store, so reading that commit fetches nothing, and a
# commit the slot cannot read keeps origin's tip.
SPAWN_PRIMARY_BASE_REV=
spawn_base_from_primary_checkout() { # <worktree> <project> <default> <origin-rev> <mode>
  local worktree=$1 project=$2 default=$3 origin_rev=$4 mode=$5 primary_rev ahead behind
  SPAWN_PRIMARY_BASE_REV=
  if [ -z "$project" ] || fm_mode_publishes "$mode"; then
    return 1
  fi
  primary_rev=$(git -C "$project" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null) || return 1
  ahead=$(git -C "$worktree" rev-list --count "$origin_rev..$primary_rev" 2>/dev/null) || return 1
  behind=$(git -C "$worktree" rev-list --count "$primary_rev..$origin_rev" 2>/dev/null) || return 1
  [ "$ahead" -gt 0 ] || return 1
  if [ "$behind" -eq 0 ]; then
    SPAWN_PRIMARY_BASE_REV=$primary_rev
    return 0
  fi
  echo "note: pooled worktree '$worktree': $default in the primary checkout has diverged from origin/$default (ahead by $ahead, behind by $behind); starting from origin's tip" >&2
  return 1
}

freshen_spawn_worktree_base() { # <worktree> <base-branch> <project> <mode>; 2 when the worktree is not clean
  local worktree=$1 base=${2:-} project=${3:-} mode=${4:-} default target expected reset_ref actual status
  status=$(git -C "$worktree" -c core.quotePath=false status --porcelain) || {
    echo "error: could not inspect pooled worktree '$worktree' before refreshing its base" >&2
    return 1
  }
  if [ -n "$status" ]; then
    if describe_stale_submodule_pins "$worktree" "$status"; then
      echo "error: pooled worktree '$worktree' has a stale submodule checkout, not uncommitted work; refusing to launch and leaving it untouched" >&2
    else
      echo "error: pooled worktree '$worktree' is not clean; refusing to discard uncommitted work while refreshing its base" >&2
    fi
    return 2
  fi
  if ! spawn_worktree_has_origin_config "$worktree"; then
    [ -z "$base" ] || {
      echo "error: pooled worktree '$worktree' has no origin, so it cannot start from base branch '$base'" >&2
      return 1
    }
    return 0
  fi
  if ! git -C "$worktree" fetch --quiet origin; then
    echo "error: could not fetch origin for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  if [ -n "$base" ]; then
    default=$base
  else
    if ! git -C "$worktree" remote set-head origin --auto >/dev/null 2>&1; then
      echo "error: could not resolve origin's current default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
      return 1
    fi
    default=$(default_branch "$worktree") || {
      echo "error: could not determine origin's default branch for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
      return 1
    }
  fi
  target="origin/$default"
  if ! git -C "$worktree" fetch --quiet origin "+refs/heads/$default:refs/remotes/origin/$default"; then
    echo "error: could not fetch '$target' for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  expected=$(git -C "$worktree" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    echo "error: '$target' is not a commit for pooled worktree '$worktree'; refusing to launch from a potentially stale base" >&2
    return 1
  }
  reset_ref=$target
  if [ -z "$base" ] && [ -e "$CONFIG/spawn-base-primary-checkout" ] \
    && spawn_base_from_primary_checkout "$worktree" "$project" "$default" "$expected" "$mode"; then
    target="$default in the primary checkout"
    expected=$SPAWN_PRIMARY_BASE_REV
    reset_ref=$expected
  fi
  if ! git -C "$worktree" reset --hard "$reset_ref" >/dev/null; then
    echo "error: could not reset pooled worktree '$worktree' to '$target'; refusing to launch from a potentially stale base" >&2
    return 1
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree '$worktree' is at '${actual:-unknown}', not current '$target' ('$expected'); refusing to launch" >&2
    return 1
  fi
}

herdr_projection_meta_field_exact() { # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower version 2 reclaim path.
herdr_projection_existing_meta_allows_flat() { # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  HERDR_RECOVERY_BACKEND=$old_backend
  if [ "$old_backend" = herdr ]; then
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    target_session=$FM_BACKEND_HERDR_SESSION
    target_pane=$FM_BACKEND_HERDR_PANE
    old_session=$(herdr_projection_meta_field_exact "$meta" herdr_session) || {
      echo "error: existing herdr metadata for $ID has an ambiguous session; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_WORKSPACE_ID=$(herdr_projection_meta_field_exact "$meta" herdr_workspace_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous workspace; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_TAB_ID=$(herdr_projection_meta_field_exact "$meta" herdr_tab_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous tab; refusing duplicate launch" >&2
      return 1
    }
    old_pane=$(herdr_projection_meta_field_exact "$meta" herdr_pane_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous pane; refusing duplicate launch" >&2
      return 1
    }
    [ "$target_session" = "$old_session" ] && [ "$target_pane" = "$old_pane" ] || {
      echo "error: existing herdr metadata for $ID has inconsistent endpoint identities; refusing duplicate launch" >&2
      return 1
    }
    HERDR_RECOVERY_PANE_ID=$old_pane
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_herdr_pane_agent_state "$old_session" "$old_pane")
    case "$old_state" in
    # A stale registration over a shell-only pane is agent-free for RECOVERY
    # (--relaunch reuses the pane, issue #4115), but the duplicate-launch
    # corridor keeps refusing it like every other non-husk state, so a fresh
    # spawn is refused here consistently with the reclaim and presentation
    # gates downstream.
    dead | no-agent) return 0 ;;
    live | stale-agent | unknown)
      echo "error: existing herdr endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target")
  case "$old_state" in
  dead) return 0 ;;
  alive | unknown)
    echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
    return 1
    ;;
  esac
}

# Backlog preflight (bin/fm-backlog-transition-lib.sh). This spawn is about to
# become the sole owner of the row's In-flight transition, so prove the row is
# transitionable BEFORE any endpoint, worktree, or record exists: a refusal here
# costs nothing to unwind, while the same refusal after publication would strand
# a live pane. The authoritative mutation still runs under the meta lock below.
BACKLOG_TRANSITION=0
BACKLOG_ROW_STATE=
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if fm_backlog_row_probe "$DATA" "$ID"; then
    BACKLOG_ROW_STATE=$FM_BACKLOG_ROW_STATE
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    echo "error: task $ID has no backlog item in this home, so dispatching it would leave a worker no record owns; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND) and re-run" >&2
    exit 1
  else
    echo "error: task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)" >&2
    exit 1
  fi
  if ! fm_backlog_row_dispatchable "$BACKLOG_ROW_STATE"; then
    echo "error: this home's backlog item $ID is not dispatchable in state $BACKLOG_ROW_STATE; refusing before creating its endpoint or local copy" >&2
    exit 1
  fi
else
  BACKLOG_GATE_STATUS=$?
  if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
    echo "error: task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi

if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ -e "$STATE/$ID.backlog-close" ] || [ -L "$STATE/$ID.backlog-close" ]; then
  echo "error: task $ID has a pending authoritative backlog close at $STATE/$ID.backlog-close; finish or repair that close before dispatching a new worker" >&2
  exit 1
fi

W="fm-$ID"
if [ "$RELAUNCH" -eq 1 ]; then
  # The recorded worktree is REUSED, never re-created: its branch, commits and
  # uncommitted changes are exactly as the previous agent left them, and nothing
  # below may touch them.
  WT=$RELAUNCH_WT
  if [ "$RELAUNCH_REBIND" -eq 0 ]; then
    # Adopt the recorded endpoint instead of creating one. This is what keeps a
    # relaunch a REPLACEMENT rather than a second copy of the task: no new
    # terminal, no second worktree, and every uncommitted change left exactly
    # where the previous agent left it.
    T=$RELAUNCH_TARGET
    WT_TARGET=$T
  else
    # The recorded endpoint is authoritatively gone, so there is nothing to
    # adopt: create ONE fresh endpoint for the same task, opened directly in the
    # recorded worktree. The record published below writes window= (and herdr's
    # ids) from these values, which is the whole rebind - the task id, brief,
    # worktree, armed poll and status log are untouched.
    #
    # Herdr reaches here only on a PROVEN-gone pane: its every read is scoped to
    # the session the record names (fm_control_endpoint_absence_verdict owns
    # that argument).
    #
    # The endpoint is placed exactly as a fresh spawn places it: its own
    # presentation workspace when this home projects, otherwise a flat tab
    # beside the launcher (docs/herdr-backend.md "Presentation spaces").
    #
    # Re-create it under the RECORDED herdr session. Without the explicit
    # session the container would resolve from the AMBIENT one
    # (${HERDR_SESSION:-default}), so reclaiming a task recorded on a named
    # session from a seat that is not in it would silently relocate the task
    # onto another herdr server - an identity change, published as a
    # self-consistent but wrong record.
    HERDR_REBIND_SES=${RELAUNCH_TARGET%%:*}
    HERDR_LABEL_HOME=$FM_HOME
    HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
    HERDR_PROJECTED=0
    if fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE" "$HERDR_REBIND_SES"; then
      HERDR_PARENT_LABEL=$(fm_backend_herdr_workspace_label)
      spawn_herdr_project_task "$HERDR_REBIND_SES" "$WT" "$RELAUNCH_LAUNCHER_PANE_ID"
    fi
  fi
  if [ "$RELAUNCH_REBIND" -eq 1 ] && [ "$HERDR_PROJECTED" -ne 1 ]; then
    # The flat tab minted below has no abort cleanup, so a later refusal
    # leaves that pane behind and a retry mints another.
    HERDR_CONTAINER_RAW=$(HERDR_PANE_ID="$RELAUNCH_LAUNCHER_PANE_ID" \
      fm_backend_herdr_container_ensure "$PROJ_ABS" launcher-home "$HERDR_REBIND_SES") || {
      # container_ensure returns 1 for several unrelated reasons - a failed
      # version check, a server that will not start, an ambiguous workspace
      # label, a cross-session launcher identity, a failed workspace create -
      # and each already printed its own accurate message. Add only what this
      # layer actually knows, and name the session mismatch solely when there
      # IS one, rather than asserting a cause this condition cannot establish.
      #
      # A seat with NO herdr pane never reaches the cross-session guard at all:
      # fm_backend_herdr_launcher_identity returns 2 for it and the placement
      # falls back to the recorded session's labeled container, which is what
      # makes a plain ssh or cron reclaim work. Its ambient session still reads
      # `default` (fm_backend_herdr_session's fallback), so the inequality alone
      # would fire for EVERY named-session task reclaimed from a plain shell and
      # send the operator chasing a session mismatch that was never the cause.
      HERDR_AMBIENT_SES=$(fm_backend_herdr_session)
      if [ -n "$RELAUNCH_LAUNCHER_PANE_ID" ] && [ "$HERDR_AMBIENT_SES" != "$HERDR_REBIND_SES" ]; then
        echo "error: task $ID's endpoint could not be re-created in its recorded herdr session '$HERDR_REBIND_SES'; this seat is running in herdr session '$HERDR_AMBIENT_SES', and a reclaim never moves a task to another session" >&2
      else
        echo "error: task $ID's endpoint could not be re-created in its recorded herdr session '$HERDR_REBIND_SES'; see the refusal above for what failed" >&2
      fi
      exit 1
    }
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$W" "$WT" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
  fi
  if [ "$RELAUNCH_REBIND" -eq 1 ]; then
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    WT_TARGET=$T
  fi
else
  # A worker belongs in the exact herdr workspace its launcher runs in, never a same-labeled sibling.
  HERDR_LABEL_HOME=$FM_HOME
  HERDR_LAUNCHER_RELATIONSHIP='launcher-home'
  HERDR_PRESENTATION_JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
  HERDR_PROJECTED=0
  if fm_backend_herdr_presentation_enabled "$CONFIG" "$STATE"; then
    HERDR_SES=$(fm_backend_herdr_session)
    HERDR_PARENT_LABEL=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_workspace_label)
    if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
      fm_backend_herdr_server_ensure "$HERDR_SES" || {
        echo "error: herdr presentation recovery could not ensure its exact named session" >&2
        exit 1
      }
      # Refuse-by-default on contention. Wait only when the caller opted in
      # with --herdr-resume-lock-wait (see header).
      if [ "$HERDR_RESUME_LOCK_WAIT" = 1 ]; then
        spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" wait || {
          echo "error: herdr presentation recovery could not resolve its session lock" >&2
          exit 1
        }
      else
        spawn_herdr_presentation_order_lock_acquire "$HERDR_SES" || {
          echo "error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume" >&2
          exit 1
        }
      fi
      if [ -e "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ]; then
        herdr_projection_existing_meta_allows_flat "$STATE/$ID.meta" || exit 1
      fi
      fm_backend_herdr_projection_recovery_allows_flat \
        "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" || exit 1
      if [ "${HERDR_RECOVERY_BACKEND:-}" = herdr ]; then
        set +e
        FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_projection_reclaim_task \
          "$HERDR_SES" "$HERDR_PRESENTATION_JOURNAL" "$ID" "$HERDR_LABEL_HOME" \
          "$HERDR_RECOVERY_WORKSPACE_ID" "$HERDR_RECOVERY_TAB_ID" "$HERDR_RECOVERY_PANE_ID" \
          "$HERDR_PARENT_LABEL" "$W" "$PROJ_ABS"
        HERDR_RECLAIM_STATUS=$?
        set -e
        case "$HERDR_RECLAIM_STATUS" in
        0)
          HERDR_PROJECTED=1
          HERDR_WORKSPACE_ID=$HERDR_RECOVERY_WORKSPACE_ID
          HERDR_SEEDED_DEFAULT_TAB_ID=""
          HERDR_TAB_ID=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
          HERDR_PANE_ID=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
          HERDR_PROJECTION_ABORT_CLEANUP=1
          HERDR_PROJECTION_ABORT_SESSION=$HERDR_SES
          HERDR_PROJECTION_ABORT_TASK_PANE=$HERDR_PANE_ID
          HERDR_PROJECTION_ABORT_SEEDED_PANE=""
          ;;
        2)
          spawn_herdr_presentation_order_lock_release
          ;;
        *) exit 1 ;;
        esac
      else
        spawn_herdr_presentation_order_lock_release
      fi
    elif [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
      spawn_herdr_project_task "$HERDR_SES" "$PROJ_ABS" "${HERDR_PANE_ID:-}" "$PROJ_ABS"
    fi
  fi
  if [ "$HERDR_PROJECTED" -ne 1 ]; then
    HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS" "$HERDR_LAUNCHER_RELATIONSHIP") || exit 1
    # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
    # (the second field empty when this call ADOPTED a pre-existing workspace
    # rather than creating a fresh one). Split on the guaranteed single tab
    # character; the seeded tab id is threaded through to create_task
    # untouched, which is the only function permitted to prune it (never
    # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$PROJ_ABS" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
  fi
  if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
    echo "error: herdr did not return a tab/pane id for $W" >&2
    exit 1
  fi
  T="$HERDR_SES:$HERDR_PANE_ID"
fi
: "${WT_TARGET:=$T}"
spawn_send_text_line() { # <target> <text>
  fm_backend_herdr_send_text_line "$1" "$2"
}
spawn_current_path() { # <target>
  fm_backend_herdr_current_path "$1"
}
spawn_send_literal() { # <target> <text>
  fm_backend_herdr_send_literal "$1" "$(fm_shell_history_prefix "$2")"
}
spawn_send_key() { # <target> <key>
  fm_backend_herdr_send_key "$1" "$2"
}

# A sandboxed launch starts nono, and nono 0.80.0 holds one system-wide debug
# log subscription per session while it runs. Stop that stream once the launch
# is delivered: enforcement stays in the kernel profile, only the post-run
# denial attribution goes blind. Gated on the launch itself, so an adopted pane
# that never starts nono is untouched. Never fatal: an unresolvable pane root
# or a missing stream only warns, and the worker keeps running with its stream.
spawn_sandbox_quiet_after_launch() { # <target>
  local target=$1 root="" info=""
  case "$LAUNCH" in
  *"nono run"*) ;;
  *) return 0 ;;
  esac
  case "$BACKEND" in
  herdr)
    if [ -n "${HERDR_SES:-}" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
      info=$(fm_backend_herdr_cli "$HERDR_SES" pane process-info --pane "$HERDR_PANE_ID" 2>/dev/null) || info=
      root=$(printf '%s' "$info" | jq -er '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || root=
    fi
    ;;
  *)
    echo "warning: task $ID sandboxed launch keeps its log stream: backend $BACKEND has no pane-root probe" >&2
    return 0
    ;;
  esac
  case "$root" in
  ''|*[!0-9]*)
    echo "warning: task $ID sandboxed launch keeps its log stream: pane root for $target did not resolve" >&2
    return 0
    ;;
  esac
  "$SCRIPT_DIR/fm-sandbox-quiet.sh" --wait "${FM_SANDBOX_QUIET_WAIT:-30}" "$root" 2>&1 ||
    echo "warning: task $ID sandboxed launch keeps its log stream: quiet helper failed" >&2
}

# Lease the task copy durably instead of typing the interactive `treehouse get`
# into the pane. That command runs a subshell, so the later `cd` lands inside
# it and the pane's top-level shell stays in the project; Herdr restores a pane
# from that top-level shell's cwd, so a host restart reopened every worker in
# the primary clone. A durable lease needs no subshell, which lets the cd in
# spawn_enter_recorded_worktree move the top-level shell itself. A lease
# outlives its pane, so an aborted spawn returns it (spawn_abort_cleanup) and
# bin/fm-teardown.sh returns it for a finished task.
spawn_lease_herdr_slot() {
  WT=$(cd "$PROJ_ABS" && treehouse get --lease --lease-holder "$ID") || {
    echo "error: treehouse get --lease failed to lease a worktree for $ID from $PROJ_ABS; inspect window $T" >&2
    exit 1
  }
  [ -n "$WT" ] || { echo "error: treehouse get --lease did not report a worktree for $ID" >&2; exit 1; }
  HERDR_LEASED=1
  validate_spawn_worktree "treehouse get --lease" "$WT (leased to $ID; once inspected, release it with 'treehouse return --force $WT' from $PROJ_ABS)"
}

# Enter the exact copy recorded for this task immediately before trust setup and
# launch. Herdr restores a pane's shell cwd from its durable tab layout, so a
# treehouse subshell's foreground cwd is not enough to keep a later pane restart
# out of the primary checkout. The same explicit cd gives every backend one
# launch boundary and makes a dropped or ignored cwd change a refusal.
spawn_enter_recorded_worktree() {
  spawn_send_text_line "$WT_TARGET" "cd -- $(shell_quote "$WT")" || {
    echo "error: task $ID's endpoint could not be moved into its recorded worktree '$WT'; refusing to launch outside the copy holding its work" >&2
    exit 1
  }
}

# Verify the endpoint's cwd after the explicit handoff but before any harness
# starts.
spawn_assert_agent_worktree() {
  local expected seen i last_poll=19 agent_status
  expected=$(real_path_or_raw "$WT")
  # The out-of-pane Herdr lease no longer waits for the new shell to process
  # treehouse get. Allow its former minute of startup tolerance here, and
  # repeat the idempotent cd once in case input arrived before shell readiness.
  last_poll=120
  for i in $(seq 0 "$last_poll"); do
    [ "$i" -eq 0 ] || sleep 0.5
    seen=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$seen" ] && [ "$(real_path_or_raw "$seen")" = "$expected" ]; then
      return 0
    fi
    if [ "$i" -eq 20 ]; then
      spawn_enter_recorded_worktree
    fi
  done
  echo "error: task $ID's worker started in '${seen:-unknown}', not its recorded worktree '$WT'; refusing to continue outside the copy holding its work" >&2
  if fm_backend_herdr_parse_target "$WT_TARGET"; then
    agent_status=$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
    echo "error: Herdr pane '$WT_TARGET': last foreground_cwd='${seen:-unknown}', agent_status='${agent_status:-unknown}'" >&2
  fi
  exit 1
}

# Rewrite <meta> into <out> without the <owned keys>, placing <line>... ahead
# of the first pr= line so no key fm_pr_metadata_identity_parse refuses lands
# after the PR region.
# A launch gate runs after the task record is published, when neither the abort
# trap nor a teardown owns this endpoint, so a failed gate closes it here or the
# agent keeps running outside task control.
spawn_endpoint_cleanup() {
  fm_backend_kill "$BACKEND" "$T" "" "fm-$ID" 2>/dev/null && SPAWN_ENDPOINT_CLOSED=1 || true
}


spawn_meta_rewrite_before_pr() {  # <meta> <out> <owned keys> <line>...
  local meta=$1 out=$2 keys=$3
  shift 3
  FM_SPAWN_META_LINES=$(printf '%s\n' "$@") awk -F= -v keys="$keys" '
    BEGIN {
      n = split(keys, k, " ")
      for (i = 1; i <= n; i++) owned[k[i]] = 1
      lines = ENVIRON["FM_SPAWN_META_LINES"]
    }
    $1 in owned { next }
    !placed && $1 == "pr" { print lines; placed = 1 }
    { print }
    END { if (!placed) print lines }
  ' "$meta" >"$out"
}

if [ "$RELAUNCH" -eq 1 ]; then
  # No worktree is acquired: the recorded one is reused as-is. What must be
  # proven instead is that the adopted endpoint's shell is actually sitting in
  # that worktree, so the replacement agent starts where the work is rather
  # than wherever the pane happened to drift.
  relaunch_wt_real=$(real_path_or_raw "$WT")
  relaunch_seen=
  for _ in $(seq 1 10); do
    relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
    [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
    sleep 0.5
  done
  if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
    relaunch_cd_path=${WT//\'/\'\\\'\'}
    spawn_send_text_line "$WT_TARGET" "cd -- '$relaunch_cd_path'" || {
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and could not be told to return to its recorded worktree '$WT'; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    }
    for _ in $(seq 1 10); do
      relaunch_seen=$(spawn_current_path "$WT_TARGET" || true)
      [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ] || break
      sleep 0.5
    done
    if [ -z "$relaunch_seen" ] || [ "$(real_path_or_raw "$relaunch_seen")" != "$relaunch_wt_real" ]; then
      echo "error: task $ID's endpoint is in '${relaunch_seen:-unknown}' and did not return to its recorded worktree '$WT' when told to; refusing to relaunch an agent outside the copy holding its work" >&2
      exit 1
    fi
  fi
  validate_spawn_worktree "relaunch" "$T"
else
  fm_treehouse_reserve_recorded_slots "$PROJ_ABS" "$STATE"
  spawn_lease_herdr_slot

  # A copy another task's record still names is that task's work, even while
  # its agent is stopped and Treehouse sees nothing running there.
  SPAWN_WT_OTHER_RC=0
  fm_worktree_other_record "$STATE" "$STATE/$ID.meta" "$WT" || SPAWN_WT_OTHER_RC=$?
  case "$SPAWN_WT_OTHER_RC" in
    0)
      echo "error: treehouse handed task $ID the worktree $WT, which task $FM_WORKTREE_OTHER_ID still records as its $FM_WORKTREE_OTHER_FIELD ($FM_WORKTREE_OTHER_META); refusing to start $ID in a copy that holds another task's work; inspect window $T" >&2
      exit 1
      ;;
    1) ;;
    *)
      echo "error: could not prove no other task records the worktree $WT ($FM_LOCAL_FIRSTMATE_ERROR); refusing to start $ID in it; inspect window $T" >&2
      exit 1
      ;;
  esac

  # The owner claim lets bin/fm-teardown.sh leave a reassigned slot untouched,
  # so a slot that cannot be claimed is refused before launch.
  # Written under the Treehouse project lock held from before slot allocation
  # through metadata publication, so no other spawn or return sees a half-claim.
  if fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    if ! fm_treehouse_slot_owner_claim "$WT" "$ID" "$FM_HOME"; then
      echo "error: could not claim Treehouse pool slot $WT for task $ID; refusing to launch a worker whose slot cannot later be proved to be its own; inspect window $T" >&2
      exit 1
    fi
    SPAWN_SLOT_CLAIMED=1
  fi
fi
if [ "$RELAUNCH" -eq 0 ]; then
  freshen_spawn_worktree_base "$WT" "$BASE_BRANCH" "$PROJ_ABS" "$MODE" || exit 1
fi

# Re-assert the durable task copy after either treehouse acquisition or endpoint
# adoption. Inside a treehouse subshell this cannot move the pane shell Herdr
# restores after a server restart, which stays in the project directory.
spawn_enter_recorded_worktree
spawn_assert_agent_worktree

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
# create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
# The root is private (0700) because its path is predictable under a shared
# /tmp: a root that already exists is reused only as a real directory owned by
# this user and writable by nobody else, then tightened, so no other local user
# can plant or swap a file in it. The staged launch command lives in a sibling
# directory namespaced by home identity, not in this shared per-id root.
TASK_TMP="/tmp/fm-$ID"
if ! (umask 077 && mkdir "$TASK_TMP") 2>/dev/null; then
  if [ -L "$TASK_TMP" ] || [ ! -d "$TASK_TMP" ] || [ ! -O "$TASK_TMP" ] ||
    [ -n "$(find "$TASK_TMP" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
    ! chmod 700 "$TASK_TMP"; then
    echo "error: task temp root $TASK_TMP already exists and is not a private directory owned by this user; refusing to stage the launch command there; inspect and remove it, then retry" >&2
    exit 1
  fi
fi
mkdir -p "$TASK_TMP/gotmp"

# Per-harness turn-end hook where enabled: a file that touches
# state/<id>.turn-ended when the agent finishes a turn. Worktree-resident hooks
# and token pointers stay out of git's view so they never block teardown's dirty
# check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  # git rev-parse --git-path is relative to the repository, not to this
  # process's cwd. A caller sitting in another worktree must not mkdir
  # against its own .git file.
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  case "$EXCL" in
    /*) ;;
    *) EXCL="$WT/$EXCL" ;;
  esac
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >>"$EXCL"
}
if [ "$RELAUNCH" -eq 1 ]; then
  # Retire the previous incarnation's per-task harness wiring before arming the
  # new one. Without this, a harness switch would leave the old adapter's hook
  # files and turn-end token registry entries behind, and even a same-harness
  # relaunch would orphan the retired busy generation's token
  # (bin/fm-control-lib.sh owns where those artifacts live).
  clear_relaunch_harness_wiring "$RELAUNCH_PRIOR_HARNESS" "$WT" "$STATE_REAL" "$ID" "$KIND" || {
    echo "error: could not retire $RELAUNCH_PRIOR_HARNESS wiring for task $ID; refusing to arm the replacement" >&2
    exit 1
  }
fi
if [ "$RELAUNCH" -eq 1 ]; then
  RELAUNCH_REPLACEMENT_PENDING=1
  RELAUNCH_REPLACEMENT_HARNESS=$HARNESS
  RELAUNCH_REPLACEMENT_STATE=$STATE_REAL
  RELAUNCH_REPLACEMENT_WT=$WT
fi
# Arm the semantic busy-state contract (bin/fm-busy-lib.sh). The launch brief
# is a submitted turn, so the seed record is busy/fm-spawn, and the minted gen
# lets the extension's events reject a superseded incarnation as stale.
busy_notify_turnend=true
BUSY_GEN=
case "$HARNESS" in
pi | pi-signed)
  BUSY_GEN=$("$FM_ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID") || {
    echo "error: failed to arm the busy-state contract for $ID" >&2
    exit 1
  }
  [ "$RELAUNCH" -ne 1 ] || RELAUNCH_REPLACEMENT_BUSY_GEN=$BUSY_GEN
  ;;
esac
  case "$HARNESS" in
  pi | pi-signed)
    # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
    # loaded from inside the project (verified live), but an explicit -e path
    # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
    pi_stream_monitoring=false
    if [ "$(fm_busy_stream_seconds "${FM_STREAM_SILENT_MAX_SECS:-}")" -gt 0 ]; then
      pi_stream_version=$(fm_run_timed 5 "$PI_BIN" --version 2>/dev/null || true)
      if fm_busy_pi_stream_version_supported "$pi_stream_version"; then
        pi_stream_monitoring=true
      else
        echo "warning: $HARNESS model-stream observation unavailable for version ${pi_stream_version:-unknown}; verified version: 1.2.0; existing busy bound remains active" >&2
      fi
    fi
    cat >"$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate semantic busy-state events, turn-end notification, and - when this
// worker was launched with opted-in stream observation - foreground model-stream
// evidence; written by fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
// "session_shutdown" marks the session dead: a handler resumed after it records nothing.
import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";
const notifyTurnEnd = $busy_notify_turnend;
const streamMonitoring = $pi_stream_monitoring;
const excludeTools = "$EXCLUDE_TOOLS".split(",").filter(Boolean);
const excludeFile = $(perl -MJSON::PP -MEncode=decode_utf8 -e 'print encode_json(decode_utf8($ARGV[0]))' -- "$CONFIG/crew-exclude-tools");
const statusFile = $(perl -MJSON::PP -MEncode=decode_utf8 -e 'print encode_json(decode_utf8($ARGV[0]))' -- "$STATE/$ID.status");
const busyEvent = (state: string, event: string, resetEpoch = 0) =>
  new Promise<void>((resolve) => {
    const args = [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "pi-ext", "--event", event,
    ];
    if (resetEpoch > 0) args.push("--reset-epoch", String(resetEpoch));
    execFile("$FM_ROOT/bin/fm-busy-event.sh", args, () => resolve());
  });
const quotaResetEpoch = (provider: string): Promise<number> =>
  new Promise((resolve) => {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(provider)) return resolve(0);
    execFile("quota-axi", ["--provider", provider, "--json", "--no-credential-refresh"], { timeout: 5000 }, (error, stdout) => {
      if (error) return resolve(0);
      try {
        const rows = JSON.parse(stdout).providers ?? [];
        const resetsAt = rows.find((row: any) => row.provider === provider)?.resetsAt;
        const epoch = typeof resetsAt === "number" ? resetsAt : Date.parse(resetsAt);
        resolve(Number.isFinite(epoch) ? Math.floor(epoch > 1e12 ? epoch / 1000 : epoch) : 0);
      } catch {
        resolve(0);
      }
    });
  });
const providerLimitReset = async (entries: any[], provider: string): Promise<number | null> => {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
    const message = entry.message;
    if (message.stopReason !== "error") return null;
    const detail = String(message.errorMessage ?? "");
    if (!/(?:usage[ _-]*limit|rate[ _-]*limit|quota[ _-]*(?:exceeded|limit)|daily[ _-]*limit)/i.test(detail)) return null;
    const match = detail.match(/(?:reset|resets|retry)[^0-9]*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)/i);
    if (match) {
      const epoch = Date.parse(match[1]);
      if (Number.isFinite(epoch)) return Math.floor(epoch / 1000);
    }
    return (await quotaResetEpoch(provider)) || 0;
  }
  return null;
};
export default async function (pi: any) {
  let checkedExclusions = false;
  let shutDown = false;
  // session_shutdown precedes invalidation, so a set flag means pi and ctx are dead and nothing may be recorded.
  pi.on("session_shutdown", () => { shutDown = true; });
  let request = 0;
  let activeRequest = 0;
  let lastStreamProgress = -Infinity;
  let lastContent = "";
  let streamWrites: Promise<void> = Promise.resolve();
  const streamEvent = (operation: string, current: number) => {
    streamWrites = streamWrites.then(() => new Promise<void>((resolve) => {
      execFile("bash", [
        "-c", '. "\$1"; shift; fm_exec_timed 5 1 "\$@"', "fm-stream-observation",
        "$FM_ROOT/bin/fm-timeout-lib.sh", "$FM_ROOT/bin/fm-busy-event.sh",
        "stream", "$STATE_REAL", "$ID", operation,
        "--gen", "$BUSY_GEN", "--request", String(current),
      ], (error) => {
        if (error) console.error("Firstmate model-stream observation write failed; inspect worker instrumentation.");
        resolve();
      });
    }));
    return streamWrites;
  };
  const closeStream = () => {
    const current = activeRequest;
    activeRequest = 0;
    return current ? streamEvent("close", current) : streamWrites;
  };
  if (streamMonitoring) {
    // Foreground context excludes Pi's background provider/cache-warming calls.
    pi.on("context", () => {
      request = Math.max(request + 1, Date.now());
      activeRequest = request;
      lastStreamProgress = -Infinity;
      lastContent = "";
      return streamEvent("open", request);
    });
    pi.on("message_update", (event: any) => {
      if (!activeRequest || event.message?.role !== "assistant") return streamWrites;
      const now = Date.now();
      if (now - lastStreamProgress < 1000) return streamWrites;
      const content = (event.message.content || []).map((part: any) => {
        if (part.type === "text" && part.text) return ["text", part.text];
        if (part.type === "thinking" && (part.thinking || part.thinkingSignature)) {
          return ["thinking", part.thinking || "", part.thinkingSignature || ""];
        }
        if (part.type === "toolCall" && part.name) return ["toolCall", part.name, part.arguments];
        return null;
      }).filter(Boolean);
      if (!content.length) return streamWrites;
      const signature = JSON.stringify(content);
      if (signature === lastContent) return streamWrites;
      lastContent = signature;
      lastStreamProgress = now;
      return streamEvent("progress", activeRequest);
    });
    pi.on("message_end", (event: any) => {
      if (event.message?.role === "assistant") return closeStream();
    });
    pi.on("tool_execution_start", closeStream);
  }
  pi.on("agent_start", async () => {
    if (shutDown) return;
    // Snapshot the registry before the await: pi getters throw once the session is replaced.
    let unmatched: string[] | null = null;
    if (!checkedExclusions && excludeTools.length) {
      const loaded = new Set(pi.getAllTools().map((tool: any) => tool.name));
      unmatched = excludeTools.filter((name) => !loaded.has(name));
    }
    await busyEvent("busy", "agent-start");
    if (shutDown) return;
    // Verify only this worker's registry, never connect servers from Firstmate.
    // Check before actions so the warning cannot supersede this turn's terminal status.
    if (unmatched) {
      if (unmatched.length) {
        appendFileSync(statusFile, "note [at=" + Math.floor(Date.now() / 1000) + "]: warning: " + excludeFile
          + " unmatched exclusion entries (unverified: absent from the worker's loaded-tool registry; excluded tools or unavailable servers cannot be verified): "
          + unmatched.join(", ") + "\n");
      }
      checkedExclusions = true;
    }
  });
  pi.on("agent_settled", async (_event: any, ctx: any) => {
    if (shutDown) return;
    // Snapshot ctx before the await: its getters throw once the session is replaced.
    const idle = !ctx || typeof ctx.isIdle !== "function" || ctx.isIdle();
    const entries = ctx?.sessionManager?.getEntries?.() ?? [];
    const provider = String(ctx?.model?.provider ?? "");
    if (!idle) return;
    await closeStream();
    const resetEpoch = await providerLimitReset(entries, provider);
    if (shutDown) return;
    if (resetEpoch !== null) return busyEvent("idle", "provider-limit", resetEpoch);
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => { if (notifyTurnEnd) execFile("touch", ["$TURNEND"]); });
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "progress", "$STATE_REAL", "$ID", "--gen", "$BUSY_GEN",
    ]);
  });
  // Imported last and guarded, so busy-state reporting never depends on the
  // presentation module that collapses the launch brief and doorbell rows.
  try {
    const rows = await import("$FM_ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts");
    rows.installCalmOperationalUserLayout();
    pi.on("session_start", (_event: any, ctx: any) => {
      if (ctx?.ui?.theme) rows.bindOperationalRowTheme(ctx.ui.theme);
    });
  } catch (error) {
    console.error("Firstmate: operational-row presentation unavailable, skipping. " + error);
  }
}
EOF
    ;;
  esac

# Per-task git hooksPath for the pane. Installed for every kind, with or without config/keep-ai-trailers. The commit-msg strip
# removes AI trailers at the commit object unless the home opts in to keeping
# them. The pre-commit identity guard and the pre-push backstop run in both
# modes. The pane receives this directory via GIT_CONFIG_* below, which
# overrides a project's husky core.hooksPath without rewriting it; the installer
# chains the previous hooks so they still run. A launch whose worktree is not
# git fails closed rather than shipping a runtime without the guard.
# A forge=external ship always gets this directory, because its pre-push
# wrapper carries the guard that keeps task branches off the shared origin; a
# home that keeps trailers gets a commit-msg wrapper that only chains.

GIT_HOOKS_DIR="$STATE_REAL/$ID.git-hooks"
GIT_HOOKS_INSTALLED=0
if [ "$EXTERNAL_REVIEW" = 1 ]; then
  PUSH_GUARD_FILE="$STATE_REAL/$ID.push-guard"
  guard_args=("$PUSH_GUARD_FILE" "$WT" "$BRANCH" "$(fm_ship_branch_prefix "$BRANCH" "$ID")")
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || guard_args+=("$EXTERNAL_BACKUP_REMOTE" "$EXTERNAL_BACKUP_PREFIX")
  strip_args=()
  [ "$KEEP_AI_TRAILERS" = 0 ] || strip_args=(--no-strip)
  { "$FM_ROOT/bin/fm-git-push-guard.sh" write "${guard_args[@]}" \
    && "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install "${strip_args[@]+"${strip_args[@]}"}" \
      --push-guard "$PUSH_GUARD_FILE" "$GIT_HOOKS_DIR" "$WT"; } || {
    echo "error: could not install the external-review push guard hooks for $ID" >&2
    exit 1
  }
  GIT_HOOKS_INSTALLED=1
elif [ "$KEEP_AI_TRAILERS" = 0 ]; then
  "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install "$GIT_HOOKS_DIR" "$WT" || {
    echo "error: could not install the per-task git hooks for $ID" >&2
    exit 1
  }
  GIT_HOOKS_INSTALLED=1
else
  "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh" install --no-strip "$GIT_HOOKS_DIR" "$WT" || {
    echo "error: could not install the per-task git hooks for $ID" >&2
    exit 1
  }
  GIT_HOOKS_INSTALLED=1
fi

if [ "$KIND" = scout ]; then
  MODE=
  YOLO=
fi

# Resolve the optional default-off W3C trace context (bin/fm-trace-context-lib.sh,
# docs/configuration.md): the one carrier both recorded in meta and injected into
# the pane, so an observer reads exactly what the child receives. Empty only when
# disabled or on entropy/validation failure. Reuses this task's already-recorded
# value on relaunch; any other spawn roots a fresh trace, never adopting this
# process's own ambient TRACEPARENT, so each routed task is its own trace
# boundary even under a persistent supervisor. Never aborts the spawn and adds
# only the cost of reading a few bytes of entropy.
#
  SPAWN_TRACE_EFFECTIVE=$(fm_trace_context_session_effective "$STATE/.trace-context-effective")
  if [ "$SPAWN_TRACE_EFFECTIVE" = on ]; then
    SPAWN_TRACEPARENT=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$STATE/$ID.meta" || true)
  else
    SPAWN_TRACEPARENT=
  fi

META_WINDOW=$T
SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"
SPAWN_META_PATH="$STATE/$ID.meta"
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_TMP="$STATE/.$ID.meta.relaunch.${BASHPID:-$$}"
else
  SPAWN_META_TMP="$STATE/.$ID.meta.spawn.${BASHPID:-$$}"
  SPAWN_FRESH_COMMIT_PENDING=1
fi
SPAWN_META_PATH=$SPAWN_META_TMP
if [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_HOME_SNAPSHOT="$STATE/$ID.home-snapshot"
  "$SCRIPT_DIR/fm-home-write-diff.sh" snapshot "$SPAWN_HOME_SNAPSHOT" "$WT" ||
    echo "warning: could not record the state of ~/.claude and ~/.pi/agent for $ID; cleanup will not report its writes there" >&2
fi
preserve_relaunch_meta() {
  awk -F= '
    BEGIN {
      split("window endpoint_task_id worktree project harness kind mode yolo branch tasktmp base_branch upstream_consent forge backup_remote backup_prefix model effort account account_provider claude_account quota_gate busy_gen spawn_gen traceparent backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id home projects control_relaunch_tx", keys, " ")

      for (i in keys) owned[keys[i]] = 1
    }
    !($1 in owned)
  ' "$RELAUNCH_META"
}
{
  echo "window=$META_WINDOW"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  [ -z "$MODE" ] || echo "mode=$MODE"
  [ -z "$YOLO" ] || echo "yolo=$YOLO"
  [ -z "${BRANCH:-}" ] || echo "branch=$BRANCH"
  echo "tasktmp=$TASK_TMP"
  [ -z "$BASE_BRANCH" ] || echo "base_branch=$BASE_BRANCH"
  [ -z "$UPSTREAM_CONSENT" ] || echo "upstream_consent=$UPSTREAM_CONSENT"
  # Read by bin/fm-dod-lib.sh's ready-report gate; absent on every other forge.
  [ "$EXTERNAL_REVIEW" = 0 ] || echo "forge=external"
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || echo "backup_remote=$EXTERNAL_BACKUP_REMOTE"
  [ -z "$EXTERNAL_BACKUP_REMOTE" ] || echo "backup_prefix=$EXTERNAL_BACKUP_PREFIX"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  [ -z "$DISPATCH_OVERRIDE" ] || printf 'dispatch_override=%s\n' "$DISPATCH_OVERRIDE"
  # The worker account pin, only when this home declares one, so an unpinned
  # task record stays byte-identical.
  [ -z "$WORKER_ACCOUNT" ] || echo "account=$WORKER_ACCOUNT_DECLARED"
  [ -z "$WORKER_ACCOUNT_PROVIDER" ] || echo "account_provider=$WORKER_ACCOUNT_PROVIDER"
  [ -z "$CLAUDE_ACCOUNT" ] || echo "claude_account=$CLAUDE_ACCOUNT"
  gate_note=$(fm_quota_spawn_gate_note)
  [ -z "$gate_note" ] || echo "quota_gate=$gate_note"
  proof_note=$(fm_dispatch_proof_note)
  [ -z "$proof_note" ] || echo "dispatch_proof=$proof_note"
  [ -z "${BUSY_GEN:-}" ] || echo "busy_gen=$BUSY_GEN"
  echo "spawn_gen=$SPAWN_GEN"
  if [ "$RELAUNCH" -eq 1 ] && [ -z "$(fm_meta_get "$RELAUNCH_META" first_spawn_gen)" ]; then
    prior_spawn_gen=$(fm_meta_get "$RELAUNCH_META" spawn_gen)
    [ -n "$prior_spawn_gen" ] && echo "first_spawn_gen=$prior_spawn_gen"
  fi
  # Default-off writes no traceparent= line.
  echo "backend=$BACKEND"
  {
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  }
  if [ "$SPAWN_CONTROL_PARENT" = 1 ] && [ -n "${FM_CONTROL_RELAUNCH_TX:-}" ]; then
    echo "control_relaunch_tx=$FM_CONTROL_RELAUNCH_TX"
  fi
  # Preserved lines stay last: any key after pr= besides pr_head= and x_* fails poll authentication.
  if [ "$RELAUNCH" -eq 1 ]; then
    preserve_relaunch_meta
  fi
} >"$SPAWN_META_PATH" || {
  echo "error: task record for $ID could not be prepared at $SPAWN_META_PATH" >&2
  exit 1
}
if [ "$RELAUNCH" -eq 0 ]; then
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  SPAWN_META_TMP=
fi

# Fuse the backlog In-flight transition into the publication that just created
# the record (bin/fm-backlog-transition-lib.sh owns the invariant). It runs under
# this task's own meta lock, so a steer or teardown racing the same id stays
# serialized exactly as before. The call itself is deferred to the final commit
# point below so every earlier launch-delivery failure remains unwindable.
spawn_commit_backlog_transition() {
  [ "$BACKLOG_TRANSITION" = 1 ] || return 0
  fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"
}

# The deferred-signal exit path's preservation report. A claim about preserved
# state is only trustworthy if that state is read back after the commit: the
# commit's own exit status has been observed to agree with a row that did not
# actually move (fm-yi4j evidence, 2026-09-05). This re-reads the paired record
# and the backlog row under the same per-task lock as the commit, repairs a row
# the commit believed it moved, and sets SPAWN_PRESERVED_CLAIM to exactly what
# was verified or attempted - never intent phrased as outcome.
spawn_report_preserved_state() {
  local repair_error=
  if ! fm_backlog_record_present "$STATE/$ID.meta" "task record" "$STATE"; then
    SPAWN_PRESERVED_CLAIM="preservation could not be verified: its paired task record is missing; close out its backlog item by hand"
    return 1
  fi
  if ! fm_backlog_row_probe "$DATA" "$ID"; then
    if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item was not found; close out its paired task record by hand"
    else
      SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item state is unreadable (${FM_BACKLOG_ROW_ERROR:-no error recorded}); close out its paired task record and backlog item by hand"
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="verified preserved: its paired task record is present and its backlog item is In flight"
    return 0
  fi
  # The commit reported success, but the row does not read back In flight:
  # move it now under the same lock and verify the result before naming it.
  fm_backlog_start "$DATA" "$ID" || repair_error=$FM_BACKLOG_TRANSITION_ERROR
  if [ -z "$repair_error" ] &&
    fm_backlog_row_probe "$DATA" "$ID" &&
    [ "$FM_BACKLOG_ROW_STATE" = "in_flight no no" ]; then
    SPAWN_PRESERVED_CLAIM="its backlog item did not read back In flight after the commit; it was moved to In flight now and verified, together with its paired task record"
    return 0
  fi
  SPAWN_PRESERVED_CLAIM="preservation could not be verified: its backlog item reads ${FM_BACKLOG_ROW_STATE:-unreadable}${repair_error:+, and moving it to In flight failed ($repair_error)}; close out its paired task record and backlog item by hand"
  return 1
}

if [ "$RELAUNCH" -eq 1 ]; then
  SPAWN_META_PUBLISH_STARTED=1
  if ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
    echo "error: replacement task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  RELAUNCH_REPLACEMENT_PENDING=0
  SPAWN_META_PUBLISH_STARTED=0
  SPAWN_META_TMP=
fi
# A dispatch or relaunch keeps the per-task meta lock through launch delivery.
# The backlog mutation is deliberately the final fallible commit below, so
# teardown cannot remove a relaunched record while its replacement worker is
# still being delivered, cannot observe or complete a fresh provisional record
# between its state check and `tasks-axi start`, and a delivery failure cannot
# follow a committed In-flight transition.
if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
  SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
  fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK"
fi
if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
  # The record is published, so this task is now part of the set a teardown
  # enumerates and locks per task. The set lock is only needed across that
  # publication.
  SPAWN_TASK_SET_LOCK_HELD=0
  fm_lock_release "$SPAWN_TASK_SET_LOCK"
fi

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_opinput=$(shell_quote "$FM_ROOT/bin/fm-operational-input.sh")
sq_worktree=$(shell_quote "$WT")
MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
# A pinned Pi launch confines Pi's model lookup to the declared provider.
[ -z "$WORKER_ACCOUNT_PROVIDER" ] || MODELFLAG="--provider $(shell_quote "$WORKER_ACCOUNT_PROVIDER") $MODELFLAG"
EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$EFFORT" "$MODEL") || exit 1
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__OPINPUT__/$sq_opinput}
case "$HARNESS" in
pi | pi-signed) LAUNCH=${LAUNCH//__PIBIN__/"$(shell_quote "$PI_BIN")"} ;;
esac
LAUNCH=${LAUNCH//__WORKTREE__/$sq_worktree}

# A worker account pin names the agent directory the launch uses.
FM_SANDBOX_PROFILE=
if { [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; } && { [ "$KIND" = scout ] || [ "${MODE:-}" = no-mistakes ]; }; then
  if "$SCRIPT_DIR/fm-agent-sandbox.sh" enabled "$CONFIG"; then
    "$SCRIPT_DIR/fm-agent-sandbox.sh" check "$CONFIG" || exit 1
    FM_SANDBOX_ROUTE=$("$SCRIPT_DIR/fm-agent-sandbox.sh" model-route "${MODEL:-}") || exit 1
    case "$FM_SANDBOX_ROUTE" in
    proxy:opencode-go)
      FM_SANDBOX_RENDER=$("$SCRIPT_DIR/fm-agent-sandbox.sh" render "$STATE_REAL" "$ID" "$WT" "$TASK_TMP" "$DATA/$ID" "$GIT_HOOKS_DIR" "$FM_ROOT" "$KIND" "${MODE:-}") || exit 1
      FM_SANDBOX_PROFILE=$(printf '%s\n' "$FM_SANDBOX_RENDER" | sed -n 's/^profile=//p')
      FM_SANDBOX_PIDIR=$(printf '%s\n' "$FM_SANDBOX_RENDER" | sed -n 's/^pi_dir=//p')
      [ -n "$FM_SANDBOX_PROFILE" ] && [ -n "$FM_SANDBOX_PIDIR" ] || {
        echo "error: sandbox profile render for $ID printed no paths" >&2
        exit 1
      }
      LAUNCH="FM_AGENT_SANDBOX_PI_BIN=$(shell_quote "$PI_BIN") FM_AGENT_SANDBOX_CAPTURE_LOG=$(shell_quote "$TASK_TMP/nono-capture.log") env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH PI_CODING_AGENT_DIR=$(shell_quote "$FM_SANDBOX_PIDIR") TMPDIR=$(shell_quote "$TASK_TMP") nono run --profile $(shell_quote "$FM_SANDBOX_PROFILE") --allow-cwd --no-rollback-prompt -- $LAUNCH"
      ;;
    claude)
      if "$SCRIPT_DIR/fm-agent-sandbox.sh" claude-token-check "$CONFIG" 2>/dev/null; then
        FM_SANDBOX_TOKEN=$("$SCRIPT_DIR/fm-agent-sandbox.sh" claude-token-path "$CONFIG")
        FM_SANDBOX_RENDER=$("$SCRIPT_DIR/fm-agent-sandbox.sh" render "$STATE_REAL" "$ID" "$WT" "$TASK_TMP" "$DATA/$ID" "$GIT_HOOKS_DIR" "$FM_ROOT" "$KIND" "${MODE:-}" claude) || exit 1
        FM_SANDBOX_PROFILE=$(printf '%s\n' "$FM_SANDBOX_RENDER" | sed -n 's/^profile=//p')
        FM_SANDBOX_PIDIR=$(printf '%s\n' "$FM_SANDBOX_RENDER" | sed -n 's/^pi_dir=//p')
        [ -n "$FM_SANDBOX_PROFILE" ] && [ -n "$FM_SANDBOX_PIDIR" ] || {
          echo "error: sandbox profile render for $ID printed no paths" >&2
          exit 1
        }
        LAUNCH="FM_AGENT_SANDBOX_CLAUDE_TOKEN_FILE=$(shell_quote "$FM_SANDBOX_TOKEN") FM_AGENT_SANDBOX_CAPTURE_LOG=$(shell_quote "$TASK_TMP/nono-capture.log") env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=$(shell_quote "$TASK_TMP/claude") PI_CODING_AGENT_DIR=$(shell_quote "$FM_SANDBOX_PIDIR") TMPDIR=$(shell_quote "$TASK_TMP") nono run --profile $(shell_quote "$FM_SANDBOX_PROFILE") --allow-cwd --no-rollback-prompt -- $LAUNCH"
      else
        echo "warning: sandboxed Claude sign-in needs a setup token; launching $ID unsandboxed" >&2
      fi
      ;;
    *)
      echo "warning: the worker sandbox covers the opencode-go provider only; launching $ID unsandboxed" >&2
      ;;
    esac
  fi
fi
FM_SANDBOX_PIDIR=${FM_SANDBOX_PIDIR:-}
if [ -n "$WORKER_ACCOUNT" ]; then
  case "$HARNESS" in
  pi | pi-signed)
    LAUNCH="PI_CODING_AGENT_DIR=$(shell_quote "${FM_SANDBOX_PIDIR:-$WORKER_ACCOUNT_ROOT}") $LAUNCH"
    ;;
  esac
fi
if [ -n "$CLAUDE_ACCOUNT_SELECTION" ]; then
  if [ -n "$CLAUDE_ACCOUNT_ROOT" ]; then
    LAUNCH="$(fm_worker_account_claude_shed) CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_ACCOUNT_ROOT") $LAUNCH"
  else
    LAUNCH="$(fm_worker_account_claude_shed) -u CLAUDE_CONFIG_DIR $LAUNCH"
  fi
fi
# Implement the launch-delivery contract in this script's header. The full
# home-identity hash isolates equal task ids across homes, and the spawn token in
# the final filename keeps a buffered source line bound to this incarnation.
spawn_launch_home_token() {
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}
LAUNCH_HOME_TOKEN=$(spawn_launch_home_token "$FM_HOME") || LAUNCH_HOME_TOKEN=
if [ -z "$LAUNCH_HOME_TOKEN" ]; then
  echo "error: could not derive a home identity for the staged launch file" >&2
  exit 1
fi
case "$SPAWN_GEN" in
  *[!A-Za-z0-9.]*|'') echo "error: spawn incarnation token is not a usable launch-file nonce" >&2; exit 1 ;;
esac
LAUNCH_DIR="/tmp/fm-$ID+$LAUNCH_HOME_TOKEN"
# Pane-scoped override: git in this worker reads our per-task hooks without
# rewriting the project's core.hooksPath. The helper appends after the
# GIT_CONFIG_COUNT entries the worker actually inherits (after any launch
# environment filtering), so credential.helper and other inherited entries
# survive. A home that keeps trailers gets a commit-msg wrapper that only
# chains, so the repository's own hooks still run.
if [ "$GIT_HOOKS_INSTALLED" = 1 ]; then
  GIT_CONFIG_ENV_FILE=$(shell_quote "$LAUNCH_DIR/git-config.$SPAWN_GEN.sh")
  LAUNCH="$(shell_quote "$FM_ROOT/bin/fm-git-strip-ai-trailers.sh") env-file $(shell_quote "$GIT_HOOKS_DIR") $GIT_CONFIG_ENV_FILE && . $GIT_CONFIG_ENV_FILE || return 1 2>/dev/null || exit 1; $LAUNCH"
fi
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  LAUNCH="export LAVISH_AXI_HOST=$(shell_quote "$LAVISH_AXI_HOST"); $LAUNCH"
fi
# Every launch also exports the absolute path of this task's steering inbox, so
# the constant doorbell line (bin/fm-task-inbox-lib.sh) can name
# "$FM_TASK_INBOX" instead of a path that grows with the home's depth. Like the
# kill switch below it is an export statement, so it survives a compound raw
# launch and the launch-env-allowlist `env -i` wrapper.
LAUNCH="export FM_TASK_INBOX=$(shell_quote "$STATE_REAL/$ID.inbox"); $LAUNCH"
# An export rather than a command prefix, so it reaches every command of a compound raw launch.
LAUNCH="export COMPACT_ADVISER_DISABLE=1; $LAUNCH"
# The herdr server builds the pane without this process's environment, so the value rides the launch text.
if [ -n "${DISABLE_AUTOUPDATER:-}" ]; then
  LAUNCH="export DISABLE_AUTOUPDATER=$(shell_quote "$DISABLE_AUTOUPDATER"); $LAUNCH"
fi
if [ -z "$SPAWN_TRACEPARENT" ] && [ "$RELAUNCH" -eq 1 ]; then
  LAUNCH="unset TRACEPARENT; $LAUNCH"
fi

spawn_record_traceparent() {
  local meta="$STATE/$ID.meta" status=0 acquired=0
  # Fresh publication still owns the lock. Relaunch deliberately uses a short
  # independent critical section so other metadata interfaces can serialize.
  if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
    SPAWN_META_LOCK=$(fm_meta_lock_path "$meta") || return 1
    fm_lock_acquire_wait "$SPAWN_META_LOCK"
    SPAWN_META_LOCK_HELD=1
    acquired=1
  fi
  SPAWN_META_TMP="$STATE/.$ID.meta.trace.${BASHPID:-$$}"
  if [ ! -f "$meta" ] || [ ! -w "$meta" ] ||
    ! spawn_meta_rewrite_before_pr "$meta" "$SPAWN_META_TMP" traceparent \
      "traceparent=$SPAWN_TRACEPARENT" ||
    ! fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$meta" "task record" "$STATE"; then
    status=1
    rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  fi
  SPAWN_META_TMP=
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$SPAWN_META_LOCK" || status=1
    SPAWN_META_LOCK_HELD=0
  fi
  return "$status"
}

# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it. Sent before the launch command so
# the env is set when the agent starts; the brief sleep lets the export land.
spawn_send_text_line "$T" "export GOTMPDIR=$TASK_TMP/gotmp"
# Export the compact-adviser kill switch into the pane shell through the same
# pre-launch channel, so later commands in that shell inherit it too. The launch
# command independently establishes the value for the agent process itself.
spawn_send_text_line "$T" "export COMPACT_ADVISER_DISABLE=1"
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  spawn_send_text_line "$T" "export LAVISH_AXI_HOST=$(shell_quote "$LAVISH_AXI_HOST")"
fi
# The id passed the bare-slug check above, so it carries no shell syntax.
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  spawn_send_text_line "$T" "export FM_TASK_ID=$ID"
fi
if [ -n "$SPAWN_TRACEPARENT" ]; then
  if spawn_send_text_line "$T" "export TRACEPARENT=$SPAWN_TRACEPARENT"; then
    if ! spawn_record_traceparent; then
      LAUNCH="unset TRACEPARENT; $LAUNCH"
    fi
  else
    TRACE_SEND_STATUS=$?
    if [ "$TRACE_SEND_STATUS" -eq 2 ]; then
      echo "error: trace-context input could not be cleared for $W; refusing to append the launch command" >&2
      exit 1
    fi
    LAUNCH="unset TRACEPARENT; $LAUNCH"
  fi
fi
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  if HEAVY_QUEUE_DIR=$(spawn_heavy_queue_path); then
    LAUNCH="export PATH=$(shell_quote "$HEAVY_QUEUE_DIR")\":\$PATH\"; $LAUNCH"
  fi
fi
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  LAUNCH_ENV_PREFIX='/usr/bin/env -i'
  for env_name in HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE \
    TMPDIR TMP TEMP GOTMPDIR HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH \
    HERDR_PANE_ID TERM_PROGRAM FM_TASK_ID COMPACT_ADVISER_DISABLE LAVISH_AXI_HOST \
    $LAUNCH_ENV_NAMES; do
    # Only validated names enter shell syntax. Values expand once, quoted, in
    # the pane shell and never become source text or spawn-process snapshots.
    # shellcheck disable=SC2016
    printf -v env_arg '${%s+"%s=$%s"}' "$env_name" "$env_name" "$env_name"
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX $env_arg"
  done
  # Last, because env applies assignments left to right and this value must win over a forwarded one.
  LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX COMPACT_ADVISER_DISABLE=1"
  if [ -n "$SPAWN_TRACEPARENT" ]; then
    # shellcheck disable=SC2016
    LAUNCH_ENV_PREFIX="$LAUNCH_ENV_PREFIX "'${TRACEPARENT+"TRACEPARENT=$TRACEPARENT"}'
  fi
  LAUNCH="$LAUNCH_ENV_PREFIX /bin/sh -c $(shell_quote "$LAUNCH")"
fi
if ! (umask 077 && mkdir "$LAUNCH_DIR") 2>/dev/null; then
  if [ -L "$LAUNCH_DIR" ] || [ ! -d "$LAUNCH_DIR" ] || [ ! -O "$LAUNCH_DIR" ] ||
    [ -n "$(find "$LAUNCH_DIR" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] ||
    ! chmod 700 "$LAUNCH_DIR"; then
    echo "error: task launch directory $LAUNCH_DIR already exists and is not a private directory owned by this user; refusing to stage the launch command there; inspect and remove it, then retry" >&2
    exit 1
  fi
fi
LAUNCH_FILE="$LAUNCH_DIR/launch.$SPAWN_GEN.sh"
LAUNCH_STAGE="$LAUNCH_DIR/.launch.$SPAWN_GEN.tmp"
if [ -e "$LAUNCH_FILE" ] || [ -L "$LAUNCH_FILE" ]; then
  echo "error: task launch file $LAUNCH_FILE already exists; refusing to replace it" >&2
  exit 1
fi
if ! (umask 077 && printf '%s\n' "$LAUNCH" >"$LAUNCH_STAGE" &&
  chmod 0600 "$LAUNCH_STAGE" && mv -f "$LAUNCH_STAGE" "$LAUNCH_FILE"); then
  rm -f "$LAUNCH_STAGE"
  echo "error: could not stage the launch command at $LAUNCH_FILE" >&2
  exit 1
fi
sleep 0.3
if [ "$RELAUNCH" -eq 1 ] && [ "$RELAUNCH_REBIND" -eq 0 ] &&
  { [ "$HARNESS" = pi ] || [ "$HARNESS" = pi-signed ]; }; then
  # Resuming the bound session would keep Herdr's status authority but hand
  # the replacement its predecessor's conversation.
  fm_backend_herdr_parse_target "$T" &&
    fm_backend_herdr_pane_session_binding_clear "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" ||
    echo "warning: herdr pane $T still binds its previous agent's session, so its status may not follow the fresh replacement for $ID" >&2
fi
SPAWN_LAUNCH_SENT=1
LAUNCH_SOURCE_TEXT=". $(shell_quote "$LAUNCH_FILE")"
spawn_send_literal "$T" "$LAUNCH_SOURCE_TEXT" || exit 1
sleep 0.3
if [ "${HERDR_PROJECTED:-0}" -eq 1 ]; then
  HERDR_PROJECTION_ABORT_CLEANUP=0
  spawn_herdr_presentation_order_lock_release
fi
spawn_send_key "$T" Enter || exit 1
spawn_sandbox_quiet_after_launch "$T"
# This is the commit point: all endpoint and harness delivery that can reject
# the spawn has succeeded. Re-read and transition while holding the same
# per-task lock as metadata publication, then and only then report success.
if [ "$SPAWN_META_LOCK_HELD" != 1 ]; then
  SPAWN_META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  fm_lock_acquire_wait "$SPAWN_META_LOCK"
  SPAWN_META_LOCK_HELD=1
fi
SPAWN_DEFERRED_SIGNAL=
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  trap 'SPAWN_DEFERRED_SIGNAL=HUP' HUP
  trap 'SPAWN_DEFERRED_SIGNAL=INT' INT
  trap 'SPAWN_DEFERRED_SIGNAL=TERM' TERM
fi
SPAWN_BACKLOG_COMMIT_STATUS=0
# Both the commit and its preservation read-back run under this task's meta
# lock, so an unresponsive tasks-axi there would hold the lock - and every
# lifecycle operation waiting on it - open ended, with even the deferred
# signals parked in a trap. Bound each invocation
# (bin/fm-backlog-transition-lib.sh's fm_tasks_axi): a timed-out call
# fails through the ordinary error plumbing, and the interrupted exit path
# reports it as the reason the preservation could not be verified.
FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
if spawn_commit_backlog_transition; then
  SPAWN_FRESH_COMMIT_PENDING=0
else
  SPAWN_BACKLOG_COMMIT_STATUS=$?
  if spawn_commit_backlog_transition; then
    SPAWN_BACKLOG_COMMIT_STATUS=0
    SPAWN_FRESH_COMMIT_PENDING=0
  fi
fi
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  if [ "$RELAUNCH" -eq 0 ]; then
    if spawn_fresh_commit_rollback; then
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); its record was removed so no worker is left that the backlog does not own - close out endpoint $T and local copy $WT by hand, then re-run the spawn" >&2
    else
      echo "error: task $ID's backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR), and failed-dispatch cleanup is incomplete; the provisional record may remain at $STATE/$ID.meta - close out endpoint $T and local copy $WT by hand, then remove the record and busy state before retrying" >&2
    fi
  else
    echo "error: task $ID was republished but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); fix the backlog and re-run the relaunch" >&2
  fi
fi
trap - HUP INT TERM
if [ "$SPAWN_BACKLOG_COMMIT_STATUS" -ne 0 ]; then
  exit "$SPAWN_BACKLOG_COMMIT_STATUS"
fi
if [ -n "$SPAWN_DEFERRED_SIGNAL" ]; then
  case "$SPAWN_DEFERRED_SIGNAL" in
  HUP) SPAWN_DEFERRED_SIGNAL_STATUS=129 ;;
  INT) SPAWN_DEFERRED_SIGNAL_STATUS=130 ;;
  TERM) SPAWN_DEFERRED_SIGNAL_STATUS=143 ;;
  esac
  # Keep deferring further signals so the read-back below cannot itself be
  # killed halfway through verifying or correcting the preserved state.
  trap 'SPAWN_DEFERRED_SIGNAL=$SPAWN_DEFERRED_SIGNAL' HUP INT TERM
  # Deliberately unguarded against errexit: a failed verification still set
  # the honest attempted-preservation claim the exit below reports.
  spawn_report_preserved_state || true
  trap - HUP INT TERM
  echo "error: spawn of $ID was interrupted after launch delivery began; $SPAWN_PRESERVED_CLAIM" >&2
  exit "$SPAWN_DEFERRED_SIGNAL_STATUS"
fi
fm_lock_release "$SPAWN_META_LOCK"
SPAWN_META_LOCK_HELD=0
# Only now can no rollback remove the record that lets teardown return a
# leased slot.
if [ "$SPAWN_SLOT_CLAIMED" = 1 ] && [ "$RELAUNCH" -eq 0 ]; then
  SPAWN_LEASE_RC=0
  fm_treehouse_slot_lease "$PROJ_ABS" "$WT" "$ID" || SPAWN_LEASE_RC=$?
  [ "$SPAWN_LEASE_RC" -ne 1 ] ||
    echo "warning: could not lease Treehouse slot $WT for task $ID; the next spawn reserves it instead" >&2
fi

SPAWN_DELIVERY=
[ -z "$MODE" ] || SPAWN_DELIVERY=" mode=$MODE yolo=$YOLO"
SPAWN_ACCOUNT=
[ -z "$WORKER_ACCOUNT" ] || SPAWN_ACCOUNT=" account=$WORKER_ACCOUNT_DECLARED"
[ -z "$WORKER_ACCOUNT_PROVIDER" ] || SPAWN_ACCOUNT="$SPAWN_ACCOUNT account_provider=$WORKER_ACCOUNT_PROVIDER"
[ -z "$CLAUDE_ACCOUNT" ] || SPAWN_ACCOUNT="$SPAWN_ACCOUNT claude_account=$CLAUDE_ACCOUNT"
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "$CONFIG/fleet-ledger" ] || [ "$RELAUNCH" -eq 1 ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" dispatched "$ID" "$KIND" "${PROJ_ABS##*/}" "$HARNESS" "$MODEL" || true
# Opt-in Herdr project groups (docs/herdr-backend.md "Project groups") tag the
# new endpoint now rather than at the next watcher poll; off costs one file test.
[ ! -e "$CONFIG/herdr-project-groups" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-herdr-groups.sh" sync "$ID" || true
# A yolo ship's green pull request merges with no supervision turn, so its
# merge watch starts with the task rather than with the later recording turn,
# which a missed wake can skip until the pull request sits green and unmerged.
if [ "$KIND" = ship ] && [ "$YOLO" = on ] && [ "$MODE" != local-only ] && [ "$EXTERNAL_REVIEW" = 0 ]; then
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-procevent-merge-on-green.sh" arm >/dev/null 2>&1 || true
fi
echo "spawned $ID harness=$HARNESS kind=$KIND$SPAWN_DELIVERY window=$META_WINDOW worktree=$WT$SPAWN_ACCOUNT"
