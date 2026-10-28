#!/usr/bin/env bash
# Behavior tests for the cloud-claude worker (bin/fm-cloud-claude-lib.sh, bin/fm-cloud-claude-relay.sh).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-cloud-claude)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

make_cloud_fakes() {  # <fakebin> <case-dir>
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
printf 'CLAUDE_CONFIG_DIR=%s ARGS=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" >> '$dir/claude-calls'
SH
  chmod +x "$fakebin/claude"
  fm_fake_exit0 "$fakebin" gh script clauth
}

new_case() {  # <name> -> sets CASE HOME_DIR PROJ FAKEBIN
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_cloud_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$PROJ" "$CASE/wt-seed" "wt-seed-$1"
  # The insteadOf rewrite keeps git traffic on the local bare origin while the
  # configured url, which the cloud session clones, names GitHub.
  git -C "$PROJ" config "url.$(git -C "$PROJ" config --get remote.origin.url).insteadOf" https://github.com/acme/widget.git
  git -C "$PROJ" remote set-url origin https://github.com/acme/widget.git
  mkdir -p "$CASE/second"
  printf '{}\n' > "$CASE/second/.credentials.json"
  printf '%s\n' 'main ordinary' "second $CASE/second" > "$HOME_DIR/config/claude-accounts"
  printf '%s\n' second > "$HOME_DIR/config/cloud-claude-account"
}

spawn_cloud() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  WT="$CASE/wt-$id"
  git -C "$PROJ" worktree add --quiet -b "wt-$id" "$WT" >/dev/null 2>&1 || fail "could not create a copy for $id"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" cloud-claude "$@"
}

assert_refused() {  # <id> <rc> <out> <needle>
  expect_code 1 "$2" "the spawn should refuse: $3"
  assert_contains "$3" "$4" "the refusal should say: $4"
  assert_absent "$HOME_DIR/state/$1.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch: $(cat "$CASE/launch.log")"
}

test_direct_pr_ship_launches_the_relay_on_the_cloud_account() {
  local out rc id=cloud-ok launch
  new_case ok
  out=$(spawn_cloud "$id" --mode direct-PR --yolo off); rc=$?
  expect_code 0 "$rc" "a direct-PR ship on a GitHub project should spawn: $out"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "bin/fm-cloud-claude-relay.sh" "the pane should run the relay"
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE/second'" "the relay should run on the credit-backed account"
  assert_contains "$launch" "--repo 'acme/widget'" "the relay should target the origin repository"
  assert_contains "$launch" "--branch 'fm/$id' --base 'main'" "the relay should name the task branch and its base"
  assert_contains "$launch" "--deadline 90 --gen '$(cat "$HOME_DIR/state/$id.busy-gen")'" "the relay should write the armed busy incarnation; the default deadline is 90 minutes"
  assert_grep "state=busy source=fm-spawn" "$HOME_DIR/state/$id.busy-state" "the launch should seed a busy turn"
  assert_grep "harness=cloud-claude" "$HOME_DIR/state/$id.meta" "the record should name the cloud harness"
  assert_grep "claude_account=second" "$HOME_DIR/state/$id.meta" "the record should name the account"
  assert_grep "$CASE/wt-$id" "$CASE/second/.claude.json" "workspace trust should be registered on the cloud account, whose claude --cloud would otherwise stop at the trust dialog"
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1); rc=$?
  expect_code 1 "$rc" "interrupting a cloud task should refuse: $out"
  assert_contains "$out" "runs in a Claude Code cloud session" "the refusal should name the cloud session"
  pass "a direct-PR ship launches the relay on the configured account"
}

test_cloud_spawn_is_not_deferred_by_local_load_or_heavy_cap() {
  local out rc id=cloud-busy i=0 launch high
  case "$(uname -s)" in
    Linux) high=16.0 ;;
    *) high=10.0 ;;
  esac
  new_case busy
  while [ "$i" -lt 6 ]; do
    i=$((i + 1))
    fm_write_meta "$HOME_DIR/state/local-$i.meta" "window=firstmate:fm-local-$i" "project=$PROJ" "harness=codex" "kind=ship"
  done
  out=$(export FM_MAC_LOAD_MOCK_5MIN=$high FM_CORE_BUDGET_MOCK_USAGE=99; spawn_cloud "$id" --mode direct-PR --yolo off); rc=$?
  expect_code 0 "$rc" "a cloud spawn was deferred by local load, the heavy cap, or the core budget: $out"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "bin/fm-cloud-claude-relay.sh" "the cloud spawn launched no relay"
  assert_grep "harness=cloud-claude" "$HOME_DIR/state/$id.meta" "the record should name the cloud harness"
  pass "a cloud spawn starts under high local load with the heavy cap full"
}

test_cloud_spawn_still_waits_for_its_project_capacity() {
  local out rc id=cloud-capped
  new_case capped
  printf '%s\n' "project 1" > "$HOME_DIR/config/project-capacity"
  fm_write_meta "$HOME_DIR/state/local-1.meta" "window=firstmate:fm-local-1" "project=$PROJ" "harness=codex" "kind=ship"
  out=$(spawn_cloud "$id" --mode direct-PR --yolo off); rc=$?
  expect_code 75 "$rc" "a cloud spawn ignored its project's declared capacity: $out"
  assert_contains "$out" "admits 1 worker" "the deferral did not name the project capacity"
  assert_absent "$HOME_DIR/state/$id.meta" "a deferred cloud spawn published a record"
  pass "a cloud spawn still waits for its project's declared capacity"
}

test_refusals_before_launch() {
  local out rc
  new_case refuse
  out=$(spawn_cloud cloud-nm --mode no-mistakes --yolo off); rc=$?
  assert_refused cloud-nm "$rc" "$out" "needs --mode direct-PR"
  out=$(spawn_cloud cloud-model --mode direct-PR --yolo off --model opus); rc=$?
  assert_refused cloud-model "$rc" "$out" "omit --model and --effort"
  rm "$HOME_DIR/config/cloud-claude-account"
  out=$(spawn_cloud cloud-noacct --mode direct-PR --yolo off); rc=$?
  assert_refused cloud-noacct "$rc" "$out" "needs the credit-backed Claude account"
  printf '%s\n' second > "$HOME_DIR/config/cloud-claude-account"
  git -C "$PROJ" remote set-url origin https://gitlab.com/acme/widget.git
  out=$(spawn_cloud cloud-gitlab --mode direct-PR --yolo off); rc=$?
  assert_refused cloud-gitlab "$rc" "$out" "needs a project whose origin is on github.com"
  pass "non-qualifying cloud launches refuse before any record or launch"
}

test_github_repo_forms() {
  # shellcheck source=bin/fm-cloud-claude-lib.sh
  . "$ROOT/bin/fm-cloud-claude-lib.sh"
  local url
  for url in https://github.com/acme/widget.git git@github.com:acme/widget.git ssh://git@github.com/acme/widget https://github.com/acme/widget/; do
    assert_equals acme/widget "$(fm_cloud_github_repo "$url")" "$url should name acme/widget"
  done
  for url in https://gitlab.com/acme/widget.git https://github.com/acme git@example.com:acme/widget.git ''; do
    fm_cloud_github_repo "$url" >/dev/null && fail "$url must not resolve to a GitHub repository"
  done
  pass "only github.com origins resolve to a cloud repository"
}

make_relay_fakes() {  # <fakebin> <case-dir>
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -p ]; then
  printf '%s\n' "\$4" >> '$dir/forwarded'
  printf 'Sent to cloud session.\n'
  exit 0
fi
printf '%s\n' "\$@" > '$dir/create-args'
printf 'Created cloud session: test\nResume with: claude --teleport session_01TESTRELAY\n'
SH
  cat > "$fakebin/script" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -qec ]; then
  bash -c "$2" | tee "$3"
else
  log=$2
  shift 2
  "$@" | tee "$log"
fi
SH
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/gh-calls'
[ ! -f '$dir/pr-row' ] || cat '$dir/pr-row'
SH
  chmod +x "$fakebin/claude" "$fakebin/script" "$fakebin/gh"
}

busy_verdict() {  # <state-dir> <id>
  bash -c '. "$1/bin/fm-busy-lib.sh" && fm_busy_classify tmux fm-x cloud-claude "$3" "$2"' _ "$ROOT" "$1" "$2"
}

wait_for() {  # <file> <needle> <what>
  local i
  for i in $(seq 1 100); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  fail "timed out waiting for $3; $1 holds: $(cat "$1" 2>/dev/null)"
}

# cloud_push <case-dir> <bare-origin> <branch> <file>: what the cloud session does.
cloud_push() {
  local clone=$1/cloud-clone
  [ -d "$clone" ] || git clone --quiet --branch "$3" "$2" "$clone"
  git -C "$clone" pull --quiet --ff-only origin "$3"
  printf '%s\n' "$4" > "$clone/$4"
  git -C "$clone" add "$4"
  git -C "$clone" -c user.name=cloud -c user.email=cloud@example.invalid commit -qm "$4"
  git -C "$clone" push --quiet origin "HEAD:$3"
  git -C "$clone" rev-parse HEAD
}

start_relay() {  # <dir> <id> <deadline-minutes> <pane-input>; sets STATE WT BARE STATUS RELAY_PID STARTED
  local dir=$1 id=$2 gen fakebin
  STATE=$dir/state
  WT=$dir/wt
  BARE=$dir/project.origin.git
  STATUS=$STATE/$id.status
  mkdir -p "$STATE" "$dir/data/$id"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id") || fail "could not arm the busy record"
  fakebin=$(fm_fakebin "$dir/fake")
  make_relay_fakes "$fakebin" "$dir"
  fm_git_worktree "$dir/project" "$WT" "fm/$id"
  fm_test_spawn_brief "$dir" "$id" "Change the README"
  STARTED=$(date +%s)
  FM_TASK_INBOX=$STATE/$id.inbox PATH="$fakebin:$PATH" "$ROOT/bin/fm-cloud-claude-relay.sh" \
    --task "$id" --worktree "$WT" --brief "$dir/data/$id/brief.md" --status "$STATUS" \
    --repo acme/widget --branch "fm/$id" --base main --deadline "$3" --gen "$gen" --poll 1 <"$4" >"$dir/pane.log" 2>&1 &
  RELAY_PID=$!
}

stop_relay() {
  kill "$RELAY_PID" 2>/dev/null
  wait "$RELAY_PID" 2>/dev/null
}

test_relay_flags_the_deadline_and_reports_the_pull_request() {
  local dir="$TMP_ROOT/relay" sha url=https://github.com/acme/widget/pull/7 out until_epoch seen latest
  start_relay "$dir" rt 0 /dev/null

  wait_for "$STATE/rt.cloud-session" session_01TESTRELAY "the session id record"
  wait_for "$STATUS" "paused [at=" "the declared cloud wait"
  seen=$(date +%s)
  # The brief's wait contract: until is the wait's start plus the timeout, rounded up to
  # the minute, and that start falls between the launch and the wait being seen.
  latest=$(( (seen + 59) / 60 * 60 ))
  until_epoch=$(bash -c '. "$1/bin/fm-classify-lib.sh" && status_paused_until "$(grep "^paused" "$2" | head -n 1)"' _ "$ROOT" "$STATUS") ||
    fail "the declared wait should carry a readable until time: $(cat "$STATUS")"
  [ "$until_epoch" -ge "$STARTED" ] && [ "$until_epoch" -le "$latest" ] && [ $((until_epoch % 60)) -eq 0 ] ||
    fail "a zero-minute deadline should declare the wait until a whole minute between $STARTED and $latest, got $until_epoch"
  git -C "$BARE" rev-parse --verify --quiet refs/heads/fm/rt >/dev/null || fail "the relay must push the task branch before the cloud session starts"
  assert_grep "Change the README" "$dir/create-args" "the cloud task should carry the captain's intent"
  assert_grep "fm/rt" "$dir/create-args" "the cloud session should run on the task branch"
  wait_for "$STATUS" "blocked [key=cloud-deadline]" "the deadline report"
  wait_for "$STATE/rt.busy-state" "event=deadline" "the deadline busy event"
  assert_equals "idle cloud-relay" "$(busy_verdict "$STATE" rt)" "a passed deadline should read idle so the blocker surfaces"
  rm -f "$STATE/rt.turn-ended"

  sha=$(cloud_push "$dir" "$BARE" fm/rt first.txt)
  printf '%s\topen\tfalse\t%s\n' "$url" "$sha" > "$dir/pr-row"
  wait_for "$STATUS" "]: PR $url" "the done report"
  assert_grep "resolved [key=cloud-deadline]" "$STATUS" "a pull request should resolve the deadline report"
  assert_equals "$sha" "$(git -C "$WT" rev-parse HEAD)" "the local copy should sit at the pull request head"
  assert_grep "head=acme:fm/rt" "$dir/gh-calls" "the poll should ask for the task branch's pull request"
  wait_for "$STATE/rt.busy-state" "event=pr-ready" "the pr-ready busy event"
  assert_present "$STATE/rt.turn-ended" "a ready pull request should notify the watcher"
  out=$(bash -c '. "$1/bin/fm-dod-lib.sh" && fm_dod_accept_ship_done ship direct-PR "$2" "$3" "$(grep "^done" "$4" | tail -n 1)"' \
    _ "$ROOT" "$WT" "$dir/project" "$STATUS") || fail "the ship-done check should accept the relay's report: $out"
  stop_relay
  pass "the relay flags a passed deadline and reports the pull request that resolves it"
}

# A deadline that cannot pass during the test keeps each busy event in place
# until the next pull request head, which is the only thing that moves it.
test_relay_forwards_steers_and_reports_the_follow_up() {
  local dir="$TMP_ROOT/relay-steer" sha url=https://github.com/acme/widget/pull/7
  mkdir -p "$dir"
  mkfifo "$dir/pane"
  exec 3<>"$dir/pane"
  start_relay "$dir" rs 90 "$dir/pane"

  wait_for "$STATUS" "paused [at=" "the declared cloud wait"
  sha=$(cloud_push "$dir" "$BARE" fm/rs first.txt)
  printf '%s\topen\tfalse\t%s\n' "$url" "$sha" > "$dir/pr-row"
  wait_for "$STATUS" "]: PR $url" "the done report"
  wait_for "$STATE/rs.busy-state" "event=pr-ready" "the pr-ready busy event"
  assert_equals "idle cloud-relay" "$(busy_verdict "$STATE" rs)" "a ready pull request should read idle"

  bash -c '. "$1/bin/fm-task-inbox-lib.sh" && rec=$(fm_task_inbox_write "$2" rs "please rename the heading") &&
    fm_task_inbox_doorbell_line "$rec" && echo' _ "$ROOT" "$STATE" >&3 || fail "could not enqueue and ring a steer"
  wait_for "$dir/forwarded" "please rename the heading" "the forwarded steer"
  wait_for "$STATE/rs.busy-state" "event=awaiting-pr" "the busy event after a steer"
  [ -z "$(ls "$STATE/rs.inbox"/*.msg 2>/dev/null)" ] || fail "a forwarded steer should move to handled/"
  grep -qF 'Firstmate instruction waiting' "$dir/forwarded" && fail "the doorbell line itself must not be forwarded"
  sleep 1.5
  assert_equals "busy cloud-relay" "$(busy_verdict "$STATE" rs)" "a forwarded steer should still read busy after further polls with no new push"
  assert_equals 2 "$(grep -c '^paused' "$STATUS")" "a forwarded steer should declare a fresh cloud wait"

  sha=$(cloud_push "$dir" "$BARE" fm/rs second.txt)
  printf '%s\topen\tfalse\t%s\n' "$url" "$sha" > "$dir/pr-row"
  for _ in $(seq 1 100); do
    [ "$(grep -c "]: PR $url" "$STATUS")" -ge 2 ] && break
    sleep 0.1
  done
  [ "$(grep -c "]: PR $url" "$STATUS")" -ge 2 ] || fail "the follow-up push should report done again: $(cat "$STATUS")"
  assert_equals "$sha" "$(git -C "$WT" rev-parse HEAD)" "the local copy should follow the follow-up push"
  assert_no_grep "cloud-deadline" "$STATUS" "a 90-minute deadline must not fire during the test"

  stop_relay
  exec 3>&-
  pass "the relay forwards steers, reads busy until the next push, and reports the follow-up"
}

test_relay_reports_a_draft_as_not_done() {
  local dir="$TMP_ROOT/relay-draft" state wt fakebin relay_pid gen
  state=$dir/state
  wt=$dir/wt
  mkdir -p "$state" "$dir/data/rd"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" rd) || fail "could not arm the busy record"
  fakebin=$(fm_fakebin "$dir/fake")
  make_relay_fakes "$fakebin" "$dir"
  fm_git_worktree "$dir/project" "$wt" fm/rd
  fm_test_spawn_brief "$dir" rd
  printf 'https://github.com/acme/widget/pull/8\topen\ttrue\t%s\n' "$(git -C "$wt" rev-parse HEAD)" > "$dir/pr-row"
  FM_TASK_INBOX=$state/rd.inbox PATH="$fakebin:$PATH" "$ROOT/bin/fm-cloud-claude-relay.sh" \
    --task rd --worktree "$wt" --brief "$dir/data/rd/brief.md" --status "$state/rd.status" \
    --repo acme/widget --branch fm/rd --base main --deadline 0 --gen "$gen" --poll 1 </dev/null >"$dir/pane.log" 2>&1 &
  relay_pid=$!
  wait_for "$state/rd.status" "blocked [key=cloud-deadline]" "the deadline report"
  sleep 1.5
  assert_no_grep "^done" "$state/rd.status" "a draft pull request is not done"
  kill "$relay_pid" 2>/dev/null
  wait "$relay_pid" 2>/dev/null
  pass "a draft pull request never reads as done"
}

test_direct_pr_ship_launches_the_relay_on_the_cloud_account
test_cloud_spawn_is_not_deferred_by_local_load_or_heavy_cap
test_cloud_spawn_still_waits_for_its_project_capacity
test_relay_flags_the_deadline_and_reports_the_pull_request
test_relay_forwards_steers_and_reports_the_follow_up
test_relay_reports_a_draft_as_not_done
test_refusals_before_launch
test_github_repo_forms

echo "# all fm-cloud-claude tests passed"
