#!/usr/bin/env bash
# Behavior tests for bin/fm-home-write-diff.sh through its snapshot and report commands.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DIFF="$ROOT/bin/fm-home-write-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-write-diff)

make_world() {  # <name> -> sets HOME_DIR, WORKTREE, SNAP
  local name=$1
  HOME_DIR="$TMP_ROOT/$name/home"
  WORKTREE="$TMP_ROOT/$name/worktree"
  SNAP="$TMP_ROOT/$name/state/task.home-snapshot"
  mkdir -p "$HOME_DIR/.claude/projects/p" "$HOME_DIR/.pi/agent/extensions" \
    "$HOME_DIR/.pi/agent/sessions" "$WORKTREE/harness" "$TMP_ROOT/$name/live/harness" "${SNAP%/*}"
  printf '{}\n' >"$TMP_ROOT/$name/live/harness/settings.json"
  printf '{}\n' >"$WORKTREE/harness/settings.json"
  ln -s "$TMP_ROOT/$name/live/harness/settings.json" "$HOME_DIR/.claude/settings.json"
  printf '{"a":1}\n' >"$HOME_DIR/.pi/agent/settings.json"
  printf 'old\n' >"$HOME_DIR/.pi/agent/extensions/stale.ts"
  printf 'transcript\n' >"$HOME_DIR/.claude/projects/p/one.jsonl"
  fm_touch_epoch 1700000000 "$HOME_DIR/.pi/agent/settings.json"
}

home_listing() {  # <dir>: every entry with its full metadata, for proving nothing was written
  (cd "$1" && find . -exec ls -ld {} + | LC_ALL=C sort)
}

test_untouched_home_reports_nothing() {
  local out code
  make_world untouched
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  out=$("$DIFF" report "$SNAP"); code=$?
  expect_code 0 "$code" "report on an untouched home"
  assert_equals "" "$out" "an untouched home reports no difference"
  pass "an untouched home reports nothing"
}

test_relink_into_worktree_and_copied_file_are_reported() {
  local out
  make_world relink
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  ln -sfn "$WORKTREE/harness/settings.json" "$HOME_DIR/.claude/settings.json"
  printf '{}\n' >"$HOME_DIR/.pi/agent/keybindings.json"
  out=$("$DIFF" report "$SNAP") || fail "report should succeed"
  assert_contains "$out" "relinked .claude/settings.json: $TMP_ROOT/relink/live/harness/settings.json -> $WORKTREE/harness/settings.json (into the task's worktree)" \
    "a link repointed into the worktree is named with both targets"
  assert_contains "$out" "created .pi/agent/keybindings.json (file)" "a file copied into the home is reported"
  pass "a relink into the worktree and a copied file are reported"
}

test_changed_removed_and_created_link_are_reported() {
  local out
  make_world changes
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  printf '{"a":2}\n' >"$HOME_DIR/.pi/agent/settings.json"
  rm "$HOME_DIR/.pi/agent/extensions/stale.ts"
  ln -s "$TMP_ROOT/changes/live/harness/settings.json" "$HOME_DIR/.pi/agent/extensions/new.ts"
  out=$("$DIFF" report "$SNAP") || fail "report should succeed"
  assert_contains "$out" "changed .pi/agent/settings.json" "a rewritten file is reported"
  assert_contains "$out" "removed .pi/agent/extensions/stale.ts (file)" "a deleted file is reported"
  assert_contains "$out" "created .pi/agent/extensions/new.ts (link) -> $TMP_ROOT/changes/live/harness/settings.json" \
    "a new link is reported with its target"
  assert_not_contains "$out" "worktree)" "a link outside the worktree is not attributed to it"
  pass "changed, removed, and newly linked entries are reported"
}

test_file_replaced_by_link_is_retyped() {
  local out
  make_world retype
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  rm "$HOME_DIR/.pi/agent/settings.json"
  ln -s "$WORKTREE/harness/settings.json" "$HOME_DIR/.pi/agent/settings.json"
  out=$("$DIFF" report "$SNAP") || fail "report should succeed"
  assert_equals ".pi/agent/settings.json: file -> link (into the task's worktree)" "${out#retyped }" \
    "a file replaced by a link is reported once as retyped"
  pass "a file replaced by a link is reported as retyped"
}

test_session_churn_is_not_reported() {
  local out
  make_world churn
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  printf 'more\n' >>"$HOME_DIR/.claude/projects/p/one.jsonl"
  printf 'new\n' >"$HOME_DIR/.claude/projects/p/two.jsonl"
  printf 's\n' >"$HOME_DIR/.pi/agent/sessions/s.jsonl"
  printf 'h\n' >"$HOME_DIR/.claude/history.jsonl"
  printf 'l\n' >"$HOME_DIR/.pi/agent/bridge.log"
  out=$("$DIFF" report "$SNAP") || fail "report should succeed"
  assert_equals "" "$out" "transcripts, history, and logs are not configuration writes"
  pass "session churn is not reported"
}

test_both_modes_leave_the_home_untouched() {
  local before after
  make_world readonly
  before=$(home_listing "$HOME_DIR")
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  after=$(home_listing "$HOME_DIR")
  assert_equals "$before" "$after" "snapshot writes nothing in the home"
  ln -sfn "$WORKTREE/harness/settings.json" "$HOME_DIR/.claude/settings.json"
  before=$(home_listing "$HOME_DIR")
  "$DIFF" report "$SNAP" >/dev/null || fail "report should succeed"
  after=$(home_listing "$HOME_DIR")
  assert_equals "$before" "$after" "report reverts and writes nothing in the home"
  pass "snapshot and report never write the home"
}

test_report_reads_the_home_recorded_at_spawn() {
  local out
  make_world recorded
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "snapshot should succeed"
  printf '{}\n' >"$HOME_DIR/.pi/agent/keybindings.json"
  out=$(HOME="$TMP_ROOT/elsewhere" "$DIFF" report "$SNAP") || fail "report should succeed"
  assert_contains "$out" "created .pi/agent/keybindings.json (file)" "the report compares the home named in the snapshot"
  pass "the report reads the home recorded at spawn"
}

test_missing_or_foreign_snapshot_is_refused() {
  local code
  "$DIFF" report "$TMP_ROOT/absent" >/dev/null 2>&1; code=$?
  expect_code 1 "$code" "a missing snapshot"
  printf 'not a snapshot\n' >"$TMP_ROOT/foreign"
  "$DIFF" report "$TMP_ROOT/foreign" >/dev/null 2>&1; code=$?
  expect_code 1 "$code" "a file that is not a snapshot"
  pass "a missing or foreign snapshot is refused"
}

test_spawn_records_the_home_before_launch() {  # <label> <id> <fm-spawn args...>
  local label=$1 id=$2 case_dir home proj wt fakebin out status snap
  shift 2
  case_dir="$TMP_ROOT/spawn-$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$home/user-home/.claude" "$case_dir/live"
  ln -s "$case_dir/live/settings.json" "$home/user-home/.claude/settings.json"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@")
  status=$?
  expect_code 0 "$status" "$label spawn should succeed: $out"
  snap="$home/state/$id.home-snapshot"
  assert_present "$snap" "$label spawn recorded no home snapshot"
  assert_grep "home=$home/user-home" "$snap" "$label snapshot does not name the spawn's home"
  assert_grep "worktree=$wt" "$snap" "$label snapshot does not name the task's worktree"
  assert_grep ".claude/settings.json	$case_dir/live/settings.json" "$snap" \
    "$label snapshot does not hold the home's links as they were at spawn"
  assert_equals "" "$("$DIFF" report "$snap")" "$label spawn itself changed the recorded home"
  pass "a $label spawn records the home's state before its worker launches"
}

test_untouched_home_reports_nothing
test_relink_into_worktree_and_copied_file_are_reported
test_changed_removed_and_created_link_are_reported
test_file_replaced_by_link_is_retyped
test_session_churn_is_not_reported
test_both_modes_leave_the_home_untouched
test_report_reads_the_home_recorded_at_spawn
AUTH_BEFORE='{"openai":{"type":"oauth","access":"TOKEN-V1","refresh":"TOKEN-R1","expires":111,"clientId":"cid","scopes":["a"]},"opencode-go":{"type":"api_key","key":"SECRET-V1"}}'

# Oracle: only the OAuth token fields were rewritten, so this is a renewal.
# Rejects a value-based comparison that flags every token rewrite.
auth_rewrite_report() {  # <name> <before-json> <after-json> sets AUTH_OUT
  local name=$1
  make_world "$name"
  printf '%s' "$2" >"$HOME_DIR/.pi/agent/auth.json"
  fm_touch_epoch 1700000000 "$HOME_DIR/.pi/agent/auth.json"
  HOME=$HOME_DIR "$DIFF" snapshot "$SNAP" "$WORKTREE" || fail "$name: snapshot should succeed"
  printf '%s' "$3" >"$HOME_DIR/.pi/agent/auth.json"
  AUTH_OUT=$("$DIFF" report "$SNAP") || fail "$name: report should succeed"
}

test_auth_token_renewal_is_routine() {
  auth_rewrite_report auth-renewal "$AUTH_BEFORE" '{"openai":{"type":"oauth","access":"TOKEN-V2-LONGER","refresh":"TOKEN-R2-LONGER","expires":999999,"clientId":"cid","scopes":["a"]},"opencode-go":{"type":"api_key","key":"SECRET-V1"}}'
  assert_equals "routine .pi/agent/auth.json (sign-in token renewal)" "$AUTH_OUT" "rewritten token fields are a routine renewal, not a change to review"
  assert_not_contains "$AUTH_OUT" "TOKEN" "the report prints no token value"
  assert_not_contains "$AUTH_OUT" "SECRET" "the report prints no secret value"
  assert_not_contains "$(cat "$SNAP")" "TOKEN" "the snapshot stores no token value"
  assert_not_contains "$(cat "$SNAP")" "SECRET" "the snapshot stores no secret value"
  pass "a sign-in token renewal is routine"
}

test_auth_added_entry_is_flagged() {
  auth_rewrite_report auth-added "$AUTH_BEFORE" '{"openai":{"type":"oauth","access":"TOKEN-V1","refresh":"TOKEN-R1","expires":111,"clientId":"cid","scopes":["a"]},"opencode-go":{"type":"api_key","key":"SECRET-V1"},"newp":{"type":"api_key","key":"SECRET-9"}}'
  assert_contains "$AUTH_OUT" "changed .pi/agent/auth.json" "an added provider entry is still flagged"
  pass "an added provider entry is flagged"
}

test_auth_removed_entry_is_flagged() {
  auth_rewrite_report auth-removed "$AUTH_BEFORE" '{"openai":{"type":"oauth","access":"TOKEN-V1","refresh":"TOKEN-R1","expires":111,"clientId":"cid","scopes":["a"]}}'
  assert_contains "$AUTH_OUT" "changed .pi/agent/auth.json" "a removed provider entry is still flagged"
  pass "a removed provider entry is flagged"
}

test_auth_retyped_entry_is_flagged() {
  auth_rewrite_report auth-retyped "$AUTH_BEFORE" '{"openai":{"type":"api_key","key":"SECRET-9"},"opencode-go":{"type":"api_key","key":"SECRET-V1"}}'
  assert_contains "$AUTH_OUT" "changed .pi/agent/auth.json" "a retyped provider entry is still flagged"
  pass "a retyped provider entry is flagged"
}

test_auth_api_key_change_is_flagged() {
  auth_rewrite_report auth-apikey "$AUTH_BEFORE" '{"openai":{"type":"oauth","access":"TOKEN-V1","refresh":"TOKEN-R1","expires":111,"clientId":"cid","scopes":["a"]},"opencode-go":{"type":"api_key","key":"SECRET-V2"}}'
  assert_contains "$AUTH_OUT" "changed .pi/agent/auth.json" "an api_key value change is still flagged"
  pass "an api_key value change is flagged"
}

test_auth_token_renewal_is_routine
test_auth_added_entry_is_flagged
test_auth_removed_entry_is_flagged
test_auth_retyped_entry_is_flagged
test_auth_api_key_change_is_flagged
test_missing_or_foreign_snapshot_is_refused
test_spawn_records_the_home_before_launch ship home-ship-a1 --mode local-only --yolo off
test_spawn_records_the_home_before_launch scout home-scout-a1 --scout
