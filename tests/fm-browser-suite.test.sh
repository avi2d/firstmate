#!/usr/bin/env bash
# A browser-suite worker always starts heavy, and browser-suite starts are staggered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-suite)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

write_brief() {  # <home> <id> [extra-spec-line]
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the suite for $2.

## Firstmate spec
Exercise the browser-suite admission.
${3:-}

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
TOML
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  new-window)
    name= previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    ;;
  list-windows)
    [ ! -s "$window_file" ] || cat "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes claude codex opencode grok gemini
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <usage> <weight> <case-dir> <pane> <now> <args...>
  local usage=$1 weight=$2 case_dir=$3 pane=$4 now=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_MAC_LOAD_MOCK_5MIN=1.0 \
    FM_MAC_CORE_BUDGET_FORCE=1 \
    FM_CORE_BUDGET_MOCK_USAGE="$usage" \
    FM_BROWSER_SUITE_MOCK_NOW="$now" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" --weight "$weight" 2>&1
}

spawn_ship() {  # <case-dir> <id> <now> [weight] [usage] [pane]
  local case_dir=$1 id=$2 now=$3 weight=${4:-heavy} usage=${5:-1.0} pane=${6:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  rm -f "$case_dir/fakebin/.spawn-window"
  run_spawn "$usage" "$weight" "$case_dir" "$pane" "$now" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

declare_browser_suites() {  # <case-dir> <line...>
  local case_dir=$1
  shift
  printf '%s\n' "$@" > "$case_dir/home/config/browser-suites"
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }
worktree_list() { git -C "$1/project" worktree list --porcelain; }

assert_nothing_created() {  # <case-dir> <home> <id> <calls> <worktrees>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] || fail "a deferred spawn touched the terminal or worktree pool for $id"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] || fail "a deferred spawn moved $id out of queued"
  fi
}

NOW=1792703200

test_listed_project_browser_suite_light_start_still_counted_heavy() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case listed task-b task-plain)
  home="$case_dir/home"
  out=$(spawn_ship "$case_dir" task-plain "$NOW" light 8.0) || rc=$?
  expect_code 0 "$rc" "a light start with no browser suite was held over budget, so the case proves nothing: $out"
  rm -f "$home/state/task-plain.meta"
  declare_browser_suites "$case_dir" project
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  rc=0
  out=$(spawn_ship "$case_dir" task-b "$NOW" light 8.0 "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a light start on a listed browser-suite project skipped the heavy budget: $out"
  assert_contains "$out" "starts heavy despite --weight light" "the spawn did not say why the light weight was overridden"
  assert_contains "$out" "trailing-hour CPU use is 8.0 core-hours" "the heavy budget did not hold the browser-suite start"
  assert_nothing_created "$case_dir" "$home" task-b "$before" "$worktrees"
  pass "a light start on a listed browser-suite project is still counted heavy"
}

test_brief_marked_browser_suite_light_start_still_counted_heavy() {
  local case_dir home out rc=0
  case_dir=$(make_case marked)
  home="$case_dir/home"
  write_brief "$home" task-b "Browser suite: yes"
  add_item "$home" task-b
  out=$(spawn_ship "$case_dir" task-b "$NOW" light 8.0 "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a light start whose brief marks a browser suite skipped the heavy budget: $out"
  assert_contains "$out" "trailing-hour CPU use is 8.0 core-hours" "the heavy budget did not hold the brief-marked start"
  pass "a light start whose brief marks a browser suite is still counted heavy"
}

test_second_browser_suite_start_inside_gap_deferred_not_launched_at_once() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case gap)
  home="$case_dir/home"
  declare_browser_suites "$case_dir" '@stagger-minutes 10'
  write_brief "$home" task-a "Browser suite: yes"
  add_item "$home" task-a
  write_brief "$home" task-b "Browser suite: yes"
  add_item "$home" task-b
  out=$(spawn_ship "$case_dir" task-a "$NOW") || rc=$?
  expect_code 0 "$rc" "the first browser-suite start was refused: $out"
  assert_contains "$out" "spawned task-a" "the first browser-suite start did not launch"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-b "$((NOW + 599))" heavy 1.0 "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a second browser-suite start inside the gap launched at once: $out"
  assert_contains "$out" "10-minute stagger gap" "the deferral did not name the gap"
  assert_contains "$out" "dispatch it again in 1 minute(s)" "the deferral did not say when to retry"
  assert_nothing_created "$case_dir" "$home" task-b "$before" "$worktrees"
  rc=0
  out=$(spawn_ship "$case_dir" task-b "$((NOW + 600))") || rc=$?
  expect_code 0 "$rc" "a browser-suite start once the gap passed was still deferred: $out"
  assert_contains "$out" "spawned task-b" "the browser-suite start after the gap did not launch"
  pass "a second browser-suite start inside the stagger gap waits, and launches once the gap passes"
}

test_non_browser_task_not_delayed_by_stagger() {
  local case_dir home out rc=0
  case_dir=$(make_case other task-plain)
  home="$case_dir/home"
  declare_browser_suites "$case_dir" '@stagger-minutes 10'
  write_brief "$home" task-a "Browser suite: yes"
  add_item "$home" task-a
  out=$(spawn_ship "$case_dir" task-a "$NOW") || rc=$?
  expect_code 0 "$rc" "the browser-suite start was refused: $out"
  out=$(spawn_ship "$case_dir" task-plain "$((NOW + 1))") || rc=$?
  expect_code 0 "$rc" "a task with no browser suite was delayed by the stagger: $out"
  assert_contains "$out" "spawned task-plain" "the task with no browser suite did not launch"
  pass "a task with no browser suite starts inside the stagger gap"
}

test_malformed_declaration_refuses() {
  local case_dir home out rc=0
  case_dir=$(make_case malformed task-c)
  home="$case_dir/home"
  declare_browser_suites "$case_dir" '@stagger-minutes soon'
  out=$(spawn_ship "$case_dir" task-c "$NOW" heavy 1.0 "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a malformed stagger did not refuse the spawn: $out"
  assert_contains "$out" "browser-suite declaration is unreadable" "the refusal did not name the declaration"
  assert_absent "$home/state/task-c.meta" "the refused spawn published a record"
  declare_browser_suites "$case_dir" '@stagger-minutes 5' '@stagger-minutes 5'
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$NOW" heavy 1.0 "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a duplicated stagger did not refuse the spawn: $out"
  pass "a malformed browser-suite declaration refuses rather than guessing the gap"
}

test_listed_project_browser_suite_light_start_still_counted_heavy
test_brief_marked_browser_suite_light_start_still_counted_heavy
test_second_browser_suite_start_inside_gap_deferred_not_launched_at_once
test_non_browser_task_not_delayed_by_stagger
test_malformed_declaration_refuses
