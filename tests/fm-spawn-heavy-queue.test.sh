#!/usr/bin/env bash
# tests/fm-spawn-heavy-queue.test.sh - a ship or scout worker starts with the
# folder `orc heavy path` prints first on its PATH, and a spawn whose orc cannot
# provide one launches unchanged with one note.
#
# Each case drives the real spawn against a fake pane, then executes the launch
# command the pane received with the harness replaced by a probe that prints
# where `command -v bun` resolves.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-heavy-queue)

# make_case <name> <id>
make_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  ORC_LOG="$CASE_DIR/orc.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
command -v bun || echo no-bun
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

# The folder carries a space and a quote so the launch must quote it.
install_heavy_orc() {
  STANDIN_DIR="$CASE_DIR/heavy dir's bin"
  mkdir -p "$STANDIN_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$STANDIN_DIR/bun"
  chmod +x "$STANDIN_DIR/bun"
  cat > "$FAKEBIN_DIR/orc" <<SH
#!/bin/sh
printf '%s\\n' "\$*" >> $(printf '%q' "$ORC_LOG")
[ "\$*" = "heavy path" ] || exit 2
printf '%s\\n' $(printf '%q' "$STANDIN_DIR")
SH
  chmod +x "$FAKEBIN_DIR/orc"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The probe PATH holds no bun, so only the launch can make one resolve.
emitted_bun() {
  local preamble
  preamble=$(grep '^ export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:/usr/bin:/bin" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_ship_and_scout_resolve_bun_to_the_standin_not_the_ambient_path() {
  local kind setting id out status
  for kind in ship scout; do
    for setting in absent enabled; do
      id="$kind-$setting-a1"
      make_case "$kind-$setting" "$id"
      install_heavy_orc
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist $setting should succeed: $out"
      assert_equals "heavy path" "$(cat "$ORC_LOG")" "$kind/$setting: spawn should ask orc for the heavy path once"
      assert_not_contains "$out" "without the heavy queue" "$kind/$setting: a working orc must not print the fallback note"
      assert_equals "$STANDIN_DIR/bun" "$(emitted_bun)" \
        "$kind/$setting: the worker's bun must resolve to the stand-in"
    done
  done
  pass "ship and scout workers resolve bun to the heavy-queue stand-in under both allowlist postures"
}

test_failing_orc_launches_unchanged_with_one_note_instead_of_refusing() {
  local id=fail-a1 out status
  make_case orc-fails "$id"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a failing orc must not block the spawn: $out"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c "launches without the heavy queue on its PATH")" \
    "a failing orc should be reported exactly once: $out"
  assert_equals no-bun "$(emitted_bun)" "a failing orc must leave the worker PATH unchanged"
  pass "a spawn whose orc fails launches unchanged and says so once"
}

test_folder_that_does_not_exist_is_not_put_on_the_path() {
  local id=missing-a1 out status
  make_case orc-missing-dir "$id"
  cat > "$FAKEBIN_DIR/orc" <<SH
#!/bin/sh
printf '%s\\n' $(printf '%q' "$CASE_DIR/never-made")
SH
  chmod +x "$FAKEBIN_DIR/orc"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unusable folder must not block the spawn: $out"
  assert_contains "$out" "printed no folder" "an unusable folder should be named in the note: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "never-made" "an unusable folder must stay off the launch"
  pass "a folder orc printed but that does not exist stays off the worker PATH"
}

test_secondmate_launch_does_not_ask_orc() {
  local sm out status
  make_case secondmate sm-heavy
  install_heavy_orc
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-heavy > "$sm/.fm-secondmate-home"
  printf 'charter for sm-heavy\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-heavy "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  assert_absent "$ORC_LOG" "a secondmate spawn must not ask orc for the heavy path"
  pass "a secondmate launch leaves its PATH alone"
}

test_ship_and_scout_resolve_bun_to_the_standin_not_the_ambient_path
test_failing_orc_launches_unchanged_with_one_note_instead_of_refusing
test_folder_that_does_not_exist_is_not_put_on_the_path
test_secondmate_launch_does_not_ask_orc
