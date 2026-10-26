#!/usr/bin/env bash
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

TMP_ROOT=$(fm_test_tmproot fm-wait-declaration-tests)

# 2026-10-26T09:00:00Z: recheck=2026-10-24 fell due at 2026-10-25T00:00Z, 33 hours earlier.
NOW=1793005200

utc_day() {  # <epoch> -> YYYY-MM-DD
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d
}

scan() { scan_wait_declarations "$1" "$NOW"; }

reasons() {  # <scan items> -> one reason per item
  local item
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    wait_declaration_item_reason "$item"; printf '\n'
  done <<EOF
$1
EOF
}

record_all() {  # <state> <scan items>
  local item
  while IFS= read -r item || [ -n "$item" ]; do
    [ -n "$item" ] || continue
    wait_declaration_record_raised "$1" "$item" || fail "recording a raised wait failed"
  done <<EOF
$2
EOF
}

test_accepted_shape_quiet_before_recheck() {
  local dir state items
  dir=$(make_case wait-accepted); state="$dir/state"
  printf 'working: setup\npaused [at=1793000000]: release cut | owner=daily-release workflow | recheck=2026-10-26\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on a well-formed wait"
  [ -z "$items" ] || fail "a well-formed wait whose recheck day has not ended was raised: $items"
  printf 'paused [at=1793000000]: nm run | owner=the worker | recheck=2026-10-26T09:30Z\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on a timed recheck"
  [ -z "$items" ] || fail "a wait whose recheck time is still ahead was raised: $items"
  pass "a wait naming owner and a future recheck stays quiet"
}

test_refused_shape_flagged() {
  local dir state items text
  dir=$(make_case wait-refused); state="$dir/state"
  printf 'paused [at=1793000000]: waiting for the release to cut\n' > "$state/a.status"
  printf 'paused [at=1793000000]: waiting | owner=captain\n' > "$state/b.status"
  printf 'blocked [at=1793000000]: no credential | recheck=2026-10-30\n' > "$state/c.status"
  printf 'paused [at=1793000000]: waiting | owner=captain | recheck=tomorrow\n' > "$state/d.status"
  items=$(scan "$state") || fail "the scan failed on undeclared fields"
  text=$(reasons "$items")
  assert_contains "$text" "wait names no owner or recheck date: a paused: waiting for the release to cut" "a wait with neither field was not flagged"
  assert_contains "$text" "wait names no recheck date: b paused: waiting" "a wait with no recheck was not flagged"
  assert_contains "$text" "wait names no owner: c blocked: no credential" "a blocker with no owner was not flagged"
  assert_contains "$text" "wait names no recheck date: d paused: waiting" "an unreadable recheck date was accepted"
  [ "$(printf '%s\n' "$items" | grep -c '^undated')" -eq 4 ] || fail "expected four undated flags: $items"
  pass "a wait missing its owner or a readable recheck date is flagged"
}

test_overdue_raised_with_owner_and_time() {
  local dir state items text
  dir=$(make_case wait-overdue); state="$dir/state"
  printf 'paused [at=1792800000]: release cut | owner=daily-release workflow | recheck=2026-10-24\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on an overdue wait"
  text=$(reasons "$items")
  assert_contains "$text" "wait overdue: t paused waiting on daily-release workflow, recheck 2026-10-24 passed 1d 9h ago: release cut" "the overdue wait was not raised with its task, owner and overdue time"
  printf 'blocked [key=cred] [at=1792800000]: no token | owner=captain | recheck=2026-10-26T08:00Z\n' > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on an overdue blocker"
  assert_contains "$(reasons "$items")" "wait overdue: t blocked waiting on captain, recheck 2026-10-26T08:00Z passed 1h 0m ago: no token" "the overdue blocker was not raised"
  pass "an overdue wait is raised naming task, owner and overdue time"
}

test_cleared_wait_quiet() {
  local dir state items
  dir=$(make_case wait-cleared); state="$dir/state"
  {
    printf 'paused [at=1792800000]: release cut | owner=ci | recheck=2026-10-24\n'
    printf 'working [at=1792900000]: release shipped\n'
    printf 'blocked [key=cred] [at=1792800000]: no token | owner=captain | recheck=2026-10-24\n'
    printf 'resolved [key=cred] [at=1792900000]: token granted\n'
  } > "$state/t.status"
  items=$(scan "$state") || fail "the scan failed on cleared waits"
  [ -z "$items" ] || fail "a wait no longer declared was raised: $items"
  pass "a wait that cleared is not raised"
}

test_raised_once_then_rearmed_by_redeclaration() {
  local dir state items
  dir=$(make_case wait-once); state="$dir/state"
  printf 'paused [at=1792800000]: release cut | owner=ci | recheck=2026-10-24\n' > "$state/t.status"
  items=$(scan "$state") || fail "the first scan failed"
  [ -n "$items" ] || fail "the first scan raised nothing"
  record_all "$state" "$items"
  items=$(scan "$state") || fail "the second scan failed"
  [ -z "$items" ] || fail "the same overdue wait was raised twice: $items"
  printf 'paused [at=1793000000]: release cut | owner=ci | recheck=2026-10-25\n' >> "$state/t.status"
  items=$(scan "$state") || fail "the scan after redeclaring failed"
  assert_contains "$(reasons "$items")" "recheck 2026-10-25 passed 9h 0m ago" "a redeclared wait whose new recheck also passed was not raised"
  printf 'working [at=1793000100]: resumed\n' >> "$state/t.status"
  scan "$state" >/dev/null || fail "the scan after clearing failed"
  if compgen -G "$state/.wait-flag-*" >/dev/null; then
    fail "a raised marker outlived its wait: $(ls -a "$state")"
  fi
  pass "a wait is raised once per declaration and its marker goes when the wait clears"
}

test_older_line_flagged_once_and_still_read() {
  local dir state items until
  dir=$(make_case wait-older); state="$dir/state"
  printf 'working: setup\npaused: awaiting external CI until 2026-10-26T12:00Z\n' > "$state/t.status"
  printf 'blocked: launched in primary checkout\n' > "$state/u.status"
  items=$(scan "$state") || fail "the scan failed on older undated lines"
  assert_contains "$(reasons "$items")" "wait names no owner or recheck date: t paused: awaiting external CI until 2026-10-26T12:00Z" "an older paused line was not flagged as undated"
  assert_contains "$(reasons "$items")" "wait names no owner or recheck date: u blocked: launched in primary checkout" "an older blocked line was not flagged as undated"
  record_all "$state" "$items"
  items=$(scan "$state") || fail "the rescan failed"
  [ -z "$items" ] || fail "an older undated line was flagged twice: $items"
  status_is_paused "$(status_declared_wait_line "$state/t.status")" || fail "the older line no longer reads as a declared wait"
  until=$(status_paused_until "$(status_declared_wait_line "$state/t.status")") || fail "the older line's until time is no longer read"
  [ "$until" = 1793016000 ] || fail "the older line's until time changed: $until"
  pass "an older undated line is flagged once and keeps its existing reading"
}

test_watcher_raises_overdue_wait() {
  local dir state out pid day
  dir=$(make_case wait-watcher); state="$dir/state"
  day=$(utc_day "$(( $(date +%s) - 3 * 86400 ))")
  printf 'paused [at=1792800000]: release cut | owner=daily-release workflow | recheck=%s\n' "$day" > "$state/t.status"
  prime_status_seen "$state" "$state/t.status" || fail "priming the already-surfaced marker failed"
  out="$dir/watch.out"
  rm -f "$state/.last-check"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$pid" 2>/dev/null || true; fail "the watcher did not exit on an overdue wait: $(cat "$out")"; }
  grep -F "check: wait-declaration: wait overdue: t paused waiting on daily-release workflow, recheck $day passed" "$out" >/dev/null \
    || fail "the watcher did not raise the overdue wait: $(cat "$out")"
  pass "the watcher raises an overdue wait through the real entry point"
}

test_daemon_flags_undated_wait() {
  local dir state
  dir=$(make_case wait-daemon); state="$dir/state"
  printf 'paused [at=1793000000]: waiting for the release\n' > "$state/t.status"
  FM_HEARTBEAT_SCAN_SECS=1 housekeeping "$state" >/dev/null 2>&1 || fail "the housekeeping run failed"
  assert_contains "$(cat "$state/.subsuper-escalations" 2>/dev/null || true)" "wait names no owner or recheck date: t paused: waiting for the release" \
    "the daemon did not flag the undated wait"
  pass "the daemon flags an undated wait through the real entry point"
}

test_accepted_shape_quiet_before_recheck
test_refused_shape_flagged
test_overdue_raised_with_owner_and_time
test_cleared_wait_quiet
test_raised_once_then_rearmed_by_redeclaration
test_older_line_flagged_once_and_still_read
test_watcher_raises_overdue_wait
test_daemon_flags_undated_wait
