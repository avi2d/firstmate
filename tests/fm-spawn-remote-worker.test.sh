#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
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
  *' capabilities') printf 'fm-remote-worker-control.v2\n' ;;
  *' claude-account-check '*)
    [ "${FM_TEST_OLD_HOST:-0}" != 1 ] || { printf 'error: unknown remote worker command\n' >&2; exit 1; }
    [ "$6" = main ] || { printf 'error: --claude-account %s needs a login declared for it in config/claude-accounts: /remote/home/config/claude-accounts\n' "$6" >&2; exit 1; }
    printf '%s\n' "$*" > "$FM_HOME/account-check-args"
    printf 'claude_account=%s\n' "$6" ;;
  *' admit '*)
    if [ "${FM_TEST_ADMIT_DEFER:-0}" = 1 ]; then printf 'defer: host already holds 6 alpha worker(s) at its declared limit 6\n'; exit 75; fi
    printf 'admit project=alpha holders=0 load=%s load_limit=16 heavy_free=%s\n' "${FM_TEST_REMOTE_LOAD:-1.0}" "${FM_TEST_REMOTE_FREE:-6}" ;;
  *' launch '*)
    cat >/dev/null
    [ "${FM_TEST_LAUNCH_DEFER:-0}" != 1 ] || { printf 'defer: host already holds 6 alpha worker(s) at its declared limit 6\n'; exit 75; }
    printf '%s\n' "$*" > "$FM_HOME/launch-args"
    account=${16:-}
    [ "${FM_TEST_DROP_ACCOUNT:-0}" != 1 ] || account=
    target=fm-lab-test:w1:pane1
    [ "${FM_TEST_BAD_TARGET:-0}" != 1 ] || target=fm-lab-test:bad/path
    printf 'schema=fm-remote-worker-control.v1\nbackend=herdr\ntarget=%s\nherdr_session=fm-lab-test\nkind=%s\nharness=pi\nworktree=/remote/worktree\nproject=/remote/home/projects/alpha\n%s' "$target" "$7" "${account:+claude_account=$account
}" ;;
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
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add full-host 'Research alpha' --kind scout >/dev/null
mkdir -p "$HOME_DIR/data/full-host"
printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/full-host/brief.md"
rc=0
out=$(FM_TEST_ADMIT_DEFER=1 FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" full-host "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) || rc=$?
[ "$rc" -eq 75 ] || fail "a full host did not defer with exit 75 (rc=$rc): $out"
[ ! -e "$HOME_DIR/state/full-host.meta" ] || fail "a deferred launch published task metadata"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" list --state queued | grep -F 'full-host' >/dev/null || fail "a deferred launch moved its item out of Queued"
pass "a full host defers with exit 75 and keeps the item queued instead of reporting a launch"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add bad-route 'Research alpha' --kind scout >/dev/null
mkdir -p "$HOME_DIR/data/bad-route"
printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/bad-route/brief.md"
out=$(FM_TEST_BAD_TARGET=1 FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" bad-route "$HOME_DIR/projects/alpha" --scout --harness pi 2>&1) && fail "remote launch accepted a malformed endpoint"
assert_grep 'remote_target=pending' "$HOME_DIR/state/bad-route.meta" "ambiguous launch was not preserved"
pass "remote launch preserves an unconfirmed record instead of accepting a malformed endpoint"

new_remote_scout() {  # <task-id>
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add "$1" 'Research alpha' --kind scout >/dev/null
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$HOME_DIR/data/$1/brief.md"
}
remote_spawn() {  # <task-id> [spawn flags...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 bash "$FAKE_ROOT/bin/fm-spawn.sh" "$id" "$HOME_DIR/projects/alpha" --scout --harness pi --model claude-bridge/opus "$@" 2>&1
}

new_remote_scout acct-ok
out=$(remote_spawn acct-ok --claude-account main) || fail "remote launch refused a Claude account: $out"
assert_grep 'claude_account=main' "$HOME_DIR/state/acct-ok.meta" "remote task record did not record the Claude account"
printf '%s\n' "$out" | grep -F 'claude_account=main' >/dev/null || fail "spawned line did not name the Claude account: $out"
assert_grep 'claude-account-check pi claude-bridge/opus main' "$HOME_DIR/account-check-args" "the host was not asked to resolve the account against its own map"
[ "$(awk '{print $NF}' "$HOME_DIR/launch-args")" = main ] || fail "remote launch did not carry the account: $(cat "$HOME_DIR/launch-args")"
pass "remote launch forwards --claude-account to the host and records it instead of refusing the flag"

new_remote_scout acct-none
out=$(remote_spawn acct-none) || fail "remote launch without an account failed: $out"
[ "$(wc -w < "$HOME_DIR/launch-args")" -eq 15 ] || fail "a launch without an account sent an account argument: $(cat "$HOME_DIR/launch-args")"
assert_no_grep 'claude_account=' "$HOME_DIR/state/acct-none.meta" "a launch without an account recorded one"
pass "remote launch without an account sends the older launch shape instead of an empty account"

new_remote_scout acct-missing
out=$(remote_spawn acct-missing --claude-account second) && fail "remote launch accepted an account the host does not map: $out"
printf '%s\n' "$out" | grep -F 'Claude account second' >/dev/null || fail "refusal did not name the missing account: $out"
[ ! -e "$HOME_DIR/state/acct-missing.meta" ] || fail "an unmapped account published a task record"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" list --state queued | grep -F 'acct-missing' >/dev/null || fail "an unmapped account moved its item out of Queued"
pass "remote launch on an account the host does not map refuses before publishing instead of launching on another login"

new_remote_scout acct-old
out=$(FM_TEST_OLD_HOST=1 remote_spawn acct-old --claude-account main) && fail "an older host accepted an account it cannot apply: $out"
printf '%s\n' "$out" | grep -F 'older than this home' >/dev/null || fail "older host refusal did not say to update the host: $out"
[ ! -e "$HOME_DIR/state/acct-old.meta" ] || fail "an older host published a task record"
pass "remote launch on an older host refuses the account instead of dropping it"

new_remote_scout acct-dropped
out=$(FM_TEST_DROP_ACCOUNT=1 remote_spawn acct-dropped --claude-account main) && fail "remote launch trusted a host that dropped the account: $out"
printf '%s\n' "$out" | grep -F 'inconsistent identity' >/dev/null || fail "dropped account was not reported: $out"
assert_grep 'remote_target=pending' "$HOME_DIR/state/acct-dropped.meta" "dropped account did not preserve the pending record"
pass "remote launch whose host reports no account is not recorded as launched on it"

printf '{}\n' > "$HOME_DIR/config/crew-dispatch.json"
new_remote_scout acct-clear
printf '{"task":"acct-clear","status":"clear","profile":{"harness":"pi","model":"claude-bridge/opus","effort":null,"claude_account":"main"}}\n' > "$HOME_DIR/data/acct-clear/dispatch-resolution.json"
out=$(remote_spawn acct-clear) && fail "remote launch dropped the account the clear dispatch selection chose: $out"
[ ! -e "$HOME_DIR/state/acct-clear.meta" ] || fail "a launch without the selected account published a task record"
out=$(remote_spawn acct-clear --claude-account main) || fail "remote launch refused the clear dispatch profile line unchanged: $out"
assert_grep 'claude_account=main' "$HOME_DIR/state/acct-clear.meta" "the selected account was not recorded"
rm "$HOME_DIR/config/crew-dispatch.json"
pass "remote launch takes the clear dispatch profile line unchanged and refuses one missing its account"

NOTMUX="$TMP_ROOT/no-tmux"
mkdir -p "$NOTMUX"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOTMUX/tmux"
chmod +x "$NOTMUX/tmux"
choose_home() {  # <task-id>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data/$1" "$h/state" "$h/config" "$h/projects/alpha"
  printf '%s\n' '- alpha [direct-PR host=exec-one] - project' > "$h/data/projects.md"
  cp "$HOME_DIR/data/remote-homes.md" "$h/data/remote-homes.md"
  printf '# Task\n## Captain\x27s intent\nResearch.\n\n## Firstmate spec\nReport evidence.\n' > "$h/data/$1/brief.md"
  FM_HOME="$h" "$ROOT/bin/fm-tasks-axi.sh" add "$1" 'Research alpha' --kind scout >/dev/null
  printf '%s\n' "$h"
}
choose_run() {  # <home> <task-id> <local-load> <remote-load> <remote-free> [remote-defers]
  local h=$1 id=$2
  PATH="$NOTMUX:$PATH" FM_MAC_LOAD_MOCK_5MIN="$3" FM_TEST_REMOTE_LOAD="$4" FM_TEST_REMOTE_FREE="$5" FM_TEST_ADMIT_DEFER="${6:-0}" FM_TEST_LAUNCH_DEFER="${7:-0}" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_HOME="$h" FM_SPAWN_NO_GUARD=1 \
    bash "$FAKE_ROOT/bin/fm-spawn.sh" "$id" "$h/projects/alpha" --scout --harness pi 2>&1
}

h=$(choose_home refused-here)
out=$(choose_run "$h" refused-here 2.8 26 0 1) || true
printf '%s\n' "$out" | grep -F 'machine: this machine picked' >/dev/null || fail "a host that refused on load took a launch while this machine had room: $out"
[ ! -e "$h/launch-args" ] || fail "a launch was sent to a host that refused on load: $out"
pass "a launch is not sent to a host that refused on load while this machine has room"

h=$(choose_home more-room-there)
out=$(choose_run "$h" more-room-there 2.8 1.0 99) || fail "a launch to the host with more room failed: $out"
printf '%s\n' "$out" | grep -F 'machine: testhost picked' >/dev/null || fail "the host with more room was not picked: $out"
assert_grep 'remote_host=testhost' "$h/state/more-room-there.meta" "the launch with more room did not land on that host"
pass "a launch with more room on the host route is not kept on this machine"

h=$(choose_home more-room-here)
out=$(choose_run "$h" more-room-here 2.8 1.0 0) || true
printf '%s\n' "$out" | grep -F 'machine: this machine picked' >/dev/null || fail "a launch went to a host with no free heavy slot: $out"
[ ! -e "$h/launch-args" ] || fail "a launch was sent to a host with no free heavy slot: $out"
pass "a launch is not sent to a host with no free heavy slot while this machine has room"

h=$(choose_home refused-by-load-here)
out=$(choose_run "$h" refused-by-load-here 20 1.0 6) || fail "the host with room did not take a launch this machine refused on load: $out"
printf '%s\n' "$out" | grep -F 'machine: testhost picked' >/dev/null || fail "the host with room was not picked: $out"
assert_grep 'remote_host=testhost' "$h/state/refused-by-load-here.meta" "the launch refused here did not land on the host with room"
pass "a launch this machine refuses on load moves to the host that has room instead of deferring"

h=$(choose_home no-room-anywhere)
out=$(choose_run "$h" no-room-anywhere 20 26 0 1) || true
printf '%s\n' "$out" | grep -F 'machine: this machine picked - neither machine has room' >/dev/null || fail "a launch with no room on either machine did not say so: $out"
[ ! -e "$h/launch-args" ] && [ ! -e "$h/state/no-room-anywhere.meta" ] || fail "a launch with no room anywhere reached the host that refused: $out"
pass "a launch with no room on either machine is not sent to the host that refused"

h=$(choose_home launch-deferred)
rc=0
out=$(choose_run "$h" launch-deferred 2.8 1.0 99 0 1) || rc=$?
printf '%s\n' "$out" | grep -F 'machine: testhost picked' >/dev/null || fail "the host with room was not chosen before its launch deferred: $out"
printf '%s\n' "$out" | grep -F 'launching here' >/dev/null || fail "a launch the host deferred did not fall back to this machine: $out"
[ "$rc" -ne 75 ] || fail "a launch the host deferred exited 75 without trying this machine: $out"
! grep -qs 'remote_host=testhost' "$h/state/launch-deferred.meta" || fail "a launch the host deferred was recorded as launched there: $out"
pass "a launch the host defers after the room check is handed back to this machine instead of exiting 75"
