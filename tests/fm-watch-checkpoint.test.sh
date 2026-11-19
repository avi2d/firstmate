#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

# Copy the checkpoint into <home>/root/bin and build <home>/fixture-bin, a
# PATH holding only the named host tools, so stubs decide which timeout runs.
make_isolated_checkpoint() {  # <home> <tool...>
  local home=$1 tool tool_path
  shift
  mkdir -p "$home/root/bin" "$home/fixture-bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  for tool in "$@"; do
    tool_path=$(command -v "$tool") || fail "could not locate $tool for the isolated checkpoint fixture"
    ln -s "$tool_path" "$home/fixture-bin/$tool"
  done
}

write_non_gnu_timeout_stub() {  # <path>
  cat > "$1" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'uutils 0.12.0'
  exit 0
fi
exit 137
SH
  chmod +x "$1"
}

# A GNU stub records its name and arguments, then reports a timeout.
write_gnu_timeout_stub() {  # <path>
  cat > "$1" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'timeout (GNU coreutils) 9.5'
  exit 0
fi
printf '%s' "${0##*/}" >> "$FM_HOME/timeout-calls"
printf ' %s' "$@" >> "$FM_HOME/timeout-calls"
printf '\n' >> "$FM_HOME/timeout-calls"
exit 124
SH
  chmod +x "$1"
}

expect_gnu_timeout_call() {  # <home> <command-name> <label>
  local home=$1 name=$2 label=$3 status
  status=0
  PATH="$home/fixture-bin" FM_HOME="$home" FM_SIGNAL_GRACE=1 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "$label checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "$label did not return a quiet checkpoint"
  [ "$(cat "$home/timeout-calls" 2>/dev/null)" = "$name --signal=INT --kill-after=5s 1 $home/root/bin/fm-watch.sh" ] \
    || fail "$label did not run $name with the watcher bound: $(cat "$home/timeout-calls" 2>/dev/null)"
}

test_gnu_timeout_runs_the_watcher_bound() {
  local home
  home=$(make_home gnu-timeout)
  make_isolated_checkpoint "$home" bash dirname mktemp rm grep cat
  write_gnu_timeout_stub "$home/fixture-bin/timeout"
  write_gnu_timeout_stub "$home/fixture-bin/gtimeout"
  expect_gnu_timeout_call "$home" timeout "GNU timeout"
  pass "GNU timeout runs the watcher with the INT signal and kill-after bound"
}

test_non_gnu_timeout_uses_gnu_gtimeout() {
  local home
  home=$(make_home non-gnu-timeout-gtimeout)
  make_isolated_checkpoint "$home" bash dirname mktemp rm grep cat
  write_non_gnu_timeout_stub "$home/fixture-bin/timeout"
  write_gnu_timeout_stub "$home/fixture-bin/gtimeout"
  expect_gnu_timeout_call "$home" gtimeout "GNU gtimeout"
  pass "non-GNU timeout yields to GNU gtimeout with the INT signal and kill-after bound"
}

test_non_gnu_timeout_falls_back_to_perl_before_escalating() {
  local home fallback_bin status watcher_pid
  home=$(make_home non-gnu-timeout)
  fallback_bin="$home/fixture-bin"
  make_isolated_checkpoint "$home" bash dirname mktemp rm perl grep cat
  write_non_gnu_timeout_stub "$fallback_bin/timeout"
  cat > "$home/root/bin/fm-watch.sh" <<'PL'
#!/usr/bin/env perl
use strict;
use warnings;
$SIG{INT} = sub {
  open my $int_file, '>', "$ENV{FM_HOME}/int-received" or die "open INT marker: $!";
  close $int_file;
};
open my $pid_file, '>', "$ENV{FM_HOME}/watcher.pid" or die "open pid file: $!";
printf {$pid_file} "%s\n", $$;
close $pid_file;
my $cleanup_deadline = time + 7;
while ((my $left = $cleanup_deadline - time) > 0) {
  sleep $left;
}
open my $cleanup_file, '>', "$ENV{FM_HOME}/cleanup-reached" or die "open cleanup marker: $!";
print {$cleanup_file} "reached\n";
close $cleanup_file;
END {
  if (open my $exit_file, '>', "$ENV{FM_HOME}/natural-exit") {
    print {$exit_file} "natural\n";
  }
}
sleep 20;
PL
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-watch.sh"

  status=0
  PATH="$fallback_bin" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WATCHER_CLEANUP_LOCK_BOUND=8 \
    "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out.txt" 2>"$home/err.txt" || status=$?

  expect_code 124 "$status" "Perl fallback checkpoint exit"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 1s" \
    "Perl fallback did not return a quiet checkpoint"
  [ -e "$home/int-received" ] || fail "the Perl fallback did not deliver INT to the watcher"
  [ -e "$home/cleanup-reached" ] || fail "the Perl fallback killed the watcher before its 8-second cleanup bound"
  [ ! -e "$home/natural-exit" ] || fail "the INT-surviving watcher exited naturally instead of being killed"
  [ -s "$home/watcher.pid" ] || fail "the INT-surviving watcher did not start"
  watcher_pid=$(cat "$home/watcher.pid")
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "the watcher survived the Perl fallback KILL escalation"
  fi
  pass "non-GNU timeout falls back to Perl and honors the cleanup bound before escalating"
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?

  expect_code 124 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"
  pass "a never-announced recovery still surfaces once from a foreground checkpoint"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_gnu_timeout_runs_the_watcher_bound
test_non_gnu_timeout_uses_gnu_gtimeout
test_non_gnu_timeout_falls_back_to_perl_before_escalating
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
