#!/usr/bin/env bash
# Open and arm a board page a sandboxed worker declared but never opened.
# Usage: fm-lavish-board-handoff.sh <board.html> --for <task-id>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

fail() {
  printf 'fm-lavish-board-handoff: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

BOARD=
TASK=
want_value=
for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$arg" in
      --*) fail "--$want_value requires a value" ;;
    esac
    TASK=$arg
    want_value=
    continue
  fi
  case "$arg" in
    -h|--help) usage ;;
    --for) want_value=for ;;
    --for=*) TASK=${arg#--for=} ;;
    --*) fail "unknown flag '$arg'" ;;
    *) [ -z "$BOARD" ] || fail "takes exactly one board page"; BOARD=$arg ;;
  esac
done
[ -n "$want_value" ] && fail "--$want_value requires a value"
[ -n "$BOARD" ] || fail "takes a board page: fm-lavish-board-handoff.sh <board.html> --for <task-id>"
[ -n "$TASK" ] || fail "takes a task id: fm-lavish-board-handoff.sh <board.html> --for <task-id>"
[ -f "$BOARD" ] || fail "board page is not a file: $BOARD"

# A page without queuePrompt can never deliver an answer.
grep -q 'queuePrompt' "$BOARD" \
  || fail "board page carries no queuePrompt: $BOARD"

command -v lavish-axi >/dev/null 2>&1 \
  || fail "lavish-axi is not installed"

lavish-axi "$BOARD" \
  || fail "cannot open the board page: $BOARD"

SOURCE_ID=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$BOARD") \
  || fail "cannot derive the board source id: $BOARD"

"$SCRIPT_DIR/fm-captain-hold.sh" bind "$SOURCE_ID" \
  || fail "cannot bind the board source: $SOURCE_ID"

"$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$BOARD" --for "$TASK" \
  || fail "cannot arm the board for task: $TASK"

printf 'handoff: %s %s\n' "$SOURCE_ID" "$TASK"
