#!/usr/bin/env bash
# server_ensure starts the server as its own session leader.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"

herdr_forget_inherited_pane

SESSION="fm-lab-server-detach-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_backend_herdr_server_ensure "$SESSION" || fail "server_ensure failed to start the isolated session server"

SOCKET=$(HERDR_SESSION="$SESSION" herdr status --json --session "$SESSION" 2>/dev/null | jq -r '.server.socket // empty')
[ -n "$SOCKET" ] || fail "the running lab server reported no socket"
SERVER_PID=$(fm_remote_herdr_socket_owner "$SOCKET")
case "$SERVER_PID" in ''|*[!0-9]*) fail "no herdr process could be proven to own $SOCKET" ;; esac
SERVER_SID=$(python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$SERVER_PID")
[ "$SERVER_SID" = "$SERVER_PID" ] || fail "server pid $SERVER_PID runs in session $SERVER_SID instead of its own; Herdr treats it as liable to die with the SSH connection"
pass "server_ensure starts the isolated session server as its own session leader (pid $SERVER_PID, sid $SERVER_SID)"
