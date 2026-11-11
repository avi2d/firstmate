#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-remote-home-header.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-remote-home-header) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
REMOTE_ROOT="$TMP_ROOT/code"
JOB_STATE="$TMP_ROOT/jobs"

CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ -f "$JOB_STATE/worker.pid" ]; then
    ( . "$REMOTE_ROOT/bin/fm-remote-job-lib.sh" && fm_remote_job_stop_worker_tree "$(cat "$JOB_STATE/worker.pid")" ) || true
  fi
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

workspaces_labelled() {  # <label>
  lab workspace list 2>/dev/null \
    | jq -r --arg l "$1" '[.result.workspaces[]? | select(.label == $l) | .workspace_id] | join(" ")' 2>/dev/null
}

pane_cwds_of_workspace() {  # <workspace_id>
  lab pane list --workspace "$1" 2>/dev/null | jq -r '[.result.panes[]?.cwd] | join(" ")' 2>/dev/null
}

# --- scratch world: a parent home routing project alpha to execution home exec-one

PARENT="$TMP_ROOT/parent"
EXEC_HOME="$TMP_ROOT/exec"
FAKE="$TMP_ROOT/fake"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects/alpha" "$REMOTE_ROOT" "$FAKE"
(cd "$ROOT" && tar --exclude=.git --exclude=data --exclude=state --exclude=config --exclude=projects --exclude=.no-mistakes -cf - .) \
  | (cd "$REMOTE_ROOT" && tar -xf -)
mkdir -p "$EXEC_HOME/data" "$EXEC_HOME/projects/alpha" "$EXEC_HOME/state" "$EXEC_HOME/config"
chmod 700 "$PARENT/state" "$EXEC_HOME/state"
touch "$EXEC_HOME/state/.last-watcher-beat"
printf 'codex\n' > "$EXEC_HOME/config/crew-harness"
printf 'exec-one\n' > "$EXEC_HOME/.fm-exec-home"
printf 'manual\n' > "$EXEC_HOME/config/backlog-backend"
# The header holds projected rows; CI's pinned herdr is below the default floor.
printf 'on\n' > "$EXEC_HOME/config/herdr-presentation-spaces"
printf '%s\n' "$HERDR_LAB_SESSION" > "$EXEC_HOME/config/herdr-session"
git -C "$EXEC_HOME/projects/alpha" init -q -b main
printf '# alpha\n' > "$EXEC_HOME/projects/alpha/README.md"
git -C "$EXEC_HOME/projects/alpha" add README.md
git -C "$EXEC_HOME/projects/alpha" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

cat > "$REMOTE_ROOT/bin/treehouse" <<SH
#!/usr/bin/env bash
case "\$*" in
  'get --lease '*)
    n=\$(( \$(cat '$TMP_ROOT/slots' 2>/dev/null || echo 0) + 1 ))
    printf '%s\\n' "\$n" > '$TMP_ROOT/slots'
    git clone -q '$EXEC_HOME/projects/alpha' '$TMP_ROOT/slot'"\$n" || exit 1
    printf '%s\\n' '$TMP_ROOT/slot'"\$n" ;;
esac
exit 0
SH
cat > "$REMOTE_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'OpenAI Codex (fake)\n> '
exec sleep 100000
SH
chmod +x "$REMOTE_ROOT/bin/treehouse" "$REMOTE_ROOT/bin/codex"
# A remote job composes its PATH from the account home and system directories,
# so a herdr installed elsewhere is only reachable through the code root's bin.
ln -s "$(command -v herdr)" "$REMOTE_ROOT/bin/herdr"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture

cat > "$FAKE/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "\$1" = testhost ] || exit 91
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
export PATH='$REMOTE_ROOT/bin':"\$PATH"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT='$JOB_STATE' FM_MAC_LOAD_MOCK_5MIN=0
exec '$REMOTE_ROOT/bin/fm-remote-entrypoint.sh' "\$@"
SH
chmod +x "$FAKE/ssh"

printf '%s\n' '- alpha [direct-PR host=exec-one] - project' > "$PARENT/data/projects.md"
printf '%s\n' "- exec-one - execution (host: testhost; root: $REMOTE_ROOT; home: $EXEC_HOME; session: $HERDR_LAB_SESSION; scope: workers; projects: alpha; added 2026-01-01)" \
  > "$PARENT/data/remote-homes.md"

parent() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 FM_SSH_BIN="$FAKE/ssh" \
    FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_MAC_LOAD_MOCK_5MIN=1000 "$@"
}

launch() {  # <task-id>
  local id=$1 out
  parent "$ROOT/bin/fm-tasks-axi.sh" add "$id" 'Research alpha' --kind scout >/dev/null \
    || fail "could not file backlog item $id"
  mkdir -p "$PARENT/data/$id"
  printf "# Task\n## Captain's intent\nResearch the project.\n\n## Firstmate spec\nReport evidence.\n" \
    > "$PARENT/data/$id/brief.md"
  out=$(parent "$ROOT/bin/fm-spawn.sh" "$id" "$PARENT/projects/alpha" --scout --harness codex 2>&1) \
    || fail "remote launch of $id failed"$'\n'"$out"
}

clean_up() {  # <task-id>
  local id=$1 out home
  for home in "$PARENT" "$EXEC_HOME"; do
    mkdir -p "$home/data/$id"
    printf '# report\n\nFinding.\n\n## References\n\n- README.md\n' > "$home/data/$id/report.md"
  done
  for home in "$PARENT" "$EXEC_HOME"; do
    env FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null 2>&1 || true
  done
  out=$(parent "$ROOT/bin/fm-teardown.sh" "$id" 2>&1) || fail "cleanup of $id failed"$'\n'"$out"
}

HEADER_RECORD="$EXEC_HOME/state/herdr-home-header"

workspace_ids() {
  lab workspace list 2>/dev/null | jq -r '[.result.workspaces[]?.workspace_id] | join(" ")' 2>/dev/null
}

task_row_of() {  # <task-id>
  lab workspace list 2>/dev/null \
    | jq -r --arg t "$1" '[.result.workspaces[]? | select(.label | startswith("└ " + $t + " · p:")) | .workspace_id] | join(" ")' 2>/dev/null
}

tab_labels_of_workspace() {  # <workspace_id>
  lab tab list --workspace "$1" 2>/dev/null | jq -r '[.result.tabs[]?.label] | join(" ")' 2>/dev/null
}

# --- 1. one launch and cleanup ----------------------------------------------

[ -z "$(workspace_ids)" ] || fail "the fresh lab already holds a workspace"
launch solo1
ROW=$(task_row_of solo1)
[ -n "$ROW" ] && [ "${ROW#* }" = "$ROW" ] || fail "launch did not create exactly one task row: '$ROW'"
[ "$(workspace_ids)" = "$ROW" ] || fail "launch created a workspace besides its task row: $(workspace_ids)"
[ "$(tab_labels_of_workspace "$ROW")" = fm-solo1 ] || fail "the task row holds more than its task tab: $(tab_labels_of_workspace "$ROW")"
[ ! -e "$HEADER_RECORD" ] || fail "a launch that created no home workspace recorded one"
pass "real herdr E2E: a remote launch creates only its task row, with no empty home workspace"

clean_up solo1
[ -z "$(workspace_ids)" ] || fail "cleanup left a workspace behind: $(workspace_ids)"
pass "real herdr E2E: cleaning up the only remote worker leaves the session empty"

# --- 2. two workers ---------------------------------------------------------

launch pair1
launch pair2
[ -z "$(workspaces_labelled firstmate)" ] || fail "a second launch created a home workspace"
[ "$(workspace_ids)" = "$(task_row_of pair1) $(task_row_of pair2)" ] \
  || fail "two launches did not leave exactly their two task rows: $(workspace_ids)"
clean_up pair1
[ "$(workspace_ids)" = "$(task_row_of pair2)" ] || fail "cleanup of one worker disturbed the other row: $(workspace_ids)"
clean_up pair2
[ -z "$(workspace_ids)" ] || fail "cleanup of the last worker left a workspace behind: $(workspace_ids)"
pass "real herdr E2E: several remote workers each get only their own task row"

# --- 3. a home-labelled workspace that existed before the launch ------------

ADOPTED=$(lab workspace create --cwd "$TMP_ROOT" --label firstmate --no-focus 2>/dev/null \
  | jq -r '.result.workspace.workspace_id // empty')
[ -n "$ADOPTED" ] || fail "could not create a pre-existing home-labelled workspace"
launch adopt1
[ "$(workspace_ids)" = "$ADOPTED $(task_row_of adopt1)" ] \
  || fail "the task row was not placed under the existing home workspace: $(workspace_ids)"
[ ! -e "$HEADER_RECORD" ] || fail "an adopted workspace was recorded as one this home created"
clean_up adopt1
[ "$(workspaces_labelled firstmate)" = "$ADOPTED" ] || fail "cleanup removed a home-labelled workspace this home did not create"
pass "real herdr E2E: a pre-existing home-labelled workspace heads the task row and is left in place"
lab workspace close "$ADOPTED" >/dev/null 2>&1 || fail "could not close the adopted workspace"

# --- 4. a recorded home workspace an earlier launch created -----------------

OLD=$(lab workspace create --cwd "$EXEC_HOME" --label firstmate --no-focus 2>/dev/null) \
  || fail "could not create a recorded home workspace"
OLD_WS=$(printf '%s' "$OLD" | jq -r '.result.workspace.workspace_id // empty')
OLD_TAB=$(printf '%s' "$OLD" | jq -r '.result.tab.tab_id // empty')
OLD_PANE=$(printf '%s' "$OLD" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$OLD_WS" ] && [ -n "$OLD_TAB" ] && [ -n "$OLD_PANE" ] || fail "the recorded home workspace returned incomplete ids"
printf 'session=%s\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$HERDR_LAB_SESSION" "$OLD_WS" "$OLD_TAB" "$OLD_PANE" > "$HEADER_RECORD"
launch legacy1
[ "$(workspace_ids)" = "$OLD_WS $(task_row_of legacy1)" ] \
  || fail "the task row was not placed under the recorded home workspace: $(workspace_ids)"
clean_up legacy1
[ -z "$(workspace_ids)" ] || fail "the recorded home workspace outlived its last worker row: $(workspace_ids)"
[ ! -e "$HEADER_RECORD" ] || fail "the retired home workspace's record was left behind"
pass "real herdr E2E: a home workspace recorded by an earlier launch heads new rows and goes with the last one"

cleanup_all || { printf 'not ok - isolated lab teardown failed\n' >&2; exit 1; }
pass "real herdr E2E: isolated lab session removed and default fleet session unchanged"
