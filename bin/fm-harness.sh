#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  cat <<'EOF'
Usage: fm-harness.sh                  print own harness: pi|pi-signed|unknown
       fm-harness.sh crew             print the worker harness (config/crew-harness; "default" is own)
       fm-harness.sh validate-native-effort <harness> <model> <effort>
       fm-harness.sh ancestry [<pid>] print "<comm|args> pi" for the nearest Pi process, or nothing
EOF
}

harness_marker() {
  [ "${PI_CODING_AGENT:-}" = "true" ] || return 0
  if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
}

harness_process_verdict() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  case "$(basename -- "$comm")" in
    pi|pi-signed) echo "comm pi" ;;
    node*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        *" pi "*|*/pi) echo "args pi" ;;
      esac ;;
  esac
}

harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Inside a PID namespace the harness itself is pid 1, so pid 1 is examined.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

# Under FM_SUPERVISION_ACTOR=branch, FM_SUPERVISION_PRIMARY_HARNESS replaces detection.
supervision_primary_pin() {
  local pin=${FM_SUPERVISION_PRIMARY_HARNESS:-}
  [ "${FM_SUPERVISION_ACTOR:-}" = branch ] && [ -n "$pin" ] || return 0
  case "$pin" in
    pi|pi-signed) printf '%s\n' "$pin" ;;
    *)
      echo "error: FM_SUPERVISION_PRIMARY_HARNESS='$pin' names no known harness; refusing to resolve the supervision branch's harness" >&2
      return 2
      ;;
  esac
}

# Only the marker can name pi-signed; ancestry sees the pi family.
detect_own() {
  local marker pin
  pin=$(supervision_primary_pin) || exit 2
  [ -z "$pin" ] || { echo "$pin"; return; }
  marker=$(harness_marker)
  [ -z "$marker" ] || { echo "$marker"; return; }
  if [ -n "$(harness_ancestry)" ]; then echo pi; else echo unknown; fi
}

resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

validate_native_effort() {
  local harness=${1:-} model=${2:-} effort=${3:-}
  [ "$effort" = ultra ] || return 0
  case "$harness" in
    pi|pi-signed)
      case "$model" in codex-native/?*) return 0 ;; esac
      ;;
  esac
  echo "error: ultra effort requires pi or pi-signed with an explicit codex-native/<model> model" >&2
  return 1
}

case "${1:-}" in
  -h|--help) usage ;;
  validate-native-effort) shift; validate_native_effort "$@" ;;
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  crew) resolve_crew ;;
  *) detect_own ;;
esac
