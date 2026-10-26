#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-day-review)
TOOL="$ROOT/bin/fm-day-review.sh"
# 2026-10-24 21:00 and 2026-10-25 21:00 in Europe/Moscow, which has no daylight saving.
SINCE=1792864800
UNTIL=1792951200
T0=$((SINCE + 3600))

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s' "$home"
}

review() {
  local home="$1" now="$2"
  shift 2
  FM_HOME="$home" FM_DAY_REVIEW_NOW="$now" NM_HOME="$TMP_ROOT/nm-$(basename "$home")" \
    FM_DAY_REVIEW_SESSION_ROOTS="$TMP_ROOT/sessions-$(basename "$home")" "$TOOL" "$@" 2>&1
}

metric() {
  python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])); [v := v[k] for k in sys.argv[2:]]; print(v)' "$@"
}

# One task t-alpha finishing inside the window, its worker and supervisor conversations,
# and one validation run. Every figure the tests expect is derived by hand from these values.
write_fixture() {
  local home="$1"
  python3 -I - "$home" "$TMP_ROOT/sessions-$(basename "$home")" "$TMP_ROOT/nm-$(basename "$home")" "$T0" <<'PY'
import json, os, sqlite3, sys
from datetime import datetime, timezone
home, sessions, nm, t0 = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
iso = lambda at: datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
archive = os.path.join(home, "state", "status-archive", "t-alpha")
os.makedirs(archive)
os.makedirs(os.path.join(home, "data", "t-alpha"))
open(os.path.join(home, "data", "t-alpha", "brief.md"), "w").write("brief\n")
with open(os.path.join(archive, f"{t0}.1.status"), "w") as out:
    for state, offset in (("working", 0), ("needs-decision", 600), ("resolved", 1200), ("paused", 1800), ("working", 2400), ("done", 3600)):
        out.write(f"{state} [at={t0 + offset}]: step\n")
with open(os.path.join(home, "state", "merge-on-green.log"), "w") as out:
    out.write(f"{iso(t0 + 4200)} t-alpha merged https://example.invalid/pr/1\n")

def conversation(name, cwd, first_user, turns):
    os.makedirs(os.path.join(sessions, "--fixture--"), exist_ok=True)
    with open(os.path.join(sessions, "--fixture--", name), "w") as out:
        out.write(json.dumps({"type": "session", "cwd": cwd}) + "\n")
        out.write(json.dumps({"type": "message", "timestamp": iso(t0), "message": {"role": "user", "content": first_user}}) + "\n")
        for offset, model, usage in turns:
            usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, **usage}
            out.write(json.dumps({"type": "message", "timestamp": iso(t0 + offset), "message": {"role": "assistant", "model": model, "usage": usage}}) + "\n")

conversation("worker.jsonl", "/elsewhere", f"Your steering inbox is \x60{home}/state/t-alpha.inbox\x60.", [
    (60, "claude-opus-5-5", {"input": 1000000, "output": 100000, "cacheRead": 1000000}),
    (120, "claude-haiku-5-5", {"input": 200000}),
    (180, "gpt-unlisted", {"input": 5000}),
])
conversation("supervisor.jsonl", home, "hello", [(240, "claude-sonnet-5-5", {"input": 1000000})])

os.makedirs(nm)
db = sqlite3.connect(os.path.join(nm, "state.sqlite"))
db.executescript("""
create table runs(id text, branch text, status text, pr_url text, created_at integer, updated_at integer);
create table step_results(id integer, run_id text, step_name text);
create table step_rounds(step_result_id integer, round integer, trigger_type text, findings_json text);
create table agent_invocations(run_id text, model text, fresh_input_tokens integer, cache_read_tokens integer,
  cache_creation_tokens integer, output_tokens integer, started_at integer);
""")
db.execute("insert into runs values('r1', 'fm/t-alpha', 'completed', '', ?, ?)", (t0 + 2500, t0 + 3500))
db.execute("insert into step_results values(1, 'r1', 'review')")
db.execute("insert into step_results values(2, 'r1', 'ci')")
findings = {"findings": [
    {"id": "a", "severity": "error", "description": "x", "file": "src/a.py"},
    {"id": "b", "severity": "warning", "description": "y", "file": "src/a.py"},
]}
db.execute("insert into step_rounds values(1, 1, 'initial', ?)", (json.dumps(findings),))
db.execute("insert into step_rounds values(1, 2, 'auto_fix', '{}')")
db.execute("insert into step_rounds values(2, 1, 'auto_fix', '{}')")
db.execute("insert into agent_invocations values('r1', 'claude-opus-5-5', 600000, 0, 100000, 0, ?)", (t0 + 2600,))
db.commit()
PY
}

test_due_at_the_moscow_hour_whatever_the_host_zone() {
  local home out zone
  home=$(make_home due)
  for zone in UTC Asia/Tokyo America/Los_Angeles; do
    out=$(TZ=$zone review "$home" $((UNTIL - 60)) check)
    assert_equals "" "$out" "check spoke before 21:00 Moscow with TZ=$zone"
    out=$(TZ=$zone review "$home" "$UNTIL" check)
    assert_contains "$out" "day-review due" "check stayed silent at 21:00 Moscow with TZ=$zone"
  done
}

test_custom_time_and_zone() {
  local home out
  home=$(make_home custom)
  printf '09:30 UTC\n' > "$home/config/day-review"
  out=$(review "$home" 1792920540 check)
  assert_equals "" "$out" "check spoke before 09:30 UTC"
  out=$(review "$home" 1792920600 check)
  assert_contains "$out" "day-review due" "check stayed silent at 09:30 UTC"
}

test_off_afk_and_bad_config() {
  local home out
  home=$(make_home quiet)
  printf 'off\n' > "$home/config/day-review"
  out=$(review "$home" "$UNTIL" check)
  assert_equals "" "$out" "off still woke the supervisor"
  rm "$home/config/day-review"
  touch "$home/state/.afk"
  out=$(review "$home" "$UNTIL" check)
  assert_equals "" "$out" "a parked supervisor was woken"
  rm "$home/state/.afk"
  printf '9pm\n' > "$home/config/day-review"
  out=$(review "$home" "$UNTIL" check)
  assert_contains "$out" "config/day-review is not" "a malformed schedule was not reported"
  out=$(review "$home" "$UNTIL" check)
  assert_equals "" "$out" "a malformed schedule was reported twice"
}

test_run_builds_the_board_from_the_records() {
  local home out numbers
  home=$(make_home board)
  write_fixture "$home"
  out=$(review "$home" $((UNTIL - 60)) run)
  assert_contains "$out" "not due" "run went ahead before 21:00"
  out=$(review "$home" $((UNTIL + 60)) run) || fail "run failed: $out"
  numbers="$home/data/day-review/2026-10-25/numbers.json"
  assert_present "$numbers" "run wrote no numbers"
  assert_grep 'href="full.html"' "$home/data/day-review/2026-10-25/board.html" "the board does not link the full numbers"
  assert_present "$home/data/day-review/2026-10-25/full.html" "run wrote no full page"
  assert_equals "2026-10-25" "$(metric "$numbers" day)" "wrong review day"
  assert_equals "$SINCE.0" "$(metric "$numbers" since)" "window does not start at 21:00 the evening before"
  assert_equals "1" "$(metric "$numbers" metrics tasks_finished)" "wrong finished count"
  # Status records: 10 min to the question, 10 min to the answer, 10 min paused,
  # 20 min working to done, merged 10 min after done.
  assert_equals "40 10 10 10 0" "$(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1]))["tasks"][0]["minutes"]; print(m["working"], m["decision"], m["checks"], m["merge"], m["restart"])' "$numbers")" "wrong time split"
  # List prices per million: opus 4 in, 20 out, 0.2 cache read, 5 cache write; haiku over
  # 100k prompt 0.5 in; sonnet 2 in. Worker 4 + 2 + 0.2 + 0.1, pipeline 0.5 x 4 + 0.1 x 5,
  # supervisor 2.
  assert_equals "6.3" "$(python3 -I -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["tasks"][0]["usd"] - 2.5, 2))' "$numbers")" "wrong worker price"
  assert_equals "10.8" "$(metric "$numbers" metrics usd_total)" "wrong day price"
  assert_equals "2.0" "$(metric "$numbers" metrics supervisor_usd)" "wrong supervisor price"
  assert_equals "1" "$(metric "$numbers" metrics review_errors)" "wrong review error count"
  assert_equals "1" "$(metric "$numbers" metrics review_fix_rounds)" "wrong review fix rounds"
  assert_equals "1" "$(metric "$numbers" metrics ci_fix_rounds)" "wrong failed CI rounds"
  assert_equals "1" "$(metric "$numbers" metrics worker_questions)" "wrong question count"
  assert_grep "gpt-unlisted have no list price" "$numbers" "an unpriced model was not named as a gap"
  assert_equals "3" "$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["recommendations"]))' "$numbers")" "the board needs three recommendations"
  out=$(review "$home" $((UNTIL + 120)) check)
  assert_equals "" "$out" "check fired again on the same day"
}

test_unreachable_secondmate_is_a_gap() {
  local home out
  home=$(make_home gap)
  write_fixture "$home"
  printf -- '- ghost - test mate (home: %s/missing; scope: test; projects: none; added 2026-10-10)\n' "$TMP_ROOT" > "$home/data/secondmates.md"
  out=$(review "$home" $((UNTIL + 60)) run) || fail "run failed: $out"
  assert_grep "The ghost second mate could not be read" "$home/data/day-review/2026-10-25/numbers.json" "a missing second mate was not stated"
}

test_force_does_not_mark_the_day() {
  local home out
  home=$(make_home force)
  write_fixture "$home"
  out=$(review "$home" $((UNTIL - 600)) run --force) || fail "forced run failed: $out"
  assert_absent "$home/state/.day-review" "a forced run marked the day done"
  assert_absent "$home/data/day-review/notes.json" "a forced run recorded advice for tomorrow"
  out=$(review "$home" "$UNTIL" check)
  assert_contains "$out" "day-review due" "a forced run silenced the scheduled one"
}

test_next_review_judges_advice_per_task() {
  local home out numbers
  home=$(make_home advice)
  write_fixture "$home"
  review "$home" $((UNTIL + 60)) run > /dev/null || fail "first run failed"
  out=$(review "$home" $((UNTIL + 86400 + 60)) run) || fail "second run failed: $out"
  numbers="$home/data/day-review/2026-10-26/numbers.json"
  assert_equals "$UNTIL.0" "$(metric "$numbers" since)" "the second review does not start where the first ended"
  # No task finished on the second day, so no per task rate exists to judge.
  assert_equals "no data" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["previousAdvice"][0]["verdict"])' "$numbers")" "advice was judged on raw totals"
}

test_arm_and_disarm() {
  local home out shim
  home=$(make_home arming)
  out=$(FM_HOME="$home" "$TOOL" arm 2>&1)
  assert_contains "$out" "armed: state/day-review.check.sh" "arm failed"
  shim="$home/state/day-review.check.sh"
  out=$(FM_DAY_REVIEW_NOW="$UNTIL" "$shim" 2>&1)
  assert_contains "$out" "day-review due" "shim did not run the check"
  FM_HOME="$home" "$TOOL" disarm >/dev/null 2>&1
  assert_absent "$shim" "disarm left the check shim"
  assert_absent "$home/state/day-review.check-trust" "disarm left the trust binding"
}

test_due_at_the_moscow_hour_whatever_the_host_zone
test_custom_time_and_zone
test_off_afk_and_bad_config
test_run_builds_the_board_from_the_records
test_unreachable_secondmate_is_a_gap
test_force_does_not_mark_the_day
test_next_review_judges_advice_per_task
test_arm_and_disarm
pass "fm-day-review"
