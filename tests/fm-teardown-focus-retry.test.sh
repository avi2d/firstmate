#!/usr/bin/env bash
# Deferred Herdr pane closes: teardown finishes when only a focus-held pane
# close remains, and the watcher retries it on its heartbeat until focus moves.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
CLEANUP="$ROOT/bin/fm-herdr-session-cleanup.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-focus-retry)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST

TOKEN=AbCdEfGhIjKlMnOpQrStUv
TOKEN2=ZyXwVuTsRqPoNmLkJiHgFe

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ]; then
    printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
  elif [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
exit 1
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=default:wG:pQ" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1" \
    "backend=herdr" \
    "herdr_session=default" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:tQ" \
    "herdr_pane_id=wG:pQ"
}

write_journal_v2() { # <case-dir> <id> <token> <home> <workspace> <tab> <pane>
  local case_dir=$1 id=$2 token=$3 home=$4 workspace=$5 tab=$6 pane=$7
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=default\n'
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'parent_workspace_id=wH\n'
    printf 'parent_label=firstmate\n'
    printf 'workspace_label=└ %s · p:%s\n' "$id" "$token"
    printf 'task_label=fm-%s\n' "$id"
  } > "$case_dir/state/$id.herdr-presentation"
}

install_fake_herdr() {
  local case_dir=$1
  printf '%s\n' "$TOKEN" > "$case_dir/herdr-token"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
D="$case_dir"
printf '%s\n' "\$*" >> "\$D/herdr.log"
focus=\$(cat "\$D/focus-tab" 2>/dev/null || printf 'wH:t1')
fg=\$(cat "\$D/foreground" 2>/dev/null || printf 'present')
TOKEN=\$(cat "\$D/herdr-token")
TITLE="└ task-x1 · p:\$TOKEN"
ws_focused() { case "\$focus" in "\$1:"*) printf true ;; *) printf false ;; esac; }
tab_focused() { [ "\$1" = "\$focus" ] && printf true || printf false; }
pane_dead() { [ -e "\$D/closed-\$1" ]; }
pane_tab() { case "\$1" in wH:*) printf 'wH:t1' ;; *) printf 'wG:tQ' ;; esac; }
pane_ws() { case "\$1" in wH:*) printf 'wH' ;; *) printf 'wG' ;; esac; }
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wG","label":"%s","focused":%s,"active_tab_id":"wG:tQ","tab_count":1,"pane_count":1},{"workspace_id":"wH","label":"firstmate","focused":%s,"active_tab_id":"wH:t1","tab_count":1,"pane_count":1}]}}\n' "\$TITLE" "\$(ws_focused wG)" "\$(ws_focused wH)"
    ;;
  "workspace get")
    printf '{"result":{"workspace":{"workspace_id":"wG","label":"%s","focused":%s,"active_tab_id":"wG:tQ","tab_count":1,"pane_count":1}}}\n' "\$TITLE" "\$(ws_focused wG)"
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wG"*) printf '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG","focused":%s}]}}\n' "\$(tab_focused wG:tQ)" ;;
      *"--workspace wH"*) printf '{"result":{"tabs":[{"tab_id":"wH:t1","workspace_id":"wH","focused":%s}]}}\n' "\$(tab_focused wH:t1)" ;;
      *) printf '{"result":{"tabs":[]}}\n' ;;
    esac
    ;;
  "tab get")
    printf '{"result":{"tab":{"workspace_id":"%s","tab_id":"%s"}}}\n' "\$(pane_ws "\${3:-}")" "\${3:-}"
    ;;
  "tab focus")
    printf '%s\n' "\${3:-}" > "\$D/focus-tab"
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}]}}\n'
    ;;
  "pane get")
    if pane_dead "\${3:-}"; then printf '{"error":{"code":"pane_not_found"}}\n' >&2; exit 1; fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' "\${3:-}" "\$(pane_tab "\${3:-}")" "\$(pane_ws "\${3:-}")"
    ;;
  "pane close")
    if [ -e "\$D/fail-close" ]; then exit 1; fi
    : > "\$D/closed-\${3:-}"
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found"}}\n' >&2
    exit 1
    ;;
  "pane process-info")
    id=""; prev=""
    for a in "\$@"; do [ "\$prev" = --pane ] && id="\$a"; prev="\$a"; done
    if [ -e "\$D/no-process-info" ]; then exit 1; fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"pid":67,"name":"sh","argv0":"sh"}]}}}\n' "\$id"
    ;;
  "terminal title")
    case "\$fg" in
      present) printf '{"result":{"reason":"cleared"}}\n' ;;
      absent) printf '{"result":{"reason":"no_foreground_client"}}\n' ;;
      *) printf '{"result":{"reason":"defocused_pointer"}}\n' ;;
    esac
    ;;
  "api snapshot")
    fws=wH; fpane=wH:p1
    case "\$focus" in wG:*) fws=wG; fpane=wG:pQ ;; esac
    printf '{"result":{"snapshot":{"focused_workspace_id":"%s","focused_tab_id":"%s","focused_pane_id":"%s","workspaces":[{"workspace_id":"wG","label":"%s","tab_count":1,"pane_count":1},{"workspace_id":"wH","label":"firstmate","tab_count":1,"pane_count":1}],"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"},{"tab_id":"wH:t1","workspace_id":"wH"}],"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"},{"pane_id":"wH:p1","tab_id":"wH:t1","workspace_id":"wH"}]}}}\n' "\$fws" "\$focus" "\$fpane" "\$TITLE"
    ;;
  "status --json")
    printf '{"server":{"running":true}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$case_dir"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

install_fake_ps() {
  local case_dir=$1
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n67 1\n' ;;
  "-p 67 -o stat=") printf 'Ss\n' ;;
  "-p 67 -o comm=") printf 'sh\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/ps"
}

seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_HERDR_DIR="$case_dir" \
  FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

run_heartbeat_cleanup() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_HERDR_DIR="$case_dir" \
  FM_HERDR_PS_BIN="$case_dir/fakebin/ps" \
  FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$CLEANUP" --heartbeat "$@"
}

land_worktree() {
  local case_dir=$1
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

test_teardown_defers_focus_held_pane_close() {
  local case_dir rc
  case_dir=$(make_case teardown-defer)
  write_meta "$case_dir" local-only ship
  land_worktree "$case_dir"
  install_fake_herdr "$case_dir"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  seed_backlog_in_flight "$case_dir" ship
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  : > "$case_dir/herdr.log"
  printf 'wG:tQ\n' > "$case_dir/focus-tab"
  printf 'present\n' > "$case_dir/foreground"
  : > "$case_dir/treehouse.log"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "focus-held teardown should finish cleanup, not fail: $(cat "$case_dir/stderr")"
  assert_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "focus-held teardown did not report completion"
  assert_grep "deferred" "$case_dir/stdout" \
    "focus-held teardown did not report a deferred pane close"
  if grep -q "pane close" "$case_dir/herdr.log"; then
    fail "focus-held teardown closed a pane the viewer is watching"
  fi
  assert_absent "$case_dir/state/task-x1.meta" \
    "focus-held teardown left the task record in flight"
  assert_absent "$case_dir/state/task-x1.status" \
    "focus-held teardown left the status record behind"
  [ -f "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "focus-held teardown dropped the durable pending pane-close record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "focus-held teardown left the backlog item in flight: $(backlog_row_state "$case_dir")"
  [ -s "$case_dir/treehouse.log" ] \
    || fail "focus-held teardown did not return the isolated copy"
  pass "teardown defers a focus-held pane close and finishes every other step"
}

test_teardown_refuses_non_focus_close_failure() {
  local case_dir rc
  case_dir=$(make_case teardown-no-defer)
  write_meta "$case_dir" local-only ship
  land_worktree "$case_dir"
  install_fake_herdr "$case_dir"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  seed_backlog_in_flight "$case_dir" ship
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  : > "$case_dir/herdr.log"
  printf 'wH:t1\n' > "$case_dir/focus-tab"
  printf 'present\n' > "$case_dir/foreground"
  : > "$case_dir/fail-close"
  : > "$case_dir/treehouse.log"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-focus close failure finished cleanup instead of refusing"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "a non-focus close failure erased the durable endpoint metadata"
  if grep -q "deferred" "$case_dir/stdout" "$case_dir/stderr"; then
    fail "a non-focus close failure was reported as a deferred close"
  fi
  pass "teardown still refuses a close failure that is not a focus refusal"
}

test_heartbeat_retry_closes_once_focus_moves() {
  local case_dir
  case_dir=$(make_case heartbeat-close)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  mkdir -p "$case_dir/home"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  : > "$case_dir/herdr.log"
  printf 'wH:t1\n' > "$case_dir/focus-tab"
  printf 'present\n' > "$case_dir/foreground"

  run_heartbeat_cleanup "$case_dir" > "$case_dir/hb-out" 2> "$case_dir/hb-err" \
    || fail "heartbeat retry failed: $(cat "$case_dir/hb-err")"
  grep -q "pane close" "$case_dir/herdr.log" \
    || fail "heartbeat retry never closed the unfocused pane"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "heartbeat retry left the pending pane-close record behind"
  pass "heartbeat retry closes the pane once focus moves and drops the record"
}

test_heartbeat_retry_focuses_home_tab_with_no_client() {
  local case_dir
  case_dir=$(make_case heartbeat-refocus)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  mkdir -p "$case_dir/home"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  fm_write_meta "$case_dir/state/task-x2.meta" \
    "window=default:wH:p1" \
    "endpoint_task_id=task-x2" \
    "worktree=$case_dir/wt-x2" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=teardown-test-task-x2" \
    "backend=herdr"
  write_journal_v2 "$case_dir" task-x2 "$TOKEN2" "$case_dir/home" wH wH:t1 wH:p1
  : > "$case_dir/herdr.log"
  printf 'wG:tQ\n' > "$case_dir/focus-tab"
  printf 'absent\n' > "$case_dir/foreground"

  run_heartbeat_cleanup "$case_dir" > "$case_dir/hb-out" 2> "$case_dir/hb-err" \
    || fail "heartbeat retry failed: $(cat "$case_dir/hb-err")"
  grep -q "tab focus wH:t1" "$case_dir/herdr.log" \
    || fail "no-client retry never focused the home tab: $(cat "$case_dir/herdr.log")"
  grep -q "pane close" "$case_dir/herdr.log" \
    || fail "no-client retry never closed the pane after refocusing"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "no-client retry left the pending pane-close record behind"
  [ -f "$case_dir/state/task-x2.herdr-presentation" ] \
    || fail "no-client retry dropped the live home tab journal"
  pass "no-client retry focuses the home tab first and then closes"
}

test_heartbeat_retry_never_moves_attached_focus() {
  local case_dir
  case_dir=$(make_case heartbeat-attached)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  mkdir -p "$case_dir/home"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  fm_write_meta "$case_dir/state/task-x2.meta" \
    "window=default:wH:p1" \
    "endpoint_task_id=task-x2" \
    "worktree=$case_dir/wt-x2" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=teardown-test-task-x2" \
    "backend=herdr"
  write_journal_v2 "$case_dir" task-x2 "$TOKEN2" "$case_dir/home" wH wH:t1 wH:p1
  : > "$case_dir/herdr.log"
  printf 'wG:tQ\n' > "$case_dir/focus-tab"
  printf 'present\n' > "$case_dir/foreground"

  run_heartbeat_cleanup "$case_dir" > "$case_dir/hb-out" 2> "$case_dir/hb-err" \
    || fail "heartbeat retry failed: $(cat "$case_dir/hb-err")"
  if grep -q "tab focus" "$case_dir/herdr.log"; then
    fail "attached-viewer retry moved focus: $(cat "$case_dir/herdr.log")"
  fi
  if grep -q "pane close" "$case_dir/herdr.log"; then
    fail "attached-viewer retry closed the focused pane"
  fi
  [ "$(cat "$case_dir/focus-tab")" = wG:tQ ] \
    || fail "attached-viewer retry changed the active tab"
  [ -f "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "attached-viewer retry dropped the pending pane-close record"
  pass "attached-viewer retry never moves focus and keeps the record"
}

test_heartbeat_retry_keeps_journal_on_unknown_probe() {
  local case_dir
  case_dir=$(make_case unknown-probe)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  : > "$case_dir/herdr.log"
  printf 'wG:tQ\n' > "$case_dir/focus-tab"
  printf 'defocused\n' > "$case_dir/foreground"
  run_heartbeat_cleanup "$case_dir" > "$case_dir/hb.out" 2> "$case_dir/hb.err" \
    || fail "unknown-probe retry failed: $(cat "$case_dir/hb.out" "$case_dir/hb.err")"
  ! grep -q "tab focus" "$case_dir/herdr.log" \
    || fail "unknown-probe retry moved focus without a proven absent viewer"
  ! grep -q "pane close" "$case_dir/herdr.log" \
    || fail "unknown-probe retry closed the pane without a proven absent viewer"
  [ "$(cat "$case_dir/focus-tab")" = wG:tQ ] \
    || fail "unknown-probe retry left focus at: $(cat "$case_dir/focus-tab")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "unknown-probe retry dropped the pending journal without closing the pane"
  pass "unknown-probe retry moves nothing and keeps the journal"
}

test_teardown_refuses_on_unknown_probe() {
  local case_dir out rc
  case_dir=$(make_case unknown-teardown)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  write_meta "$case_dir" local-only ship
  seed_backlog_in_flight "$case_dir"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  printf 'wG:tQ\n' > "$case_dir/focus-tab"
  printf 'defocused\n' > "$case_dir/foreground"
  out=$(run_teardown "$case_dir" 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "teardown deferred on an unverified probe instead of refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "teardown dropped the task record on an unverified probe"
  case "$out" in
    *"still holds the viewer's focus"*)
      fail "teardown claimed a proven viewer on an unverified probe" ;;
  esac
  case "$out" in
    *"not confirmed gone"*) ;;
    *) fail "teardown refused without naming the unconfirmed pane" ;;
  esac
  pass "teardown refuses on an unverified probe and keeps every record"
}

test_watcher_retries_pending_close_on_heartbeat() {
  local case_dir pid waited=0
  case_dir=$(make_case watcher-heartbeat)
  install_fake_herdr "$case_dir"
  install_fake_ps "$case_dir"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config"
  write_journal_v2 "$case_dir" task-x1 "$TOKEN" "$case_dir/home" wG wG:tQ wG:pQ
  : > "$case_dir/herdr.log"
  printf 'wH:t1\n' > "$case_dir/focus-tab"
  printf 'present\n' > "$case_dir/foreground"

  PATH="$case_dir/fakebin:$PATH" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_HERDR_DIR="$case_dir" \
  FM_HERDR_PS_BIN="$case_dir/fakebin/ps" \
  FM_BACKEND_HERDR_DEATH_CLOSE_POLLS=1 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$case_dir/watch.out" 2> "$case_dir/watch.err" &
  pid=$!
  while [ "$waited" -lt 200 ]; do
    { [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
      && grep -q "pane close" "$case_dir/herdr.log"; } && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q "pane close" "$case_dir/herdr.log" \
    || fail "live watcher never retried the pending close: $(cat "$case_dir/watch.err")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "live watcher left the pending pane-close record behind"
  pass "live watcher retries the pending pane close on its heartbeat"
}

test_teardown_defers_focus_held_pane_close
test_teardown_refuses_non_focus_close_failure
test_heartbeat_retry_closes_once_focus_moves
test_heartbeat_retry_focuses_home_tab_with_no_client
test_heartbeat_retry_never_moves_attached_focus
test_heartbeat_retry_keeps_journal_on_unknown_probe
test_teardown_refuses_on_unknown_probe
test_watcher_retries_pending_close_on_heartbeat

printf 'all fm-teardown-focus-retry tests passed\n'
