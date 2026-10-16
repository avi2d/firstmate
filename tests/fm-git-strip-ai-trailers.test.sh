#!/usr/bin/env bash
# Behavior tests for the spawn-owned AI commit-trailer strip.
#
# Cursor injects Co-Authored-By after the typed message, so these cases assert
# the commit OBJECT, never the string passed to -m. The strip is the public
# interface; tests drive git commit through the installed hooksPath the same
# way a fleet-launched pane does.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-strip-ai-trailers)

fm_git_identity 'Captain Tests' 'captain@example.invalid'

export GIT_CONFIG_GLOBAL="$TMP_ROOT/fixture-gitconfig"
{ echo '[user]'; echo 'name = Captain Tests'; echo 'email = captain@example.invalid'; } > "$GIT_CONFIG_GLOBAL"

with_hooks_env() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

make_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
}

test_cursor_trailer_does_not_reach_the_commit_object() {
  local repo hooks body author
  repo="$TMP_ROOT/cursor-object"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-cursor"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed on a real git repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: keep the typed message clean'
  body=$(git -C "$repo" log -1 --format=%B)
  author=$(git -C "$repo" log -1 --format='%an <%ae>')
  assert_not_contains "$body" "Co-authored-by: Cursor" "Cursor trailer reached the commit object"
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor email reached the commit object"
  assert_contains "$body" "fix: keep the typed message clean" "subject was rewritten"
  [ "$author" = "Captain Tests <captain@example.invalid>" ] || fail "author was rewritten: $author"
  pass "a Cursor --trailer commit object has no AI co-author and keeps the captain identity"
}


test_human_coauthor_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/human-coauthor"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: mixed trailers'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "Cursor" "Cursor trailer was not stripped from a mixed message"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@example.com>" "human co-author was stripped"
  pass "a human Co-authored-by trailer survives next to a stripped Cursor trailer"
}

test_human_at_a_vendor_domain_is_kept() {
  local repo hooks body
  repo="$TMP_ROOT/vendor-human"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-vendor-human"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q \
    --trailer 'Co-authored-by: Claude <noreply@anthropic.com>' \
    --trailer 'Co-authored-by: Jane Doe <jane@anthropic.com>' \
    --trailer 'Co-authored-by: Sam Roe <sam@cursor.com>' -m 'fix: vendor staff co-authors'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "noreply@anthropic.com" "the Claude bot trailer reached the commit object"
  assert_contains "$body" "Co-authored-by: Jane Doe <jane@anthropic.com>" "a human at a vendor domain was stripped"
  assert_contains "$body" "Co-authored-by: Sam Roe <sam@cursor.com>" "a human at a vendor domain was stripped"
  pass "a human co-author at a vendor domain survives; only the exact bot address is stripped"
}

test_hook_manager_cannot_displace_the_strip() {
  local repo hooks target body
  if [ "$(id -u)" = 0 ]; then
    pass "a hook manager cannot displace the strip (skipped as root)"
    return 0
  fi
  repo="$TMP_ROOT/hook-manager"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-manager"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  target=$(with_hooks_env "$hooks" git -C "$repo" rev-parse --path-format=absolute --git-path hooks)
  [ "$target" = "$hooks" ] || fail "a hook manager in the pane would resolve $target, not the strip dir $hooks"
  mv "$target/commit-msg" "$target/commit-msg.old" 2>/dev/null &&
    fail "a hook manager could rename the strip's commit-msg aside"
  (printf '#!/bin/sh\nexit 0\n' >"$target/commit-msg") 2>/dev/null &&
    fail "a hook manager could overwrite the strip's commit-msg"
  (printf '#!/bin/sh\nexit 0\n' >"$target/post-update") 2>/dev/null &&
    fail "a hook manager could add a hook to the strip dir"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after a manager tried'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived a hook manager's install attempt"
  pass "a hook manager resolving the pane hooks dir fails instead of displacing the strip"
}

test_reinstall_replaces_a_read_only_install() {
  local repo hooks body
  repo="$TMP_ROOT/reinstall"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-reinstall"
  "$STRIP" install "$hooks" "$repo" || fail "first install should succeed"
  "$STRIP" install "$hooks" "$repo" || fail "a relaunch reinstall over the read-only install failed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: after reinstall'
  body=$(git -C "$repo" log -1 --format=%B)
  assert_not_contains "$body" "cursoragent@cursor.com" "Cursor trailer survived after a reinstall"
  pass "a relaunch reinstall replaces the read-only strip dir and still strips"
}

test_previous_commit_msg_hook_still_runs() {
  local repo orig hooks
  repo="$TMP_ROOT/chain-hook"
  make_repo "$repo"
  orig=$(git -C "$repo" rev-parse --git-path hooks)
  case "$orig" in
  /*) ;;
  *) orig="$repo/$orig" ;;
  esac
  mkdir -p "$orig"
  cat >"$orig/commit-msg" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' > "$(dirname "$1")/orig-commit-msg.ran"
exit 0
SH
  chmod 700 "$orig/commit-msg"
  hooks="$TMP_ROOT/hooks-chain"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: chain'
  [ -f "$repo/.git/orig-commit-msg.ran" ] || fail "the worktree's previous commit-msg hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived even though the previous hook ran"
  pass "install chains the previous commit-msg hook after stripping"
}

write_marker_hook() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' > "\$PWD/$2.ran"
exit 0
SH
  chmod 700 "$1"
}

test_relative_project_hookspath_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/husky-relative"
  make_repo "$repo"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" husky-pre-commit
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-husky"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with a relative core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: husky relative'
  [ -f "$repo/husky-pre-commit.ran" ] || fail "the project's relative-hooksPath pre-commit hook did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a relative-hooksPath install"
  pass "a relative project core.hooksPath resolves against the worktree and still runs"
}

test_inherited_hookspath_env_does_not_decide_the_chain() {
  local repo hooks parent
  repo="$TMP_ROOT/nested-spawn"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" project-pre-commit
  parent="$TMP_ROOT/parent-hooks"
  mkdir -p "$parent"
  write_marker_hook "$parent/pre-commit" parent-pre-commit
  hooks="$TMP_ROOT/hooks-nested"
  with_hooks_env "$parent" "$STRIP" install "$hooks" "$repo" ||
    fail "install should succeed with an inherited GIT_CONFIG hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: nested spawn'
  [ -f "$repo/project-pre-commit.ran" ] || fail "the project's own pre-commit hook was not chained"
  [ -f "$repo/parent-pre-commit.ran" ] && fail "a parent spawn's hooks were chained into this worktree"
  pass "an inherited GIT_CONFIG hooksPath does not become the chained previous hooks"
}

test_project_hook_generated_after_install_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/late-husky"
  make_repo "$repo"
  git -C "$repo" config core.hooksPath .husky/_
  hooks="$TMP_ROOT/hooks-late"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the project's hooks exist"
  mkdir -p "$repo/.husky/_"
  write_marker_hook "$repo/.husky/_/pre-commit" late-pre-commit
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: late husky'
  [ -f "$repo/late-pre-commit.ran" ] || fail "a project hook generated after the spawn did not run"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a late-generated project hooks directory"
  pass "a project hook that appears after install still runs for the rest of the task"
}

test_pane_hookspath_does_not_reroute_another_repository() {
  local repo other hooks
  repo="$TMP_ROOT/task-wt"
  other="$TMP_ROOT/other-repo"
  make_repo "$repo"
  make_repo "$other"
  write_marker_hook "$other/.git/hooks/pre-commit" other-pre-commit
  write_marker_hook "$repo/.git/hooks/pre-commit" task-pre-commit
  hooks="$TMP_ROOT/hooks-pane"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$other/README.md"
  git -C "$other" add README.md
  with_hooks_env "$hooks" git -C "$other" commit -q -m 'fix: other repo'
  [ -f "$other/other-pre-commit.ran" ] || fail "the other repository's own pre-commit hook did not run"
  [ -f "$other/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran inside another repository"
  [ -f "$repo/task-pre-commit.ran" ] && fail "the task worktree's pre-commit ran while committing elsewhere"
  pass "a pane GIT_CONFIG hooksPath still chains the repository git is actually in"
}

test_empty_project_hookspath_runs_no_repository_hook() {
  local repo hooks err
  repo="$TMP_ROOT/empty-hookspath"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" default-pre-commit
  git -C "$repo" config core.hooksPath ''
  hooks="$TMP_ROOT/hooks-empty"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an empty core.hooksPath"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: empty hooksPath' 2>&1) ||
    fail "a commit in a repo with an empty core.hooksPath was refused: $err"
  assert_equals "" "$err" "an empty core.hooksPath commit printed errors"
  [ -f "$repo/default-pre-commit.ran" ] && fail "a repository hook ran although core.hooksPath is empty"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived an empty-hooksPath commit"
  pass "an empty project core.hooksPath runs no repository hook and still strips the trailer"
}

test_unresolvable_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/unresolvable-hookspath"
  make_repo "$repo"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" config core.hooksPath '~fm-no-such-user-6171/hooks'
  hooks="$TMP_ROOT/hooks-unresolvable"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed with an unresolvable core.hooksPath"
  head=$(git -C "$repo" rev-parse HEAD)
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: unresolvable hooksPath' 2>&1) &&
    fail "a commit succeeded although the repository's hooks directory cannot be resolved"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c 'failed to expand user dir')" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "an unresolvable project core.hooksPath still refuses the commit"
}

test_valueless_project_hookspath_still_refuses() {
  local repo hooks head err
  repo="$TMP_ROOT/valueless-hookspath"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-valueless"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed before the valueless key is written"
  head=$(git -C "$repo" rev-parse HEAD)
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  printf '[core]\n\thooksPath\n' >>"$repo/.git/config"
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: valueless hooksPath' 2>&1) &&
    fail "a commit succeeded although core.hooksPath has no value"
  assert_contains "$err" "refusing to skip its pre-commit hook" "the refusal did not name the skipped hook"
  assert_equals 1 "$(printf '%s\n' "$err" | grep -c "missing value for 'core.hookspath'")" "git's lookup error was not shown exactly once"
  assert_equals "$head" "$(git -C "$repo" -c core.hooksPath=x rev-parse HEAD)" "a refused commit still moved HEAD"
  pass "a valueless project core.hooksPath still refuses the commit"
}

write_refusing_pre_push() {  # <path> <marker>
  cat >"$1" <<SH
#!/usr/bin/env bash
printf 'ran\n' >> "$2"
exit 1
SH
  chmod 700 "$1"
}

# A publish guard installed as the repository's pre-push must run however the
# pane's hooksPath reaches git: the pane export, git -c (GIT_CONFIG_PARAMETERS),
# or a child process that inherits either one.
test_repository_pre_push_runs_on_every_override_channel() {
  local repo remote hooks marker label child_push
  # shellcheck disable=SC2016 # the child shell expands its own positional args
  child_push='git -C "$1" push -q origin "HEAD:refs/heads/$2"'
  repo="$TMP_ROOT/guarded-push"
  remote="$TMP_ROOT/guarded-remote.git"
  make_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  marker="$TMP_ROOT/guarded-push.pre-push"
  write_refusing_pre_push "$repo/.git/hooks/pre-push" "$marker"
  hooks="$TMP_ROOT/hooks-guarded"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  git -C "$repo" commit -q --amend --no-edit --author='Captain Tests <captain@example.invalid>' || fail "fixture amend should succeed"
  for label in env param env+param child-env child-param; do
    rm -f "$marker"
    case "$label" in
    env) with_hooks_env "$hooks" git -C "$repo" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    param) git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    env+param) with_hooks_env "$hooks" git -C "$repo" -c core.hooksPath="$hooks" push -q origin "HEAD:refs/heads/$label" 2>/dev/null ;;
    child-env) with_hooks_env "$hooks" sh -c "$child_push" _ "$repo" "$label" 2>/dev/null ;;
    child-param) git -C "$repo" -c core.hooksPath="$hooks" -c "alias.guarded-push=!git push -q origin HEAD:refs/heads/$label" guarded-push 2>/dev/null ;;
    esac && fail "push via $label succeeded past the repository's refusing pre-push hook"
    [ -f "$marker" ] || fail "the repository's pre-push hook did not run via $label"
    git -C "$remote" rev-parse -q --verify "refs/heads/$label" >/dev/null &&
      fail "push via $label reached the remote despite the refusing pre-push hook"
  done
  pass "the repository's pre-push runs and can refuse under every hooksPath override channel"
}

test_git_c_override_still_strips_and_chains_commit_hooks() {
  local repo hooks
  repo="$TMP_ROOT/param-commit"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" param-pre-commit
  hooks="$TMP_ROOT/hooks-param-commit"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  printf 'note\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c core.hooksPath="$hooks" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: git -c override'
  [ -f "$repo/param-pre-commit.ran" ] || fail "the project's pre-commit hook did not run under git -c core.hooksPath"
  assert_not_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" \
    "Cursor trailer survived a git -c core.hooksPath commit"
  pass "a git -c hooksPath override still strips the trailer and chains the project's hooks"
}

test_strip_msgfile_alone_does_not_rewrite_author_fields() {
  local msg
  msg="$TMP_ROOT/msg.txt"
  printf '%s\n' 'fix: subject' '' 'Co-authored-by: Cursor <cursoragent@cursor.com>' >"$msg"
  "$STRIP" "$msg" || fail "strip should succeed"
  assert_not_contains "$(cat "$msg")" "Cursor" "strip left the Cursor trailer in the file"
  assert_contains "$(cat "$msg")" "fix: subject" "strip dropped the subject"
  pass "commit-msg file mode strips the trailer and keeps the subject"
}

test_guard_commit_allows_same_value_c_override() {
  local repo hooks
  repo="$TMP_ROOT/guard-same-value"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-same-value"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" -c user.name='Captain Tests' -c user.email='captain@example.invalid' commit -q -m 'fix: same-value override' || fail "a same-value -c override was refused"
  [ "$(git -C "$repo" log -1 --format='%an <%ae>')" = "Captain Tests <captain@example.invalid>" ] || fail "the author was rewritten"
  pass "a -c override matching the configured identity is allowed"
}

test_guard_commit_allows_amend_without_edit() {
  local repo hooks
  repo="$TMP_ROOT/guard-amend"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-amend"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: amend me' || fail "a configured-identity commit was refused"
  with_hooks_env "$hooks" git -C "$repo" commit -q --amend --no-edit || fail "an amend keeping the configured identity was refused"
  pass "an amend that keeps the configured identity is allowed"
}

test_guard_commit_refuses_c_identity_override() {
  local repo hooks err head
  repo="$TMP_ROOT/guard-c-override"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-c"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  head=$(git -C "$repo" rev-parse HEAD)
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git -C "$repo" -c user.name=firstmate -c user.email=invented@example.com commit -m 'fix: foreign -c identity' 2>&1) &&
    fail "a -c identity override commit succeeded"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "invented@example.com" "the refusal printed the foreign email"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit moved HEAD"
  pass "a -c user.name and user.email override is refused at commit time"
}

test_guard_commit_refuses_author_flag() {
  local repo hooks err head
  repo="$TMP_ROOT/guard-author-flag"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-author-flag"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  head=$(git -C "$repo" rev-parse HEAD)
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" git -C "$repo" commit -m 'fix: foreign author' --author='Sneaky <sneaky@example.com>' 2>&1) &&
    fail "a --author override commit succeeded"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "sneaky@example.com" "the refusal printed the foreign email"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit moved HEAD"
  pass "a --author override is refused at commit time"
}

test_guard_commit_refuses_author_env_override() {
  local repo hooks err head
  repo="$TMP_ROOT/guard-author-env"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-author-env"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  head=$(git -C "$repo" rev-parse HEAD)
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" env GIT_AUTHOR_NAME='Env Evil' GIT_AUTHOR_EMAIL=env-evil@example.com git -C "$repo" commit -m 'fix: env author' 2>&1) &&
    fail "a GIT_AUTHOR_* override commit succeeded"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "env-evil@example.com" "the refusal printed the foreign email"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit moved HEAD"
  pass "a GIT_AUTHOR_* override is refused at commit time"
}

test_guard_commit_refuses_committer_env_override() {
  local repo hooks err head
  repo="$TMP_ROOT/guard-committer-env"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-committer-env"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  head=$(git -C "$repo" rev-parse HEAD)
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(with_hooks_env "$hooks" env GIT_COMMITTER_NAME='Env Evil' GIT_COMMITTER_EMAIL=env-evil@example.com git -C "$repo" commit -m 'fix: env committer' 2>&1) &&
    fail "a GIT_COMMITTER_* override commit succeeded"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "env-evil@example.com" "the refusal printed the foreign email"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused commit moved HEAD"
  pass "a GIT_COMMITTER_* override is refused at commit time"
}

test_guard_commit_allows_auto_derived_identity_but_refuses_override() {
  local repo hooks err empty
  repo="$TMP_ROOT/guard-auto-derived"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-auto-derived"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  empty="$TMP_ROOT/empty-home"
  mkdir -p "$empty"
  echo change >>"$repo/README.md"
  git -C "$repo" add README.md
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_CONFIG_GLOBAL HOME="$empty" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" git -C "$repo" commit -q -m 'fix: auto-derived' || fail "a commit with the auto-derived machine identity was refused"
  echo more >>"$repo/README.md"
  git -C "$repo" add README.md
  err=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u GIT_CONFIG_GLOBAL HOME="$empty" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" git -C "$repo" -c user.name=firstmate -c user.email=invented@example.com commit -m 'fix: foreign with no base' 2>&1) &&
    fail "a foreign override succeeded with no configured identity"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "invented@example.com" "the refusal printed the foreign email"
  pass "an auto-derived machine identity is allowed and a foreign override is still refused"
}

test_guard_commit_refuses_when_identity_is_unreadable() {
  local repo hooks err broken head
  repo="$TMP_ROOT/guard-unreadable"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-unreadable"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  broken="$TMP_ROOT/broken-gitconfig"
  echo '[user' >"$broken"
  head=$(git -C "$repo" rev-parse HEAD)
  err=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL="$broken" GIT_CONFIG_NOSYSTEM=1 "$STRIP" guard-commit 2>&1) &&
    fail "guard-commit succeeded with an unreadable identity"
  assert_contains "$err" "git cannot resolve GIT_AUTHOR_IDENT here" "the refusal did not name the unresolvable identity"
  assert_equals "$head" "$(git -C "$repo" rev-parse HEAD)" "a refused guard-commit moved HEAD"
  pass "a commit with an unreadable identity is refused at commit time"
}

test_guard_push_refuses_a_smuggled_foreign_commit() {
  local repo remote hooks err
  repo="$TMP_ROOT/guard-smuggled"
  remote="$TMP_ROOT/guard-smuggled.git"
  make_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  hooks="$TMP_ROOT/hooks-guard-smuggled"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  git -C "$repo" commit -q --amend --no-edit --author='Captain Tests <captain@example.invalid>' || fail "fixture amend should succeed"
  echo clean >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -qm 'fix: clean history' || fail "a configured-identity commit was refused"
  with_hooks_env "$hooks" git -C "$repo" push -q origin "HEAD:refs/heads/main" || fail "a configured-identity push was refused"
  echo smuggled >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" env GIT_AUTHOR_NAME=Smuggled GIT_AUTHOR_EMAIL=smuggled@example.com git -C "$repo" commit -q --no-verify -m 'fix: smuggled' || fail "the fixture smuggle commit failed"
  err=$(with_hooks_env "$hooks" git -C "$repo" push origin "HEAD:refs/heads/sneaky" 2>&1) &&
    fail "a push carrying a foreign commit succeeded"
  assert_contains "$err" "differs from this machine's git config files" "the refusal did not name the configured identity as the reference"
  assert_not_contains "$err" "smuggled@example.com" "the refusal printed the foreign email"
  git -C "$remote" rev-parse -q --verify "refs/heads/sneaky" >/dev/null &&
    fail "the smuggled commit reached the remote"
  pass "a push carrying a foreign commit is refused before it reaches the remote"
}

test_guard_keep_trailers_install_keeps_trailers_and_guards_identity() {
  local repo hooks msg body err
  repo="$TMP_ROOT/guard-keep"
  make_repo "$repo"
  hooks="$TMP_ROOT/hooks-guard-keep"
  "$STRIP" install "$hooks" "$repo" --keep-trailers || fail "install --keep-trailers should succeed"
  msg="$TMP_ROOT/keep-msg.txt"
  echo 'fix: kept' >"$msg"
  echo >>"$msg"
  echo 'Co-authored-by: Cursor <cursoragent@cursor.com>' >>"$msg"
  (cd "$repo" && "$hooks/commit-msg" "$msg") || fail "the keep-trailers commit-msg hook failed"
  assert_contains "$(cat "$msg")" "Co-authored-by: Cursor" "keep-trailers stripped the trailer"
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' -m 'fix: kept trailer' || fail "a configured-identity commit was refused"
  body=$(git -C "$repo" log -1 --format=%B)
  assert_contains "$body" "Co-authored-by: Cursor" "keep-trailers stripped the trailer from the commit object"
  err=$(with_hooks_env "$hooks" env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL git -C "$repo" -c user.name=firstmate -c user.email=invented@example.com commit -m 'fix: foreign under keep' 2>&1) &&
    fail "a -c identity override succeeded under --keep-trailers"
  assert_contains "$err" "differs from this machine's git config files" "the keep-trailers refusal did not name the configured identity"
  assert_not_contains "$err" "invented@example.com" "the refusal printed the foreign email"
  pass "a --keep-trailers install keeps AI trailers and still guards the worker identity"
}

test_guard_project_pre_commit_still_runs() {
  local repo hooks
  repo="$TMP_ROOT/guard-chain"
  make_repo "$repo"
  write_marker_hook "$repo/.git/hooks/pre-commit" guard-chain-pre-commit
  hooks="$TMP_ROOT/hooks-guard-chain"
  "$STRIP" install "$hooks" "$repo" || fail "install should succeed"
  echo note >>"$repo/README.md"
  git -C "$repo" add README.md
  with_hooks_env "$hooks" git -C "$repo" commit -q -m 'fix: chained project hook' || fail "a configured-identity commit was refused"
  [ -f "$repo/guard-chain-pre-commit.ran" ] || fail "the project pre-commit hook did not run before the guard allowed the commit"
  pass "the project pre-commit hook runs and the configured commit is allowed"
}

test_guard_commit_allows_same_value_c_override
test_guard_commit_allows_amend_without_edit
test_guard_commit_refuses_c_identity_override
test_guard_commit_refuses_author_flag
test_guard_commit_refuses_author_env_override
test_guard_commit_refuses_committer_env_override
test_guard_commit_allows_auto_derived_identity_but_refuses_override
test_guard_commit_refuses_when_identity_is_unreadable
test_guard_push_refuses_a_smuggled_foreign_commit
test_guard_keep_trailers_install_keeps_trailers_and_guards_identity
test_guard_project_pre_commit_still_runs
test_cursor_trailer_does_not_reach_the_commit_object
test_human_coauthor_is_kept
test_human_at_a_vendor_domain_is_kept
test_hook_manager_cannot_displace_the_strip
test_reinstall_replaces_a_read_only_install
test_previous_commit_msg_hook_still_runs
test_relative_project_hookspath_still_runs
test_inherited_hookspath_env_does_not_decide_the_chain
test_project_hook_generated_after_install_still_runs
test_pane_hookspath_does_not_reroute_another_repository
test_empty_project_hookspath_runs_no_repository_hook
test_unresolvable_project_hookspath_still_refuses
test_valueless_project_hookspath_still_refuses
test_repository_pre_push_runs_on_every_override_channel
test_git_c_override_still_strips_and_chains_commit_hooks
test_strip_msgfile_alone_does_not_rewrite_author_fields

echo "# all fm-git-strip-ai-trailers tests passed"
