#!/usr/bin/env bash
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-local-e2e)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/code"
REMOTE_HOME="$TMP_ROOT/exec"
FAKE="$TMP_ROOT/fake"
JOB_STATE="$TMP_ROOT/jobs"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$FAKE"
SANDBOX=()
if [ "$(uname -s)" = Darwin ]; then
  [ -x /usr/bin/sandbox-exec ] || fail "macOS sandbox is required to isolate launch agents"
  ACCOUNT_HOME=$(env -u HOME bash -c 'cd ~ && pwd -P')
  AGENTS="$ACCOUNT_HOME/Library/LaunchAgents"
  PRIVATE_AGENTS="$TMP_ROOT/private-home/Library/LaunchAgents"
  mkdir -p "$PRIVATE_AGENTS"
  cp /usr/bin/true "$FAKE/launchctl"
  case "$AGENTS:$PRIVATE_AGENTS:$FAKE" in *'"'*|*\\*) fail "sandbox paths contain unsupported quoting" ;; esac
  printf '(version 1)(allow default)(deny file-write* (subpath "%s") (subpath "%s"))(deny process-exec (literal "/bin/launchctl") (literal "%s/launchctl"))\n' "$AGENTS" "$PRIVATE_AGENTS" "$FAKE" > "$TMP_ROOT/sandbox.sb"
  SANDBOX=(/usr/bin/sandbox-exec -f "$TMP_ROOT/sandbox.sb")
  touch "$PRIVATE_AGENTS/probe"
  rm "$PRIVATE_AGENTS/probe"
  if "${SANDBOX[@]}" /usr/bin/touch "$PRIVATE_AGENTS/probe" 2>/dev/null; then fail "sandbox permitted a launch-agent write"; fi
  if "${SANDBOX[@]}" "$FAKE/launchctl" 2>/dev/null; then fail "sandbox permitted launchctl execution"; fi
  if [ -d "$AGENTS" ]; then
    /usr/bin/find "$AGENTS" -maxdepth 1 -exec /usr/bin/stat -f '%N %i %z %m %c' {} \; | sort > "$TMP_ROOT/agents-before"
  else
    printf 'absent\n' > "$TMP_ROOT/agents-before"
  fi
fi
cleanup_remote_worker() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -d "$JOB_STATE/logs" ]; then
    for log in "$JOB_STATE"/logs/*.log; do [ ! -f "$log" ] || tail -n 30 "$log"; done
  fi
  if [ -f "$JOB_STATE/worker.pid" ]; then
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$(cat "$JOB_STATE/worker.pid")" || rc=1
  fi
  if pgrep -f "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" >/dev/null 2>&1; then
    printf 'not ok - local transport left a test worker running\n' >&2
    rc=1
  fi
  if [ "$(uname -s)" = Darwin ] && [ -f "$TMP_ROOT/agents-before" ]; then
    if [ -d "$AGENTS" ]; then
      /usr/bin/find "$AGENTS" -maxdepth 1 -exec /usr/bin/stat -f '%N %i %z %m %c' {} \; | sort > "$TMP_ROOT/agents-after"
    else
      printf 'absent\n' > "$TMP_ROOT/agents-after"
    fi
    if ! cmp -s "$TMP_ROOT/agents-before" "$TMP_ROOT/agents-after"; then
      printf 'not ok - account launch-agent directory changed during local transport\n' >&2
      rc=1
    fi
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_remote_worker EXIT
(cd "$ROOT" && tar --exclude=.git --exclude=data --exclude=state --exclude=config --exclude=.no-mistakes -cf - .) | (cd "$REMOTE_ROOT" && tar -xf -)
fm_test_spawn_home "$REMOTE_HOME" codex
printf 'exec-one\n' > "$REMOTE_HOME/.fm-exec-home"
printf 'manual\n' > "$REMOTE_HOME/config/backlog-backend"
printf 'fm-lab-test\n' > "$REMOTE_HOME/config/herdr-session"
fm_git_init_commit "$REMOTE_HOME/projects/alpha"
git clone -q "$REMOTE_HOME/projects/alpha" "$TMP_ROOT/slot"
printf '%s' "$TMP_ROOT/slot" > "$FAKE/slot"
printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/cwd"
printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/fg"
cat > "$REMOTE_ROOT/bin/treehouse" <<SH
#!/usr/bin/env bash
case "\$*" in
  'get --lease '*) cat '$FAKE/slot'; printf '\\n' ;;
esac
SH
cat > "$REMOTE_ROOT/bin/herdr" <<SH
#!/usr/bin/env bash
D='$FAKE'
SLOT=\$(cat '$FAKE/slot')
case "\${1:-} \${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\\n' ;;
  'session list') printf '{"sessions":[{"name":"fm-lab-test","running":true,"socket_path":"%s/herdr.sock"}]}\\n' "\$D" ;;
  'pane get')
    if [ -e "\$D/closed-\${3:-}" ]; then printf '{"error":{"code":"pane_not_found"}}\\n'; exit 1; fi
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\\n' "\${3:-}" "\$(cat "\$D/cwd")" "\$(cat "\$D/fg")" ;;
  'pane close') : > "\$D/closed-\${3:-}" ;;
  'pane run'|'pane send-text')
    payload=\${4:-}
    payload=\${payload# }
    case "\$payload" in
      ". '"*"'") staged=\${payload#". '"}; staged=\${staged%"'"}; [ ! -f "\$staged" ] || payload=\$(cat "\$staged") ;;
    esac
    case "\$payload" in
      'cd -- '*) printf '%s' "\$SLOT" > "\$D/cwd"; printf '%s' "\$SLOT" > "\$D/fg" ;;
      *'encode launch-brief'*|*'Firstmate operational input waiting: read'*) printf '%s\\n' "\$payload" > "\$D/launch"; : > "\$D/live"; printf '%s\\n' 'working: reading brief' > '$REMOTE_HOME/state/e2e-scout.status' ;;
    esac ;;
  'agent get')
    if [ -f "\$D/live" ]; then printf '{"result":{"agent":{"agent_status":"idle"}}}\\n'; else printf '{"result":{"agent":{"agent_status":"shell-starting"}}}\\n'; fi ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\\n' ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"},"root_pane":{"pane_id":"%%1"}}}\\n' ;;
  'tab list') printf '{"result":{"tabs":[]}}\\n' ;;
  'tab create') rm -f "\$D/closed-%9"; printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\\n' ;;
  'pane read') printf 'reading remote brief\\n' ;;
esac
SH
cat > "$REMOTE_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cp "$REMOTE_ROOT/bin/codex" "$REMOTE_ROOT/bin/claude"
chmod +x "$REMOTE_ROOT/bin/treehouse" "$REMOTE_ROOT/bin/herdr" "$REMOTE_ROOT/bin/codex" "$REMOTE_ROOT/bin/claude"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'test fixture'
cat > "$FAKE/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "\$1" = testhost ] || exit 91
[ "\$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
if [ -d '$FAKE/race' ] && printf '%s' "\$4" | base64 -d 2>/dev/null | tr '\\0' '\\n' | grep -qx launch; then
  cp '$FAKE'/race/*.meta '$REMOTE_HOME/state/'
fi
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT='$JOB_STATE' FM_MAC_LOAD_MOCK_5MIN=0
exec '$REMOTE_ROOT/bin/fm-remote-entrypoint.sh' "\$@"
SH
chmod +x "$FAKE/ssh"
printf '%s\n' '- alpha [direct-PR host=exec-one] - project' > "$PARENT/data/projects.md"
printf '%s\n' "- exec-one - execution (host: testhost; root: $REMOTE_ROOT; home: $REMOTE_HOME; session: fm-lab-test; scope: workers; projects: alpha; added 2026-01-01)" > "$PARENT/data/remote-homes.md"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" add e2e-scout 'Research alpha' --kind scout >/dev/null
mkdir -p "$PARENT/data/e2e-scout"
printf "# Task\n## Captain's intent\nResearch the project.\n\n## Firstmate spec\nReport evidence.\n" > "$PARENT/data/e2e-scout/brief.md"
out=$(FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-spawn.sh" e2e-scout "$PARENT/projects/alpha" --scout --harness codex 2>&1) || fail "remote local-transport launch failed: $out"
assert_grep 'remote_route=exec-one' "$PARENT/state/e2e-scout.meta" "main route missing"
assert_grep 'Research the project.' "$REMOTE_HOME/data/e2e-scout/brief.md" "remote intent missing"
[ -f "$FAKE/launch" ] || fail "remote spawn did not deliver its brief"
assert_grep 'working: reading brief' "$REMOTE_HOME/state/e2e-scout.status" "remote worker did not publish its first status"
capture=$(FM_HOME="$PARENT" FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-on.sh" exec-one fm-remote-worker-control.sh capture e2e-scout)
printf '%s\n' "$capture" | grep -F 'reading remote brief' >/dev/null || fail "capture did not reach the remote endpoint"
[ ! -e "$PARENT/state/e2e-scout.status" ] || fail "remote status reached main before the feed exists"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state in_flight | grep -F e2e-scout >/dev/null || fail "backlog did not move"
if [ "$(uname -s)" = Darwin ]; then
  if [ -d "$AGENTS" ]; then
    /usr/bin/find "$AGENTS" -maxdepth 1 -exec /usr/bin/stat -f '%N %i %z %m %c' {} \; | sort > "$TMP_ROOT/agents-after"
  else
    printf 'absent\n' > "$TMP_ROOT/agents-after"
  fi
  cmp -s "$TMP_ROOT/agents-before" "$TMP_ROOT/agents-after" || fail "account launch-agent directory changed during local transport"
fi
pass "local transport launches through the remote job worker and host-local spawn"

remote_parent() {  # <script> [args...]
  local script=$1
  shift
  FM_HOME="$PARENT" FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/$script" "$@"
}
open_keys() {  # <status-file>
  bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" | cut -f1' _ "$ROOT" "$1"
}
printf '# Findings\n\nEvidence.\n\n## References\n- alpha\n' > "$REMOTE_HOME/data/e2e-scout/report.md"
cp "$REMOTE_HOME/data/e2e-scout/report.md" "$PARENT/data/e2e-scout/report.md"
decision='needs-decision [key=fixes-to-build] [at=1700000000]: which fixes to build'
printf '%s\n' "$decision" >> "$REMOTE_HOME/state/e2e-scout.status"
printf '%s\n' "$decision" > "$PARENT/state/e2e-scout.status"
out=$(remote_parent fm-teardown.sh e2e-scout 2>&1) && fail "a remote scout with an unanswered captain call was cleaned up: $out"
printf '%s\n' "$out" | grep -F 'has not passed the captain-call completion gate' >/dev/null || fail "the refusal did not name the completion gate: $out"
[ -f "$REMOTE_HOME/state/e2e-scout.meta" ] || fail "the supervising home's refusal still cleaned up the host"
[ -f "$PARENT/state/e2e-scout.meta" ] || fail "the refusal removed the parent task record"
pass "remote_scout_with_an_unanswered_call_is_refused_by_the_supervising_home_before_the_host_is_touched"

out=$(remote_parent fm-send.sh e2e-scout --resolve-key fixes-to-build 'build the first fix' 2>&1) || fail "answering the remote scout's decision failed: $out"
printf '%s\n' "$out" | grep -F 'did not reach the status stream' >/dev/null && fail "the close did not reach the host: $out"
[ -z "$(open_keys "$PARENT/state/e2e-scout.status")" ] || fail "the answered key stayed open in the parent: $(cat "$PARENT/state/e2e-scout.status")"
[ -z "$(open_keys "$REMOTE_HOME/state/e2e-scout.status")" ] || fail "the answered key stayed open on the host: $(cat "$REMOTE_HOME/state/e2e-scout.status")"
close_line=$(grep -F 'resolved [key=fixes-to-build]' "$PARENT/state/e2e-scout.status")
grep -Fx -- "$close_line" "$REMOTE_HOME/state/e2e-scout.status" >/dev/null || fail "the host close differs from the parent's, so the feed would mirror it twice: $(cat "$REMOTE_HOME/state/e2e-scout.status")"
pass "an_answer_given_with_resolve_key_closes_the_key_on_the_host_instead_of_only_in_the_parent_mirror"

out=$(remote_parent fm-captain-hold.sh complete e2e-scout --none 2>&1) || fail "the supervising home could not attest the inventory: $out"
out=$(remote_parent fm-teardown.sh e2e-scout 2>&1) || fail "a remote scout whose inventory the supervising home verified was refused: $out"
[ ! -e "$REMOTE_HOME/state/e2e-scout.meta" ] || fail "the host kept the scout's task record"
[ ! -e "$PARENT/state/e2e-scout.meta" ] || fail "the parent kept the scout's task record"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state 'done' | grep -F e2e-scout >/dev/null || fail "the scout's backlog item did not move to Done"
pass "remote_scout_verified_in_the_supervising_home_cleans_up_instead_of_being_refused_by_the_empty_host_backlog"

ACCOUNT_DIR="$TMP_ROOT/claude-accounts/main"
mkdir -p "$ACCOUNT_DIR"
printf 'main %s\n' "$ACCOUNT_DIR" > "$REMOTE_HOME/config/claude-accounts"
remote_account_spawn() {  # <task-id> <account>
  FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" add "$1" 'Research alpha' --kind scout >/dev/null
  mkdir -p "$PARENT/data/$1"
  printf "# Task\n## Captain's intent\nResearch the project.\n\n## Firstmate spec\nReport evidence.\n" > "$PARENT/data/$1/brief.md"
  git -C "$REMOTE_HOME/projects/alpha" worktree add -q --detach "$TMP_ROOT/slot-$1"
  printf '%s' "$TMP_ROOT/slot-$1" > "$FAKE/slot"
  printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/cwd"
  printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/fg"
  rm -f "$FAKE/launch" "$FAKE/live"
  FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-spawn.sh" "$1" "$PARENT/projects/alpha" --scout --harness claude --claude-account "$2" 2>&1
}
out=$(remote_account_spawn e2e-account main) || fail "remote launch on a mapped Claude account failed: $out"
printf '%s\n' "$out" | grep -F 'claude_account=main' >/dev/null || fail "spawned line did not print the account: $out"
grep -qx 'claude_account=main' "$PARENT/state/e2e-account.meta" || fail "main task record did not record the account: $(cat "$PARENT/state/e2e-account.meta")"
grep -qx 'claude_account=main' "$REMOTE_HOME/state/e2e-account.meta" || fail "host task record did not record the account: $(cat "$REMOTE_HOME/state/e2e-account.meta")"
assert_grep "CLAUDE_CONFIG_DIR='$ACCOUNT_DIR'" "$FAKE/launch" "the host's own account folder did not reach the launch command"
pass "remote launch applies --claude-account through the host's own account map instead of the host's ambient login"
out=$(remote_account_spawn e2e-unmapped second) && fail "remote launch accepted an account the host does not map: $out"
printf '%s\n' "$out" | grep -F -- '--claude-account second needs a login declared for it in config/claude-accounts' >/dev/null || fail "refusal did not name the missing account: $out"
[ ! -e "$PARENT/state/e2e-unmapped.meta" ] || fail "an unmapped account published a main task record"
[ ! -e "$REMOTE_HOME/state/e2e-unmapped.meta" ] && [ ! -e "$REMOTE_HOME/data/e2e-unmapped" ] || fail "an unmapped account reached the host's records"
[ ! -e "$FAKE/launch" ] || fail "an unmapped account launched a worker"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state queued | grep -F e2e-unmapped >/dev/null || fail "an unmapped account moved its item out of Queued"
pass "remote launch on an account the host does not map refuses naming it instead of launching on another login"

remote_scout_spawn() {  # <task-id>
  if ! FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" show "$1" >/dev/null 2>&1; then
    FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" add "$1" 'Research alpha' --kind scout >/dev/null
    mkdir -p "$PARENT/data/$1"
    printf "# Task\n## Captain's intent\nResearch the project.\n\n## Firstmate spec\nReport evidence.\n" > "$PARENT/data/$1/brief.md"
  fi
  [ -d "$TMP_ROOT/slot-$1" ] || git -C "$REMOTE_HOME/projects/alpha" worktree add -q --detach "$TMP_ROOT/slot-$1"
  printf '%s' "$TMP_ROOT/slot-$1" > "$FAKE/slot"
  printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/cwd"
  printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/fg"
  rm -f "$FAKE/launch" "$FAKE/live"
  FM_HOME="$PARENT" FM_SPAWN_NO_GUARD=1 FM_SSH_BIN="$FAKE/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOB_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-spawn.sh" "$1" "$PARENT/projects/alpha" --scout --harness codex 2>&1
}
assert_deferred_untouched() {  # <task-id> <rc> <output> <deferring-step-line-prefix>
  [ "$2" -eq 75 ] || fail "a host at its heavy limit answered exit $2 instead of 75: $3"
  printf '%s\n' "$3" | grep -E "^$4 " | grep -F 'heavy worker(s)' >/dev/null || fail "the host's $4 line was not passed through: $3"
  printf '%s\n' "$3" | grep -F 'unconfirmed' >/dev/null && fail "a known deferral was reported as an unconfirmed outcome: $3"
  [ ! -e "$PARENT/state/$1.meta" ] || fail "a deferral left a main task record: $(cat "$PARENT/state/$1.meta")"
  FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state queued | grep -F "$1" >/dev/null || fail "a deferral moved the backlog item out of Queued"
  [ ! -e "$REMOTE_HOME/data/$1" ] || fail "a deferral left the task's data on the host: $(ls -A "$REMOTE_HOME/data/$1")"
  [ ! -e "$REMOTE_HOME/state/$1.meta" ] || fail "a deferral left a host task record"
  [ ! -e "$FAKE/launch" ] || fail "a deferral launched a worker"
}

printf '@heavy-limit 1\n' > "$REMOTE_HOME/config/project-capacity"
rc=0
out=$(remote_scout_spawn e2e-heavy-full) || rc=$?
assert_deferred_untouched e2e-heavy-full "$rc" "$out" defer:
rm "$REMOTE_HOME/config/project-capacity"
out=$(remote_scout_spawn e2e-heavy-full) || fail "dispatching a deferred task again once the host had room failed: $out"
assert_grep 'remote_target=fm-lab-test:' "$PARENT/state/e2e-heavy-full.meta" "the redispatch did not record the host's endpoint"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state in_flight | grep -F e2e-heavy-full >/dev/null || fail "the redispatch did not move the backlog item"
pass "remote_launch_at_host_heavy_limit_exits_75_and_leaves_nothing_instead_of_an_unconfirmed_pending_record"

printf '@heavy-limit 50\n' > "$REMOTE_HOME/config/project-capacity"
mkdir -p "$FAKE/race"
for n in $(seq 1 50); do
  printf 'kind=scout\nharness=codex\nproject=%s/projects/alpha\n' "$REMOTE_HOME" > "$FAKE/race/race-$n.meta"
done
rc=0
out=$(remote_scout_spawn e2e-heavy-race) || rc=$?
assert_deferred_untouched e2e-heavy-race "$rc" "$out" deferred:
rm -rf "$FAKE/race" "$REMOTE_HOME"/state/race-*.meta "$REMOTE_HOME/config/project-capacity"
out=$(remote_scout_spawn e2e-heavy-race) || fail "dispatching a launch-deferred task again once the host had room failed: $out"
FM_HOME="$PARENT" "$ROOT/bin/fm-tasks-axi.sh" list --state in_flight | grep -F e2e-heavy-race >/dev/null || fail "the redispatch after a launch deferral did not move the backlog item"
pass "host_filling_between_admit_and_launch_exits_75_and_leaves_nothing_instead_of_a_half_made_task"
