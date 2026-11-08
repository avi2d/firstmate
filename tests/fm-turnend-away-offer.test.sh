#!/usr/bin/env bash
# Tests for bin/fm-turnend-guard.sh --away-offer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-away-offer)
fm_git_identity fmtest fmtest@example.invalid

install_offer_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  chmod +x "$dir/bin/fm-turnend-guard.sh"
}

make_offer_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_offer_scripts "$dir"
  printf '%s\n' "$dir"
}

run_offer() {
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" --away-offer </dev/null 2>&1
}

test_away_offer_fires_with_task_in_flight() {
  local dir out status stamp
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-fires")
  : > "$dir/state/task1.meta"
  out=$(run_offer "$dir"); status=$?
  expect_code 0 "$status" "offer must exit 0 with a task in flight and away mode off"
  assert_contains "$out" "/afk" "offer must name /afk"
  assert_contains "$out" "1 task(s) in flight" "offer must name the in-flight work"
  stamp="$dir/state/.turnend-away-offered"
  [ -f "$stamp" ] || fail "offer must stamp the throttle file"
  case $(cat "$stamp") in ''|*[!0-9]*) fail "throttle stamp must be an epoch" ;; esac
  pass "away-offer: fires with a task in flight and away mode off"
}

test_away_offer_throttled_within_window() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-throttle")
  : > "$dir/state/task1.meta"
  run_offer "$dir" >/dev/null 2>&1
  out=$(run_offer "$dir"); status=$?
  expect_code 1 "$status" "repeat offer inside the window must stay silent"
  [ -z "$out" ] || fail "throttled offer must print nothing: $out"
  pass "away-offer: throttled to one offer per window"
}

test_away_offer_repeats_after_window() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-repeat")
  : > "$dir/state/task1.meta"
  run_offer "$dir" >/dev/null 2>&1
  out=$(FM_AWAY_OFFER_REPEAT_SECS=0 run_offer "$dir"); status=$?
  expect_code 0 "$status" "offer must repeat once the window has passed"
  assert_contains "$out" "/afk" "repeat offer must still name /afk"
  out=$(FM_AWAY_OFFER_REPEAT_SECS=bogus run_offer "$dir"); status=$?
  expect_code 1 "$status" "an unreadable window falls back to the default and stays silent"
  [ -z "$out" ] || fail "fallback-throttled offer must print nothing: $out"
  pass "away-offer: repeats after the window, invalid window falls back to silent"
}

test_away_offer_silent_when_afk_present() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-afk")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  out=$(run_offer "$dir"); status=$?
  expect_code 1 "$status" "offer must stay silent while away mode is on"
  [ -z "$out" ] || fail "away-mode offer must print nothing: $out"
  pass "away-offer: silent with the away presence file"
}

test_away_offer_silent_when_contract_present() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-contract")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk-contract"
  out=$(run_offer "$dir"); status=$?
  expect_code 1 "$status" "offer must stay silent while the away record is live"
  [ -z "$out" ] || fail "away-record offer must print nothing: $out"
  pass "away-offer: silent with the away record"
}

test_away_offer_silent_with_nothing_in_flight() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-idle")
  out=$(run_offer "$dir"); status=$?
  expect_code 1 "$status" "offer must stay silent with nothing in flight"
  [ -z "$out" ] || fail "idle offer must print nothing: $out"
  pass "away-offer: silent with nothing in flight"
}

test_away_offer_silent_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/offer-child-base"
  dir="$TMP_ROOT/offer-child"
  fm_git_worktree "$base" "$dir" fm/turnend-away-offer-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_offer_scripts "$dir"
  : > "$dir/state/task1.meta"
  out=$(run_offer "$dir"); status=$?
  expect_code 1 "$status" "offer must stay exempt in a child task worktree"
  [ -z "$out" ] || fail "child-worktree offer must print nothing: $out"
  pass "away-offer: silent in a child task worktree"
}

test_away_offer_fires_for_source_only_home() {
  local dir out status
  dir=$(make_offer_primary_dir "$TMP_ROOT/offer-source")
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/source-only.source"
  out=$(run_offer "$dir"); status=$?
  expect_code 0 "$status" "offer must fire for a source-only supervision need"
  assert_contains "$out" "1 process-event source(s) registered" "offer must name the supervision need"
  pass "away-offer: fires for a source-only home"
}

test_away_offer_fires_with_task_in_flight
test_away_offer_throttled_within_window
test_away_offer_repeats_after_window
test_away_offer_silent_when_afk_present
test_away_offer_silent_when_contract_present
test_away_offer_silent_with_nothing_in_flight
test_away_offer_silent_in_child_worktree
test_away_offer_fires_for_source_only_home
