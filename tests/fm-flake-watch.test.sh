#!/usr/bin/env bash
# fm-flake-watch replay: the 2026-09-27 skills red run files one task, then silence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-flake-watch.sh"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-flake-watch)
NOW_2026_09_28_1200Z=1790596800

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

write_gh_fake() {
  local home=$1 mode=$2
  cat > "$home/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = api ]; then
  case "\$2" in
    */jobs*)
      printf 'api_response:\n'
      if [ "$mode" = notstarted ]; then
        printf '  body: "flake\\\\tfailure\\\\t0\\\\t-\\\\t0"\n'
      else
        printf '  body: "flake\\\\tfailure\\\\t21\\\\tlinux-skills\\\\t12"\n'
      fi
      printf '  truncated: false\n'
      ;;
    */repos/avi2d/skills/*)
      printf 'api_response:\n'
      if [ "$mode" = green ]; then
        printf '  body: ""\n'
      else
        printf '  body: "36312923331\\\\tfailure\\\\thttps://github.com/avi2d/skills/actions/runs/36312923331\\\\t2026-09-27T10:33:36Z\\\\n36417204241\\\\tsuccess\\\\thttps://github.com/avi2d/skills/actions/runs/36417204241\\\\t2026-09-28T11:42:01Z"\n'
      fi
      printf '  truncated: false\n'
      ;;
    *)
      printf 'error: "gh: Not Found (HTTP 404)"\ncode: NOT_FOUND\n' >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [ "\${1:-} \$2" = "run download" ]; then
  if [ "$mode" = expired ]; then
    printf 'error: artifact expired\n' >&2
    exit 1
  fi
  dir=\$(printf '%s\n' "\$*" | sed -n 's/.* --dir //p' | cut -d' ' -f1)
  cat > "\$dir/flake-report.json" <<'JSON'
{"runs": [{"seed": 3290208862, "passed": false, "tests": 879, "failed": ["tests/e2e/claude-code-delivery.test.ts > Rules past the limit from one prompt hook arrive as a preview and the check says so; the shipped prompt hooks deliver them whole"]}], "failures": [{"file": "tests/e2e/claude-code-delivery.test.ts", "test": "Rules past the limit from one prompt hook arrive as a preview and the check says so; the shipped prompt hooks deliver them whole", "line": 182, "seeds": [3290208862]}], "outsideTests": []}
JSON
  printf 'download: ok\n'
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$home/fakebin/gh-axi"
}

run_check() {
  local home=$1 out=$2
  local status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FLAKE_WATCH_NOW="$NOW_2026_09_28_1200Z" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

tasks_count() {
  PATH="$1/fakebin:$PATH" FM_HOME="$1" "$TASKS" list --state queued 2>/dev/null | grep -c '^  flake-' || true
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  pass "fm-flake-watch: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_gh_fake "$home" red
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/flake-watch.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/flake-watch.check.sh" "arm writes the check shim"
  assert_present "$home/state/flake-watch.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/flake-watch.check.sh")" "fm-flake-watch.sh check" "shim dispatches the check action"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"
  printf 'checks\nchecks 1\n' > "$home/state/.flake-watch-progress"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/.flake-watch-progress" "disarm removes the rotation record"
  assert_absent "$home/state/flake-watch.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/flake-watch.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.flake-watch-seen" "disarm removes the seen record"
  pass "fm-flake-watch: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_red_run_files_one_task_then_silence() {
  local home out body
  home=$(make_home replay)
  write_gh_fake "$home" red
  run_check "$home" "$home/out1.txt"
  out=$(cat "$home/out1.txt")
  assert_contains "$out" "flake-skills-36312923331" "first pass names the filed task"
  [ "$(wc -l < "$home/out1.txt" | tr -d '[:space:]')" = 1 ] || fail "first pass prints exactly one line: $out"
  [ "$(tasks_count "$home")" = 1 ] || fail "first pass files exactly one task"
  body=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$TASKS" show flake-skills-36312923331 2>&1)
  assert_contains "$body" "tests/e2e/claude-code-delivery.test.ts:182" "the task names line 182"
  assert_contains "$body" "3290208862" "the task names seed 3290208862"
  assert_contains "$body" "https://github.com/avi2d/skills/actions/runs/36312923331" "the task names the run URL"
  assert_contains "$(cat "$home/state/.flake-watch-seen")" "skills/36312923331" "the run is recorded as seen"
  run_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "second pass must stay silent: $(cat "$home/out2.txt")"
  [ "$(tasks_count "$home")" = 1 ] || fail "second pass files nothing"
  pass "fm-flake-watch: red run files one task naming line 182 and seed 3290208862, second pass files nothing"
}

test_green_week_files_nothing() {
  local home
  home=$(make_home green)
  write_gh_fake "$home" green
  run_check "$home" "$home/out.txt"
  [ ! -s "$home/out.txt" ] || fail "a green week must stay silent: $(cat "$home/out.txt")"
  [ "$(tasks_count "$home")" = 0 ] || fail "a green week files nothing"
  pass "fm-flake-watch: green runs file nothing"
}

test_expired_artifact_still_files_its_one_task() {
  local home body
  home=$(make_home expired)
  write_gh_fake "$home" expired
  run_check "$home" "$home/out1.txt"
  assert_contains "$(cat "$home/out1.txt")" "flake-skills-36312923331" "expired detail still files the run's task"
  body=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$TASKS" show flake-skills-36312923331 2>&1)
  assert_contains "$body" "https://github.com/avi2d/skills/actions/runs/36312923331" "the fallback task names the run URL"
  run_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "second pass must stay silent: $(cat "$home/out2.txt")"
  pass "fm-flake-watch: expired artifact still files exactly one task"
}

test_unstarted_job_files_nothing_but_is_recorded_seen() {
  local home
  home=$(make_home notstarted)
  write_gh_fake "$home" notstarted
  run_check "$home" "$home/out1.txt"
  [ ! -s "$home/out1.txt" ] || fail "a never-started job must stay silent: $(cat "$home/out1.txt")"
  [ "$(tasks_count "$home")" = 0 ] || fail "a never-started job files nothing"
  assert_contains "$(cat "$home/state/.flake-watch-seen")" "skills/36312923331" "the skipped run is recorded as seen"
  run_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "second pass must stay silent: $(cat "$home/out2.txt")"
  pass "fm-flake-watch: a job that never started files nothing and is recorded as seen"
}

test_existing_task_is_adopted_not_duplicated() {
  local home
  home=$(make_home adopted)
  write_gh_fake "$home" red
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$TASKS" add flake-skills-36312923331 \
    "skills flake red: tests/e2e/claude-code-delivery.test.ts:182 seed 3290208862" \
    --kind ship --repo skills >/dev/null || fail "seeding the existing task must succeed"
  run_check "$home" "$home/out.txt"
  [ ! -s "$home/out.txt" ] || fail "an already-filed run must stay silent: $(cat "$home/out.txt")"
  [ "$(tasks_count "$home")" = 1 ] || fail "an already-filed run is never duplicated"
  assert_contains "$(cat "$home/state/.flake-watch-seen")" "skills/36312923331" "the adopted run is recorded as seen"
  pass "fm-flake-watch: an existing task for the run is adopted, never duplicated"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_red_run_files_one_task_then_silence
test_green_week_files_nothing
test_expired_artifact_still_files_its_one_task
test_unstarted_job_files_nothing_but_is_recorded_seen
test_existing_task_is_adopted_not_duplicated

write_slow_gh_fake() {
  local home=$1
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  printf '%s\n' "$2" >> "${FLAKE_CALL_LOG:-/dev/null}"
  sleep 2
  printf 'api_response:\n  body: ""\n  truncated: false\n'
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$home/fakebin/gh-axi"
}

run_budget_check() {
  local home=$1 out=$2
  local status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FLAKE_WATCH_NOW="$NOW_2026_09_28_1200Z" \
    FM_CHECK_TIMEOUT=4 FM_FLAKE_WATCH_BUDGET=1 \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "budget check exit"
}

test_budget_overrun_stays_silent_and_rotates() {
  local home first1 first2
  home=$(make_home budget-quiet)
  write_slow_gh_fake "$home"
  export FLAKE_CALL_LOG="$home/calls.log"
  run_budget_check "$home" "$home/out1.txt"
  [ ! -s "$home/out1.txt" ] || fail "an over-budget poll must stay silent: $(cat "$home/out1.txt")"
  first1=$(head -n 1 "$home/calls.log")
  assert_contains "$first1" "/repos/avi2d/skills/" "the first poll starts at skills"
  : > "$home/calls.log"
  run_budget_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "the next over-budget poll must stay silent: $(cat "$home/out2.txt")"
  first2=$(head -n 1 "$home/calls.log")
  assert_contains "$first2" "/repos/avi2d/checks/" "the next poll resumes where the last one stopped"
  pass "fm-flake-watch: an over-budget poll stays silent and resumes at the first unread repository"
}

test_same_repo_unread_across_three_polls_wakes() {
  local home
  home=$(make_home budget-stuck)
  write_slow_gh_fake "$home"
  export FLAKE_CALL_LOG="$home/calls.log"
  run_budget_check "$home" "$home/out1.txt"
  [ ! -s "$home/out1.txt" ] || fail "first over-budget poll must stay silent: $(cat "$home/out1.txt")"
  run_budget_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "second over-budget poll must stay silent: $(cat "$home/out2.txt")"
  run_budget_check "$home" "$home/out3.txt"
  assert_contains "$(cat "$home/out3.txt")" "flake-watch: repository career left unread across 3 consecutive over-budget polls" \
    "the third poll leaving career unread wakes naming career"
  run_check "$home" "$home/out4.txt"
  [ ! -s "$home/out4.txt" ] || fail "a completing poll must stay silent: $(cat "$home/out4.txt")"
  [ ! -e "$home/state/.flake-watch-progress" ] || fail "a completing poll clears the rotation record"
  pass "fm-flake-watch: a repository unread across 3 consecutive over-budget polls wakes, a full poll resets"
}

test_genuine_failure_wakes_immediately() {
  local home
  home=$(make_home budget-error)
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  case "$2" in
    */repos/avi2d/skills/*)
      printf 'error: "gh: Internal Server Error (HTTP 500)"\ncode: SERVER_ERROR\n' >&2
      exit 1
      ;;
  esac
  printf 'api_response:\n  body: ""\n  truncated: false\n'
  exit 0
fi
printf 'unexpected gh-axi call: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$home/fakebin/gh-axi"
  run_budget_check "$home" "$home/out.txt"
  assert_contains "$(cat "$home/out.txt")" "flake-watch: skills:" \
    "a genuine api failure wakes on the first poll"
  pass "fm-flake-watch: a genuine failure stays an immediate wake"
}

test_missing_tool_wakes_immediately() {
  local home status=0
  home=$(make_home budget-notool)
  mkdir -p "$home/noghbin"
  PATH="$home/noghbin:/usr/bin:/bin" FM_HOME="$home" FM_FLAKE_WATCH_NOW="$NOW_2026_09_28_1200Z" \
    "$CHECK" check >"$home/out.txt" 2>&1 || status=$?
  expect_code 0 "$status" "check exit without gh-axi"
  assert_contains "$(cat "$home/out.txt")" "flake-watch: gh-axi is not installed" \
    "a missing tool wakes on the first poll"
  pass "fm-flake-watch: a missing tool stays an immediate wake"
}

test_repo_outside_the_default_seven_still_wakes() {
  local home
  home=$(make_home budget-newrepo)
  write_slow_gh_fake "$home"
  export FLAKE_CALL_LOG="$home/calls.log"
  export FM_FLAKE_WATCH_REPOS="skills checks dotfiles atlas"
  run_budget_check "$home" "$home/out1.txt"
  [ ! -s "$home/out1.txt" ] || fail "first over-budget poll must stay silent: $(cat "$home/out1.txt")"
  run_budget_check "$home" "$home/out2.txt"
  [ ! -s "$home/out2.txt" ] || fail "second over-budget poll must stay silent: $(cat "$home/out2.txt")"
  run_budget_check "$home" "$home/out3.txt"
  unset FM_FLAKE_WATCH_REPOS
  assert_contains "$(cat "$home/out3.txt")" "flake-watch: repository atlas left unread across 3 consecutive over-budget polls" \
    "a repository outside the default seven still wakes after 3 unread polls"
  pass "fm-flake-watch: rotation tracks repositories from REPOS, not a hard-coded list"
}

test_budget_overrun_stays_silent_and_rotates
test_repo_outside_the_default_seven_still_wakes
test_same_repo_unread_across_three_polls_wakes
test_genuine_failure_wakes_immediately
test_missing_tool_wakes_immediately
