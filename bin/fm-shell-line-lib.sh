#!/usr/bin/env bash
# fm-shell-line-lib.sh - the history guard for pane-shell input.
# Interactive shells with history-ignore-space set skip space-prefixed lines, while agent-composer text must stay verbatim.

# Every pane-shell line passes here; agent-composer text never does.
fm_shell_history_prefix() {  # <text> -> TEXT with the one leading space ignored shells skip
  case "$1" in
  ' '*) printf '%s' "$1" ;;
  *) printf ' %s' "$1" ;;
  esac
}
