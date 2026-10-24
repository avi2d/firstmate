#!/usr/bin/env bash
# tests/fm-stalled-qa-escalation.test.sh - the one-hour backstop for stalled
# worker questions and undelivered recorded answers.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
if [ -z "$(printenv FM_TEST_DAEMON_SOURCED)" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-stalled-qa-tests)

hour_ago() { printf '%s' "$(( $(date +%s) - 3700 ))"; }
minute_ago() { printf '%s' "$(( $(date +%s) - 60 ))"; }

backdate() {
  local stamp f=$2
  if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$1" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

test_scan_reports_old_unanswered_question() {
  local dir state items
  dir=$(make_case stalled-old-question); state="$dir/state"
  printf 'working: setup\nneeds-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)" > "$state/t.status"
  items=$(scan_stalled_qa "$state") || fail "the scan failed on an old unanswered question"
  assert_contains "$items" "question" "an old unanswered question was not reported"
  assert_contains "$items" "q1" "the report names the decision key"
  pass "an old unanswered question is reported"
}

test_scan_quiet_for_fresh_question() {
  local dir state items
  dir=$(make_case stalled-fresh-question); state="$dir/state"
  printf 'working: setup\nneeds-decision [at=%s] [key=q1]: pick A or B\n' "$(minute_ago)" > "$state/t.status"
  items=$(scan_stalled_qa "$state") || fail "the scan failed on a fresh question"
  [ -z "$items" ] || fail "a fresh question was reported too early: $items"
  pass "a fresh question stays quiet"
}

test_scan_quiet_after_answer() {
  local dir state items
  dir=$(make_case stalled-answered); state="$dir/state"
  {
    printf 'working: setup\nneeds-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)"
    printf 'resolved [key=q1]: answered: took A\n'
  } > "$state/t.status"
  items=$(scan_stalled_qa "$state") || fail "the scan failed on an answered question"
  [ -z "$items" ] || fail "an answered question was reported: $items"
  pass "an answered question stays quiet"
}

test_scan_reports_undelivered_answer() {
  local dir state items old
  dir=$(make_case stalled-undelivered); state="$dir/state"
  old=$(hour_ago)
  printf 'needs-decision [at=%s] [key=q1]: pick A or B\nresolved [key=q1]: answered: took A\n' "$old" > "$state/t.status"
  mkdir -p "$state/t.inbox"
  printf 'schema=fm-task-inbox.v1\nat=old\n--\ntook A\n' > "$state/t.inbox/001.msg"
  backdate "$old" "$state/t.inbox/001.msg"
  ladder_gave_up "$state/t.inbox" 001.msg
  items=$(scan_stalled_qa "$state") || fail "the scan failed on an undelivered answer"
  assert_contains "$items" "answer" "an undelivered recorded answer was not reported"
  assert_contains "$items" "001.msg" "the report names the unread message"
  pass "an undelivered recorded answer is reported"
}

ladder_gave_up() { printf '%s\n' "$2" > "$1/.escalated"; }

test_scan_quiet_while_ladder_has_budget() {
  local dir state items old
  dir=$(make_case stalled-ladder-busy); state="$dir/state"
  old=$(hour_ago)
  printf 'working: x\n' > "$state/t.status"
  mkdir -p "$state/t.inbox"
  printf 'schema=fm-task-inbox.v1\nat=old\n--\ndo the thing\n' > "$state/t.inbox/001.msg"
  backdate "$old" "$state/t.inbox/001.msg"
  items=$(scan_stalled_qa "$state") || fail "the scan failed"
  [ -z "$items" ] || fail "a record the ladder still owns was reported: $items"
  pass "a record the ladder still owns stays quiet"
}

test_scan_quiet_for_acked_and_forgetful_records() {
  local dir state items old
  dir=$(make_case stalled-quiet-records); state="$dir/state"
  old=$(hour_ago)
  printf 'working: x\n' > "$state/t.status"
  mkdir -p "$state/t.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=old\n--\nread already\n' > "$state/t.inbox/handled/001.msg"
  printf 'schema=fm-task-inbox.v1\ndelivery=fire-and-forget\n--\nfyi\n' > "$state/t.inbox/002.msg"
  backdate "$old" "$state/t.inbox/002.msg"
  items=$(scan_stalled_qa "$state") || fail "the scan failed"
  [ -z "$items" ] || fail "an acknowledged or fire-and-forget record was reported: $items"
  pass "acknowledged and fire-and-forget records stay quiet"
}

test_scan_no_refire_after_mark() {
  local dir state items line
  dir=$(make_case stalled-no-refire); state="$dir/state"
  printf 'needs-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)" > "$state/t.status"
  items=$(scan_stalled_qa "$state") || fail "the first scan failed"
  [ -n "$items" ] || fail "the first scan reported nothing"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    stalled_qa_record_escalated "$state" "$line" || fail "marking the escalation failed"
  done <<EOF
$items
EOF
  items=$(scan_stalled_qa "$state") || fail "the second scan failed"
  [ -z "$items" ] || fail "the escalation re-fired for the same episode: $items"
  pass "an escalated episode does not re-fire"
}

test_watcher_escalates_stalled_question() {
  local dir state out pid
  dir=$(make_case stalled-watcher); state="$dir/state"
  printf 'needs-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)" > "$state/t.status"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/t.status"     || fail "priming the already-surfaced marker failed"
  out="$dir/watch.out"
  rm -f "$state/.last-check"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1     FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$pid" 2>/dev/null || true; fail "the watcher did not exit on a stalled question: $(cat "$out")"; }
  grep -F "check: stalled-qa:" "$out" >/dev/null     || fail "the watcher did not raise the stalled question: $(cat "$out")"
  grep -F "q1" "$out" >/dev/null || fail "the wake names no decision key: $(cat "$out")"
  pass "the watcher raises a stalled question through the real entry point"
}

test_watcher_escalates_undelivered_answer() {
  local dir state out pid
  dir=$(make_case stalled-watcher-answer); state="$dir/state"
  printf 'working: x\n' > "$state/t.status"
  mkdir -p "$state/t.inbox"
  printf 'schema=fm-task-inbox.v1\nat=old\n--\ntook A\n' > "$state/t.inbox/001.msg"
  backdate "$(hour_ago)" "$state/t.inbox/001.msg"
  ladder_gave_up "$state/t.inbox" 001.msg
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$state/t.status" || fail "priming the already-surfaced marker failed"
  out="$dir/watch.out"
  rm -f "$state/.last-check"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$pid" 2>/dev/null || true; fail "the watcher did not exit on an undelivered answer: $(cat "$out")"; }
  grep -F "recorded answer undelivered" "$out" >/dev/null || fail "the watcher did not raise the undelivered answer: $(cat "$out")"
  grep -F "001.msg" "$out" >/dev/null || fail "the wake names no message: $(cat "$out")"
  pass "the watcher raises an undelivered answer through the real entry point"
}

test_daemon_escalates_stalled_question() {
  local dir state
  dir=$(make_case stalled-daemon); state="$dir/state"
  printf 'needs-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)" > "$state/t.status"
  FM_STALLED_QA_ESCALATE_SECS=99999999 FM_HEARTBEAT_SCAN_SECS=1 housekeeping "$state" >/dev/null 2>&1     || fail "the priming housekeeping run failed"
  rm -f "$state/.subsuper-escalations" "$state/.subsuper-last-scan"
  FM_HEARTBEAT_SCAN_SECS=1 housekeeping "$state" >/dev/null 2>&1     || fail "the housekeeping run failed"
  assert_contains "$(cat "$state/.subsuper-escalations" 2>/dev/null || true)" "worker question unanswered"     "the daemon did not raise the stalled question"
  pass "the daemon raises a stalled question through the real entry point"
}

test_scan_ignores_foreign_state_files() {
  local dir state items lines
  dir=$(make_case stalled-foreign-files); state="$dir/state"
  printf 'needs-decision [at=%s] [key=q1]: pick A or B\n' "$(hour_ago)" > "$state/t.status"
  touch "$state/.subsuper-escalations" "$state/.seen-t" "$state/.hb-surfaced-t" "$state/.last-check"
  items=$(scan_stalled_qa "$state") || fail "the scan failed beside foreign state files"
  assert_contains "$items" "question" "the question was lost among foreign state files"
  lines=$(printf '%s\n' "$items" | wc -l)
  [ "$lines" -eq 1 ] || fail "foreign state files leaked into the scan: $items"
  pass "foreign state files do not disturb the scan"
}

test_scan_reports_old_unanswered_question
test_scan_quiet_for_fresh_question
test_scan_quiet_after_answer
test_scan_reports_undelivered_answer
test_scan_quiet_while_ladder_has_budget
test_scan_quiet_for_acked_and_forgetful_records
test_scan_no_refire_after_mark
test_scan_ignores_foreign_state_files
test_watcher_escalates_stalled_question
test_watcher_escalates_undelivered_answer
test_daemon_escalates_stalled_question
