#!/usr/bin/env bash
set -eu
# The watcher's remote-worker sweep, exercised without running the watcher.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-poll)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$TMP_ROOT/fakebin"
export FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state" SCRIPT_DIR="$TMP_ROOT/fakebin" POLL=30
export FM_REMOTE_FLEET_CACHE_SECS=0 FM_REMOTE_FLEET_BUDGET=60
export FM_REMOTE_RING_GRACE=90 FM_REMOTE_RING_MAX=3 FM_REMOTE_RING_BUDGET=60
cat > "$TMP_ROOT/fakebin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -eu
target=$1; shift
case "$*" in
  *' fleet')
    printf 'fleet\n' >> "$FM_TEST_CALL_LOG"
    if [ "${FM_TEST_FLEET_MODE:-ok}" = fail ]; then exit 1; fi
    printf '%b' "${FM_TEST_FLEET_LINES:-w1\tworking\tbusy\thash1\n}"
    ;;
  *' ring w1')
    printf 'ring\n' >> "$FM_TEST_CALL_LOG"
    cat >/dev/null
    exit "${FM_TEST_RING_RC:-0}"
    ;;
  *' ring w9')
    printf 'ring9\n' >> "$FM_TEST_CALL_LOG"
    cat >/dev/null
    exit "${FM_TEST_RING_RC:-0}"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/fm-on.sh"
stat_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
age_of() {
  local f=$1 m now
  m=$(stat_mtime "$f") || { echo 999999; return; }
  now=$(date +%s)
  [ "$m" -le "$now" ] || { echo 999999; return; }
  echo $(( now - m ))
}
fm_run_timed() { shift; "$@"; }
wake() { printf 'wake:%s\n' "$1" >> "$TMP_ROOT/wakes"; }
fm_wake_append() { printf 'queue:%s:%s:%s\n' "$1" "$2" "$3" >> "$TMP_ROOT/wake-queue"; }
fm_pending_reply_dir() { printf '%s/pending-replies' "$1"; }
fm_pending_reply_get() {
  local rec=$1 key=$2
  [ -f "$rec" ] || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-remote-worker-poll-lib.sh
. "$ROOT/bin/fm-remote-worker-poll-lib.sh"
: > "$TMP_ROOT/wakes"; : > "$TMP_ROOT/wake-queue"
FM_TEST_CALL_LOG="$TMP_ROOT/calls"; export FM_TEST_CALL_LOG
: > "$FM_TEST_CALL_LOG"
FM_TEST_FLEET_LINES=$(printf 'w1\tworking\tbusy\thash1\n'); export FM_TEST_FLEET_LINES
cache=$(FM_REMOTE_FLEET_CACHE_SECS=3600 remote_worker_fleet lab) || fail "fleet probe refused a healthy host"
[ "$(grep -c '^fleet$' "$FM_TEST_CALL_LOG")" = 1 ] || fail "fleet did not probe exactly once"
cache2=$(FM_REMOTE_FLEET_CACHE_SECS=3600 remote_worker_fleet lab) || fail "fleet refused its own cache"
[ "$cache" = "$cache2" ] || fail "fleet cache returned a different path"
[ "$(grep -c '^fleet$' "$FM_TEST_CALL_LOG")" = 1 ] || fail "fleet reprobed inside its cache window"
grep -Fq 'w1' "$cache" || fail "fleet cache lost the host line"
pass "fleet caches the batched probe inside its window"
rm -f "$cache"
if FM_TEST_FLEET_MODE=fail FM_REMOTE_FLEET_CACHE_SECS=3600 remote_worker_fleet lab >/dev/null 2>&1; then fail "fleet accepted a failed probe"; fi
[ ! -e "$cache.tmp" ] || fail "a failed probe left a half-written cache"
pass "a failed probe leaves the previous cache untouched and fails"
mkdir -p "$STATE/pending-replies"
printf 'task_id=w9\nphase=open\ndelivered_epoch=\n' > "$STATE/pending-replies/undelivered"
if remote_worker_oldest_unacked "$STATE" w9 >/dev/null 2>&1; then fail "an undelivered expectation read as unacked"; fi
printf 'task_id=w1\nphase=open\ndelivered_epoch=100\n' > "$STATE/pending-replies/rec1"
printf 'task_id=w1\nphase=open\ndelivered_epoch=50\n' > "$STATE/pending-replies/rec2"
printf 'task_id=w1\nphase=resolved\ndelivered_epoch=25\n' > "$STATE/pending-replies/rec3"
printf 'task_id=w2\nphase=open\ndelivered_epoch=10\n' > "$STATE/pending-replies/other"
oldest=$(remote_worker_oldest_unacked "$STATE" w1) || fail "every expectation resolved despite two open steers"
[ "$oldest" = 50 ] || fail "the oldest open steer misreported: $oldest"
pass "only an open delivered expectation counts as an unacked steer"
rm -f "$STATE/pending-replies/rec1" "$STATE/pending-replies/rec2" "$STATE/pending-replies/rec3"
remote_worker_note_agent w1 lab-host dead
[ "$(cat "$STATE/.remote-agent-w1")" = dead ] || fail "the agent verdict was not remembered"
grep -Fq 'wake:stale: remote:w1' "$TMP_ROOT/wakes" || fail "endpoint death did not wake firstmate"
wakes_before=$(wc -l < "$TMP_ROOT/wakes")
remote_worker_note_agent w1 lab-host dead
[ "$(wc -l < "$TMP_ROOT/wakes")" = "$wakes_before" ] || fail "a persisting verdict woke firstmate twice"
remote_worker_note_agent w1 lab-host working
[ "$(cat "$STATE/.remote-agent-w1")" = working ] || fail "recovery did not update the remembered verdict"
[ "$(wc -l < "$TMP_ROOT/wakes")" = "$wakes_before" ] || fail "a live endpoint woke firstmate"
remote_worker_note_agent w2 lab-host unknown
[ "$(cat "$STATE/.remote-agent-w2")" = unknown ] || fail "an unknown verdict was not remembered"
[ "$(wc -l < "$TMP_ROOT/wakes")" = "$wakes_before" ] || fail "transport unknown woke firstmate"
pass "the host dead-or-missing verdict wakes exactly once per edge"
printf 'task_id=w1\nphase=open\ndelivered_epoch=100\n' > "$STATE/pending-replies/rec1"
printf 'task_id=w1\nphase=open\ndelivered_epoch=50\n' > "$STATE/pending-replies/rec2"
now=$(date +%s)
remote_worker_rering w1 lab-host lab "$now"
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG")" = 1 ] || fail "the first overdue steer rang no doorbell"
grep -Fq 'rings=1' "$STATE/.remote-ring-w1" || fail "the first ring was not booked"
remote_worker_rering w1 lab-host lab "$now"
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG")" = 1 ] || fail "rings ignored their spacing"
remote_worker_rering w1 lab-host lab "$((now + 100))"
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG")" = 2 ] || fail "the second overdue steer rang no doorbell"
remote_worker_rering w1 lab-host lab "$((now + 200))"
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG")" = 3 ] || fail "the third overdue steer rang no doorbell"
grep -Fq 'unread firstmate instruction' "$TMP_ROOT/wakes" || fail "a spent ring budget did not escalate"
[ -e "$STATE/.remote-ring-escalated-w1" ] || fail "the escalation was not booked"
wakes_before=$(wc -l < "$TMP_ROOT/wakes")
remote_worker_rering w1 lab-host lab "$((now + 300))"
[ "$(wc -l < "$TMP_ROOT/wakes")" = "$wakes_before" ] || fail "the escalation repeated"
pass "the re-ring ladder rings with spacing and escalates exactly once"
rm -f "$STATE/pending-replies/rec1" "$STATE/pending-replies/rec2"
remote_worker_rering w1 lab-host lab "$((now + 400))"
[ ! -e "$STATE/.remote-ring-w1" ] && [ ! -e "$STATE/.remote-ring-escalated-w1" ] || fail "an acknowledged steer kept its ring bookkeeping"
pass "an acknowledged steer clears the ring bookkeeping"
rm -f "$STATE/pending-replies/undelivered" "$STATE/pending-replies/other"
printf 'task_id=w9\nphase=open\ndelivered_epoch=50\n' > "$STATE/pending-replies/rec9"
FM_TEST_RING_RC=3 remote_worker_rering w9 lab-host lab "$now"
grep -Fq 'remote endpoint dead' "$TMP_ROOT/wakes" || fail "a refused ring did not surface endpoint death"
pass "a refused ring surfaces the host dead verdict"
unset FM_TEST_RING_RC
rm -f "$STATE/pending-replies/rec9" "$STATE/.remote-agent-w1" "$STATE/.remote-agent-w9"
rm -f "$STATE/.fleet-lab" "$STATE/.remote-ring-w1" "$STATE/.remote-ring-escalated-w1"
rm -f "$STATE/.remote-ring-w9" "$STATE/.remote-ring-escalated-w9"
printf 'kind=ship\nremote_host=h\nremote_route=lab\n' > "$STATE/w1.meta"
printf 'task_id=w1\nphase=open\ndelivered_epoch=50\n' > "$STATE/pending-replies/rec1"
: > "$FM_TEST_CALL_LOG"
remote_worker_poll
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG")" = 1 ] || fail "the sweep rang no doorbell for the unacked steer"
pass "one sweep rings the unacked steer of every live remote worker"
: > "$FM_TEST_CALL_LOG"
wakes_before=$(wc -l < "$TMP_ROOT/wakes")
FM_TEST_FLEET_MODE=fail remote_worker_poll
[ "$(grep -c '^ring$' "$FM_TEST_CALL_LOG" || true)" = 0 ] || fail "a failed fleet probe rang"
[ "$(wc -l < "$TMP_ROOT/wakes")" = "$wakes_before" ] || fail "a failed fleet probe woke"
pass "a failed fleet probe keeps the sweep silent"
FM_TEST_FLEET_LINES=$(printf 'other\tworking\tbusy\thash9\n'); export FM_TEST_FLEET_LINES
rm -f "$STATE/.fleet-lab"
: > "$TMP_ROOT/wakes"
remote_worker_poll
grep -Fq 'wake:stale: remote:w1' "$TMP_ROOT/wakes" || fail "a worker missing from the fleet did not wake"
remote_worker_poll
[ "$(grep -c 'remote:w1' "$TMP_ROOT/wakes")" = 1 ] || fail "a missing worker woke twice"
pass "a worker missing from the fleet wakes exactly once"
