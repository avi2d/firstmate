#!/usr/bin/env bash
# Behavior of bin/fm-copy-drift-check.sh against temp git copies: behind, ahead,
# dirty and fresh, dirty and stale, clean, plus the daily gate and arming.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-copy-drift-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-copy-drift-check)
DAY=86400
JAN_1_2020=1577836800

fm_git_identity fmtest fmtest@example.invalid

# make_world <name>: a home that is also its code root, as in a primary home, with
# its private directories ignored and projects/demo cloned inside it, plus a
# scratch clone per origin to push upstream commits from.
make_world() {
  local world="$TMP_ROOT/$1" name
  for name in code demo; do
    fm_git_init_commit "$world/seed-$name"
    git clone --quiet --bare "$world/seed-$name" "$world/$name.git"
    git clone --quiet "$world/$name.git" "$world/pusher-$name"
  done
  git clone --quiet "$world/code.git" "$world/home"
  printf '/state/\n/projects/\n' >> "$world/home/.git/info/exclude"
  mkdir -p "$world/home/state" "$world/home/projects"
  git clone --quiet "$world/demo.git" "$world/home/projects/demo"
  printf '%s\n' "$world"
}

push_upstream() {
  local world=$1 name=$2 count=$3 i
  for i in $(seq 1 "$count"); do
    git -C "$world/pusher-$name" commit -q --allow-empty -m "upstream $i"
  done
  git -C "$world/pusher-$name" push -q origin main
}

run_check() {
  local world=$1 status=0
  shift
  env FM_CHECK_TIMEOUT=30 FM_COPY_DRIFT_INTERVAL=0 "$@" \
    FM_HOME="$world/home" FM_ROOT_OVERRIDE="$world/home" \
    "$CHECK" > "$world/out.txt" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  cat "$world/out.txt"
}

assert_one_line() {
  [ "$(printf '%s\n' "$1" | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "the report must be exactly one line for the wake record: $1"
}

test_clean_current_copies_are_silent() {
  local world out
  world=$(make_world clean)
  out=$(run_check "$world")
  assert_equals "" "$out" "clean, current copies raised a report"
  pass "clean, current copies raise nothing"
}

test_behind_reports_count_without_changing_the_copy() {
  local world out before
  world=$(make_world behind)
  before=$(git -C "$world/home/projects/demo" rev-parse main)
  push_upstream "$world" demo 3
  push_upstream "$world" code 1
  out=$(run_check "$world")
  assert_one_line "$out"
  assert_contains "$out" "copy drift: " "the report is missing its prefix"
  assert_contains "$out" "projects/demo is 3 commits behind origin/main" "the project count is wrong"
  assert_contains "$out" "firstmate code root is 1 commit behind origin/main" "the code root count is wrong"
  assert_equals "$before" "$(git -C "$world/home/projects/demo" rev-parse main)" "the check moved the local default branch"
  assert_equals "" "$(git -C "$world/home/projects/demo" status --porcelain)" "the check changed the working tree"
  pass "a copy behind origin is reported with its count and left untouched"
}

test_ahead_is_silent() {
  local world out
  world=$(make_world ahead)
  git -C "$world/home/projects/demo" commit -q --allow-empty -m local-only
  out=$(run_check "$world")
  assert_equals "" "$out" "a copy ahead of origin raised a report"
  pass "a copy only ahead of origin raises nothing"
}

test_dirty_fresh_is_silent() {
  local world out demo
  world=$(make_world fresh)
  demo="$world/home/projects/demo"
  printf 'edit\n' >> "$demo/README.md"
  printf 'new\n' > "$demo/scratch.txt"
  out=$(run_check "$world")
  assert_equals "" "$out" "a change made just now raised a report"
  pass "an uncommitted change younger than a day raises nothing"
}

test_dirty_stale_names_the_oldest_file() {
  local world out demo
  world=$(make_world stale)
  demo="$world/home/projects/demo"
  printf 'edit\n' >> "$demo/README.md"
  mkdir -p "$demo/notes"
  printf 'new\n' > "$demo/notes/left.txt"
  fm_touch_epoch "$((JAN_1_2020 + 2 * DAY))" "$demo/README.md"
  fm_touch_epoch "$JAN_1_2020" "$demo/notes/left.txt"
  out=$(run_check "$world" FM_COPY_DRIFT_NOW="$((JAN_1_2020 + 3 * DAY + 60))")
  assert_one_line "$out"
  assert_equals "copy drift: projects/demo has an uncommitted change 3 days old: notes/left.txt" "$out" \
    "the stale change was not named by its oldest file"
  pass "an uncommitted change older than a day names the copy and its oldest file"
}

test_stale_starts_after_exactly_one_day() {
  local world out demo
  world=$(make_world boundary)
  demo="$world/home/projects/demo"
  printf 'edit\n' >> "$demo/README.md"
  fm_touch_epoch "$JAN_1_2020" "$demo/README.md"
  out=$(run_check "$world" FM_COPY_DRIFT_NOW="$((JAN_1_2020 + DAY))")
  assert_equals "" "$out" "a change exactly one day old counted as stale"
  out=$(run_check "$world" FM_COPY_DRIFT_NOW="$((JAN_1_2020 + DAY + 1))")
  assert_equals "copy drift: projects/demo has an uncommitted change 1 day old: README.md" "$out" \
    "a change just over a day old was not reported"
  pass "a change is stale only once it is more than a day old"
}

test_clone_without_origin_is_still_checked_for_stale_work() {
  local world out solo
  world=$(make_world solo)
  solo="$world/home/projects/solo"
  fm_git_init_commit "$solo"
  printf 'edit\n' >> "$solo/README.md"
  fm_touch_epoch "$JAN_1_2020" "$solo/README.md"
  printf 'edit\n' >> "$world/home/README.md"
  fm_touch_epoch "$((JAN_1_2020 + DAY))" "$world/home/README.md"
  push_upstream "$world" code 1
  mkdir -p "$world/home/projects/not-a-clone"
  out=$(run_check "$world" FM_COPY_DRIFT_NOW="$((JAN_1_2020 + 5 * DAY))")
  assert_equals "copy drift: firstmate code root is 1 commit behind origin/main; firstmate code root has an uncommitted change 4 days old: README.md; projects/solo has an uncommitted change 5 days old: README.md" "$out" \
    "a clone without origin was compared, or a plain directory was read as the code root"
  pass "a clone without origin is checked only for stale work and a plain directory is skipped"
}

test_unreachable_origin_is_reported() {
  local world out
  world=$(make_world unreachable)
  git -C "$world/home/projects/demo" remote set-url origin "$world/missing.git"
  out=$(run_check "$world")
  assert_equals "copy drift: projects/demo could not be compared: fetching origin failed" "$out" \
    "an unreachable origin was read as current"
  pass "an origin that cannot be fetched is reported rather than read as current"
}

test_worktrees_of_one_repository_share_one_fetch() {
  local world out demo counter
  world=$(make_world worktrees)
  demo="$world/home/projects/demo"
  git -C "$demo" worktree add --quiet --detach "$demo-task"
  counter="$world/count-upload-pack"
  printf '#!/bin/sh\necho fetch >> %s\nexec git-upload-pack "$@"\n' "$world/fetches.log" > "$counter"
  chmod +x "$counter"
  git -C "$demo" config remote.origin.uploadpack "$counter"
  push_upstream "$world" demo 2
  out=$(run_check "$world")
  assert_equals "copy drift: projects/demo is 2 commits behind origin/main; projects/demo-task is 2 commits behind origin/main" "$out" \
    "two worktrees of one repository were not both compared"
  assert_equals 1 "$(wc -l < "$world/fetches.log" | tr -d '[:space:]')" \
    "worktrees of one repository were fetched more than once"
  pass "worktrees of one repository are fetched once and each compared"
}

test_daily_gate_holds_then_repeats() {
  local world out now
  world=$(make_world gate)
  push_upstream "$world" demo 1
  now=$(date +%s)
  out=$(run_check "$world" FM_COPY_DRIFT_INTERVAL="$DAY" FM_COPY_DRIFT_NOW="$now")
  assert_contains "$out" "projects/demo is 1 commit behind" "the first sweep did not report"
  out=$(run_check "$world" FM_COPY_DRIFT_INTERVAL="$DAY" FM_COPY_DRIFT_NOW="$((now + DAY - 1))")
  assert_equals "" "$out" "a second sweep inside the day ran"
  out=$(run_check "$world" FM_COPY_DRIFT_INTERVAL="$DAY" FM_COPY_DRIFT_NOW="$((now + DAY))")
  assert_contains "$out" "projects/demo is 1 commit behind" "an unresolved copy was not reported again the next day"
  pass "the sweep runs once a day and repeats while a copy stays behind"
}

test_arm_and_disarm() {
  local world shim status=0
  world=$(make_world arm)
  FM_HOME="$world/home" "$CHECK" arm > /dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  shim="$world/home/state/copy-drift.check.sh"
  [ -f "$shim" ] && [ -x "$shim" ] || fail "arm did not write an executable check shim"
  [ -f "$world/home/state/copy-drift.check-trust" ] || fail "arm did not bind the check bytes"
  FM_HOME="$world/home" "$CHECK" disarm > /dev/null 2>&1 || status=$?
  expect_code 0 "$status" "disarm exit"
  [ ! -e "$shim" ] || fail "disarm left the check shim behind"
  [ ! -e "$world/home/state/copy-drift.check-trust" ] || fail "disarm left the trust binding behind"
  pass "arm writes and binds the shim, disarm removes it"
}

test_clean_current_copies_are_silent
test_behind_reports_count_without_changing_the_copy
test_ahead_is_silent
test_dirty_fresh_is_silent
test_dirty_stale_names_the_oldest_file
test_stale_starts_after_exactly_one_day
test_clone_without_origin_is_still_checked_for_stale_work
test_unreachable_origin_is_reported
test_worktrees_of_one_repository_share_one_fetch
test_daily_gate_holds_then_repeats
test_arm_and_disarm
