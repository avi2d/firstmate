#!/usr/bin/env bash
# Behavior tests for the Mac load gate: a heavy start waits while the
# five-minute average is high or four heavy workers already run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-mac-load-gate)
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
Exercise the Mac load gate.

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
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
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
    FM_MAC_LOAD_MOCK_5MIN="$load" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship_load() {  # <load> <case-dir> <id> [pane]
  local load=$1 case_dir=$2 id=$3 pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn_load "$load" "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
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

test_high_average_defers_then_clear_admits() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case hot task-c)
  home="$case_dir/home"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship_load 10.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn at a five-minute average of 10 was not deferred: $out"
  assert_contains "$out" "five-minute load average is 10.0 (limit 10)" "the deferral did not name the average and the limit"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  rc=0
  out=$(spawn_ship_load 9.9 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after the average cleared: $out"
  assert_contains "$out" "spawned task-c" "the cleared spawn did not launch"
  pass "a high five-minute average defers a heavy start, and the same start launches once it clears"
}

test_four_heavy_workers_defer_a_fifth_then_release_admits() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case full task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  write_live "$home" live-c "$case_dir/project"
  write_live "$home" live-d "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a fifth heavy worker was not deferred: $out"
  assert_contains "$out" "4 heavy worker(s) already run on this machine (limit 4" "the deferral did not name the count and the limit"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  printf 'pr=%s\n' "https://example.invalid/o/r/pull/1" >> "$home/state/live-a.meta"
  rc=0
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after a handoff freed a place: $out"
  assert_contains "$out" "spawned task-c" "the released spawn did not launch"
  pass "four heavy workers defer a fifth, and a handoff admits it again"
}

test_handed_off_and_secondmate_records_do_not_count() {
  local case_dir home out rc=0
  case_dir=$(make_case holders task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  write_live "$home" handed "$case_dir/project" "pr=https://example.invalid/o/r/pull/2"
  fm_write_meta "$home/state/mate-x.meta" "kind=secondmate" "project=$case_dir/project"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a handed-off or secondmate record counted as a heavy worker: $out"
  assert_contains "$out" "spawned task-c" "the spawn did not launch"
  pass "handed-off and secondmate records hold no heavy-worker place"
}

test_restart_does_not_count_its_own_record() {
  local case_dir home out rc=0
  case_dir=$(make_case restart task-c task-d)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  write_live "$home" live-c "$case_dir/project"
  fm_write_meta "$home/state/task-c.meta" "window=firstmate:fm-task-c" "project=$case_dir/project" "kind=ship"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a restart was deferred by its own record: $out"
  rc=0
  out=$(spawn_ship_load 1.0 "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a new task ignored the restarted worker: $out"
  pass "a restart of a task id does not count that task's own record"
}

test_unreadable_record_refuses() {
  local case_dir home out rc=0
  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unreadable-record case (root reads files regardless of mode)\n'
    return 0
  fi
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  chmod 000 "$home/state/live-a.meta"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "an unreadable record did not refuse the spawn: $out"
  assert_contains "$out" "cannot all be read" "the refusal did not say the records could not be read"
  assert_absent "$home/state/task-c.meta" "the refused spawn published a record"
  pass "an unreadable task record refuses a heavy start rather than undercounting"
}

test_declared_heavy_limit_tunes_the_gate() {
  local case_dir home out rc=0
  case_dir=$(make_case tuned task-c)
  home="$case_dir/home"
  printf '%s\n' '@heavy-limit 2' > "$home/config/project-capacity"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a third heavy worker was not deferred under a declared limit of 2: $out"
  assert_contains "$out" "(limit 2" "the deferral did not name the declared limit"
  rm "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship_load 1.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after the declaration cleared: $out"
  pass "a declared heavy limit tunes the gate, and its removal restores the standing one"
}

test_declared_load_limit_tunes_the_gate() {
  local case_dir home out rc=0
  case_dir=$(make_case loadtuned task-c)
  home="$case_dir/home"
  printf '%s\n' '@load-limit 5' > "$home/config/project-capacity"
  out=$(spawn_ship_load 6.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn at 6 was not deferred under a declared limit of 5: $out"
  rc=0
  out=$(spawn_ship_load 4.0 "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused under a cleared average: $out"
  pass "a declared load limit tunes the gate"
}

test_malformed_machine_setting_refuses() {
  local case_dir home out rc=0
  case_dir=$(make_case malformed task-c)
  home="$case_dir/home"
  printf '%s\n' '@heavy-limit many' > "$home/config/project-capacity"
  out=$(spawn_ship_load 1.0 "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a malformed machine setting did not refuse the spawn: $out"
  assert_contains "$out" "unreadable" "the refusal did not say the declaration could not be read"
  assert_absent "$home/state/task-c.meta" "the refused spawn published a record"
  pass "a malformed machine setting refuses a heavy start rather than guessing the limit"
}

test_high_average_defers_then_clear_admits
test_four_heavy_workers_defer_a_fifth_then_release_admits
test_handed_off_and_secondmate_records_do_not_count
test_restart_does_not_count_its_own_record
test_unreadable_record_refuses
test_declared_heavy_limit_tunes_the_gate
test_declared_load_limit_tunes_the_gate
test_malformed_machine_setting_refuses
