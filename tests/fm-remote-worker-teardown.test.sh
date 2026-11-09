#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-teardown)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$TMP_ROOT/fakebin"
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
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if ! printf '%s' "$4" | base64 --decode > "$tmp" 2>/dev/null; then
  printf '%s' "$4" | base64 -D > "$tmp" 2>/dev/null || exit 99
fi
tr '\000' ' ' < "$tmp" >> "$FM_TEST_REMOTE_LOG"
printf '\n' >> "$FM_TEST_REMOTE_LOG"
if [ "$(tr '\000' '\n' < "$tmp" | sed -n '1p')" = fm-fleet-sync.sh ]; then
  [ "${FM_TEST_SYNC_MODE:-ok}" = ok ] || exit 255
  printf 'alpha: synced 1111111..2222222\n'
  exit 0
fi
case "$(tr '\000' '\n' < "$tmp" | sed -n '2p')" in
  capabilities) printf 'fm-remote-worker-control.v2\n' ;;
  teardown)
    case "$FM_TEST_HOP_MODE" in
      ok) printf 'teardown=done rc=0\n' ;;
      refused) printf 'REFUSED: unlanded work on host\n'; exit 1 ;;
      lost) exit 255 ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/fake-ssh" "$TMP_ROOT/fakebin/canned-entrypoint"
export FM_SSH_BIN="$TMP_ROOT/fakebin/fake-ssh"
export FM_FAKE_REMOTE_ENTRYPOINT="$TMP_ROOT/fakebin/canned-entrypoint"
export FM_TEST_REMOTE_LOG="$TMP_ROOT/remote.log"

seed() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  printf '%s\n' '- lab - execution home (host: lab-host; root: /remote/code; home: /remote/home; session: fm-remote; scope: test; projects: alpha; added 2026-01-01)' > "$HOME_DIR/data/remote-homes.md"
  printf '# Backlog\n\n## In flight\n\n- [ ] w1 - Remote widget (kind: ship)\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  printf 'kind=ship\nmode=direct-PR\nyolo=off\nharness=pi\nspawn_gen=g1\nwindow=remote:w1\nendpoint_task_id=w1\nworktree=/remote/home/projects/alpha-wt\nproject=/remote/home/projects/alpha\nremote_host=lab-host\nremote_route=lab\nremote_root=/remote/code\nremote_backend=herdr\nremote_target=fm-remote:p1\nremote_herdr_session=fm-remote\npr=https://github.com/o/alpha/pull/7\n' > "$HOME_DIR/state/w1.meta"
  printf 'working [at=1]: started\n' > "$HOME_DIR/state/w1.status"
  : > "$FM_TEST_REMOTE_LOG"
}

seed
out=$(FM_TEST_HOP_MODE=lost FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-teardown.sh" w1 2>&1) && fail "teardown trusted a lost transport: $out"
printf '%s\n' "$out" | grep -F 'did not confirm completion' >/dev/null || fail "a lost transport was not reported as unknown completion: $out"
[ -f "$HOME_DIR/state/w1.meta" ] || fail "a lost transport removed the task record"
awk '/^## In flight/{f=1} /^## Queued/{f=0} f && /w1 - Remote widget/ {m=1} END {exit !m}' "$HOME_DIR/data/backlog.md" || fail "a lost transport moved the backlog item"
pass "a lost cleanup transport preserves every local record"

seed
out=$(FM_TEST_HOP_MODE=refused FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-teardown.sh" w1 2>&1) && fail "teardown passed a host refusal: $out"
printf '%s\n' "$out" | grep -F 'unlanded work on host' >/dev/null || fail "the host refusal reason was hidden: $out"
[ -f "$HOME_DIR/state/w1.meta" ] || fail "a host refusal removed the task record"
pass "a host refusal relays its reason and preserves the task record"

seed
mkdir -p "$HOME_DIR/state/remote-feeds/lab"
: > "$HOME_DIR/state/remote-feeds/lab/w1.cursor"
: > "$HOME_DIR/state/remote-feeds/lab/w1.3.ingested"
: > "$HOME_DIR/state/remote-feeds/lab/w1.2.3.ingested"
out=$(FM_TEST_HOP_MODE=ok FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-teardown.sh" w1 2>&1) || fail "remote cleanup refused: $out"
grep -F 'fm-remote-worker-control.sh teardown w1' "$FM_TEST_REMOTE_LOG" >/dev/null || fail "the host teardown hop was not made: $(cat "$FM_TEST_REMOTE_LOG")"
[ ! -e "$HOME_DIR/state/w1.meta" ] || fail "a confirmed remote cleanup left the task record"
[ ! -e "$HOME_DIR/state/w1.status" ] || fail "a confirmed remote cleanup left the live status"
awk '/^## Done/{d=1} d && /w1 - Remote widget/ {f=1} END {exit !f}' "$HOME_DIR/data/backlog.md" || fail "the backlog item did not move to Done: $(cat "$HOME_DIR/data/backlog.md")"
assert_grep 'pull/7' "$HOME_DIR/data/backlog.md" "the Done item lost its PR link"
[ ! -e "$HOME_DIR/state/remote-feeds/lab/w1.cursor" ] && [ ! -e "$HOME_DIR/state/remote-feeds/lab/w1.3.ingested" ] || fail "cleanup left the task's feed cursor"
[ -e "$HOME_DIR/state/remote-feeds/lab/w1.2.3.ingested" ] || fail "cleanup removed another task's feed receipt"
pass "a confirmed remote cleanup closes the item with its PR link"
EXEC_HOME="$TMP_ROOT/exec-home"
mkdir -p "$EXEC_HOME/state"
: > "$EXEC_HOME/.fm-exec-home"
out=$(FM_HOME="$EXEC_HOME" bash "$ROOT/bin/fm-remote-worker-control.sh" teardown w1 2>&1) || fail "a host rerun after a lost reply refused: $out"
[ "$out" = 'teardown=absent' ] || fail "a host rerun did not report the record already gone: $out"
out=$(FM_HOME="$EXEC_HOME" bash "$ROOT/bin/fm-remote-worker-control.sh" teardown w1 --keep 2>&1) && fail "host teardown accepted an unknown option"
pass "a host rerun after a lost reply converges on an absent record"
seed
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-fleet-sync.sh" --remote lab alpha 2>/dev/null) || fail "the remote sync hop failed: $out"
[ "$out" = 'lab: alpha: synced 1111111..2222222' ] || fail "the remote sync hop did not relay the host line under its route: $out"
grep -Fx 'fm-fleet-sync.sh alpha ' "$FM_TEST_REMOTE_LOG" >/dev/null || fail "the remote sync hop sent the wrong command: $(cat "$FM_TEST_REMOTE_LOG")"
out=$(FM_TEST_SYNC_MODE=lost FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-fleet-sync.sh" --remote lab alpha 2>/dev/null) || fail "an unanswered remote sync failed the caller: $out"
printf '%s\n' "$out" | grep -F 'lab: skipped: the execution home did not answer' >/dev/null || fail "an unanswered remote sync was not reported as skipped: $out"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-fleet-sync.sh" --remote lab ../alpha 2>&1) && fail "the remote sync hop accepted a path for a project name"
pass "the post-merge remote sync hop relays the host result and skips an unanswered host"
