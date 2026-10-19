#!/usr/bin/env bash
# Behavioral tests for bin/fm-merge-on-green.sh and bin/fm-procevent-merge-on-green.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-on-green-tests)
URL=https://github.com/example/repo/pull/9
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

write_view() {  # <case> <head> <rollup-json> [draft] [mergeable] [head-branch]
  printf '{"state":"OPEN","isDraft":%s,"mergeable":"%s","mergeStateStatus":"CLEAN","headRefOid":"%s","headRefName":"%s","baseRefName":"main","statusCheckRollup":%s}\n' \
    "${4:-false}" "${5:-MERGEABLE}" "$2" "${6:-fm/task-x1}" "$3" > "$1/view.json"
}

green_rollup='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T10:00:00Z","completedAt":"2026-10-19T10:01:00Z"},{"__typename":"StatusContext","context":"commitlint","state":"SUCCESS","startedAt":"2026-10-19T10:00:30Z"}]'

green_rollup_finished_at() {  # <epoch>
  printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-19T10:00:00Z","completedAt":"%s"}]' \
    "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ)"
}
red_rollup='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T10:00:00Z"}]'
pending_rollup='[{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-10-19T10:00:00Z"}]'

plain_diff() {
  printf '%s\n' 'diff --git a/README.md b/README.md' '--- a/README.md' '+++ b/README.md' '@@ -1 +1 @@' '-old' '+new'
}

make_case() {  # <name> [registry-tokens] [task-yolo]
  local name=$1 tokens=${2:-direct-PR +yolo} yolo=${3:-on} c
  c="$TMP_ROOT/$name"
  mkdir -p "$c/state" "$c/home/data" "$c/fakebin" "$c/claims" "$c/user-home" "$c/wt"
  fm_test_tasks_toml "$c/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$c/home/data/backlog.md"
  printf -- '- repo [%s] - fixture (added 2026-10-19)\n' "$tokens" > "$c/home/data/projects.md"
  fm_write_meta "$c/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$c/wt" \
    "project=$c/projects/repo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=$yolo" \
    "pr=$URL"
  printf 'done [at=1792400000]: PR %s checks green\n' "$URL" > "$c/state/task-x1.status"
  write_view "$c" "$HEAD_A" "$green_rollup"
  plain_diff > "$c/diff.txt"
  printf '0\n' > "$c/behind"
  printf '%s\n' state=MERGED merged=true queued=false base=main > "$c/outcome"
  : > "$c/gh.log"
  cat > "$c/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE/gh.log"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*|*isDraft*) cat "$FM_TEST_CASE/view.json" ;;
      *headRefOid*) jq -r .headRefOid "$FM_TEST_CASE/view.json" ;;
      *) cat "$FM_TEST_CASE/view.json" ;;
    esac
    ;;
  "pr diff") cat "$FM_TEST_CASE/diff.txt" ;;
  "pr update-branch") printf 'updated\n' ;;
  "pr merge") printf 'merged\n' ;;
  "api graphql") cat "$FM_TEST_CASE/outcome" ;;
  "api repos/"*/compare/*) cat "$FM_TEST_CASE/behind" ;;
  api\ *)
    case " $* " in
      *" repos/"*"/rules/branches/"*) printf '[]\n' ;;
      *" repos/"*"/branches/"*) printf '{"name":"main","protected":false}\n' ;;
      *) printf '[]\n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$c/fakebin/gh"
  printf '%s\n' "$c"
}

run_in() {  # <case> <command...>
  local c=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$c/home" \
  FM_STATE_OVERRIDE="$c/state" \
  FM_PROCEVENT_CLAIM_ROOT="$c/claims" \
  FM_MERGE_ON_GREEN_SETTLE_SECS="${SETTLE:-0}" \
  FM_TEST_CASE="$c" \
  HOME="$c/user-home" \
  PATH="$c/fakebin:$PATH" \
    "$@"
}

sweep() { run_in "$1" "$ROOT/bin/fm-merge-on-green.sh" sweep; }
assess() { run_in "$1" "$ROOT/bin/fm-merge-on-green.sh" assess task-x1; }
merge_calls() { grep -c '^pr merge ' "$1/gh.log" || true; }

expect_verdict() {  # <case> <verdict> <reason-fragment> <label>
  local line
  line=$(assess "$1")
  case "$line" in
    "$2"$'\t'*"$3"*) ;;
    *) fail "$4: expected verdict $2 naming '$3', got: $line" ;;
  esac
}

expect_stays_open() {  # <case> <verdict> <reason-fragment> <label>
  sweep "$1"
  sweep "$1"
  [ "$(merge_calls "$1")" -eq 0 ] || fail "$4: the pull request was merged: $(cat "$1/gh.log")"
  if grep -q '^pr update-branch' "$1/gh.log"; then
    fail "$4: the branch was updated"
  fi
  expect_verdict "$1" "$2" "$3" "$4"
}

test_settled_green_pull_request_merges_on_its_first_sweep() {
  local c
  c=$(make_case green)
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "green: expected one merge on the first sweep, got: $(cat "$c/gh.log")"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $HEAD_A --squash" "$c/gh.log" \
    || fail "green: the merge was not the guarded bin/fm-pr-merge.sh call: $(grep '^pr merge' "$c/gh.log")"
  assert_grep "merge landed: task-x1 $URL" "$c/state/.wake-queue" "green: the main home got no merge outcome"
  assert_grep " task-x1 merged $URL" "$c/state/merge-on-green.log" "green: the merge was not logged"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "green: an already merged pull request was merged again"
  pass "a green +yolo pull request whose last check finished past the settle window merges through fm-pr-merge.sh on its first sweep"
}

test_green_without_a_settled_finish_merges_on_the_second_sighting() {
  local c
  c=$(make_case unfinished-at)
  write_view "$c" "$HEAD_A" "$(green_rollup_finished_at $(($(date +%s) + 3600)))"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 0 ] || fail "unfinished-at: merged on the first sighting of a check that had not settled"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "unfinished-at: a head green on two sweeps did not merge: $(cat "$c/gh.log")"
  pass "a green head whose last finish is not yet settled merges on its second green sighting"
}

test_unsettled_green_waits() {
  local c
  c=$(make_case unsettled)
  write_view "$c" "$HEAD_A" "$(green_rollup_finished_at "$(date +%s)")"
  SETTLE=3600 sweep "$c"
  SETTLE=3600 sweep "$c"
  [ "$(merge_calls "$c")" -eq 0 ] || fail "unsettled: merged before the settle window elapsed"
  pass "a green state younger than the settle window does not merge yet"
}

test_red_pull_request_stays_open() {
  local c
  c=$(make_case red)
  write_view "$c" "$HEAD_A" "$red_rollup"
  expect_stays_open "$c" skip "checks are not green: ci" red
  [ "$(grep -c '^pr view ' "$c/gh.log")" -eq 2 ] \
    || fail "red: a red pull request was read again inside the recheck window: $(cat "$c/gh.log")"
  FM_MERGE_ON_GREEN_SKIP_RECHECK_SECS=0 sweep "$c"
  [ "$(grep -c '^pr view ' "$c/gh.log")" -eq 3 ] || fail "red: the recheck window never reopened"
  pass "a red pull request stays open and is read again only on the slower recheck cadence"
}

test_pending_and_unreported_checks_wait() {
  local c
  c=$(make_case pending)
  write_view "$c" "$HEAD_A" "$pending_rollup"
  expect_stays_open "$c" wait "still running" pending
  c=$(make_case unreported)
  write_view "$c" "$HEAD_A" '[]'
  expect_stays_open "$c" wait "no check has reported" unreported
  pass "pending checks and a pull request with no reported check wait"
}

test_draft_and_conflicting_stay_open() {
  local c
  c=$(make_case draft)
  write_view "$c" "$HEAD_A" "$green_rollup" true
  expect_stays_open "$c" skip "draft" draft
  c=$(make_case conflicting)
  write_view "$c" "$HEAD_A" "$green_rollup" false CONFLICTING
  printf '3\n' > "$c/behind"
  expect_stays_open "$c" skip "conflicts" conflicting
  pass "a draft or conflicting pull request stays open and is never updated"
}

test_yolo_must_be_on_in_the_registry_and_the_task() {
  local c
  c=$(make_case registry-off direct-PR)
  expect_stays_open "$c" skip "does not carry +yolo" registry-off
  [ ! -s "$c/gh.log" ] || fail "registry-off: a non-yolo project was read from the forge"
  c=$(make_case task-off "direct-PR +yolo" off)
  expect_stays_open "$c" skip "task yolo is off" task-off
  pass "both the registry entry and the task must carry yolo"
}

test_captain_hold_and_open_decisions_stay_open() {
  local c
  c=$(make_case held)
  run_in "$c" "$ROOT/bin/fm-captain-hold.sh" hold task-x1 --title fixture --reason "fixture hold" >/dev/null \
    || fail "held: could not record the fixture hold"
  expect_stays_open "$c" skip "held for the captain" held
  c=$(make_case decision)
  printf 'needs-decision [key=scope]: which scope\n' >> "$c/state/task-x1.status"
  expect_stays_open "$c" skip "open decision or blocker scope" decision
  pass "a captain-held task or one with an open decision stays open"
}

test_merge_waits_for_the_workers_done_report() {
  local c
  c=$(make_case no-done)
  : > "$c/state/task-x1.status"
  expect_stays_open "$c" wait "has not reported done" no-done
  c=$(make_case other-pr)
  printf 'done [at=1792400000]: PR %s0 checks green\n' "$URL" > "$c/state/task-x1.status"
  expect_stays_open "$c" wait "does not name this pull request" other-pr
  c=$(make_case back-to-work)
  printf 'working [at=1792400100]: addressing a late steer\n' >> "$c/state/task-x1.status"
  expect_stays_open "$c" wait "reported working after done" back-to-work
  printf 'done [at=1792400200]: PR %s steer addressed\n' "$URL" >> "$c/state/task-x1.status"
  sweep "$c"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "back-to-work: a fresh done report naming the pull request did not merge"
  pass "a pull request merges only after its worker's latest done report names it"
}

test_done_line_boundary_flag_stays_open() {
  local c
  c=$(make_case flagged)
  printf 'done [at=1792400100]: PR %s; rotates the deploy token\n' "$URL" >> "$c/state/task-x1.status"
  expect_stays_open "$c" skip "done line flags" flagged
  c=$(make_case negated)
  printf 'done [at=1792400100]: PR %s; no credential, token or security boundary change\n' "$URL" >> "$c/state/task-x1.status"
  sweep "$c"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "negated: a done line denying any boundary change blocked the merge"
  pass "a done line flagging a credential or token change stays open, a denial does not"
}

test_boundary_diffs_stay_open() {
  local c
  c=$(make_case workflow-permissions)
  printf '%s\n' 'diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml' '--- a/.github/workflows/ci.yml' \
    '+++ b/.github/workflows/ci.yml' '@@ -3,2 +3,2 @@ permissions:' '-  contents: read' '+  contents: write' > "$c/diff.txt"
  expect_stays_open "$c" skip "workflow permissions" workflow-permissions
  c=$(make_case secret-path)
  printf '%s\n' 'diff --git a/bin/fm-vendor-auth-probe.sh b/bin/fm-vendor-auth-probe.sh' '@@ -1 +1 @@' '-a' '+b' > "$c/diff.txt"
  expect_stays_open "$c" skip "touches" secret-path
  c=$(make_case workflow-steps)
  printf '%s\n' 'diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml' '@@ -9 +9 @@' '-      run: make' '+      run: make test' > "$c/diff.txt"
  sweep "$c"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "workflow-steps: a workflow change outside permissions blocked the merge"
  pass "a diff touching credential paths or workflow permissions stays open"
}

test_behind_head_is_updated_by_merge_then_merges_when_green_again() {
  local c
  c=$(make_case behind)
  printf '2\n' > "$c/behind"
  sweep "$c"
  grep -qxF "pr update-branch $URL" "$c/gh.log" || fail "behind: the branch was not updated with a merge: $(cat "$c/gh.log")"
  if grep -q -- '--rebase' "$c/gh.log"; then
    fail "behind: the branch was rebased"
  fi
  sweep "$c"
  [ "$(grep -c '^pr update-branch' "$c/gh.log")" -eq 1 ] || fail "behind: the same head was updated twice"
  [ "$(merge_calls "$c")" -eq 0 ] || fail "behind: a behind head was merged"
  printf '0\n' > "$c/behind"
  write_view "$c" "$HEAD_B" "$pending_rollup"
  sweep "$c"
  write_view "$c" "$HEAD_B" "$green_rollup"
  sweep "$c"
  sweep "$c"
  grep -qxF "pr merge 9 --repo example/repo --match-head-commit $HEAD_B --squash" "$c/gh.log" \
    || fail "behind: the updated head did not merge once green again: $(cat "$c/gh.log")"
  pass "a behind head is updated by merging its base, never rebased, and merges once green again"
}

test_secondmate_home_wakes_itself_after_its_own_merge() {
  local c
  c=$(make_case secondmate)
  printf '%s\n' mate-x > "$c/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$c/home/.fm-secondmate-parent"
  sweep "$c"
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "secondmate: the mate's pull request did not merge"
  assert_grep "merged task-x1 $URL" "$c/state/parent-replies.status" "secondmate: the merge was not reported upward"
  assert_grep "check: merge landed: task-x1 $URL" "$c/state/.wake-queue" \
    "secondmate: the mate home got no wake to run its own cleanup"
  pass "a secondmate home merges its own task and wakes itself for cleanup"
}

test_adapter_polls_silently_while_work_remains() {
  local c other id other_id out rc
  c=$(make_case adapter)
  other=$(make_case adapter-other)
  id=$(run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" source-id)
  other_id=$(run_in "$other" "$ROOT/bin/fm-procevent-merge-on-green.sh" source-id)
  case "$id" in merge-on-green-????????????????) ;; *) fail "adapter: unexpected source id $id" ;; esac
  [ "$id" != "$other_id" ] || fail "adapter: two homes share one machine-wide source id"
  write_view "$c" "$HEAD_A" "$pending_rollup"
  rc=0
  out=$(run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" poll --home "$c/home" --state "$c/state" --interval 1 --lifetime 1) || rc=$?
  expect_code 75 "$rc" "adapter: an ended poll window must exit empty for the runner to relisten"
  [ -z "$out" ] || fail "adapter: poll printed a result while a pull request was left to merge: $out"
  [ -f "$c/state/task-x1.merge-on-green" ] || fail "adapter: poll did not sweep the home"
  run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" relisten || fail "adapter: relisten must ask the runner to poll again"
  pass "the adapter keeps one source per home polling without a result while work remains"
}

test_idle_source_retires_through_the_runner_without_a_wake() {
  local c id
  c=$(make_case idle "direct-PR +yolo" off)
  fm_test_track_procevent_home "$c/home" "$c/claims"
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" arm >/dev/null || fail "idle: arm failed"
  id=$(run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" source-id)
  [ -f "$c/state/procevent/$id.source" ] || fail "idle: arm registered nothing"
  FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 run_in "$c" "$ROOT/bin/fm-procevent.sh" start "$id" > "$c/start.out" 2>&1 \
    || fail "idle: the runner failed: $(cat "$c/start.out")"
  [ ! -e "$c/state/procevent/$id.source" ] || fail "idle: an idle source stayed registered: $(cat "$c/start.out")"
  if grep -q procevent "$c/state/.wake-queue" 2>/dev/null; then
    fail "idle: an idle source woke supervision: $(cat "$c/state/.wake-queue")"
  fi
  pass "a source with nothing left to merge retires itself through the runner without waking anyone"
}

test_pr_check_arms_the_source_for_a_yolo_pull_request() {
  local c id
  c=$(make_case pr-check-arm)
  fm_test_track_procevent_home "$c/home" "$c/claims"
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  run_in "$c" "$ROOT/bin/fm-pr-check.sh" task-x1 "$URL" >/dev/null 2>&1 || fail "pr-check-arm: fm-pr-check.sh failed"
  id=$(run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" source-id)
  [ -f "$c/state/procevent/$id.source" ] || fail "pr-check-arm: a +yolo pull request did not arm merge on green"
  c=$(make_case pr-check-no-arm "direct-PR +yolo" off)
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  run_in "$c" "$ROOT/bin/fm-pr-check.sh" task-x1 "$URL" >/dev/null 2>&1 || fail "pr-check-no-arm: fm-pr-check.sh failed"
  id=$(run_in "$c" "$ROOT/bin/fm-procevent-merge-on-green.sh" source-id)
  [ ! -e "$c/state/procevent/$id.source" ] || fail "pr-check-no-arm: a task with yolo off armed merge on green"
  pass "fm-pr-check.sh arms merge on green only for a yolo task"
}

test_unrecorded_direct_pr_done_line_is_adopted_once_green() {
  local c
  c=$(make_case unrecorded-direct)
  sed -i.bak 's/^mode=no-mistakes$/mode=direct-PR/' "$c/state/task-x1.meta"
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  printf 'done [at=1792400000]: PR %s\n' "$URL" > "$c/state/task-x1.status"
  write_view "$c" "$HEAD_A" "$green_rollup" false MERGEABLE fm/task-x1
  expect_verdict "$c" green "every check is green" unrecorded-direct
  pass "a direct-PR done line naming the pull request with no recorded pr= is adopted as a merge candidate once checks are green"
}

test_done_line_pull_request_from_another_branch_is_never_adopted() {
  local c
  c=$(make_case unrecorded-foreign)
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  write_view "$c" "$HEAD_A" "$green_rollup" false MERGEABLE fm/someone-else
  expect_stays_open "$c" skip "does not own" unrecorded-foreign
  pass "a done line naming a pull request from another branch is never adopted"
}

test_unrecorded_pull_request_merges_through_the_sweep() {
  local c
  c=$(make_case unrecorded-merge)
  sed -i.bak '/^pr=/d' "$c/state/task-x1.meta"
  write_view "$c" "$HEAD_A" "$green_rollup" false MERGEABLE fm/task-x1
  sweep "$c"
  [ "$(merge_calls "$c")" -eq 1 ] || fail "unrecorded-merge: a green pull request with no recorded pr= was not merged: $(cat "$c/gh.log")"
  grep -qxF "pr=$URL" "$c/state/task-x1.meta" || fail "unrecorded-merge: the merge did not record pr="
  pass "a green pull request with no recorded pr= merges through the sweep and ends recorded"
}

test_settled_green_pull_request_merges_on_its_first_sweep
test_green_without_a_settled_finish_merges_on_the_second_sighting
test_unsettled_green_waits
test_red_pull_request_stays_open
test_pending_and_unreported_checks_wait
test_draft_and_conflicting_stay_open
test_yolo_must_be_on_in_the_registry_and_the_task
test_captain_hold_and_open_decisions_stay_open
test_merge_waits_for_the_workers_done_report
test_done_line_boundary_flag_stays_open
test_boundary_diffs_stay_open
test_behind_head_is_updated_by_merge_then_merges_when_green_again
test_secondmate_home_wakes_itself_after_its_own_merge
test_adapter_polls_silently_while_work_remains
test_idle_source_retires_through_the_runner_without_a_wake
test_pr_check_arms_the_source_for_a_yolo_pull_request
test_unrecorded_direct_pr_done_line_is_adopted_once_green
test_done_line_pull_request_from_another_branch_is_never_adopted
test_unrecorded_pull_request_merges_through_the_sweep
