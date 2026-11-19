# shellcheck shell=bash
# fm_cap_line "<line>" [<max>]: the one per-line cut and truncation marker for agent-facing digest lines.
# The cap counts characters, so a multibyte character is never cut in half.

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put <line> in FM_LINE_CAP_LINE, cut to <max>
# characters with FM_LINE_CAP_SUFFIX in place of the tail when it is longer. A
# line at or under the cap is kept unchanged, marker and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller that needs
# the value - the wake digest builds its section in a variable to weigh each
# item against a global budget - never pays a command substitution per item on
# a path that runs at the top of every wake-handling turn.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_LINE_CAP_LINE="${line:0:$keep}$FM_LINE_CAP_SUFFIX"
}

# fm_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
