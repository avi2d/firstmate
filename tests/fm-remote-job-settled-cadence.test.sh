#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-settled-cadence)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
SLEEP_BIN="$TMP_ROOT/sleep-bin"
PRODUCER_PID=
LANE_PID=
mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME" "$SLEEP_BIN"
cleanup_settled_fixture() {
  [ -z "$PRODUCER_PID" ] || kill -TERM "$PRODUCER_PID" 2>/dev/null || true
  [ -z "$LANE_PID" ] || kill -TERM "$LANE_PID" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_settled_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-delay-job.sh" <<'SH'
#!/bin/bash
sleep "$1"
printf 'ran\n' > "$2"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'settled cadence fixture'

cat > "$SLEEP_BIN/sleep" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FM_POLL_SLEEP_LOG"
exec /bin/sleep "$@"
SH
chmod +x "$SLEEP_BIN/sleep"

unset FM_REMOTE_JOB_POLL_SECONDS FM_REMOTE_JOB_ACTIVE_POLL_SECONDS FM_REMOTE_JOB_SETTLED_POLL_SECONDS
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state" FM_ROOT_OVERRIDE="$REMOTE_ROOT"
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=30
export PATH="$SLEEP_BIN:$PATH" FM_POLL_SLEEP_LOG="$TMP_ROOT/sleeps"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

settled_sleeps_ok() { # <label>
  local sleeps
  sleeps=$(tr '\n' ' ' < "$FM_POLL_SLEEP_LOG")
  grep -qx 0.25 "$FM_POLL_SLEEP_LOG" || fail "$1 never sampled fast at the start of its wait: $sleeps"
  grep -qx 1 "$FM_POLL_SLEEP_LOG" || fail "$1 never settled to one-second samples: $sleeps"
  ! grep -Eqvx '0\.25|1' "$FM_POLL_SLEEP_LOG" || fail "$1 slept an unexpected interval: $sleeps"
  [ -z "$(awk '$0 == "1" { settled = 1 } settled && $0 == "0.25" { print }' "$FM_POLL_SLEEP_LOG")" ] \
    || fail "$1 returned to fast samples after settling: $sleeps"
  [ "$(grep -cx 0.25 "$FM_POLL_SLEEP_LOG")" -le 13 ] || fail "$1 sampled fast beyond its two-second window: $sleeps"
}

: > "$FM_POLL_SLEEP_LOG"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4.5 "$TMP_ROOT/ran" </dev/null >/dev/null || fail "$FM_REMOTE_JOB_ERROR"
JOB="$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID"
(
  /bin/sleep 4.5
  : > "$JOB/stdout"
  : > "$JOB/stderr"
  printf '0\n' > "$JOB/exit"
  fm_remote_job_write_state "$JOB" 'done'
) &
PRODUCER_PID=$!
fm_remote_job_wait "$ACCOUNT_HOME" "$FM_REMOTE_JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
wait "$PRODUCER_PID" || fail 'the result producer failed'
PRODUCER_PID=
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail 'the long result wait lost the exit status'
settled_sleeps_ok 'a long result wait'
pass 'a long result wait settles to one-second samples after two seconds instead of quarter-second samples throughout'

: > "$FM_POLL_SLEEP_LOG"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-delay-job.sh 4.5 "$TMP_ROOT/ran" </dev/null >/dev/null || fail "$FM_REMOTE_JOB_ERROR"
HOME="$ACCOUNT_HOME" "$BASH" "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --lane "$FM_REMOTE_JOB_ID" &
LANE_PID=$!
wait "$LANE_PID" || fail 'the command lane failed'
LANE_PID=
[ -e "$TMP_ROOT/ran" ] || fail 'the lane did not execute its command'
[ "$(fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID")" = 'done' ] || fail 'the lane did not publish completion'
# The job's own sleep and the lane's 0.01-second start handshake are not monitor samples.
grep -Ex '0\.25|1' "$FM_POLL_SLEEP_LOG" > "$FM_POLL_SLEEP_LOG.monitor" || true
mv -f "$FM_POLL_SLEEP_LOG.monitor" "$FM_POLL_SLEEP_LOG"
settled_sleeps_ok 'a long command lane'
pass 'a long command lane settles to one-second samples after two seconds instead of quarter-second samples throughout'

printf 'remote job settled cadence tests complete\n'
