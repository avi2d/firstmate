#!/usr/bin/env bash
# Remote secondmate retirement through the host-side entry point,
# fm-remote-secondmate-control.sh retire, against fixture homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-retire)
CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
CLAIMS="$TMP_ROOT/claims"
FAKE="$TMP_ROOT/fake"
HERDR_STATE="$TMP_ROOT/herdr.state"
mkdir -p "$CLAIMS" "$FAKE"
export FM_PROCEVENT_CLAIM_ROOT="$CLAIMS"
install_remote_herdr_fixture "$FAKE" "$HERDR_STATE" "$TMP_ROOT/herdr.log" "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
cleanup_retire_fixture() {
  [ ! -f "$HERDR_STATE.shell-pid" ] || kill "$(cat "$HERDR_STATE.shell-pid")" 2>/dev/null || true
}
trap 'cleanup_retire_fixture; fm_test_cleanup' EXIT

# A seeded remote secondmate home whose parent-route record names a Herdr pane
# that is already gone. Echoes the home.
make_home() {  # <name>
  local name=$1 home route
  home="$TMP_ROOT/$name/home"
  route="$home/state/parent-route"
  mkdir -p "$route" "$home/data/.parent-route" "$home/config" "$home/projects" "$home/state/procevent"
  cp -R "$ROOT/bin" "$home/bin"
  printf '# fixture\n' > "$home/AGENTS.md"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$route/sm1.meta" \
    "window=fm-remote:w1:p2" \
    "endpoint_task_id=sm1" \
    "backend=herdr" \
    "herdr_session=fm-remote" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2" \
    "worktree=$home" \
    "home=$home" \
    "project=$home" \
    "kind=secondmate" \
    "mode=local-only" \
    "spawn_gen=retire-test-sm1"
  chmod -R go-w "$TMP_ROOT/$name"
  printf '%s\n' "$home"
}

add_home_source() {  # <home> <source-id>
  cat > "$1/state/procevent/$2.source" <<EOF
adapter=lavish
kind=persistent
argc=2
argv:
$ROOT/bin/fm-procevent-lavish.sh
poll
EOF
}

retire() {  # <home> [--force]
  PATH="$FAKE/bin:$PATH" FM_HOME="$1" "$CONTROL" retire sm1 ${2:+"$2"}
}

test_retire_sweeps_the_home_process_events_not_the_parent_route() {
  local home rc=0 out
  home=$(make_home sweep-own-state)
  add_home_source "$home" board-review
  chmod g+w "$home/state/parent-route"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 0 "$rc" "retirement refused a home whose only process event is its own: $out"
  assert_contains "$out" "swept: attempted=1" "the sweep did not reach the home's own source"
  assert_absent "$home" "retirement kept the home"
  pass "retirement sweeps the home's own process events instead of the group-writable parent-route folder"
}

test_unprivate_state_root_refusal_names_the_folder() {
  local home rc=0 out
  home=$(make_home unprivate-state)
  add_home_source "$home" board-review
  chmod g+w "$home/state"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement accepted a group-writable process-event state folder"
  assert_contains "$out" "not a private directory: $home/state" "the refusal did not name the folder"
  assert_present "$home/state/procevent/board-review.source" "a refused retirement dropped the source"
  pass "a non-private process-event state folder refuses with its path instead of an unnamed folder"
}

test_unread_round_refusal_lists_each_round_and_its_text() {
  local home rc=0 out inbox
  home=$(make_home unread-round)
  add_home_source "$home" board-review
  sed -i.bak 's/^kind=persistent$/kind=task-owned/' "$home/state/procevent/board-review.source"
  rm -f "$home/state/procevent/board-review.source.bak"
  printf 'owner_task=ship1\n' >> "$home/state/procevent/board-review.source"
  inbox="$home/state/procevent-inbox"
  mkdir -p "$inbox"
  chmod 700 "$inbox"
  printf 'Approve the layout, but tighten the header spacing\n' > "$inbox/board-review.1.result"
  printf 'Second pass: ship it\n' > "$inbox/board-review.2.result"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement accepted a home with unread captured rounds"
  assert_contains "$out" "board-review sequence 1" "the refusal did not name the first unread round"
  assert_contains "$out" "Approve the layout, but tighten the header spacing" "the refusal did not show the first round's text"
  assert_contains "$out" "board-review sequence 2" "the refusal did not name the second unread round"
  assert_contains "$out" "Second pass: ship it" "the refusal did not show the second round's text"
  assert_present "$home/state/procevent/board-review.source" "a refused retirement dropped the source"
  pass "an unread captured round refuses retirement with each round and its text instead of an unnamed failure"
}

# A ship child parked with an open PR: its copy sits on a pushed branch in a
# project clone inside the home. Echoes the copy.
add_pushed_ship_child() {  # <home>
  local home=$1 origin="$1/../origin.git" proj="$1/projects/proj" wt="$1/projects/proj-ship1"
  git init -q --bare "$origin"
  git init -q -b main "$proj"
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q origin main
  git -C "$proj" worktree add -q -b fm/ship1 "$wt"
  printf 'change\n' > "$wt/change.txt"
  git -C "$wt" add change.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q -m change
  git -C "$wt" push -q -u origin fm/ship1
  fm_write_meta "$home/state/ship1.meta" \
    "worktree=$wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=https://github.com/example/proj/pull/7" \
    "spawn_gen=retire-test-ship1"
  printf '%s\n' "$wt"
}

test_retire_accepts_a_child_copy_equal_to_its_pushed_branch() {
  local home rc=0 out
  home=$(make_home pushed-child)
  add_pushed_ship_child "$home" >/dev/null
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 0 "$rc" "retirement refused a home whose only leftover is a clean copy equal to its pushed branch: $out"
  assert_absent "$home" "retirement kept the home"
  [ -n "$(git -C "$TMP_ROOT/pushed-child/origin.git" rev-parse --verify -q refs/heads/fm/ship1)" ] \
    || fail "retirement lost the pushed branch"
  pass "a non-forced retirement removes a child copy that equals its pushed branch"
}

test_retire_still_refuses_a_child_copy_ahead_of_its_pushed_branch() {
  local home rc=0 out wt
  home=$(make_home unpushed-child)
  wt=$(add_pushed_ship_child "$home")
  printf 'more\n' >> "$wt/change.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q -am more
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement accepted a child copy with an unpushed commit"
  assert_contains "$out" "ship1" "the refusal did not name the child"
  assert_present "$wt/change.txt" "a refused retirement removed the child copy"
  pass "a non-forced retirement still refuses a child copy with a commit its pushed branch lacks"
}

test_retire_still_refuses_a_dirty_child_copy() {
  local home rc=0 out wt
  home=$(make_home dirty-child)
  wt=$(add_pushed_ship_child "$home")
  printf 'scratch\n' > "$wt/untracked.txt"
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement accepted a child copy with an untracked file"
  assert_present "$wt/untracked.txt" "a refused retirement removed the uncommitted file"
  pass "a non-forced retirement still refuses a child copy with uncommitted files"
}

test_retire_still_refuses_a_child_copy_whose_remote_branch_is_gone() {
  local home rc=0 out wt
  home=$(make_home deleted-branch-child)
  wt=$(add_pushed_ship_child "$home")
  git -C "$TMP_ROOT/deleted-branch-child/origin.git" update-ref -d refs/heads/fm/ship1
  out=$(retire "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "retirement trusted a stale tracking ref for a branch the remote no longer holds"
  assert_present "$wt/change.txt" "a refused retirement removed the child copy"
  pass "a non-forced retirement still refuses a child copy whose branch the remote no longer holds"
}

test_retire_sweeps_the_home_process_events_not_the_parent_route
test_retire_still_refuses_a_child_copy_whose_remote_branch_is_gone
test_retire_accepts_a_child_copy_equal_to_its_pushed_branch
test_retire_still_refuses_a_child_copy_ahead_of_its_pushed_branch
test_retire_still_refuses_a_dirty_child_copy
test_unread_round_refusal_lists_each_round_and_its_text
test_unprivate_state_root_refusal_names_the_folder
