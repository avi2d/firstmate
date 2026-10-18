#!/usr/bin/env bash
# Every Herdr call goes through bin/fm-herdr-lab.sh on one named session, and no
# real agent starts: the test skips unless lab panes resolve grok to the stand-in.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-rebind-e2e.XXXXXX")
HERDR_BIN="$TMP_ROOT/herdr-bin"
HARNESS_BIN="$TMP_ROOT/harness-bin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
HERDR_ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
mkdir -p "$HERDR_BIN" "$HARNESS_BIN"
: > "$HERDR_CALL_LOG"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-rebind-place) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION HERDR_LAB_HELPER
export HERDR_CALL_LOG HERDR_ORIGINAL_PATH REAL_HERDR

CLEANED=0
LAB_READY=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ "$LAB_READY" = 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  fi
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT

# Each adapter call is logged and sent through the lab helper, which re-appends
# the lab session. A call naming any other session is refused, so a rebind that
# drifted to the ambient session cannot pass.
cat > "$HERDR_BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
args=("$@")
last=$((${#args[@]} - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$((last - 1))]}" = --session ] \
   && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$((last - 1))]"
fi
set -- ${args[@]+"${args[@]}"}
for arg in "$@"; do
  case "$arg" in
    --session|--session=*) echo "test wrapper: a call named another herdr session: $*" >&2; exit 1 ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$HERDR_BIN/herdr"

# The stand-in agent titles its terminal `nono`, which must not relabel the
# task's tab or workspace.
cat > "$HARNESS_BIN/grok" <<SH
#!/bin/sh
printf '\\033]0;nono\\007'
: > "$TMP_ROOT/agent-launched"
sleep 1
SH
chmod +x "$HARNESS_BIN/grok"

PATH="$HARNESS_BIN:$PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"
LAB_READY=1

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

wait_for_file() {  # <path>
  local _
  for _ in $(seq 1 100); do
    [ ! -e "$1" ] || return 0
    sleep 0.1
  done
  return 1
}

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

LAUNCHER_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus) \
  || fail "could not create the launcher workspace"
LAUNCHER_WS=$(printf '%s' "$LAUNCHER_OUT" | jq -r '.result.workspace.workspace_id // empty')
LAUNCHER_PANE=$(printf '%s' "$LAUNCHER_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$LAUNCHER_WS" ] && [ -n "$LAUNCHER_PANE" ] || fail "the launcher workspace returned incomplete ids"
LAUNCHER_TABS_BEFORE=$(lab tab list --workspace "$LAUNCHER_WS" | jq -c '[.result.tabs[]?.tab_id] | sort')

lab pane run "$LAUNCHER_PANE" "command -v grok > '$TMP_ROOT/agent-path'" >/dev/null \
  || fail "could not ask a lab pane which grok it resolves"
wait_for_file "$TMP_ROOT/agent-path" || fail "a lab pane did not report which grok it resolves"
if [ "$(cat "$TMP_ROOT/agent-path")" != "$HARNESS_BIN/grok" ]; then
  echo "skip: lab panes resolve grok to '$(cat "$TMP_ROOT/agent-path")', not the stand-in, so a relaunch could start a real agent"
  exit 0
fi

ID=rb1
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/proj"
WT="$TMP_ROOT/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$ID" "$PROJ"
printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise a Herdr reclaim safely.

## Firstmate spec
Keep the recorded worktree when the endpoint is re-created.
EOF
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b "task-$ID" "$WT"
WT_REAL=$(cd "$WT" && pwd -P)
printf 'never committed\n' > "$WT/dirty.txt"
HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)

project_original_endpoint() {
  (
    set -eu
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source herdr
    state="$HOME_DIR/state"
    journal=$(fm_backend_herdr_projection_journal_path "$state" "$ID")
    token=$(fm_backend_herdr_projection_journal_create "$state" "$ID")
    label=$(fm_backend_herdr_projection_workspace_label "$ID" "$token")
    fm_backend_herdr_projection_create_task "$WT" "$label" "fm-$ID" "$HERDR_LAB_SESSION"
    fm_backend_herdr_projection_journal_bind "$journal" "$ID" \
      "$(fm_backend_herdr_projection_home_identity "$HOME_DIR")" "$HERDR_LAB_SESSION" \
      "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
      "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" "$LAUNCHER_WS" firstmate "$label" "fm-$ID"
    printf '%s %s %s\n' "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" "$FM_BACKEND_HERDR_PROJECTION_PANE_ID"
  )
}
ORIGINAL=$(PATH="$HERDR_BIN:$PATH" FM_HOME="$HOME_DIR" project_original_endpoint) \
  || fail "could not project the original endpoint"
read -r OLD_WS OLD_TAB OLD_PANE <<EOF
$ORIGINAL
EOF
JOURNAL="$HOME_DIR/state/$ID.herdr-presentation"
OLD_TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ "$(grep '^version=' "$JOURNAL")" = version=2 ] || fail "the original projection did not bind its journal"

{
  echo "window=$HERDR_LAB_SESSION:$OLD_PANE"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=grok"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$HERDR_LAB_SESSION"
  echo "herdr_workspace_id=$OLD_WS"
  echo "herdr_tab_id=$OLD_TAB"
  echo "herdr_pane_id=$OLD_PANE"
} > "$HOME_DIR/state/$ID.meta"

lab workspace close "$OLD_WS" >/dev/null || fail "could not close the original endpoint's workspace"
if lab pane get "$OLD_PANE" >/dev/null 2>&1; then
  fail "the original endpoint survived closing its workspace"
fi

: > "$HERDR_CALL_LOG"
OUT=$(env HERDR_ENV=1 HERDR_PANE_ID="$LAUNCHER_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" \
  HERDR_SOCKET_PATH="$LAB_SOCKET" PATH="$HERDR_BIN:$HARNESS_BIN:$PATH" \
  FM_HOME="$HOME_DIR" GROK_HOME="$TMP_ROOT/grok-home" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
  FM_MAC_LOAD_MOCK_5MIN=1.0 \
  "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch 2>&1) \
  || fail "relaunching a task whose endpoint is gone failed: $OUT"
wait_for_file "$TMP_ROOT/agent-launched" || fail "the replacement agent was not launched: $OUT"

meta() { grep "^$1=" "$HOME_DIR/state/$ID.meta" | tail -1 | cut -d= -f2-; }
NEW_WS=$(meta herdr_workspace_id)
NEW_TAB=$(meta herdr_tab_id)
NEW_PANE=$(meta herdr_pane_id)
[ "$(meta herdr_session)" = "$HERDR_LAB_SESSION" ] || fail "the rebind left its recorded herdr session"
[ "$(meta window)" = "$HERDR_LAB_SESSION:$NEW_PANE" ] || fail "the rebound window does not name the new pane"
[ -n "$NEW_WS" ] && [ "$NEW_WS" != "$LAUNCHER_WS" ] \
  || fail "the rebind landed in the launcher's workspace ($LAUNCHER_WS) instead of its own"
[ "$(lab tab list --workspace "$LAUNCHER_WS" | jq -c '[.result.tabs[]?.tab_id] | sort')" = "$LAUNCHER_TABS_BEFORE" ] \
  || fail "the rebind added a tab to the launcher's workspace"
[ "$(lab pane get "$NEW_PANE" | jq -r '.result.pane.workspace_id')" = "$NEW_WS" ] \
  || fail "the recorded pane does not live in the recorded workspace"
pass "real herdr: a relaunch whose endpoint is gone gets its own workspace, not a tab in the launcher's"

NEW_TOKEN=$(grep '^projection_id=' "$JOURNAL" | cut -d= -f2-)
[ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "$OLD_TOKEN" ] \
  || fail "the rebind did not retire the orphaned journal for a fresh projection"
[ "$(grep '^pane_id=' "$JOURNAL" | cut -d= -f2-)" = "$NEW_PANE" ] \
  || fail "the new projection journal is not bound to the rebound pane"
sleep 2
WS_LABEL=$(lab workspace get "$NEW_WS" | jq -r '.result.workspace.label // empty')
[ "$WS_LABEL" = "└ $ID · p:$NEW_TOKEN" ] || fail "the rebound workspace is labelled '$WS_LABEL', not with its task id"
TAB_LABEL=$(lab tab get "$NEW_TAB" | jq -r '.result.tab.label // empty')
[ "$TAB_LABEL" = "fm-$ID" ] || fail "the rebound tab is labelled '$TAB_LABEL', not fm-$ID"
pass "real herdr: the rebound workspace and tab carry the task id after the agent titled its terminal"

[ "$(lab pane get "$NEW_PANE" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd')" = "$WT_REAL" ] \
  || fail "the rebound pane is not in the recorded worktree"
[ "$(meta worktree)" = "$WT" ] || fail "the rebind changed the recorded worktree"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "the rebind moved the worktree's HEAD"
grep -q 'never committed' "$WT/dirty.txt" || fail "the rebind lost an uncommitted change"
# The bare version and client-protocol reads address no server at all.
OFF_SESSION=$(grep -v -- "--session $HERDR_LAB_SESSION\$" "$HERDR_CALL_LOG" | grep -Ev '^(--version|status --json)$' || true)
[ -z "$OFF_SESSION" ] || fail "the rebind made a herdr call outside its recorded session: $OFF_SESSION"
pass "real herdr: the rebind keeps the recorded session and reuses the recorded worktree untouched"
