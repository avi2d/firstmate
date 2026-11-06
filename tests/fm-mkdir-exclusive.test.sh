#!/usr/bin/env bash
# Behavior tests for the mkdir-shaped locks and claims in bin/ under racing
# creators.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

test_racing_busy_writers_lose_no_sequence_step

echo "all fm-mkdir-exclusive tests passed"
