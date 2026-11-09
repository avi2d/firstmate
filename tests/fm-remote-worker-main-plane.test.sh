#!/usr/bin/env bash
set -eu
# Main-home remote-worker plane: control hop, crew-state arm, done gate,
# and send routing, all through a canned remote entrypoint (no real host).
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-main-plane)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$TMP_ROOT/fakebin"
printf '%s\n' '- lab - lab route (host: lab-host; root: /remote/code; home: /remote/home; scope: test; projects: alpha; added 2026-01-01)' > "$HOME_DIR/data/remote-homes.md"
printf 'kind=ship\nharness=pi\nremote_host=lab-host\nremote_route=lab\nworktree=/tmp/wt\nproject=/tmp/proj\n' > "$HOME_DIR/state/w1.meta"
printf 'kind=secondmate\nharness=pi\nremote_host=lab-host\n' > "$HOME_DIR/state/w2.meta"
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
task=$(tr '\000' '\n' < "$tmp" | sed -n '3p')
case "$verb" in
  capabilities) printf 'fm-remote-worker-control.v2\n' ;;
  interrupt|exit|relaunch)
    case "${FM_TEST_HOP_MODE:-ok}" in
      ok) printf 'interrupt delivered to %s on host\nschema=fm-remote-worker-control.v2\nbackend=tmux\ntarget=lab:fm-%s\nherdr_session=\nkind=ship\nharness=pi\n' "$task" "$task" ;;
      old) printf "unknown remote worker command '%s'\n" "$verb"; exit 1 ;;
    esac ;;
  crew-state)
    if [ "${FM_TEST_CREW_MODE:-ok}" = ok ]; then printf 'state: working: building the widget\n'; else exit 1; fi ;;
  done-gate)
    case "${FM_TEST_GATE_MODE:-ok}" in
      ok) printf 'ok\n' ;;
      refused) printf 'refused: host checks red\n' ;;
      down) exit 1 ;;
    esac ;;
  send-stdin) cat > "$FM_TEST_STDIN_CAPTURE"; printf 'published %s\n' "$task" ;;
  key) printf 'key sent to %s\n' "$task" ;;
  fleet) printf 'w1\tworking\tbusy\thash1\n' ;;
  *) printf "unknown remote worker command '%s'\n" "$verb"; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/fake-ssh" "$TMP_ROOT/fakebin/canned-entrypoint"
export FM_SSH_BIN="$TMP_ROOT/fakebin/fake-ssh"
export FM_FAKE_REMOTE_ENTRYPOINT="$TMP_ROOT/fakebin/canned-entrypoint"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-control.sh" w1 interrupt 2>&1) || fail "remote interrupt hop refused: $out"
printf '%s\n' "$out" | grep -F 'interrupt delivered to w1' >/dev/null || fail "remote interrupt hid the host receipt: $out"
assert_grep 'remote_target=lab:fm-w1' "$HOME_DIR/state/w1.meta" "remote interrupt did not record the host endpoint"
pass "remote interrupt hops to the execution home and records its endpoint"
out=$(FM_TEST_HOP_MODE=old FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-control.sh" w1 interrupt 2>&1) && fail "remote interrupt trusted an older remote code root"
printf '%s\n' "$out" | grep -F 'older than this home' >/dev/null || fail "remote interrupt did not identify the older root: $out"
pass "remote lifecycle refuses an older remote code root by name"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-control.sh" w2 interrupt 2>&1) && fail "lifecycle reached a remotely placed secondmate"
printf '%s\n' "$out" | grep -F 'remotely placed secondmate' >/dev/null || fail "secondmate refusal lost its placement reason: $out"
pass "a remotely placed secondmate keeps its own recovery path"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-crew-state.sh" w1 2>&1) || fail "remote crew-state refused: $out"
[ "$out" = 'state: working: building the widget' ] || fail "remote crew-state did not relay the host line: $out"
pass "remote crew-state relays the execution-home state line"
out=$(FM_TEST_CREW_MODE=down FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-crew-state.sh" w1 2>&1) || fail "unreachable crew-state exited nonzero: $out"
printf '%s\n' "$out" | grep -F 'unknown-remote' >/dev/null || fail "unreachable crew-state did not say unknown-remote: $out"
pass "an unreachable host reads as unknown-remote, never as death"
dod() {
  FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_dod_accept_ship_done "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"' _ "$ROOT/bin/fm-dod-lib.sh" "$@"
}
out=$(dod ship direct-PR /tmp/wt /tmp/proj 'done: all green' "$HOME_DIR/state" w1 "$HOME_DIR/state/w1.meta") || fail "remote done gate refused: $out"
[ -z "$out" ] || fail "the done gate printed on a pass: $out"
pass "the done gate passes silently on a host ok"
out=$(FM_TEST_GATE_MODE=refused dod ship direct-PR /tmp/wt /tmp/proj 'done: all green' "$HOME_DIR/state" w1 "$HOME_DIR/state/w1.meta" 2>&1) && fail "the done gate passed a refused host verdict"
[ "$out" = 'host checks red' ] || fail "the done gate hid the host reason: $out"
pass "the done gate relays a host refusal as the reason"
out=$(FM_TEST_GATE_MODE=down dod ship direct-PR /tmp/wt /tmp/proj 'done: all green' "$HOME_DIR/state" w1 "$HOME_DIR/state/w1.meta" 2>&1) && fail "the done gate passed an unreachable host"
printf '%s\n' "$out" | grep -F 'host done gate unreachable' >/dev/null || fail "the done gate did not say unreachable: $out"
pass "an unreachable done gate refuses with completion unknown"
export FM_TEST_STDIN_CAPTURE="$TMP_ROOT/captured"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-send.sh" w1 'inspect the session' 2>&1) || fail "remote text steer refused: $out"
[ "$(cat "$FM_TEST_STDIN_CAPTURE")" = 'inspect the session' ] || fail "the steer body did not reach the host verbatim"
pass "a remote text steer rides the inbox with its body verbatim"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-send.sh" w1 --key C-c 2>&1) || fail "remote key steer refused: $out"
pass "a remote key steer crosses to the remote endpoint"
