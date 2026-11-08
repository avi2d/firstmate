#!/usr/bin/env bash
set -eu
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
  case "$AGENTS:$PRIVATE_AGENTS:$FAKE" in *'"'*|*'\\'*) fail "sandbox paths contain unsupported quoting" ;; esac
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
printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/cwd"
printf '%s' "$REMOTE_HOME/projects/alpha" > "$FAKE/fg"
cat > "$REMOTE_ROOT/bin/treehouse" <<SH
#!/usr/bin/env bash
case "\$*" in
  'get --lease '*) printf '%s\\n' '$TMP_ROOT/slot' ;;
esac
SH
cat > "$REMOTE_ROOT/bin/herdr" <<SH
#!/usr/bin/env bash
D='$FAKE'
SLOT='$TMP_ROOT/slot'
case "\${1:-} \${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\\n' ;;
  'session list') printf '{"sessions":[{"name":"fm-lab-test","running":true,"socket_path":"%s/herdr.sock"}]}\\n' "\$D" ;;
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\\n' "\${3:-}" "\$(cat "\$D/cwd")" "\$(cat "\$D/fg")" ;;
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
  'tab create') printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\\n' ;;
  'pane read') printf 'reading remote brief\\n' ;;
esac
SH
cat > "$REMOTE_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/treehouse" "$REMOTE_ROOT/bin/herdr" "$REMOTE_ROOT/bin/codex"
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
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT='$JOB_STATE'
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
