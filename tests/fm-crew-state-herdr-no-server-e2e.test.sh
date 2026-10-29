#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-crew-state-no-server-$$"
PROBE_BOUND=20
LAB_PREPARED=0
cleanup_all() {
  local status=$?
  trap - EXIT
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr lab session: $SESSION" >&2
      status=1
    }
  fi
  fm_test_cleanup
  exit "$status"
}
trap cleanup_all EXIT

LAB_PREPARED=1
fm_herdr_lab_provision "$SESSION" >/dev/null || fail "could not provision isolated Herdr lab session"
fm_herdr_lab_stop "$SESSION" >/dev/null || fail "could not stop the lab session's server"

server_running() {
  fm_herdr_lab_raw "$SESSION" status --json 2>/dev/null | jq -r '.server.running'
}

server_pids() {
  pgrep -f "herdr server --session $SESSION\$" || true
}

for _ in $(seq 1 20); do
  [ "$(server_running)" = false ] && [ -z "$(server_pids)" ] && break
  sleep 0.5
done
[ "$(server_running)" = false ] || fail "the lab session's server did not stop before the probe"
[ -z "$(server_pids)" ] || fail "a lab server process outlived the stop: $(server_pids)"

SCRATCH=$(fm_test_tmproot fm-crew-state-herdr-no-server) || fail "could not create scratch dir"
mkdir -p "$SCRATCH/state" "$SCRATCH/nm" "$SCRATCH/wt"
git -C "$SCRATCH/wt" init -q -b fm/no-server || fail "could not create the task worktree"
git -C "$SCRATCH/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init \
  || fail "could not seed the task worktree"
printf '%s\n' "window=$SESSION:w1:p1" "worktree=$SCRATCH/wt" kind=ship backend=herdr harness=claude branch=fm/no-server \
  > "$SCRATCH/state/no-server.meta"

# A server the probe starts keeps a pipe on its stdout open for the server's
# lifetime, so capturing it with $(...) would hang past the bound.
NM_HOME="$SCRATCH/nm" FM_STATE_OVERRIDE="$SCRATCH/state" \
  fm_run_timed "$PROBE_BOUND" "$ROOT/bin/fm-crew-state.sh" no-server >"$SCRATCH/probe.out" 2>/dev/null
rc=$?
out=$(cat "$SCRATCH/probe.out")
fm_timed_out "$rc" && fail "fm-crew-state.sh did not return within ${PROBE_BOUND}s on a stopped herdr session"
[ "$rc" -eq 0 ] || fail "fm-crew-state.sh exited $rc on a stopped herdr session: $out"
case "$out" in
  "state: unknown · source: none"*) ;;
  *) fail "a stopped herdr session should read as an unknown endpoint, got: $out" ;;
esac
[ "$(server_running)" = false ] || fail "fm-crew-state.sh started the stopped lab session's herdr server"
[ -z "$(server_pids)" ] || fail "fm-crew-state.sh left a herdr server process for the lab session: $(server_pids)"
pass "fm-crew-state.sh on a stopped herdr session returns within ${PROBE_BOUND}s and starts no server"
