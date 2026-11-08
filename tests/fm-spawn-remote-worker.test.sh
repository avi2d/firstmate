#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-remote-worker)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
printf '%s\n' '- alpha [direct-PR host=exec-one] - project' > "$HOME_DIR/data/projects.md"
mkdir -p "$HOME_DIR/data/test-task"
printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/test-task/brief.md"
out=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" test-task "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) && fail "missing execution-home route was accepted"
printf '%s\n' "$out" | grep -F 'execution-home route' >/dev/null || fail "missing execution-home route was not identified: $out"
[ ! -e "$HOME_DIR/state/test-task.meta" ] || fail "missing route created task metadata"
pass "remote project without an execution-home route refuses before launch"
out=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" task-mate --secondmate --local 2>&1) && fail "secondmate accepted a worker placement override"
printf '%s\n' "$out" | grep -F -- '--local applies only to fresh ship and scout workers' >/dev/null || fail "secondmate did not reject the placement override: $out"
pass "secondmate refuses a worker placement override"
FAKE_ROOT="$TMP_ROOT/code"
mkdir -p "$FAKE_ROOT"
cp -R "$ROOT/bin" "$FAKE_ROOT/bin"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf '%s\n' '- exec-one - execution home (host: testhost; root: /remote/code; home: /remote/home; session: fm-lab-test; scope: workers; projects: alpha; added 2026-01-01)' > "$HOME_DIR/data/remote-homes.md"
cat > "$FAKE_ROOT/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  *' capabilities') printf 'fm-remote-worker-control.v1\n' ;;
  *' launch '*)
    cat >/dev/null
    target=fm-lab-test:w1:pane1
    [ "${FM_TEST_BAD_TARGET:-0}" != 1 ] || target=fm-lab-test:bad/path
    printf 'schema=fm-remote-worker-control.v1\nbackend=herdr\ntarget=%s\nherdr_session=fm-lab-test\nkind=%s\nharness=pi\nworktree=/remote/worktree\nproject=/remote/home/projects/alpha\n' "$target" "$7" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_ROOT/bin/fm-on.sh"
out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" test-task "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) || fail "remote launch refused: $out"
assert_grep 'remote_host=testhost' "$HOME_DIR/state/test-task.meta" "remote host was not recorded"
assert_grep 'remote_route=exec-one' "$HOME_DIR/state/test-task.meta" "execution-home route was not recorded"
assert_grep 'remote_target=fm-lab-test:w1:pane1' "$HOME_DIR/state/test-task.meta" "remote endpoint was not recorded"
pass "remote launch records the host, route and actual endpoint"
FM_ROOT_OVERRIDE="$FAKE_ROOT" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" test-task; [ "$FM_BACKEND_VALIDATED_BACKEND" = remote ]' _ "$FAKE_ROOT" "$HOME_DIR/state/test-task.meta" || fail "remote task record was rejected by endpoint validation"
pass "endpoint validation accepts a remote worker record"
rm "$HOME_DIR/config/backlog-backend"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add task-two 'Research alpha' --kind scout >/dev/null
mkdir -p "$HOME_DIR/data/task-two"
printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/task-two/brief.md"
out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" task-two "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) || fail "backlog-backed remote launch failed: $out"
list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" list --state in_flight)
printf '%s\n' "$list" | grep -F 'task-two' >/dev/null || fail "remote task did not move to In flight: spawn=$out list=$list"
pass "remote launch moves its backlog item to In flight"
printf '%s\n' '- alpha [direct-PR forge=forgejo host=exec-one] - project' > "$HOME_DIR/data/projects.md"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add ship-one 'Change alpha' --kind ship >/dev/null
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" ship-one alpha --mode direct-PR --forge forgejo >/dev/null
awk '$0 == "{TASK}" {print "Change alpha."; next} $0 == "{FIRSTMATE_SPEC}" {print "Use the selected forge."; next} {print}' "$HOME_DIR/data/ship-one/brief.md" > "$TMP_ROOT/ship-brief"
mv "$TMP_ROOT/ship-brief" "$HOME_DIR/data/ship-one/brief.md"
out=$(FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" ship-one "$HOME_DIR/projects/alpha" --mode direct-PR --yolo off --harness pi 2>&1) || fail "remote forge ship was refused: $out"
assert_grep 'mode=direct-PR' "$HOME_DIR/state/ship-one.meta" "remote ship mode was lost"
assert_grep 'branch=fm/ship-one' "$HOME_DIR/state/ship-one.meta" "remote ship branch was lost"
assert_no_grep 'mode=-' "$HOME_DIR/state/test-task.meta" "scout metadata invented a delivery mode"
pass "remote ship accepts its selected forge contract"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add bad-route 'Research alpha' --kind scout >/dev/null
mkdir -p "$HOME_DIR/data/bad-route"
printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/bad-route/brief.md"
out=$(FM_TEST_BAD_TARGET=1 FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" bad-route "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) && fail "remote launch accepted a malformed endpoint"
assert_grep 'remote_target=pending' "$HOME_DIR/state/bad-route.meta" "ambiguous launch was not preserved"
pass "remote launch preserves an unconfirmed record instead of accepting a malformed endpoint"
