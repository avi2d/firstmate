#!/usr/bin/env bash
# Behavior tests for bin/fm-mkdir-lib.sh, the exclusive directory creation
# every mkdir-shaped lock and claim in bin/ goes through.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-mkdir-lib.sh
. "$ROOT/bin/fm-mkdir-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mkdir-exclusive)

# Every racer blocks reading one line from the fifo until all the lines are
# written at once. The fifo is held open read-write so a racer that opens it
# late still finds its line instead of waiting forever for a writer.
race() { # <name> <racers> <command>...
  local name=$1 racers=$2 barrier fd pids=() i
  shift 2
  barrier="$TMP_ROOT/$name.barrier"
  mkfifo "$barrier"
  exec {fd}<>"$barrier"
  for i in $(seq "$racers"); do
    ( read -r _ < "$barrier"; "$@" ) &
    pids+=("$!")
  done
  printf '%*s' "$racers" '' | tr ' ' '\n' >&"$fd"
  wait "${pids[@]}" 2>/dev/null || true
  exec {fd}>&-
}

claim_and_record() { # <dir> <wins-file>
  if fm_mkdir_exclusive "$1" 2>/dev/null; then printf 'win\n' >> "$2"; fi
}

test_racing_creators_never_share_one_directory() {
  local round dir wins count
  for round in 1 2; do
    dir="$TMP_ROOT/claim-$round"
    wins="$TMP_ROOT/wins-$round"
    : > "$wins"
    race "claim-$round" 200 claim_and_record "$dir" "$wins"
    count=$(wc -l < "$wins" | tr -d ' ')
    [ "$count" = 1 ] || fail "round $round: $count of 200 racers own $dir, want exactly 1"
  done
  pass "of 200 racing creators exactly one owns the directory, in every round"
}

test_existing_directory_is_never_claimed() {
  local dir="$TMP_ROOT/existing"
  mkdir "$dir"
  if fm_mkdir_exclusive "$dir" 2>/dev/null; then fail "a pre-existing directory was claimed"; fi
  [ -d "$dir" ] || fail "a refused claim removed the existing directory"
  pass "a directory that already exists is refused and left in place"
}

test_release_lets_the_next_creator_win() {
  local dir="$TMP_ROOT/cycle"
  fm_mkdir_exclusive "$dir" || fail "first claim failed"
  if fm_mkdir_exclusive "$dir" 2>/dev/null; then fail "a held claim was claimed twice"; fi
  fm_mkdir_exclusive_release "$dir" || fail "release failed"
  [ ! -e "$dir" ] || fail "release left the directory behind"
  fm_mkdir_exclusive "$dir" || fail "claim after release failed"
  pass "release removes the claim and the next creator can take it"
}

test_release_refuses_a_directory_holding_other_files() {
  local dir="$TMP_ROOT/occupied"
  fm_mkdir_exclusive "$dir" || fail "claim failed"
  : > "$dir/payload"
  if fm_mkdir_exclusive_release "$dir" 2>/dev/null; then fail "release removed a non-empty claim"; fi
  [ -f "$dir/payload" ] || fail "release removed the claim's payload"
  pass "release never removes a claim that still holds other files"
}

busy_apply() { # <state-dir> <successes-file>
  if "$ROOT/bin/fm-busy-event.sh" apply "$1" t1 idle --current-gen --source fm-recovery --event race >/dev/null 2>&1; then
    printf 'ok\n' >> "$2"
  fi
}

test_racing_busy_writers_lose_no_sequence_step() {
  local state="$TMP_ROOT/busy/state" successes="$TMP_ROOT/busy-successes" applied seq
  mkdir -p "$state"
  : > "$successes"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" t1 >/dev/null || fail "arm failed"
  FM_BUSY_LOCK_STALE_SECS=600 race busy 50 busy_apply "$state" "$successes"
  applied=$(wc -l < "$successes" | tr -d ' ')
  [ "$applied" -gt 0 ] || fail "no racing busy writer applied"
  seq=$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$state/t1.busy-state")
  [ "$seq" = "$((applied + 1))" ] || fail "seq=$seq after $applied applied writes, want $((applied + 1))"
  pass "$applied racing fm-busy-event writers each advanced seq once"
}

test_racing_creators_never_share_one_directory
test_existing_directory_is_never_claimed
test_release_lets_the_next_creator_win
test_release_refuses_a_directory_holding_other_files
test_racing_busy_writers_lose_no_sequence_step

echo "all fm-mkdir-exclusive tests passed"
