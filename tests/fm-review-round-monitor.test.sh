#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-review-round-monitor.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-round-monitor)

T0=1800000000

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/nm"
  python3 -I - "$home/nm/state.sqlite" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.executescript("""
create table repos (id text primary key, working_path text not null unique, upstream_url text not null, created_at integer not null);
create table runs (id text primary key, repo_id text not null references repos(id), branch text not null, status text not null, created_at integer not null, updated_at integer not null);
create table step_results (id text primary key, run_id text not null references runs(id), step_name text not null, step_order integer not null);
create table step_rounds (id text primary key, step_result_id text not null references step_results(id), round integer not null, trigger_type text not null, duration_ms integer not null, created_at integer not null);
insert into repos values ('repo-demo', '/Users/x/projects/demo', 'https://example.invalid/demo.git', 0);
""")
db.commit()
PY
  printf '%s\n' "$home"
}

sql() {  # <db> <statement> [params...]
  python3 -I -c '
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute(sys.argv[2], sys.argv[3:])
db.commit()
' "$@"
}

write_task() {  # <home> <id> <branch>
  fm_write_meta "$1/state/$2.meta" "kind=ship" "branch=$3"
}

add_run() {  # <home> <run-id> <branch> <status>
  sql "$1/nm/state.sqlite" "insert into runs values (?, 'repo-demo', ?, ?, 0, 0)" "$2" "$3" "$4"
}

add_round() {  # <home> <run-id> <created-at> [step] [trigger]
  local db="$1/nm/state.sqlite" step="${4:-review}" trigger="${5:-auto_fix}"
  sql "$db" "insert or ignore into step_results values (?, ?, ?, 1)" "$2-$step" "$2" "$step"
  sql "$db" "insert into step_rounds values (?, ?, 1, ?, 1, ?)" "$2-$step-$3" "$2-$step" "$trigger" "$3"
}

run_check() {  # <home>
  local home=$1 out status=0
  out=$(NM_HOME="$home/nm" FM_HOME="$home" "$CHECK" check 2>&1) || status=$?
  expect_code 0 "$status" "check exit"
  printf '%s' "$out"
}

run_status() {  # <home>
  local home=$1 out status=0
  out=$(NM_HOME="$home/nm" FM_HOME="$home" "$CHECK" status 2>&1) || status=$?
  expect_code 0 "$status" "status exit"
  printf '%s' "$out"
}

test_two_rounds_stay_silent() {
  local home out
  home=$(make_home two)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x running
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120)) test auto_fix
  add_round "$home" r1 $((T0 + 180)) review initial
  out=$(run_check "$home")
  assert_equals "" "$out" "two review fix rounds stay silent"
  pass "two review fix rounds stay silent, and only review auto-fix rounds count"
}

test_third_round_wakes_once() {
  local home out again
  home=$(make_home third)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x running
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120))
  out=$(run_check "$home")
  assert_contains "$out" "task alpha, project demo, branch fm/alpha-x, 3 review fix rounds in run r1" "third round names task, project, branch and count"
  again=$(run_check "$home")
  assert_equals "" "$again" "the same run does not wake again"
  pass "third review fix round wakes once with task, project, branch and count"
}

test_fourth_round_stays_silent() {
  local home out
  home=$(make_home fourth)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x running
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120))
  run_check "$home" >/dev/null
  add_round "$home" r1 $((T0 + 180))
  out=$(run_check "$home")
  assert_equals "" "$out" "a fourth round after the wake stays silent"
  pass "a fourth review fix round after the wake stays silent"
}

test_millisecond_stamps() {
  local home out status_line
  home=$(make_home millis)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x running
  add_round "$home" r1 $((T0 * 1000))
  add_round "$home" r1 $((T0 * 1000 + 60000))
  add_round "$home" r1 $((T0 * 1000 + 120000))
  out=$(run_check "$home")
  assert_contains "$out" "3 review fix rounds in run r1" "millisecond stamps count as rounds"
  status_line=$(run_status "$home")
  assert_equals "alpha demo fm/alpha-x rounds=3 third_round_at=$((T0 + 120)) woken=yes" "$status_line" "millisecond third round reads as seconds"
  pass "millisecond created_at values are normalized to seconds"
}

test_terminal_runs_stay_silent() {
  local home out status_word n=0
  home=$(make_home terminal)
  write_task "$home" alpha fm/alpha-x
  for status_word in completed failed cancelled; do
    n=$((n + 1))
    add_run "$home" "t$n" fm/alpha-x "$status_word"
    add_round "$home" "t$n" "$T0"
    add_round "$home" "t$n" $((T0 + 60))
    add_round "$home" "t$n" $((T0 + 120))
  done
  out=$(run_check "$home")
  assert_equals "" "$out" "terminal runs with three rounds stay silent"
  pass "completed, failed and cancelled runs never wake"
}

test_fixing_run_is_live() {
  local home out
  home=$(make_home fixing)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x fixing
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120))
  out=$(run_check "$home")
  assert_contains "$out" "3 review fix rounds in run r1" "a fixing run is live and wakes"
  pass "a run in the fixing state counts as live"
}

test_unmatched_branch_stays_silent() {
  local home out
  home=$(make_home unmatched)
  add_run "$home" r1 fm/orphan running
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120))
  out=$(run_check "$home")
  assert_equals "" "$out" "a run on a branch with no task stays silent"
  pass "a run on a branch with no task of this home stays silent"
}

test_absent_database_is_silent() {
  local home out
  home=$(make_home absent)
  rm -f "$home/nm/state.sqlite"
  out=$(run_check "$home")
  assert_equals "" "$out" "an absent database stays silent"
  pass "an absent state database does nothing"
}

test_unreadable_database_reports_once() {
  local home out again
  home=$(make_home unreadable)
  printf 'not a database\n' > "$home/nm/state.sqlite"
  out=$(run_check "$home")
  assert_contains "$out" "could not be read" "an unreadable database is reported"
  again=$(run_check "$home")
  assert_equals "" "$again" "the same unreadable database is not reported again"
  pass "an unreadable state database is reported once"
}

test_arm_and_disarm() {
  local home shim out
  home=$(make_home arm)
  write_task "$home" alpha fm/alpha-x
  add_run "$home" r1 fm/alpha-x running
  add_round "$home" r1 "$T0"
  add_round "$home" r1 $((T0 + 60))
  add_round "$home" r1 $((T0 + 120))
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1
  expect_code 0 "$?" "arm exit"
  shim="$home/state/review-rounds.check.sh"
  [ -f "$shim" ] && [ ! -L "$shim" ] || fail "arm did not write the check shim"
  [ -x "$shim" ] || fail "the check shim is not executable"
  [ -f "$home/state/review-rounds.check-trust" ] || fail "arm did not bind the check bytes"
  out=$(NM_HOME="$home/nm" "$shim")
  assert_contains "$out" "3 review fix rounds in run r1" "the armed shim wakes through the check"
  FM_HOME="$home" "$CHECK" disarm >/dev/null 2>&1
  expect_code 0 "$?" "disarm exit"
  [ ! -e "$shim" ] || fail "disarm left the check shim behind"
  [ ! -e "$home/state/review-rounds.check-trust" ] || fail "disarm left the trust binding behind"
  [ ! -e "$home/state/.review-rounds" ] || fail "disarm left the de-dupe record behind"
  pass "arm writes and binds the shim, and disarm removes it with its record"
}

test_two_rounds_stay_silent
test_third_round_wakes_once
test_fourth_round_stays_silent
test_millisecond_stamps
test_terminal_runs_stay_silent
test_fixing_run_is_live
test_unmatched_branch_stays_silent
test_absent_database_is_silent
test_unreadable_database_reports_once
test_arm_and_disarm
