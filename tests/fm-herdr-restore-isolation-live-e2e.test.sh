#!/usr/bin/env bash
# Live guard: a worker Pi that a real Herdr server restart resumes must read as
# an unsafe worker in crew state. Pi gets no prompt, so no model token is spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_RESTORE_ISOLATION_LIVE_E2E herdr pi jq
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper not executable at $HERDR_LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-isolation.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PRIMARY="$TMP_ROOT/primary"
WT="$TMP_ROOT/wt"
ID=restored-worker
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$PRIMARY" "$WT" "$TMP_ROOT/sessions"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name restore-isolation)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab"

# The production adapter appends the exact session itself, so this shim strips
# that pair and refuses any other session before routing through the lab helper.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
type_line() {  # <pane> <text>
  lab pane send-text "$1" "$2" >/dev/null || return 1
  lab pane send-keys "$1" Enter >/dev/null || return 1
  sleep 0.5
}
production() {  # <command...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_CREW_STATE_NO_FORGE=1 PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" "$@"
}
isolation() {
  HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_task_isolation herdr "$1" "$2" "$3"' "$ROOT" "$TARGET" "$WT" "$ID"
}
wait_for_pi() {  # <seconds>
  local i=0 verdict
  while [ "$i" -lt $(($1 * 5)) ]; do
    verdict=$(isolation)
    case "$verdict" in no-agent|unreadable) ;; *) printf '%s' "$verdict"; return 0 ;; esac
    sleep 0.2
    i=$((i + 1))
  done
  printf '%s' "$verdict"
  return 1
}
registered_session_ref() {
  lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty'
}

WS=$(lab workspace create --cwd "$PRIMARY" --label fm-restore-isolation --no-focus) \
  || fail "could not create the lab workspace: $WS"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "workspace create did not return a root pane id"
TARGET="$HERDR_LAB_SESSION:$PANE"
fm_write_meta "$HOME_DIR/state/$ID.meta" "window=$TARGET" "worktree=$WT" "kind=scout" \
  "backend=herdr" "harness=pi"

# The crew shape: a nested shell under the pane's top shell enters the worktree,
# exports the task marker, and starts Pi there.
sleep 1
type_line "$PANE" "zsh -f" || fail "could not start the nested shell"
type_line "$PANE" "cd -- '$WT'" || fail "could not enter the worktree"
type_line "$PANE" "export FM_TASK_ID=$ID" || fail "could not export the task marker"
type_line "$PANE" "pi --session '$TMP_ROOT/sessions/worker.jsonl'" || fail "could not start pi"

VERDICT=$(wait_for_pi 60) || version_fail "pi never appeared as the pane's harness (verdict '$VERDICT')"
[ "$VERDICT" = isolated ] \
  || version_fail "a Pi launched in its worktree with its marker reads '$VERDICT', not isolated"
for _ in $(seq 1 150); do
  [ -z "$(registered_session_ref)" ] || break
  sleep 0.2
done
[ -n "$(registered_session_ref)" ] \
  || version_fail "pi never reported its session reference to Herdr, so no restart can resume it"
OUT=$(production "$ROOT/bin/fm-crew-state.sh" "$ID")
case "$OUT" in
  *"unsafe worker"*) version_fail "the launched worker already reads unsafe: $OUT" ;;
esac
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a launched worker in its worktree is not flagged"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the lab for the restart"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not restart the lab"

if ! VERDICT=$(wait_for_pi 60); then
  note "herdr $HERDR_VERSION restored the pane without resuming pi, so the unsafe shape does not arise"
  pass "real herdr: a restart that resumes no agent leaves nothing to flag"
  exit 0
fi
PRIMARY_REAL=$(cd "$PRIMARY" && pwd -P)
case "$VERDICT" in
  "outside $PRIMARY_REAL"|unmarked) ;;
  *) version_fail "the Pi Herdr resumed reads '$VERDICT', expected outside $PRIMARY_REAL or unmarked" ;;
esac
note "herdr resumed pi with launch-isolation verdict: $VERDICT"
OUT=$(production "$ROOT/bin/fm-crew-state.sh" "$ID")
case "$OUT" in
  "state: blocked"*"unsafe worker"*"bin/fm-control.sh $ID relaunch"*) ;;
  *) version_fail "crew state for the Pi Herdr resumed must be an unsafe blocked worker, got: $OUT" ;;
esac
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a worker resumed by a server restart reads as an unsafe blocked worker"
