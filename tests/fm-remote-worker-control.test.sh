#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-control)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
printf 'exec-route\n' > "$HOME_DIR/.fm-exec-home"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capabilities)
[ "$out" = 'fm-remote-worker-control.v1' ] || fail "capability handshake differs from protocol"
pass "remote worker advertises launch protocol"
mkdir -p "$HOME_DIR/state"
printf 'window=lab:fm-scout-a\nworktree=/tmp/worktree\nproject=/tmp/project\nkind=scout\nharness=pi\n' > "$HOME_DIR/state/scout-a.meta"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" route scout-a)
printf '%s\n' "$out" | grep -Fx 'target=lab:fm-scout-a' >/dev/null || fail "route loses its recorded target"
printf '%s\n' "$out" | grep -Fx 'backend=tmux' >/dev/null || fail "route loses its backend"
pass "remote route reads the task endpoint"
mkdir -p "$HOME_DIR/config"
printf 'fm-lab-test\n' > "$HOME_DIR/config/herdr-session"
printf 'window=fm-other:pane1\nworktree=/tmp/worktree\nproject=/tmp/project\nbackend=herdr\nendpoint_task_id=scout-wrong\nherdr_session=fm-other\nherdr_workspace_id=workspace1\nherdr_tab_id=tab1\nherdr_pane_id=pane1\nkind=scout\nharness=pi\n' > "$HOME_DIR/state/scout-wrong.meta"
if FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" route scout-wrong >/dev/null 2>&1; then fail "route accepted an endpoint outside the execution home session"; fi
pass "route rejects an endpoint from a different Herdr session"
out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" state absent)
[ "$out" = missing ] || fail "missing task was reported as $out"
if FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capture scout-a 101 >/dev/null 2>&1; then fail "capture accepted an unbounded line count"; fi
pass "state reports an absent task and capture bounds its output"
mkdir -p "$TMP_ROOT/fake-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/fake-bin/tmux"
chmod +x "$TMP_ROOT/fake-bin/tmux"
if PATH="$TMP_ROOT/fake-bin:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" capture scout-a >/dev/null 2>&1; then fail "capture reported success when the backend refused"; fi
pass "capture propagates backend failure"
out=$(printf 'test\n' | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" launch scout-b missing scout - - fm/ - pi - - herdr 2>&1) && fail "launch accepted a missing project"
printf '%s\n' "$out" | grep -F 'project is unavailable' >/dev/null || fail "missing project refusal does not identify the cause: $out"
[ ! -e "$HOME_DIR/data/scout-b" ] || fail "missing project created task data"
pass "launch refuses a missing project before writing task data"
mkdir -p "$HOME_DIR/projects"
out=$(printf 'test\n' | FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-remote-worker-control.sh" launch scout-b . scout - - fm/ - pi - - herdr 2>&1) && fail "launch accepted the projects directory as a project"
printf '%s\n' "$out" | grep -F 'invalid task or project id' >/dev/null || fail "dot project was not rejected before reading input: $out"
pass "launch rejects the projects directory as a project"
FAKE_ROOT="$TMP_ROOT/code"
mkdir -p "$FAKE_ROOT" "$HOME_DIR/projects/alpha" "$HOME_DIR/config" "$HOME_DIR/data"
cp -R "$ROOT/bin" "$FAKE_ROOT/bin"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
cat > "$FAKE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
if [ -f "$FM_HOME/config/crew-dispatch.json" ] && [ ! -f "$FM_HOME/data/$id/dispatch-resolution.json" ]; then exit 8; fi
kind=ship
for arg in "$@"; do [ "$arg" != --scout ] || kind=scout; done
printf '%s\n' "$@" > "$FM_HOME/state/$id.args"
printf 'window=lab:fm-%s\nworktree=/tmp/worktree\nproject=/tmp/project\nkind=%s\nharness=pi\n' "$id" "$kind" > "$FM_HOME/state/$id.meta"
printf 'working: reading brief\n' > "$FM_HOME/state/$id.status"
SH
chmod +x "$FAKE_ROOT/bin/fm-spawn.sh"
printf '# Task\n## Captain\x27s intent\nIndependent request.\n\n## Firstmate spec\nExact constraints.\n' > "$TMP_ROOT/brief"
out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-c alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief") || fail "remote launch refused a valid scout"
assert_grep 'Independent request.' "$HOME_DIR/data/scout-c/brief.md" "remote scaffold dropped intent"
assert_grep 'Exact constraints.' "$HOME_DIR/data/scout-c/brief.md" "remote scaffold dropped specification"
assert_grep '--local' "$HOME_DIR/state/scout-c.args" "host spawn did not override remote placement"
assert_grep "$HOME_DIR/state/scout-c.status" "$HOME_DIR/data/scout-c/brief.md" "remote scaffold retained main paths"
printf '%s\n' "$out" | grep -Fx 'target=lab:fm-scout-c' >/dev/null || fail "launch omitted route"
pass "remote launch rebuilds the brief and returns the host endpoint"
{ printf '# Task\n'; sleep 0.2; printf '## Captain\x27s intent\nComplete request.\n\n## Firstmate spec\nComplete constraints.\n'; } | \
  FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-d alpha scout - - fm/ - pi - - herdr >/dev/null \
  || fail "launch dropped a brief split across pipe writes"
assert_grep 'Complete constraints.' "$HOME_DIR/data/scout-d/brief.md" "split brief lost its second write"
pass "launch reads every part of a streamed brief"
mkdir -p "$TMP_ROOT/main/data"
FM_HOME="$TMP_ROOT/main" "$ROOT/bin/fm-brief.sh" scout-e alpha --scout --herdr-lab >/dev/null
awk '$0 == "{TASK}" {print "Inspect the session."; next} $0 == "{FIRSTMATE_SPEC}" {print "Use the lab."; next} {print}' "$TMP_ROOT/main/data/scout-e/brief.md" > "$TMP_ROOT/lab-brief"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-e alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/lab-brief" >/dev/null || fail "lab brief launch failed"
assert_grep "This brief was explicitly scaffolded with \`--herdr-lab\`" "$HOME_DIR/data/scout-e/brief.md" "host scaffold dropped Herdr isolation"
pass "host scaffold retains the Herdr lab isolation contract"
FM_HOME="$TMP_ROOT/main" "$ROOT/bin/fm-brief.sh" ship-one alpha --mode direct-PR --forge forgejo >/dev/null
awk '$0 == "{TASK}" {print "Implement the request."; next} $0 == "{FIRSTMATE_SPEC}" {print "Use the selected forge."; next} {print}' "$TMP_ROOT/main/data/ship-one/brief.md" > "$TMP_ROOT/ship-brief"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch ship-one alpha ship direct-PR off fm/ - pi - - herdr < "$TMP_ROOT/ship-brief" >/dev/null || fail "remote ship launch failed"
assert_grep 'Delivery contract: mode=direct-PR forge=forgejo' "$HOME_DIR/data/ship-one/brief.md" "host scaffold lost the selected forge"
pass "remote ship preserves the forge delivery contract"
printf '{}\n' > "$HOME_DIR/config/crew-dispatch.json"
cat > "$FAKE_ROOT/bin/fm-dispatch-resolve.sh" <<'SH'
#!/usr/bin/env bash
printf '{"status":"off"}\n' > "$(dirname "$1")/dispatch-resolution.json"
SH
chmod +x "$FAKE_ROOT/bin/fm-dispatch-resolve.sh"
FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" bash "$FAKE_ROOT/bin/fm-remote-worker-control.sh" launch scout-f alpha scout - - fm/ - pi - - herdr < "$TMP_ROOT/brief" >/dev/null || fail "remote launch skipped execution-home dispatch resolution"
[ -f "$HOME_DIR/data/scout-f/dispatch-resolution.json" ] || fail "execution-home dispatch record was not created"
pass "remote launch resolves the execution-home dispatch record before spawning"
