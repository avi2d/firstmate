#!/usr/bin/env bash
# Merge entrypoints and done-retention interplay with captain holds.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

test_merge_approval_releases_before_zero_done_retention() {
  local home id archive repo wt pr show
  home=$(make_home zero-done-retention)
  id=sample-zero-retention-merge
  archive="$home/data/done-archive.md"
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  pr="https://github.com/sample/sample/pull/19"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/done-archive.md"' \
    'done_keep = 0' > "$home/.tasks.toml"
  fm_git_worktree "$repo" "$wt" fm/zero-retention-merge
  tasks_in "$home" add "$id" "Ship zero-retention merge $pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the zero-retention fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the zero-retention merge"
  printf 'Merge the approved change.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved zero-retention merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge row disappeared"
  assert_contains "$show" "state: in_flight" \
    "merge approval completed the zero-retention row before landing"
  assert_contains "$show" "Resolution mode: released" \
    "merge approval did not record the existing release mode"
  zero_head=$(git -C "$wt" rev-parse HEAD) \
    || fail "could not read the zero-retention merge head"
  configure_merged_pr_for_head "$home" "$pr" "$zero_head"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "zero-retention cleanup failed: $(cat "$home/teardown.err")"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "zero-retention cleanup kept the completed row in the active backlog"
  assert_grep "$id" "$archive" "zero-retention cleanup did not archive the completed row"
  assert_grep "$pr" "$archive" "zero-retention archival lost the merged pull request"
  assert_grep "Merge the approved change." "$archive" \
    "zero-retention archival lost the recorded merge approval"
  assert_absent "$home/state/$id.meta" "zero-retention cleanup retained task metadata"
  assert_absent "$home/state/$id.backlog-close" \
    "zero-retention cleanup retained its pending close record"
  pass "merge approval releases before zero-retention cleanup records completion"
}

# Done retention moves answered rounds into the configured archive, so a later
# round's completion must still attest the pruned rounds while refusing an
# entry that was never a captain call.
test_complete_accepts_pruned_answered_rounds() {
  local home id archive rc
  home=$(make_home complete-pruned-archive)
  id=sample-pruned-interview
  archive="$home/data/custom-archive.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/custom-archive.md"' \
    'done_keep = 10' > "$home/.tasks.toml"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the pruned interview" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the pruned-interview origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Pruned interview\n\nThree rounds remain.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id-r1" --title "Round one" --reason "round one pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold round one"
  run_captain "$home" hold "$id-r2" --title "Round two" --reason "round two pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold round two"
  run_captain "$home" hold "$id-r3" --title "Round three" --reason "round three pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold round three"
  printf 'Captain chose one.\n' > "$home/answer-one.txt"
  printf 'Captain chose two.\n' > "$home/answer-two.txt"
  run_captain "$home" answer "$id-r1" --decision-file "$home/answer-one.txt" >/dev/null \
    || fail "could not answer round one"
  run_captain "$home" answer "$id-r2" --decision-file "$home/answer-two.txt" >/dev/null \
    || fail "could not answer round two"
  tasks_in "$home" add sample-plain-work "Ordinary finished work" --kind ship --repo sample >/dev/null \
    || fail "could not create the ordinary finished task"
  tasks_in "$home" "done" sample-plain-work >/dev/null \
    || fail "could not close the ordinary finished task"
  tasks_in "$home" prune --keep 0 >/dev/null \
    || fail "could not prune answered rounds into the configured archive"
  if tasks_in "$home" show "$id-r1" --full >/dev/null 2>&1; then
    fail "round one survived pruning instead of moving to the archive"
  fi
  assert_grep "$id-r1" "$archive" "pruning did not move the answered round into the configured archive"
  run_captain "$home" complete "$id" "$id-r1" "$id-r2" "$id-r3" >/dev/null \
    || fail "completion refused an inventory whose answered rounds were pruned into the archive"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "verify refused the pruned answered rounds after completion"
  if run_captain "$home" complete "$id" "$id-r1" "$id-r2" "$id-r3" sample-plain-work \
    > "$home/plain.out" 2> "$home/plain.err"; then
    fail "completion accepted an archived task that was never a captain call"
  fi
  if run_captain "$home" complete "$id" "$id-r1" "$id-r2" "$id-r3" sample-unknown-round \
    > "$home/unknown.out" 2> "$home/unknown.err"; then
    fail "completion accepted an inventory entry that never existed"
  fi
  rc=0
  run_captain "$home" verify "$id" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "a refused completion broke the attested pruned inventory"
  pass "completion attests answered rounds pruned into the configured archive and refuses the rest"
}

test_complete_accepts_released_round_in_done_archive() {
  local home id archive rc
  home=$(make_home complete-released-archive)
  id=sample-released-interview
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the released interview" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the released-interview origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Released interview\n\nOne round remains.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id-r1" --title "Round one" --reason "round one pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold round one"
  printf 'Captain chose one.\n' > "$home/answer-one.txt"
  run_captain "$home" answer "$id-r1" --decision-file "$home/answer-one.txt" --release >/dev/null \
    || fail "could not release round one"
  tasks_in "$home" "done" "$id-r1" >/dev/null \
    || fail "could not close the released round"
  run_captain "$home" hold "$id-open" --title "Open round" --reason "round still pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the open round"
  tasks_in "$home" "done" "$id-open" >/dev/null \
    || fail "could not close the unanswered round"
  for i in $(seq 1 12); do
    tasks_in "$home" add "filler-$i" "Filler $i" --kind ship --repo sample >/dev/null \
      || fail "could not create filler $i"
    tasks_in "$home" "done" "filler-$i" >/dev/null \
      || fail "could not close filler $i"
  done
  tasks_in "$home" prune >/dev/null \
    || fail "could not prune closed rounds into the done archive"
  if tasks_in "$home" show "$id-r1" --full >/dev/null 2>&1; then
    fail "the released round survived pruning instead of moving to the archive"
  fi
  assert_grep "$id-r1" "$archive" "pruning did not move the released round into the done archive"
  run_captain "$home" complete "$id" "$id-r1" >/dev/null \
    || fail "completion refused a released round pruned into the done archive"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "verify refused the released round after completion"
  if run_captain "$home" complete "$id" "$id-r1" filler-1 \
    > "$home/plain.out" 2> "$home/plain.err"; then
    fail "completion accepted an archived task that was never a captain call"
  fi
  if run_captain "$home" complete "$id" "$id-r1" sample-unknown-round \
    > "$home/unknown.out" 2> "$home/unknown.err"; then
    fail "completion accepted an inventory entry that never existed"
  fi
  if run_captain "$home" complete "$id" "$id-r1" "$id-open" \
    > "$home/unanswered.out" 2> "$home/unanswered.err"; then
    fail "completion accepted an archived round the captain never answered"
  fi
  rc=0
  run_captain "$home" verify "$id" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "a refused completion broke the attested released inventory"
  pass "completion attests a released round pruned into the done archive and refuses the rest"
}

test_pr_merge_entrypoint_refuses_a_captain_held_task() {
  local home pr_id pr repo wt rc
  home=$(make_home held-merge-entrypoints)
  configure_merged_github "$home"

  pr_id=sample-held-pr-entrypoint
  pr=https://github.com/sample/sample/pull/31
  repo="$home/projects/sample-pr"
  wt="$home/projects/$pr_id"
  fm_git_worktree "$repo" "$wt" "fm/$pr_id"
  tasks_in "$home" add "$pr_id" "Ship the held pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held PR fixture"
  fm_write_meta "$home/state/$pr_id.meta" \
    "window=firstmate:fm-$pr_id" "endpoint_task_id=$pr_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$pr_id"
  run_captain "$home" hold "$pr_id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR entrypoint fixture"

  # Without the entrypoint guard, this run reaches gh and returns success even
  # though the task is still held for the captain.
  set +e
  run_pr_merge "$home" "$pr_id" "$pr" > "$home/pr.out" 2> "$home/pr.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted a still-held task"
  assert_no_grep 'pr merge 31 ' "$home/gh.log" \
    "the PR merge entrypoint reached the irreversible forge call for a held task"
  assert_grep "$pr_id is still held for the captain" "$home/pr.err" \
    "the PR merge refusal did not name the held task"
  assert_absent "$home/state/.control-$pr_id.lock" \
    "the refused PR merge left its task control lock held"
  pass "the PR merge entrypoint refuses a captain-held task before merging"
}

test_local_merge_entrypoint_refuses_a_captain_held_task() {
  local home local_id local_repo local_wt before after rc
  home=$(make_home held-local-merge-entrypoint)
  local_id=sample-held-local-entrypoint
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'held local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'held local delivery'
  tasks_in "$home" add "$local_id" "Ship the held local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_wt" rev-parse HEAD)" >> "$home/state/$local_id.meta"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the local entrypoint fixture"
  before=$(git -C "$local_repo" rev-parse main)

  # Without the entrypoint guard, this run fast-forwards main while the task
  # still carries the captain hold.
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local.out" 2> "$home/local.err"
  rc=$?
  set -e
  after=$(git -C "$local_repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted a still-held task"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main for a held task"
  assert_grep "$local_id is still held for the captain" "$home/local.err" \
    "the local merge refusal did not name the held task"
  assert_absent "$home/state/.control-$local_id.lock" \
    "the refused local merge left its task control lock held"
  pass "the local merge entrypoint refuses a captain-held task before merging"
}

test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id pr rc merge_count
  home=$(make_home missing-pr-authority-record)
  configure_merged_github "$home"
  id=sample-missing-pr-authority
  pr=https://github.com/sample/sample/pull/43
  write_origin_meta "$home" "$id" ship

  # A backlog that exists but cannot be read may hide a live captain hold, so
  # the merge must refuse without reaching the forge.
  chmod 000 "$home/data/backlog.md"
  set +e
  run_pr_merge "$home" "$id" "$pr" > "$home/missing-pr.out" 2> "$home/missing-pr.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted an unreadable captain-hold authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-pr.err" \
    "the PR merge refusal did not name its unreadable authority record"
  assert_no_grep 'pr merge 43 ' "$home/gh.log" \
    "the PR merge entrypoint reached the forge without a readable authority record"

  # A home with no backlog at all records no captain calls, so nothing can be
  # held and the merge proceeds.
  rm "$home/data/backlog.md"
  run_pr_merge "$home" "$id" "$pr" > "$home/absent-pr.out" 2> "$home/absent-pr.err" \
    || fail "the PR merge entrypoint refused a home carrying no backlog"
  merge_count=$(grep -c 'pr merge 43 ' "$home/gh.log" || true)
  [ "$merge_count" -eq 1 ] || fail "the absent backlog did not permit exactly one PR merge"
  pass "the PR merge entrypoint separates an unreadable authority record from an absent one"
}

test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id repo wt before after rc
  home=$(make_home missing-local-authority-record)
  id=sample-missing-local-authority
  repo="$home/projects/sample-local"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  printf 'untracked local delivery\n' > "$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'untracked local delivery'
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$id"
  printf 'local_done_head=%s\n' "$(git -C "$wt" rev-parse HEAD)" >> "$home/state/$id.meta"
  before=$(git -C "$repo" rev-parse main)

  # Unreadable authority record: refuse, and leave the default branch where it was.
  chmod 000 "$home/data/backlog.md"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/missing-local.out" 2> "$home/missing-local.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  after=$(git -C "$repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted an unreadable captain-hold authority record"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main without a readable authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-local.err" \
    "the local merge refusal did not name its unreadable authority record"

  # No backlog at all: nothing can be held, so the landing proceeds.
  rm "$home/data/backlog.md"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/absent-local.out" 2> "$home/absent-local.err" \
    || fail "the local merge entrypoint refused a home carrying no backlog"
  after=$(git -C "$repo" rev-parse main)
  [ "$after" != "$before" ] || fail "the absent backlog did not permit the local merge"
  pass "the local merge entrypoint separates an unreadable authority record from an absent one"
}

test_merge_entrypoints_validate_identity_and_state_before_locking() {
  local home pr_state local_state bad_id rc
  home=$(make_home invalid-merge-entrypoint-inputs)
  configure_merged_github "$home"

  pr_state="$home/missing-pr-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$pr_state" \
    "$ROOT/bin/fm-pr-merge.sh" sample-missing-pr-state \
    https://github.com/sample/sample/pull/41 \
    > "$home/missing-pr-state.out" 2> "$home/missing-pr-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the PR merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the PR merge accepted a missing state directory"
  assert_absent "$pr_state" "the PR merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-pr-state.err" \
    "the PR merge did not identify its missing state directory"

  local_state="$home/missing-local-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$local_state" \
    "$ROOT/bin/fm-merge-local.sh" sample-missing-local-state \
    > "$home/missing-local-state.out" 2> "$home/missing-local-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the local merge accepted a missing state directory"
  assert_absent "$local_state" "the local merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-local-state.err" \
    "the local merge did not identify its missing state directory"

  bad_id=sample/bad-local-id
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" "$bad_id" \
    > "$home/bad-local-id.out" 2> "$home/bad-local-id.err"
  rc=$?
  set -e
  # Without canonical ID validation, the slash creates a nested lock path whose
  # absent parent makes the blocking acquisition retry until the bound expires.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever on a slash-containing task id"
  [ "$rc" -eq 2 ] || fail "the local merge returned $rc instead of rejecting the unsafe task id"
  assert_grep "invalid local merge request" "$home/bad-local-id.err" \
    "the local merge did not identify the unsafe task id"
  assert_absent "$home/state/.control-sample" \
    "the unsafe task id constructed a nested task control path"
  pass "merge entrypoints reject unsafe identities and absent state before locking"
}

test_merge_entrypoints_refuse_a_reused_task_incarnation() {
  local home id pr old_repo old_wt new_repo new_wt teardown_pid merge_pid
  local teardown_ready teardown_release merge_ready merge_release teardown_rc merge_rc
  local local_home local_id local_old_repo local_old_wt local_new_repo local_new_wt
  local local_teardown_pid local_merge_pid local_teardown_ready local_teardown_release
  local local_merge_ready local_merge_release local_teardown_rc local_merge_rc before after
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)

  home=$(make_home reused-pr-incarnation)
  configure_merged_github "$home"
  install_reused_task_barriers "$home"
  id=sample-reused-pr-incarnation
  pr=https://github.com/sample/sample/pull/42
  old_repo="$home/projects/sample-reused-pr-old"
  old_wt="$home/projects/$id"
  fm_git_worktree "$old_repo" "$old_wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the original pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$old_wt" \
    "project=$old_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=original-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"

  teardown_ready="$home/reuse-teardown-ready"
  teardown_release="$home/reuse-teardown-release"
  merge_ready="$home/reuse-merge-ready"
  merge_release="$home/reuse-merge-release"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$id" --force > "$home/reuse-teardown.out" \
    2> "$home/reuse-teardown.err" &
  teardown_pid=$!
  if ! wait_for_test_file "$teardown_ready" "$teardown_pid"; then
    : > "$teardown_release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "forced PR cleanup did not reach its task-locked synchronization point"
  fi

  FM_TEST_REUSE_MERGE=1 FM_TEST_REUSE_MERGE_ONCE="$home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$merge_ready" FM_TEST_REUSE_MERGE_RELEASE="$merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    run_pr_merge "$home" "$id" "$pr" > "$home/reuse-merge.out" \
    2> "$home/reuse-merge.err" &
  merge_pid=$!
  if ! wait_for_test_file "$merge_ready" "$merge_pid"; then
    : > "$teardown_release"
    : > "$merge_release"
    wait "$teardown_pid" 2>/dev/null || true
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not wait behind forced cleanup"
  fi

  : > "$teardown_release"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e
  if [ "$teardown_rc" -ne 0 ]; then
    : > "$merge_release"
    wait "$merge_pid" 2>/dev/null || true
    fail "forced PR cleanup failed before the task could be reused: $(cat "$home/reuse-teardown.err")"
  fi

  new_repo="$home/projects/sample-reused-pr-new"
  new_wt="$home/projects/reused-$id"
  fm_git_worktree "$new_repo" "$new_wt" "fm/$id"
  tasks_in "$home" reopen "$id" >/dev/null || fail "could not reopen the reused PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$new_wt" \
    "project=$new_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=replacement-$id"
  tasks_in "$home" start "$id" >/dev/null || fail "could not start the reused PR task"
  : > "$merge_release"
  set +e
  wait "$merge_pid"
  merge_rc=$?
  set -e

  # Without the pre-wait generation capture and locked comparison, the waiter
  # records and merges pull request 42 against the replacement task record.
  [ "$merge_rc" -ne 0 ] || fail "the PR merge accepted a replacement task incarnation"
  assert_no_grep 'pr merge 42 ' "$home/gh.log" \
    "the PR merge reached the forge for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$home/reuse-merge.err" \
    "the PR merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$id" "$home/state/$id.meta" \
    "the refused PR merge damaged the replacement task record"
  assert_absent "$home/state/.control-$id.lock" \
    "the reused-incarnation PR refusal left its task control lock held"

  local_home=$(make_home reused-local-incarnation)
  install_reused_task_barriers "$local_home"
  local_id=sample-reused-local-incarnation
  local_old_repo="$local_home/projects/sample-reused-local-old"
  local_old_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_old_repo" "$local_old_wt" "fm/$local_id"
  printf 'original local delivery\n' > "$local_old_wt/original.txt"
  git -C "$local_old_wt" add original.txt
  git -C "$local_old_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'original local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the original local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_old_wt" "project=$local_old_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=original-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_old_wt" rev-parse HEAD)" >> "$local_home/state/$local_id.meta"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"

  local_teardown_ready="$local_home/reuse-teardown-ready"
  local_teardown_release="$local_home/reuse-teardown-release"
  local_merge_ready="$local_home/reuse-merge-ready"
  local_merge_release="$local_home/reuse-merge-release"
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$local_home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$local_teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$local_teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$local_id" --force > "$local_home/reuse-teardown.out" \
    2> "$local_home/reuse-teardown.err" &
  local_teardown_pid=$!
  if ! wait_for_test_file "$local_teardown_ready" "$local_teardown_pid"; then
    : > "$local_teardown_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    fail "forced local cleanup did not reach its task-locked synchronization point"
  fi

  PATH="$local_home/fakebin:$PATH" FM_TEST_REUSE_MERGE=1 \
    FM_TEST_REUSE_MERGE_ONCE="$local_home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$local_merge_ready" \
    FM_TEST_REUSE_MERGE_RELEASE="$local_merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" > "$local_home/reuse-merge.out" \
    2> "$local_home/reuse-merge.err" &
  local_merge_pid=$!
  if ! wait_for_test_file "$local_merge_ready" "$local_merge_pid"; then
    : > "$local_teardown_release"
    : > "$local_merge_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    wait "$local_merge_pid" 2>/dev/null || true
    fail "the local merge did not wait behind forced cleanup"
  fi

  : > "$local_teardown_release"
  set +e
  wait "$local_teardown_pid"
  local_teardown_rc=$?
  set -e
  if [ "$local_teardown_rc" -ne 0 ]; then
    : > "$local_merge_release"
    wait "$local_merge_pid" 2>/dev/null || true
    fail "forced local cleanup failed before the task could be reused: $(cat "$local_home/reuse-teardown.err")"
  fi

  local_new_repo="$local_home/projects/sample-reused-local-new"
  local_new_wt="$local_home/projects/reused-$local_id"
  fm_git_worktree "$local_new_repo" "$local_new_wt" "fm/$local_id"
  printf 'replacement local delivery\n' > "$local_new_wt/replacement.txt"
  git -C "$local_new_wt" add replacement.txt
  git -C "$local_new_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'replacement local delivery'
  before=$(git -C "$local_new_repo" rev-parse main)
  tasks_in "$local_home" reopen "$local_id" >/dev/null \
    || fail "could not reopen the reused local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_new_wt" "project=$local_new_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=replacement-$local_id"
  tasks_in "$local_home" start "$local_id" >/dev/null \
    || fail "could not start the reused local task"
  : > "$local_merge_release"
  set +e
  wait "$local_merge_pid"
  local_merge_rc=$?
  set -e
  after=$(git -C "$local_new_repo" rev-parse main)

  # Without the pre-wait generation capture and locked comparison, the waiter
  # fast-forwards the replacement task's branch despite never approving it.
  [ "$local_merge_rc" -ne 0 ] || fail "the local merge accepted a replacement task incarnation"
  [ "$after" = "$before" ] || fail "the local merge moved main for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$local_home/reuse-merge.err" \
    "the local merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$local_id" "$local_home/state/$local_id.meta" \
    "the refused local merge damaged the replacement task record"
  assert_absent "$local_home/state/.control-$local_id.lock" \
    "the reused-incarnation local refusal left its task control lock held"
  pass "merge entrypoints refuse a replacement incarnation after waiting for cleanup"
}

test_merge_entrypoints_serialize_forced_teardown_before_task_reads() {
  local home id pr repo wt ready release merge_pid teardown_rc merge_rc real_grep
  local local_home local_id local_repo local_wt local_ready local_release local_pid
  local local_teardown_rc local_merge_rc real_git before after i

  home=$(make_home teardown-race-pr-entrypoint)
  configure_merged_github "$home"
  id=sample-teardown-race-pr
  pr=https://github.com/sample/sample/pull/33
  repo="$home/projects/sample-pr-race"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the released pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the PR teardown-race fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR teardown-race fixture"
  printf 'Merge the released pull request.\n' > "$home/race-answer.txt"
  run_captain "$home" answer "$id" --release --decision-file "$home/race-answer.txt" \
    >/dev/null || fail "could not release the PR teardown-race fixture"

  real_grep=$(command -v grep)
  ready="$home/pr-metadata-read-ready"
  release="$home/pr-metadata-read-release"
  cat > "$home/fakebin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -qxF ] && [ "${2:-}" = "pr=${FM_TEST_RACE_PR_URL:-}" ] \
    && [ "${3:-}" = "${FM_TEST_RACE_PR_META:-}" ]; then
  "$FM_TEST_REAL_GREP" "$@" || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  exit 0
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$home/fakebin/grep"
  FM_TEST_REAL_GREP="$real_grep" FM_TEST_RACE_PR_URL="$pr" \
    FM_TEST_RACE_PR_META="$home/state/$id.meta" FM_TEST_RACE_READY="$ready" \
    FM_TEST_RACE_RELEASE="$release" run_pr_merge "$home" "$id" "$pr" \
    > "$home/race-pr.out" 2> "$home/race-pr.err" &
  merge_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$ready" ] && break
    kill -0 "$merge_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not reach the post-metadata synchronization point"
  fi
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/race-pr-teardown.out" 2> "$home/race-pr-teardown.err"
  teardown_rc=$?
  set -e
  : > "$release"
  wait "$merge_pid"
  merge_rc=$?

  # Without early lock ownership, forced cleanup succeeds after metadata is
  # recorded, and the resumed forge call merges work whose task was retired.
  [ "$teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between PR metadata recording and merge"
  assert_grep "another lifecycle action is already running for task $id" \
    "$home/race-pr-teardown.err" \
    "PR cleanup was not refused by the merge's task control lock"
  [ "$merge_rc" -eq 0 ] || fail "the serialized PR merge failed after cleanup was refused"
  assert_present "$home/state/$id.meta" "the refused PR cleanup removed task metadata"
  assert_grep 'pr merge 33 ' "$home/gh.log" \
    "the serialized PR merge did not reach the forge after cleanup was refused"

  local_home=$(make_home teardown-race-local-entrypoint)
  local_id=sample-teardown-race-local
  local_repo="$local_home/projects/sample-local-race"
  local_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'serialized local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'serialized local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the released local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the local teardown-race fixture"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_wt" rev-parse HEAD)" >> "$local_home/state/$local_id.meta"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"
  run_captain "$local_home" hold "$local_id" \
    --reason "captain local merge approval pending" >/dev/null \
    || fail "could not hold the local teardown-race fixture"
  printf 'Land the released local change.\n' > "$local_home/race-answer.txt"
  run_captain "$local_home" answer "$local_id" --release \
    --decision-file "$local_home/race-answer.txt" >/dev/null \
    || fail "could not release the local teardown-race fixture"

  real_git=$(command -v git)
  local_ready="$local_home/local-validation-ready"
  local_release="$local_home/local-validation-release"
  cat > "$local_home/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "${FM_TEST_RACE_REPO:-}" ] \
    && [ "${3:-}" = merge-base ] && [ "${4:-}" = --is-ancestor ]; then
  output=$("$FM_TEST_REAL_GIT" "$@") || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  printf '%s\n' "$output"
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$local_home/fakebin/git"
  before=$(git -C "$local_repo" rev-parse main)
  PATH="$local_home/fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" \
    FM_TEST_RACE_REPO="$local_repo" FM_TEST_RACE_READY="$local_ready" \
    FM_TEST_RACE_RELEASE="$local_release" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$local_home" FM_STATE_OVERRIDE="$local_home/state" \
    FM_DATA_OVERRIDE="$local_home/data" FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$local_home/race-local.out" 2> "$local_home/race-local.err" &
  local_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$local_ready" ] && break
    kill -0 "$local_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$local_ready" ]; then
    : > "$local_release"
    wait "$local_pid" 2>/dev/null || true
    fail "the local merge did not reach the post-validation synchronization point"
  fi
  set +e
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" "$TEARDOWN" "$local_id" --force \
    > "$local_home/race-local-teardown.out" 2> "$local_home/race-local-teardown.err"
  local_teardown_rc=$?
  set -e
  : > "$local_release"
  wait "$local_pid"
  local_merge_rc=$?
  after=$(git -C "$local_repo" rev-parse main)

  # Without early lock ownership, forced cleanup succeeds after validation and
  # the resumed fast-forward lands work whose task was already retired.
  [ "$local_teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between local validation and merge"
  assert_grep "another lifecycle action is already running for task $local_id" \
    "$local_home/race-local-teardown.err" \
    "local cleanup was not refused by the merge's task control lock"
  [ "$local_merge_rc" -eq 0 ] || fail "the serialized local merge failed after cleanup was refused"
  [ "$after" != "$before" ] || fail "the serialized local merge did not fast-forward main"
  assert_present "$local_home/state/$local_id.meta" \
    "the refused local cleanup removed task metadata"
  pass "merge entrypoints own task state before forced cleanup can retire it"
}

# No regression covers a re-hold after a merge lands and before cleanup because
# that accepted window spans two separate lifecycle owners.
# Queued forge merges are also uncovered because they land asynchronously after
# the local merge command and its task control lock have returned.
test_released_merge_passes_the_entrypoint_and_lands() {
  local home id pr repo wt show json
  home=$(make_home released-merge-entrypoint)
  configure_merged_github "$home"
  id=sample-released-merge
  pr=https://github.com/sample/sample/pull/32
  repo="$home/projects/sample-released"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the approved pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released merge fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the released merge fixture"
  printf 'Merge the approved pull request.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge task disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "the approved merge remained captain-held after its release"
  run_pr_merge "$home" "$id" "$pr" > "$home/merge.out" 2> "$home/merge.err" \
    || fail "the released merge was refused: $(cat "$home/merge.err")"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "the released merge cleanup failed: $(cat "$home/teardown.err")"
  json=$(run_bearings "$home") || fail "Bearings failed after the released merge lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" --arg pr "$pr" \
    '.landed | any(.id == $id and .artifact == $pr)' >/dev/null \
    || fail "the released merge was absent from Recently Landed: $json"
  pass "a released merge passes the guarded entrypoint and remains recently landed"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

test_merge_approval_releases_before_zero_done_retention
test_complete_accepts_pruned_answered_rounds
test_complete_accepts_released_round_in_done_archive
test_pr_merge_entrypoint_refuses_a_captain_held_task
test_local_merge_entrypoint_refuses_a_captain_held_task
test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_merge_entrypoints_validate_identity_and_state_before_locking
test_merge_entrypoints_refuse_a_reused_task_incarnation
test_merge_entrypoints_serialize_forced_teardown_before_task_reads
test_released_merge_passes_the_entrypoint_and_lands
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
