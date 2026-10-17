#!/usr/bin/env bash
# Runs only on a private, named, throwaway Herdr lab session, never the default one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_PI_SANDBOX_LIVE_E2E herdr pi nono jq

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
NONO_VERSION=$(nono --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, nono ${NONO_VERSION:-unknown}, pi ${PI_VERSION:-unknown}]"
}

SESSION="fm-lab-pi-sandbox-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-sandbox.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
mkdir -p "$SCRATCH/state" "$SCRATCH/wt" "$SCRATCH/tmp" "$SCRATCH/data/sbx" "$SCRATCH/hooks"
git -C "$SCRATCH/wt" init -q || fail "could not create the lab worktree"

RENDER=$("$ROOT/bin/fm-agent-sandbox.sh" render "$SCRATCH/state" sbx "$SCRATCH/wt" "$SCRATCH/tmp" \
  "$SCRATCH/data/sbx" "$SCRATCH/hooks" "$ROOT" scout '') || fail "could not render the sandbox profile"
PROFILE=$(printf '%s\n' "$RENDER" | sed -n 's/^profile=//p')
PI_DIR=$(printf '%s\n' "$RENDER" | sed -n 's/^pi_dir=//p')
[ -n "$PROFILE" ] && [ -n "$PI_DIR" ] || fail "the sandbox render named no profile or Pi directory: $RENDER"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"
WS=$(lab workspace create --label fm-pi-sandbox --cwd "$SCRATCH/wt" 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_ID" ] || fail "workspace create did not return a root pane id"
TARGET="$SESSION:$PANE_ID"

wait_for() {  # <expected> <seconds> <reader...>
  local expected=$1 deadline=$((SECONDS + $2))
  shift 2
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$("$@")" = "$expected" ] && return 0
    sleep 0.2
  done
  return 1
}

foreground_names() {
  lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[] | .name]'
}

lab pane run "$PANE_ID" "FM_AGENT_SANDBOX_PI_BIN='$(command -v pi)' FM_AGENT_SANDBOX_CAPTURE_LOG='$SCRATCH/tmp/nono-capture.log' env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH PI_CODING_AGENT_DIR='$PI_DIR' TMPDIR='$SCRATCH/tmp' nono run --profile '$PROFILE' --allow-cwd --no-rollback-prompt -- pi" \
  >/dev/null 2>&1 || fail "could not launch the sandboxed pi"

wait_for agent 60 fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID" || version_fail \
  "no harness was found below the pane shell within 60s of launching a sandboxed pi; process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")', foreground $(foreground_names)"
REGISTRATION=$(lab agent get "$PANE_ID" 2>&1 | jq -r '.error.code // .result.agent.agent_status // empty' 2>/dev/null)
note "sandboxed pi: foreground $(foreground_names), herdr registration '${REGISTRATION:-none}'"

STATE=$(fm_backend_agent_state herdr "$TARGET")
[ "$STATE" = alive ] || version_fail "a running sandboxed pi reads '$STATE' rather than 'alive' (pane state '$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")')"
LAUNCH=$(fm_backend_launch_pane_state herdr "$TARGET")
[ "$LAUNCH" = occupied ] || version_fail "a running sandboxed pi's pane reads '$LAUNCH' for a launch rather than 'occupied'"
wait_for empty 30 fm_backend_composer_state herdr "$TARGET" || version_fail \
  "an idle sandboxed pi's composer reads '$(fm_backend_composer_state herdr "$TARGET")' rather than 'empty'; identity '$(fm_backend_herdr_composer_identity "$TARGET" | tr '\t' /)'"
pass "real herdr $HERDR_VERSION + nono $NONO_VERSION + pi $PI_VERSION: a sandboxed pi reads alive, refuses a launch, and has a provably empty composer"

lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1 || fail "could not type /quit"
sleep 0.5
lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || fail "could not submit /quit"
if ! wait_for shell 10 fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID"; then
  lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || true
  wait_for shell 30 fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID" || version_fail \
    "the sandboxed pi did not exit to a shell within 40s of /quit; process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")'"
fi
STATE=$(fm_backend_agent_state herdr "$TARGET")
[ "$STATE" = dead ] || version_fail "after the sandboxed pi quit the endpoint reads '$STATE' rather than 'dead'"
LAUNCH=$(fm_backend_launch_pane_state herdr "$TARGET")
[ "$LAUNCH" = shell ] || version_fail "after the sandboxed pi quit the pane reads '$LAUNCH' for a launch rather than 'shell'"
pass "real herdr $HERDR_VERSION + nono $NONO_VERSION + pi $PI_VERSION: a quit sandboxed pi reads dead and admits a launch"
