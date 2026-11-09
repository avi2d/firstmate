#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox-doorbell)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state/w1.inbox"
printf 'inspect the session\n' > "$HOME_DIR/state/w1.inbox/001.msg"
doorbell_for() {
  FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_task_inbox_doorbell_for "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}
doorbell_line() {
  FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_task_inbox_doorbell_line "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}
for_line=$(doorbell_for 'w1.inbox') || fail "doorbell_for refused a valid inbox name"
rec_line=$(doorbell_line "$HOME_DIR/state/w1.inbox/001.msg") || fail "doorbell_line refused a valid record"
[ "$for_line" = "$rec_line" ] || fail "name-addressed and record-addressed doorbells differ: [$for_line] [$rec_line]"
printf '%s\n' "$for_line" | grep -F "'w1.inbox'" >/dev/null || fail "doorbell does not name the inbox: $for_line"
pass "a name-addressed doorbell matches the record-addressed line"
if doorbell_for '' >/dev/null 2>&1; then fail "doorbell_for accepted an empty inbox name"; fi
if doorbell_for "$(printf 'w1.inbox\t')" >/dev/null 2>&1; then fail "doorbell_for accepted a non-printable inbox name"; fi
pass "doorbell_for refuses empty and non-printable inbox names"
