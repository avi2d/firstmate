#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

DEFAULT_INTERVAL=20
DEFAULT_LIFETIME=1800
WINDOW_CLOSED_EMPTY=75

usage() {
  cat <<'EOF'
Merge-on-green process-event adapter: keeps bin/fm-merge-on-green.sh sweeping
this home between supervision turns.

Usage:
  fm-procevent-merge-on-green.sh arm
  fm-procevent-merge-on-green.sh poll --home <dir> --state <dir> [--interval <secs>] [--lifetime <secs>]
  fm-procevent-merge-on-green.sh source-id
  fm-procevent-merge-on-green.sh retire
  fm-procevent-merge-on-green.sh relisten
  fm-procevent-merge-on-green.sh terminal <result-file>
  fm-procevent-merge-on-green.sh silent <result-file>
  fm-procevent-merge-on-green.sh classify <result-file>

arm        Register this home's source. bin/fm-pr-check.sh arms it for every
           +yolo GitHub pull request it records. Each arm publishes a fresh
           registration, so a runner retiring on an idle home at that moment
           cannot take the new pull request's registration with it.
poll       The child the generic runner executes; never run it in a turn.
           Sweeps every <interval> seconds (default 20) and ends empty after
           <lifetime> seconds (default 1800) so the runner relistens on the
           current script bytes. Once no yolo pull request is left to merge it
           prints one idle result, which is silent and terminal, so the source
           retires and no longer keeps supervision required.
source-id  Print this home's source id, merge-on-green-<hash of the state dir>,
           because process-event claims are machine-wide.
retire     Stop the source and drop its registration.
relisten   Exit 0: the runner keeps polling after an empty window.
terminal   Exit 0 for an idle result, which ends the source.
silent     Exit 0 for an idle result, which carries no news.
classify   Print idle for an idle result, unknown otherwise.
EOF
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }

source_id() {
  local real hash
  real=$(cd "$STATE" 2>/dev/null && pwd -P) || die "cannot resolve the state directory: $STATE"
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')
  else
    hash=$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')
  fi
  printf 'merge-on-green-%s\n' "$hash"
}

classify() {  # <result-file>
  local file=${1-}
  [ -n "$file" ] && [ -f "$file" ] || die "result file does not exist: $file"
  if [ "$(head -n 1 "$file")" = 'merge-on-green: idle' ]; then
    printf 'idle\n'
  else
    printf 'unknown\n'
  fi
}

cmd_arm() {
  local id state_real home_real
  local -a argv
  [ "$#" -eq 0 ] || usage
  [ -d "$STATE" ] || die "no state directory: $STATE"
  id=$(source_id) || exit 1
  state_real=$(cd "$STATE" && pwd -P) || die "cannot resolve the state directory: $STATE"
  home_real=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve the home directory: $FM_HOME"
  argv=("$SCRIPT_DIR/fm-procevent-merge-on-green.sh" poll --home "$home_real" --state "$state_real")
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-procevent.sh" register merge-on-green "$id" -- "${argv[@]}" >/dev/null || exit 1
  printf 'armed: %s\n' "$id"
}

cmd_poll() {
  local interval=$DEFAULT_INTERVAL lifetime=$DEFAULT_LIFETIME home='' state='' end
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage; home=$2; shift 2 ;;
      --state) [ "$#" -ge 2 ] || usage; state=$2; shift 2 ;;
      --interval) [ "$#" -ge 2 ] || usage; interval=$2; shift 2 ;;
      --lifetime) [ "$#" -ge 2 ] || usage; lifetime=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -d "$home" ] && [ -d "$state" ] || die "poll needs an existing --home and --state"
  positive_int "$interval" || die "--interval needs a positive whole number of seconds"
  positive_int "$lifetime" || die "--lifetime needs a positive whole number of seconds"
  end=$((SECONDS + lifetime))
  while [ "$SECONDS" -lt "$end" ]; do
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$SCRIPT_DIR/fm-merge-on-green.sh" sweep >/dev/null 2>&1 </dev/null || true
    if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$SCRIPT_DIR/fm-merge-on-green.sh" pending >/dev/null 2>&1 </dev/null; then
      printf 'merge-on-green: idle\n'
      exit 0
    fi
    sleep "$interval"
  done
  exit "$WINDOW_CLOSED_EMPTY"
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id)"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  source-id) shift; [ "$#" -eq 0 ] || usage; source_id ;;
  retire) shift; cmd_retire "$@" ;;
  relisten) exit 0 ;;
  terminal|silent) shift; [ "$(classify "${1-}")" = idle ] ;;
  classify) shift; classify "${1-}" ;;
  *) usage ;;
esac
