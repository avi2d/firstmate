#!/usr/bin/env bash
# Tests for bin/fm-merge-hold.sh: the per-pull-request hold the automatic and
# manual merge paths must respect.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-hold-tests)
URL=https://github.com/example/repo/pull/9

make_home() {
  local c="$TMP_ROOT/$1"
  mkdir -p "$c/state"
  printf '%s\n' "$c"
}

hold() { FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-merge-hold.sh" hold "$2" --reason "$3"; }
open_hold() { FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-merge-hold.sh" open "$2"; }
release_hold() { FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-merge-hold.sh" release "$2"; }

test_hold_round_trips_through_open() {
  local c out rc
  c=$(make_home round-trip)
  set +e
  open_hold "$c" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "round-trip: open with no hold must exit 1"
  out=$(hold "$c" "$URL" "captain review pending") \
    || fail "round-trip: hold failed: $out"
  case "$out" in "held: $URL") ;; *) fail "round-trip: unexpected hold line: $out" ;; esac
  [ -f "$c/state/merge-holds/github/github.com/example/repo/9.hold" ] \
    || fail "round-trip: the hold record is not at its documented path"
  set +e
  open_hold "$c" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 0 "$rc" "round-trip: open with a hold must exit 0"
  pass "a recorded hold reads back open"
}

test_repeat_hold_keeps_the_first_record() {
  local c first out
  c=$(make_home repeat)
  hold "$c" "$URL" "first reason" >/dev/null || fail "repeat: first hold failed"
  first=$(cat "$c/state/merge-holds/github/github.com/example/repo/9.hold")
  sleep 1
  out=$(hold "$c" "$URL" "second reason") \
    || fail "repeat: second hold failed: $out"
  case "$out" in "already held: $URL") ;; *) fail "repeat: unexpected re-hold line: $out" ;; esac
  [ "$(cat "$c/state/merge-holds/github/github.com/example/repo/9.hold")" = "$first" ] \
    || fail "repeat: a repeated hold rewrote the first record"
  pass "a repeated hold keeps the first record"
}

test_release_is_idempotent() {
  local c out rc
  c=$(make_home release)
  hold "$c" "$URL" "holding" >/dev/null || fail "release: hold failed"
  out=$(release_hold "$c" "$URL") || fail "release: release failed: $out"
  case "$out" in "released: $URL") ;; *) fail "release: unexpected release line: $out" ;; esac
  set +e
  open_hold "$c" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "release: open after release must exit 1"
  out=$(release_hold "$c" "$URL") || fail "release: second release failed: $out"
  case "$out" in "no hold recorded for $URL") ;; *) fail "release: unexpected second line: $out" ;; esac
  pass "release removes the hold and a second release succeeds"
}

test_nested_project_path_round_trips() {
  local c url rc
  url="https://git.example.com/group/sub/repo/-/merge_requests/7"
  c=$(make_home nested)
  hold "$c" "$url" "nested hold" >/dev/null || fail "nested: hold failed"
  [ -f "$c/state/merge-holds/gitlab/git.example.com/group/sub/repo/7.hold" ] \
    || fail "nested: a nested path did not keep one level per segment"
  set +e
  open_hold "$c" "$url" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 0 "$rc" "nested: open must exit 0"
  pass "a nested project path holds and reads back"
}

test_holds_stay_in_their_own_home() {
  local worker other rc
  worker=$(make_home worker)
  other=$(make_home other)
  hold "$worker" "$URL" "worker hold" >/dev/null || fail "isolation: hold failed"
  set +e
  open_hold "$other" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "isolation: a hold in one home must not read open in another"
  pass "a hold is enforced only in the home whose state carries it"
}

test_unreadable_record_is_fail_closed() {
  local c rc record
  c=$(make_home unreadable)
  record="$c/state/merge-holds/github/github.com/example/repo/9.hold"
  hold "$c" "$URL" "holding" >/dev/null || fail "fail-closed: hold failed"
  printf '%s\n' tampered > "$record"
  set +e
  open_hold "$c" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "fail-closed: a tampered record must exit 2"
  set +e
  hold "$c" "$URL" "overwrite" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "fail-closed: a tampered record must not be overwritten"
  rm -f -- "$record"
  ln -s /dev/null "$record"
  set +e
  open_hold "$c" "$URL" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "fail-closed: a symlink record must exit 2"
  pass "an unreadable hold record fails closed instead of merging or overwriting"
}

test_bad_input_refuses() {
  local c rc
  c=$(make_home bad-input)
  set +e
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" hold not-a-url --reason x >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: hold of a bad URL must exit 2"
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" hold "$URL" --reason '   ' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: hold with a blank reason must exit 2"
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" hold "$URL" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: hold with no reason flag must exit 2"
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" open not-a-url >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: open of a bad URL must exit 2"
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" release not-a-url >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: release of a bad URL must exit 2"
  FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-merge-hold.sh" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "bad-input: no subcommand must exit 2"
  set -e
  pass "bad input refuses with exit 2"
}

test_hold_round_trips_through_open
test_repeat_hold_keeps_the_first_record
test_release_is_idempotent
test_nested_project_path_round_trips
test_holds_stay_in_their_own_home
test_unreadable_record_is_fail_closed
test_bad_input_refuses
