#!/usr/bin/env bash
# tests/fm-shell-history.test.sh - pane-shell lines carry one leading space; composer text does not.
# Shells with history-ignore-space set skip space-prefixed lines, so typed launch blocks stay out of interactive history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-shell-history-tests)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr/zellij/cmux adapters)"; exit 0; }

SHELL_LINE='export FM_TASK_ID=fixture-1'
SOURCE_LINE=". '/tmp/fm-fixture-1/launch.s1.sh'"
COMPOSER_TEXT='steer text here'

make_tmux_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TMUX_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-}" in
  display-message) printf '0\n' ;;
  capture-pane) : ;;
  send-keys) : ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ZELLIJ_LOG:?}"
{
  printf 'zellij'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = list-sessions ]; then
  printf 'testsession\n'
  exit 0
fi
if [ "${3:-}" = action ] && [ "${4:-}" = list-panes ]; then
  printf '[{"id":7,"is_plugin":false}]\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fb/zellij"
  printf '%s\n' "$fb"
}

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
{
  printf 'cmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = list-panes ]; then
  printf '{"panes":[{"surface_ids":["sf-1"]}]}\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

test_helper_prefixes_one_space() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-shell-line-lib.sh"
  out=$(fm_shell_history_prefix "$SHELL_LINE")
  assert_equals " $SHELL_LINE" "$out" "a pane-shell line must carry exactly one leading space"
  out=$(fm_shell_history_prefix " $SHELL_LINE")
  assert_equals " $SHELL_LINE" "$out" "an already-prefixed line must not gain a second space"
  pass "fm_shell_history_prefix: prefixes one space, idempotently"
}

test_tmux_shell_lines_carry_the_space() {
  local dir="$TMP_ROOT/tmux" fb log
  mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV
  PATH="$fb:$PATH" FM_TMUX_LOG="$dir/log" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux >/dev/null; fm_backend_tmux_send_text_line "sess:win" "$1"; fm_backend_tmux_send_literal "sess:win" "$2"' "$ROOT" "$SHELL_LINE" "$SOURCE_LINE"
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1f %s\x1f' "$SHELL_LINE")" "tmux send_text_line did not guard its shell line from history"
  assert_contains "$log" "$(printf '\x1f-l\x1f%s' "$SOURCE_LINE")" "tmux send_literal must stay a verbatim transport"
  assert_not_contains "$log" "$(printf '\x1f-l\x1f %s' "$SOURCE_LINE")" "tmux send_literal must not guard composer-bound bytes"
  pass "tmux: shell lines guarded, literal transport verbatim"
}

test_herdr_shell_lines_carry_the_space() {
  local dir="$TMP_ROOT/herdr" fb log
  mkdir -p "$dir"
  fb=$(make_herdr_fakebin "$dir")
  unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV
  PATH="$fb:$PATH" FM_HERDR_LOG="$dir/log" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_line "testsession:w1:p1" "$1"; fm_backend_herdr_send_literal "testsession:w1:p1" "$2"' "$ROOT" "$SHELL_LINE" "$SOURCE_LINE"
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1frun\x1fw1:p1\x1f %s' "$SHELL_LINE")" "herdr send_text_line did not guard its shell line from history"
  assert_contains "$log" "$(printf '\x1fsend-text\x1fw1:p1\x1f%s' "$SOURCE_LINE")" "herdr send_literal must stay a verbatim transport"
  assert_not_contains "$log" "$(printf '\x1fsend-text\x1fw1:p1\x1f %s' "$SOURCE_LINE")" "herdr send_literal must not guard composer-bound bytes"
  pass "herdr: shell lines guarded, literal transport verbatim"
}

test_zellij_shell_lines_carry_the_space() {
  local dir="$TMP_ROOT/zellij" fb log
  mkdir -p "$dir"
  fb=$(make_zellij_fakebin "$dir")
  PATH="$fb:$PATH" FM_ZELLIJ_LOG="$dir/log" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_send_text_line "testsession:7" "$1"; fm_backend_zellij_send_literal "testsession:7" "$2"' "$ROOT" "$SHELL_LINE" "$SOURCE_LINE"
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1fpaste\x1f--pane-id\x1f7\x1f--\x1f %s' "$SHELL_LINE")" "zellij send_text_line did not guard its shell line from history"
  assert_contains "$log" "$(printf '\x1fpaste\x1f--pane-id\x1f7\x1f--\x1f%s' "$SOURCE_LINE")" "zellij send_literal must stay a verbatim transport"
  assert_not_contains "$log" "$(printf '\x1fpaste\x1f--pane-id\x1f7\x1f--\x1f %s' "$SOURCE_LINE")" "zellij send_literal must not guard composer-bound bytes"
  pass "zellij: shell lines guarded, literal transport verbatim"
}

test_orca_shell_lines_carry_the_space() {
  local dir="$TMP_ROOT/orca" fb log
  mkdir -p "$dir"
  command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the orca adapter's JSON check)"; return 0; }
  fb=$(make_orca_fakebin "$dir")
  PATH="$fb:$PATH" FM_ORCA_LOG="$dir/log" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line "term-1" "$1"; fm_backend_orca_send_literal "term-1" "$2"' "$ROOT" "$SHELL_LINE" "$SOURCE_LINE"
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1f--text\x1f %s' "$SHELL_LINE")" "orca send_text_line did not guard its shell line from history"
  assert_contains "$log" "$(printf '\x1f--text\x1f%s' "$SOURCE_LINE")" "orca send_literal must stay a verbatim transport"
  assert_not_contains "$log" "$(printf '\x1f--text\x1f %s' "$SOURCE_LINE")" "orca send_literal must not guard composer-bound bytes"
  pass "orca: shell lines guarded, literal transport verbatim"
}

test_cmux_shell_lines_carry_the_space() {
  local dir="$TMP_ROOT/cmux" fb log home
  mkdir -p "$dir"
  home="$dir/home"
  mkdir -p "$home"
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_HOME="$home" \
    bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_send_text_line "ws-1:sf-1" "$1"; fm_backend_cmux_send_literal "ws-1:sf-1" "$2"' "$ROOT" "$SHELL_LINE" "$SOURCE_LINE"
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1fsend\x1f--workspace\x1fws-1\x1f--surface\x1fsf-1\x1f--\x1f %s' "$SHELL_LINE")" "cmux send_text_line did not guard its shell line from history"
  assert_contains "$log" "$(printf '\x1fsend\x1f--workspace\x1fws-1\x1f--surface\x1fsf-1\x1f--\x1f%s' "$SOURCE_LINE")" "cmux send_literal must stay a verbatim transport"
  assert_not_contains "$log" "$(printf '\x1fsend\x1f--workspace\x1fws-1\x1f--surface\x1fsf-1\x1f--\x1f %s' "$SOURCE_LINE")" "cmux send_literal must not guard composer-bound bytes"
  pass "cmux: shell lines guarded, literal transport verbatim"
}

test_composer_text_stays_verbatim() {
  local dir="$TMP_ROOT/composer" fb log
  mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_TMUX_LOG="$dir/log" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit tmux "sess:win" "$1" 1 0.01 0.01 >/dev/null' "$ROOT" "$COMPOSER_TEXT" || true
  log=$(cat "$dir/log")
  assert_contains "$log" "$(printf '\x1f-l\x1f%s' "$COMPOSER_TEXT")" "composer text must reach the agent verbatim"
  assert_not_contains "$log" "$(printf '\x1f-l\x1f %s' "$COMPOSER_TEXT")" "composer text must not carry the shell history-guard space"
  pass "composer: agent-composer text stays verbatim"
}

test_helper_prefixes_one_space
test_tmux_shell_lines_carry_the_space
test_herdr_shell_lines_carry_the_space
test_zellij_shell_lines_carry_the_space
test_orca_shell_lines_carry_the_space
test_cmux_shell_lines_carry_the_space
test_composer_text_stays_verbatim
