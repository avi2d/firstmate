#!/usr/bin/env bash
set -eu
# The watcher sweep for remote workers, end to end except the transport:
# real sweep code, real libs, real record files, and the real fm-on.sh
# against a canned entrypoint. Proves a delivered-but-unacked steer on a
# live host worker is re-rung with the record-addressed doorbell, then
# held quiet inside the ring grace window.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-sweep)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$TMP_ROOT/fakebin"
export FM_HOME="$HOME_DIR"
export STATE POLL=30 SCRIPT_DIR="$ROOT/bin"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-remote-worker-poll-lib.sh
. "$ROOT/bin/fm-remote-worker-poll-lib.sh"
age_of() {
  local f=$1 m now
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  printf '%s' "$((now - m))"
}
printf '%s\n' '- lab - lab route (host: lab-host; root: /remote/code; home: /remote/home; scope: test; projects: alpha; added 2026-01-01)' > "$HOME_DIR/data/remote-homes.md"
printf 'kind=ship\nharness=pi\nremote_host=lab-host\nremote_route=lab\n' > "$STATE/w1.meta"
mkdir -p "$STATE/w1.inbox"
printf 'inspect the session\n' > "$STATE/w1.inbox/001.msg"
corr=$(fm_pending_reply_create "$HOME_DIR" "$STATE" w1 'inspect the session') || fail "pending-reply creation refused"
rec=$(fm_pending_reply_path "$STATE" "$corr") || fail "pending-reply path refused"
fm_pending_reply_set "$rec" delivered_epoch "$(( $(date +%s) - 120 ))" || fail "delivery confirmation refused"
cat > "$TMP_ROOT/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
cat > "$TMP_ROOT/fakebin/canned-entrypoint" <<'SH'
#!/usr/bin/env bash
set -eu
argvb64=$4
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if ! printf '%s' "$argvb64" | base64 --decode > "$tmp" 2>/dev/null; then
  printf '%s' "$argvb64" | base64 -D > "$tmp" 2>/dev/null || exit 99
fi
verb=$(tr '\000' '\n' < "$tmp" | sed -n '2p')
case "$verb" in
  fleet) printf 'w1\tworking\tbusy\thash1\n' ;;
  ring) cat >> "$FM_TEST_RING_LOG"; printf '\nrung\n' >> "$FM_TEST_RING_LOG"; exit 0 ;;
  *) printf "unknown remote worker command '%s'\n" "$verb"; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/fake-ssh" "$TMP_ROOT/fakebin/canned-entrypoint"
export FM_SSH_BIN="$TMP_ROOT/fakebin/fake-ssh"
export FM_FAKE_REMOTE_ENTRYPOINT="$TMP_ROOT/fakebin/canned-entrypoint"
export FM_TEST_RING_LOG="$TMP_ROOT/rings"
: > "$FM_TEST_RING_LOG"
remote_worker_poll || fail "the sweep refused a healthy remote worker"
[ -s "$FM_TEST_RING_LOG" ] || fail "the sweep left a delivered-but-unacked steer unrung"
want=$(fm_task_inbox_doorbell_line "$STATE/w1.inbox/001.msg") || fail "doorbell refused"
got=$(head -1 "$FM_TEST_RING_LOG")
[ "$got" = "$want" ] || fail "the re-ring carried [$got] instead of the record doorbell [$want]"
pass "one sweep re-rings an unacked steer with its record doorbell"
: > "$FM_TEST_RING_LOG"
remote_worker_poll || fail "the second sweep refused"
[ ! -s "$FM_TEST_RING_LOG" ] || fail "the sweep re-rang inside its own grace window"
[ -e "$STATE/.remote-ring-escalated-w1" ] && fail "the sweep escalated a rung steer"
pass "the second sweep in the grace window stays quiet"
