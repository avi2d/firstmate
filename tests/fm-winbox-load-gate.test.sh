#!/usr/bin/env bash
# Behavior tests for the winbox load gate at night: a heavy start waits while the
# average is high or six heavy workers already run across both homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-winbox-load-gate)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the heavy suite for $2.

## Firstmate spec
Exercise the winbox load gate.

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
  make_home "$case_dir/home-a" "$@"
  make_home "$case_dir/home-b"
  printf '%s\n' "$case_dir/home-b" > "$case_dir/home-a/config/winbox-load-siblings"
  printf '%s\n' "$case_dir/home-a" > "$case_dir/home-b/config/winbox-load-siblings"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

write_live() {  # <home> <id> <project-dir> [extra...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn_load() {  # <load> <case-dir> <home> <pane> <args...>
  local load=$1 case_dir=$2 home=$3 pane=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_MAC_LOAD_GATE_FORCE=0 FM_WINBOX_LOAD_GATE_FORCE=1 \
    FM_MAC_LOAD_MOCK_5MIN="$load" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship_load() {  # <load> <case-dir> <id> [pane]
  local load=$1 case_dir=$2 id=$3 pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn_load "$load" "$case_dir" "$case_dir/home-a" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
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
test_six_across_two_homes_defer_a_seventh_then_release_admits() {
  local case_dir home_a out rc=0 before worktrees
  case_dir=$(make_case six task-c)
  home_a="$case_dir/home-a"
  printf '%s\n' "$case_dir/home-a" >> "$home_a/config/winbox-load-siblings"
  write_live "$home_a" live-a1 "$case_dir/project"
  write_live "$home_a" live-a2 "$case_dir/project"
  write_live "$home_a" live-a3 "$case_dir/project"
  write_live "$case_dir/home-b" live-b1 "$case_dir/project"
  write_live "$case_dir/home-b" live-b2 "$case_dir/project"
  write_live "$case_dir/home-b" live-b3 "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a seventh heavy worker was not deferred: $out"
  assert_contains "$out" "6 heavy worker(s) already run on this machine (limit 6" "the deferral did not name the shared count and the limit"
  assert_nothing_created "$case_dir" "$home_a" task-c "$before" "$worktrees"
  printf 'pr=%s\n' "https://example.invalid/o/r/pull/1" >> "$case_dir/home-b/state/live-b3.meta"
  rc=0
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after a handoff freed a place: $out"
  assert_contains "$out" "spawned task-c" "the released spawn did not launch"
  pass "six heavy workers across two homes defer a seventh, and a handoff admits it again"
}
test_load_sixteen_defers_then_clear_admits() {
  local case_dir home_a out rc=0 before worktrees
  case_dir=$(make_case hot task-c)
  home_a="$case_dir/home-a"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship_load 16.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn at a five-minute average of 16 was not deferred: $out"
  assert_contains "$out" "five-minute load average is 16.0 (limit 16)" "the deferral did not name the average and the limit"
  assert_nothing_created "$case_dir" "$home_a" task-c "$before" "$worktrees"
  rc=0
  out=$(spawn_ship_load 15.9 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after the average cleared: $out"
  assert_contains "$out" "spawned task-c" "the cleared spawn did not launch"
  pass "a five-minute average of 16 defers a heavy start, and the same start launches once it clears"
}

test_handed_off_and_secondmate_records_do_not_count() {
  local case_dir home_a out rc=0
  case_dir=$(make_case holders task-c)
  home_a="$case_dir/home-a"
  write_live "$home_a" live-a1 "$case_dir/project"
  write_live "$home_a" live-a2 "$case_dir/project"
  write_live "$case_dir/home-b" live-b1 "$case_dir/project"
  write_live "$case_dir/home-b" live-b2 "$case_dir/project"
  write_live "$case_dir/home-b" handed "$case_dir/project" "pr=https://example.invalid/o/r/pull/2"
  fm_write_meta "$case_dir/home-b/state/mate-x.meta" "kind=secondmate" "project=$case_dir/project"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a handed-off or secondmate record counted as a heavy worker: $out"
  assert_contains "$out" "spawned task-c" "the spawn did not launch"
  pass "handed-off and secondmate records hold no heavy-worker place across homes"
}
test_malformed_sibling_refuses() {
  local case_dir home_a out rc=0
  case_dir=$(make_case malformed task-c)
  home_a="$case_dir/home-a"
  printf '%s\n' "relative/home" > "$home_a/config/winbox-load-siblings"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a relative sibling entry did not refuse the spawn: $out"
  assert_contains "$out" "not an absolute path" "the refusal did not say the sibling entry was not absolute"
  assert_absent "$home_a/state/task-c.meta" "the refused spawn published a record"
  pass "a malformed sibling entry refuses a heavy start rather than undercounting"
}

test_six_across_two_homes_defer_a_seventh_then_release_admits
test_load_sixteen_defers_then_clear_admits
test_handed_off_and_secondmate_records_do_not_count
test_malformed_sibling_refuses
