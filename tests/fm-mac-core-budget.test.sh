#!/usr/bin/env bash
# The Mac hourly core budget holds a heavy start past budget and releases it after, never a light start.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$ROOT/bin/fm-mac-load-lib.sh"
# shellcheck source=bin/fm-core-budget-lib.sh
. "$ROOT/bin/fm-core-budget-lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
HOLDER="$ROOT/bin/fm-mac-core-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-mac-core-budget)
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
Exercise the Mac core budget.

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

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn_budget() {  # <usage> <weight> <case-dir> <home> <pane> <args...>
  local usage=$1 weight=$2 case_dir=$3 home=$4 pane=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_MAC_LOAD_MOCK_5MIN=1.0 \
    FM_MAC_CORE_BUDGET_FORCE=1 \
    FM_CORE_BUDGET_MOCK_USAGE="$usage" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" --weight "$weight" 2>&1
}

spawn_ship_budget() {  # <usage> <weight> <case-dir> <id> [pane]
  local usage=$1 weight=$2 case_dir=$3 id=$4 pane=${5:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn_budget "$usage" "$weight" "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

spawn_scout_budget() {  # <usage> <weight> <case-dir> <id> [pane]
  local usage=$1 weight=$2 case_dir=$3 id=$4 pane=${5:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn_budget "$usage" "$weight" "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --scout
}

run_holder() {  # <usage> <case-dir> <home> <pane> <args...>
  local usage=$1 case_dir=$2 home=$3 pane=$4
  shift 4
  if [ -d "$case_dir/project" ] && [ ! -e "$pane" ]; then
    git -C "$case_dir/project" worktree add --quiet -b "wt-$RANDOM" "$pane" 2>/dev/null || mkdir -p "$pane"
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_MAC_LOAD_MOCK_5MIN=1.0 \
    FM_MAC_CORE_BUDGET_FORCE=1 \
    FM_CORE_BUDGET_MOCK_USAGE="$usage" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$HOLDER" "$@" 2>&1
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }
worktree_list() { git -C "$1/project" worktree list --porcelain; }

assert_nothing_created() {  # <case-dir> <home> <id> <calls> <worktrees>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a held spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a held spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] || fail "a held spawn touched the terminal or worktree pool for $id"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a held spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] || fail "a held spawn moved $id out of queued"
  fi
}

test_under_budget_heavy_proceeds() {
  local case_dir home out rc=0
  case_dir=$(make_case under task-c)
  home="$case_dir/home"
  out=$(spawn_ship_budget 5.0 heavy "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a heavy start under budget was refused: $out"
  assert_contains "$out" "spawned task-c" "the under-budget spawn did not launch"
  assert_absent "$home/state/core-budget-held/task-c" "an under-budget spawn left a holder"
  pass "a heavy start under budget proceeds and leaves no holder"
}

test_over_budget_heavy_held_then_released() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case held task-c)
  home="$case_dir/home"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship_budget 8.0 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a heavy start over budget was not held: $out"
  assert_contains "$out" "trailing-hour CPU use is 8.0 core-hours (budget 6)" "the hold did not name the use and the budget"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  [ -f "$home/state/core-budget-held/task-c" ] || fail "the held spawn recorded no holder"
  write_brief "$home" task-d
  add_item "$home" task-d
  out=$(spawn_ship_budget 8.0 heavy "$case_dir" task-d "$case_dir/unused") && rc=0 || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a second heavy start over budget was not held: $out"
  assert_contains "$out" "already pending" "the second hold did not reuse the pending wake"
  [ -f "$home/state/core-budget-held/task-d" ] || fail "the second held spawn recorded no holder"
  out=$(run_holder 8.0 "$case_dir" "$home" "$case_dir" status) || rc=$?
  assert_contains "$out" "held: task-c" "status did not list the held spawn"
  out=$(run_holder 8.0 "$case_dir" "$home" "$case_dir" check --clear) && rc=0 || rc=$?
  expect_code 1 "$rc" "the clear check passed while still over budget: $out"
  out=$(run_holder 8.0 "$case_dir" "$home" "$case_dir" release) && rc=0 || rc=$?
  expect_code 0 "$rc" "a release while still over budget failed: $out"
  [ -f "$home/state/core-budget-held/task-c" ] || fail "a release while still over budget dropped the holder"
  [ -f "$home/state/core-budget-held/task-d" ] || fail "a release while still over budget dropped the second holder"
  out=$(run_holder 1.0 "$case_dir" "$home" "$case_dir" check --clear) && rc=0 || rc=$?
  expect_code 0 "$rc" "the clear check failed after use dropped: $out"
  out=$(run_holder 1.0 "$case_dir" "$home" "$case_dir/retry-a" release) && rc=0 || rc=$?
  expect_code 1 "$rc" "a release that frees only one pane was expected to keep the other holder: $out"
  assert_contains "$out" "released: task-c" "the first release did not relaunch the first held spawn"
  assert_absent "$home/state/core-budget-held/task-c" "the first release kept a spent holder"
  [ -f "$home/state/core-budget-held/task-d" ] || fail "the first release dropped a holder it could not retry"
  rm -f "$case_dir/fakebin/.spawn-window"
  out=$(run_holder 1.0 "$case_dir" "$home" "$case_dir/retry-b" release) && rc=0 || rc=$?
  expect_code 0 "$rc" "the second release failed once a free pane existed: $out"
  assert_contains "$out" "released: task-d" "the second release did not relaunch the kept spawn"
  assert_absent "$home/state/core-budget-held/task-d" "the second release kept a spent holder"
  [ -f "$home/state/task-c.meta" ] || fail "the released spawn published no task record"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "the released spawn left task-c out of In flight"
  fi
  pass "a heavy start over budget is held and later released on its own"
}

test_light_never_held() {
  local case_dir home out rc=0
  case_dir=$(make_case light task-c)
  home="$case_dir/home"
  out=$(spawn_ship_budget 8.0 light "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a light start over budget was held: $out"
  assert_contains "$out" "spawned task-c" "the light spawn did not launch"
  assert_absent "$home/state/core-budget-held/task-c" "a light spawn left a holder"
  pass "a light start is never held by the budget"
}

test_at_budget_holds() {
  local case_dir out rc=0
  case_dir=$(make_case edge task-c)
  out=$(spawn_ship_budget 6.0 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a heavy start exactly at budget was not held: $out"
  pass "reaching the budget holds, not just passing it"
}

test_scout_heavy_held() {
  local case_dir out rc=0
  case_dir=$(make_case scout task-c)
  out=$(spawn_scout_budget 8.0 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a heavy scout over budget was not held: $out"
  pass "a heavy scout waits on the same budget"
}

test_declared_budget_tunes_the_gate() {
  local case_dir home out rc=0
  case_dir=$(make_case tuned task-c)
  home="$case_dir/home"
  printf '%s\n' '@core-budget 2' > "$home/config/project-capacity"
  out=$(spawn_ship_budget 2.5 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a heavy start was not held under a declared budget of 2: $out"
  assert_contains "$out" "(budget 2)" "the hold did not name the declared budget"
  rm "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship_budget 2.5 heavy "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "the same spawn was refused after the declaration cleared: $out"
  pass "a declared core budget tunes the gate, and its removal restores the standing one"
}

test_malformed_setting_refuses() {
  local case_dir home out rc=0
  case_dir=$(make_case malformed task-c)
  home="$case_dir/home"
  printf '%s\n' '@core-budget many' > "$home/config/project-capacity"
  out=$(spawn_ship_budget 1.0 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a malformed core budget did not refuse the spawn: $out"
  assert_contains "$out" "unreadable" "the refusal did not say the declaration could not be read"
  assert_absent "$home/state/task-c.meta" "the refused spawn published a record"
  printf '%s\n' '@core-budget 2' '@core-budget 2' > "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship_budget 1.0 heavy "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a duplicated core budget did not refuse the spawn: $out"
  pass "a malformed core budget refuses a heavy start rather than guessing the limit"
}

test_weight_flag_validation() {
  local case_dir out rc=0
  case_dir=$(make_case weight task-c)
  out=$(spawn_ship_budget 1.0 bogus "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a bogus weight did not refuse the spawn: $out"
  assert_contains "$out" "--weight must be heavy or light" "the refusal did not name the closed set"
  pass "a bogus weight refuses the spawn"
}

test_standing_default_and_parse() {
  local dir="$TMP_ROOT/defaults"
  mkdir -p "$dir"
  FM_MAC_LOAD_MOCK_NOW=1792703200 fm_mac_load_config "" || fail "the Mac config refused with no declaration"
  assert_equals 6 "$FM_MAC_CORE_BUDGET" "the standing core budget was not 6"
  printf '%s\n' '@core-budget 8' > "$dir/project-capacity"
  FM_MAC_LOAD_MOCK_NOW=1792703200 fm_mac_load_config "$dir" || fail "the Mac config refused a declared budget"
  assert_equals 8 "$FM_MAC_CORE_BUDGET" "a declared core budget of 8 did not win"
  pass "the standing core budget is 6 and a declaration wins"
}

test_usage_math() {
  local samples="$TMP_ROOT/samples"
  printf '%s\n' '0 6.00' '1800 6.00' > "$samples"
  assert_equals "6.00" "$(FM_CORE_BUDGET_MOCK_NOW=3600 fm_machine_core_budget_usage "$samples")" "two steady samples did not read 6 core-hours"
  printf '%s\n' '0 10.00' > "$samples"
  assert_equals "10.00" "$(FM_CORE_BUDGET_MOCK_NOW=7200 fm_machine_core_budget_usage "$samples")" "a stale sample counted more than one window"
  : > "$samples"
  assert_equals "0" "$(FM_CORE_BUDGET_MOCK_NOW=3600 fm_machine_core_budget_usage "$samples")" "an empty log did not read 0"
  rm -f "$samples"
  assert_equals "0" "$(FM_CORE_BUDGET_MOCK_NOW=3600 fm_machine_core_budget_usage "$samples")" "a missing log did not read 0"
  FM_CORE_BUDGET_MOCK_USAGE=9.5 fm_machine_core_budget_usage "$samples" >/dev/null || fail "a mock usage was refused"
  assert_equals "9.5" "$(FM_CORE_BUDGET_MOCK_USAGE=9.5 fm_machine_core_budget_usage "$samples")" "a mock usage did not win"
  fm_machine_core_budget_over 6.0 6 || fail "reaching the budget did not count as over"
  fm_machine_core_budget_over 5.9 6 && fail "staying under the budget counted as over"
  pass "usage math carries the last sample, caps the carry at one window, and the verdict holds at the line"
}

test_under_budget_heavy_proceeds
test_over_budget_heavy_held_then_released
test_light_never_held
test_at_budget_holds
test_scout_heavy_held
test_declared_budget_tunes_the_gate
test_malformed_setting_refuses
test_weight_flag_validation
test_standing_default_and_parse
test_usage_math
