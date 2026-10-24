#!/usr/bin/env bash
# A spawn whose harness executable is absent from PATH refuses before endpoint creation.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-missing-harness)
fm_git_identity fmtest fmtest@example.invalid

MISSING_HARNESSES="claude codex opencode grok gemini"

make_missing_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog h
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" timeout treehouse)
  for h in $MISSING_HARNESSES; do
    fm_fake_exit0 "$fakebin" "$h"
  done
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_missing_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_missing_harness_refuses_before_endpoint() {  # <harness>
  local harness=$1 rec id out status
  id="missing-$harness-z1"
  rec=$(make_missing_case "missing-$harness" "$id")
  read_missing_record "$rec"
  rm -f "$FAKEBIN_DIR/$harness"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness "$harness" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing $harness executable should refuse the spawn"
  assert_contains "$out" "$harness executable not found on PATH" \
    "missing $harness refusal did not name the actionable requirement"
  assert_not_contains "$out" "spawned $id" \
    "a refused spawn must never report success"
  assert_absent "$HOME_DIR/state/$id.meta" "missing $harness refusal wrote task metadata"
  assert_absent "$FAKEBIN_DIR/.spawn-window" "missing $harness refusal created an endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing $harness refusal typed a launch command"
  pass "a missing $harness executable refuses before endpoint creation"
}

test_missing_claude_refuses_before_endpoint() {
  test_missing_harness_refuses_before_endpoint claude
}

test_missing_codex_refuses_before_endpoint() {
  test_missing_harness_refuses_before_endpoint codex
}

test_missing_opencode_refuses_before_endpoint() {
  test_missing_harness_refuses_before_endpoint opencode
}

test_missing_grok_refuses_before_endpoint() {
  test_missing_harness_refuses_before_endpoint grok
}

test_missing_gemini_refuses_before_endpoint() {
  test_missing_harness_refuses_before_endpoint gemini
}

test_missing_claude_refuses_before_endpoint
test_missing_codex_refuses_before_endpoint
test_missing_opencode_refuses_before_endpoint
test_missing_grok_refuses_before_endpoint
test_missing_gemini_refuses_before_endpoint

echo "all fm-spawn-missing-harness tests passed"
