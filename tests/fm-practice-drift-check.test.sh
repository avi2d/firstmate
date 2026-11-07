#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-practice-drift-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-practice-drift-check)
REAL_GIT=$(command -v git)
DAY=86400
NOV_1_2026_1600=1793548800
KIT='@example/checks'

fm_git_identity fmtest fmtest@example.invalid

make_world() {
  local world="$TMP_ROOT/$1" fakebin
  mkdir -p "$world/home/state" "$world/home/config" "$world/home/projects" "$world/home/data" \
    "$world/gh" "$world/trees"
  printf '{"kit":{"package":"%s","repo":"example/checks"}}\n' "$KIT" > "$world/home/config/practice-drift.json"
  : > "$world/backlog.txt"
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
key=\$(printf '%s' "\$2" | tr '/?&=%' '_____')
printf '%s\n' "\$2" >> "$world/gh.log"
[ ! -e "$world/gh/\$key.fail" ] || { printf 'error: "boom"\n'; exit 1; }
[ -f "$world/gh/\$key.json" ] || { printf 'error: "gh: Not Found (HTTP 404)"\ncode: NOT_FOUND\n'; exit 1; }
printf 'api_response:\n  body: "%s"\n  truncated: false\n' "\$(jq -r "\$5" "$world/gh/\$key.json")"
SH
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = clone ]; then
  dest=\${*: -1:1}
  url=\${*: -2:1}
  slug=\${url#https://github.com/}
  slug=\${slug%.git}
  printf '%s\n' "\$slug" >> "$world/clone.log"
  [ -d "$world/trees/\${slug%%/*}_\${slug#*/}" ] || exit 128
  cp -R "$world/trees/\${slug%%/*}_\${slug#*/}" "\$dest"
  exec "$REAL_GIT" -C "\$dest" init -q -b main
fi
exec "$REAL_GIT" "\$@"
SH
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
[ ! -e "$world/backlog.fail" ] || exit 1
cat "$world/backlog.txt"
SH
  cat > "$fakebin/checks-ci-wiring" <<'SH'
#!/usr/bin/env bash
if [ -f .github/ci-wiring-fail ]; then
  cat .github/ci-wiring-fail
  exit 1
fi
printf 'ci-wiring: 6 gate(s) run on pull requests to main\n'
SH
  cat > "$fakebin/bun" <<SH
#!/usr/bin/env bash
cwd=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "--cwd" ]; then cwd="\$arg"; fi
  prev="\$arg"
done
[ -n "\$cwd" ] || exit 1
mkdir -p "\$cwd/node_modules/.bin"
cp "$world/fakebin/checks-ci-wiring" "\$cwd/node_modules/.bin/checks-ci-wiring"
chmod +x "\$cwd/node_modules/.bin/checks-ci-wiring"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$world"
}

gh_key() {
  local path=$1
  printf '%s' "$path" | tr '/?&=%' '_____'
}

gh_fixture() {
  local world=$1 path=$2 json=$3
  printf '%s\n' "$json" > "$world/gh/$(gh_key "$path").json"
}

gh_break() {
  local world=$1 path=$2
  : > "$world/gh/$(gh_key "$path").fail"
}

gh_mend() {
  local world=$1 path=$2
  rm -f "$world/gh/$(gh_key "$path").fail"
}

issues_path() {
  local slug=$1
  printf 'repos/%s/issues?state=open&creator=github-actions%%5Bbot%%5D&per_page=100\n' "$slug"
}

schedule_path() {
  local slug=$1 file=$2
  printf 'repos/%s/actions/workflows/%s/runs?event=schedule&branch=main&status=completed&per_page=10\n' "$slug" "$file"
}

# Writes the same manifest a fresh clone of main would see.
add_project() {
  local world=$1 name=$2 manifest=$3 origin=${4:-https://github.com/example/$2.git} dir
  dir="$world/home/projects/$name"
  mkdir -p "$dir"
  "$REAL_GIT" -C "$dir" init -q -b main
  printf '%s\n' "$manifest" > "$dir/package.json"
  "$REAL_GIT" -C "$dir" add package.json
  "$REAL_GIT" -C "$dir" commit -qm initial
  "$REAL_GIT" -C "$dir" remote add origin "$origin"
  mkdir -p "$world/trees/example_$name/.github/workflows"
  printf '%s\n' "$manifest" > "$world/trees/example_$name/package.json"
  gh_fixture "$world" "$(issues_path "example/$name")" '[]'
  gh_fixture "$world" "repos/example/$name" '{"private":false,"owner":{"type":"Organization"},"allow_merge_commit":false,"allow_rebase_merge":false,"allow_squash_merge":true}'
  gh_fixture "$world" "repos/example/$name/pulls?state=open&per_page=100" '[]'
}

kit_release() {
  local world=$1 tag=$2
  gh_fixture "$world" "repos/example/checks/releases/latest" "{\"tag_name\":\"$tag\"}"
}

# A kit user that is current on every practice.
add_tidy_project() {
  local world=$1 name=$2
  add_project "$world" "$name" "{\"name\":\"$name\",\"author\":\"Example Maintainer <maintainer@example.com>\",\"devDependencies\":{\"$KIT\":\"^0.69.0\"}}"
  printf 'jobs:\n  lint:\n    steps:\n      - run: bunx checks-lint\n' > "$world/trees/example_$name/.github/workflows/ci.yml"
}

run_check() {
  local world=$1 now=$2 status=0
  shift 2
  env FM_CHECK_TIMEOUT=30 FM_PRACTICE_DRIFT_NOW="$now" "$@" \
    PATH="$world/fakebin:$PATH" FM_HOME="$world/home" \
    "$CHECK" check > "$world/out.txt" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
  cat "$world/out.txt"
}

assert_lines() {
  local expected=$1 out=$2
  [ "$(printf '%s' "$out" | grep -c '^practice drift: ')" = "$expected" ] \
    || fail "expected $expected report line(s): $out"
}

test_tidy_kit_user_is_not_reported_as_drift() {
  local world out
  world=$(make_world tidy)
  kit_release "$world" v0.69.0
  add_tidy_project "$world" tidy
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_equals "" "$out" "a repository current on every practice raised a report"
  pass "a repository current on every practice is silent"
}

test_first_sweep_names_each_drifted_practice_on_one_line() {
  local world out
  world=$(make_world drift)
  kit_release "$world" v0.69.0
  add_project "$world" web "{\"name\":\"web\",\"dependencies\":{\"$KIT\":\"0.61.1\"}}"
  printf 'on:\n  schedule:\n    - cron: "0 3 * * *"\n' > "$world/trees/example_web/.github/workflows/daily-release.yml"
  printf 'jobs:\n  gate:\n    steps:\n      - run: bunx checks-lint --night\n' > "$world/trees/example_web/.github/workflows/night-run.yml"
  printf 'ci-wiring: 1 job(s) can run for hours:\n  release.yml job github-release\nci-wiring: 6 gate(s) run on pull requests to main\n' \
    > "$world/trees/example_web/.github/ci-wiring-fail"
  gh_fixture "$world" "$(schedule_path example/web daily-release.yml)" \
    '{"workflow_runs":[{"conclusion":"failure","created_at":"2026-11-01T03:00:00Z"},{"conclusion":"failure","created_at":"2026-10-31T03:00:00Z"},{"conclusion":"success","created_at":"2026-10-30T03:00:00Z"}]}'
  gh_fixture "$world" "repos/example/web" '{"private":true,"owner":{"type":"Organization"},"allow_merge_commit":true,"allow_rebase_merge":false}'
  gh_fixture "$world" "repos/example/web/pulls?state=open&per_page=100" \
    '[{"number":7,"title":"chore: release 1.2.0","html_url":"https://github.com/example/web/pull/7","created_at":"2026-10-20T00:00:00Z","user":{"login":"github-actions[bot]"}},{"number":8,"title":"chore: release by hand","html_url":"https://github.com/example/web/pull/8","created_at":"2026-10-20T00:00:00Z","user":{"login":"someone"}}]'
  gh_fixture "$world" "$(issues_path example/web)" \
    '[{"number":110,"html_url":"https://github.com/example/web/issues/110","created_at":"2026-10-30T16:00:00Z","comments":1,"user":{"login":"github-actions[bot]"},"labels":[{"name":"night-run"}]},{"number":111,"pull_request":{},"html_url":"https://github.com/example/web/pull/111","created_at":"2026-10-30T16:00:00Z","comments":0,"user":{"login":"github-actions[bot]"}}]'
  gh_fixture "$world" "repos/example/web/issues/110/comments?per_page=1&page=1" \
    '[{"created_at":"2026-10-31T03:00:00Z","body":"failed again: https://github.com/example/web/actions/runs/4242"}]'
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_lines 1 "$out"
  assert_contains "$out" "practice drift: web: " "the line does not name the repository"
  assert_contains "$out" "kit-pin: pins 0.61.1, newest release 0.69.0" "an old kit pin went unreported"
  assert_contains "$out" "retired-workflow: night-run.yml" "a retired workflow still in place went unreported"
  assert_contains "$out" "author: package.json names no author and no contributors" "a missing author went unreported"
  assert_contains "$out" "ci-wiring: 1 job(s) can run for hours" "a failing ci-wiring went unreported"
  assert_not_contains "$out" "6 gate(s) run on pull requests" "a passing ci-wiring line was reported as drift"
  assert_contains "$out" "merge-methods: allows merge commits" "merge commits went unreported"
  assert_contains "$out" "runs-on: private and sets no CI_RUNS_ON variable" "a private repository without CI_RUNS_ON went unreported"
  assert_contains "$out" "schedule-daily-release: daily-release.yml failure on main, 2 scheduled runs in a row" "a failing scheduled workflow went unreported"
  assert_contains "$out" "release-pr-7: https://github.com/example/web/pull/7 open since 2026-10-20" "a stale release pull request went unreported"
  assert_not_contains "$out" "release-pr-8" "a hand-made pull request was taken for a release pull request"
  assert_contains "$out" "issue-110: https://github.com/example/web/issues/110 open 2 days, 1 comment, last comment 2026-10-31 by run 4242" "an open failure issue went unreported"
  assert_not_contains "$out" "issue-111" "a pull request was taken for an issue"
  pass "the first sweep names every drifted practice on one line per repository"
}

test_same_findings_next_day_are_silent_and_changes_are_reported() {
  local world out
  world=$(make_world repeat)
  kit_release "$world" v0.69.0
  add_project "$world" app "{\"name\":\"app\",\"author\":\"Example\",\"devDependencies\":{\"$KIT\":\"^0.52.0\"}}"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "practice drift: app: kit-pin: pins ^0.52.0, newest release 0.69.0" "the old pin went unreported"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY))")
  assert_equals "" "$out" "an unchanged finding was reported twice"
  kit_release "$world" v0.70.0
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 2 * DAY))")
  assert_equals "" "$out" "the same pin behind a newer release was reported as a change"
  printf '{"name":"app","author":"Example","devDependencies":{"%s":"^0.70.0"}}\n' "$KIT" > "$world/trees/example_app/package.json"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 3 * DAY))")
  assert_equals "practice drift: app: kit-pin cleared" "$out" "a fixed pin was not reported as cleared"
  pass "unchanged findings stay silent, a fix is reported as cleared"
}

test_daily_gate_holds_until_the_sweep_hour() {
  local world out
  world=$(make_world gate)
  kit_release "$world" v0.69.0
  add_project "$world" app "{\"name\":\"app\",\"author\":\"Example\",\"devDependencies\":{\"$KIT\":\"0.60.0\"}}"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_lines 1 "$out"
  gh_fixture "$world" "$(issues_path example/app)" \
    '[{"number":5,"html_url":"https://github.com/example/app/issues/5","created_at":"2026-11-02T03:00:00Z","comments":0,"user":{"login":"github-actions[bot]"},"labels":[{"name":"night-run"}]}]'
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY - 2 * 3600))")
  assert_equals "" "$out" "a sweep ran before the next day's sweep hour"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY - 3600 + 60))")
  assert_contains "$out" "issue-5: " "the sweep after the hour did not run"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY + 3600))")
  assert_equals "" "$out" "a second sweep ran on the same day"
  pass "one sweep a day, at the first check after 15:00 UTC"
}

test_unreadable_reads_print_every_sweep_and_keep_findings() {
  local world out
  world=$(make_world unread)
  kit_release "$world" v0.69.0
  add_project "$world" app "{\"name\":\"app\",\"author\":\"Example\",\"devDependencies\":{\"$KIT\":\"0.60.0\"}}"
  gh_fixture "$world" "repos/example/app" '{"private":false,"owner":{"type":"Organization"},"allow_merge_commit":true,"allow_rebase_merge":false}'
  gh_fixture "$world" "$(issues_path example/app)" \
    '[{"number":5,"html_url":"https://github.com/example/app/issues/5","created_at":"2026-11-01T03:00:00Z","comments":0,"user":{"login":"github-actions[bot]"},"labels":[{"name":"night-run"}]}]'
  run_check "$world" "$NOV_1_2026_1600" > /dev/null
  gh_break "$world" "repos/example/app"
  gh_break "$world" "$(issues_path example/app)"
  rm -rf "$world/trees/example_app"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY))")
  assert_lines 1 "$out"
  assert_contains "$out" "settings unreadable: the GitHub read failed" "a failed settings read was not printed as unreadable"
  assert_contains "$out" "issues unreadable: the GitHub read failed" "a failed issues read was not printed as unreadable"
  assert_contains "$out" "main unreadable: cloning main failed" "a failed clone was not printed as unreadable"
  assert_not_contains "$out" "cleared" "an unreadable practice was reported as cleared"
  assert_not_contains "$out" "closed" "an unreadable issue was reported as closed"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 2 * DAY))")
  assert_contains "$out" "settings unreadable" "an unreadable repository went quiet on the next sweep"
  gh_mend "$world" "repos/example/app"
  gh_mend "$world" "$(issues_path example/app)"
  mkdir -p "$world/trees/example_app/.github"
  printf '{"name":"app","author":"Example","devDependencies":{"%s":"0.60.0"}}\n' "$KIT" > "$world/trees/example_app/package.json"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 3 * DAY))")
  assert_equals "" "$out" "findings kept through an unreadable sweep were reported again as new"
  pass "an unreadable read prints every sweep and keeps the recorded findings"
}

test_unread_kit_release_is_unreadable_not_clean() {
  local world out
  world=$(make_world nokit)
  add_project "$world" app "{\"name\":\"app\",\"author\":\"Example\",\"devDependencies\":{\"$KIT\":\"0.60.0\"}}"
  gh_break "$world" "repos/example/checks/releases/latest"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "kit-pin unreadable: the newest kit release is unknown" "an unknown kit release passed the pin as clean"
  assert_contains "$out" "ci-wiring unreadable" "ci-wiring without a kit passed as clean"
  pass "an unread kit release leaves the pin and ci-wiring unreadable, not clean"
}

test_issue_prints_when_seen_and_once_more_when_a_week_old_without_a_backlog_row() {
  local world out
  world=$(make_world issues)
  add_project "$world" tool '{"name":"tool"}'
  gh_fixture "$world" "$(issues_path example/tool)" \
    '[{"number":15,"html_url":"https://github.com/example/tool/issues/15","created_at":"2026-11-01T03:00:00Z","comments":5,"user":{"login":"github-actions[bot]"},"labels":[{"name":"night-run"}]},{"number":150,"html_url":"https://github.com/example/tool/issues/150","created_at":"2026-11-01T03:00:00Z","comments":0,"user":{"login":"github-actions[bot]"},"labels":[{"name":"daily-tests"}]}]'
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "issue-15: https://github.com/example/tool/issues/15 open 0 days, 5 comments" "a new issue went unreported"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 3 * DAY))")
  assert_equals "" "$out" "a known issue younger than 7 days was reported again"
  printf 'tasks[1]{id,body}:\n  fix-150,"Fix https://github.com/example/tool/issues/150"\n' > "$world/backlog.txt"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 7 * DAY))")
  assert_contains "$out" "issue-15: https://github.com/example/tool/issues/15 open 7 days with no backlog row" "a week-old issue without a backlog row was not reported again"
  assert_not_contains "$out" "issue-150" "an issue a backlog row names was reported as untracked"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 8 * DAY))")
  assert_equals "" "$out" "a week-old untracked issue was reported a third time"
  [ ! -e "$world/clone.log" ] || fail "a repository the kit does not apply to was cloned"
  gh_fixture "$world" "$(issues_path example/tool)" '[]'
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 9 * DAY))")
  assert_equals "practice drift: tool: issue-15 closed; issue-150 closed" "$out" "closed issues went unreported"
  pass "an issue prints when seen and once more after 7 days with no backlog row"
}

test_unreadable_backlog_does_not_mark_an_issue_untracked() {
  local world out
  world=$(make_world nobacklog)
  add_project "$world" tool '{"name":"tool"}'
  gh_fixture "$world" "$(issues_path example/tool)" \
    '[{"number":15,"html_url":"https://github.com/example/tool/issues/15","created_at":"2026-11-01T03:00:00Z","comments":0,"user":{"login":"github-actions[bot]"},"labels":[{"name":"night-run"}]}]'
  run_check "$world" "$NOV_1_2026_1600" > /dev/null
  : > "$world/backlog.fail"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 8 * DAY))")
  assert_equals "practice drift: tool: issue-15: backlog unreadable" "$out" "an unread backlog was taken as no backlog row"
  pass "an unreadable backlog is printed as unreadable, not as an untracked issue"
}

test_kit_clone_without_github_origin_is_unreadable() {
  local world out
  world=$(make_world local)
  kit_release "$world" v0.69.0
  add_project "$world" offline "{\"name\":\"offline\",\"devDependencies\":{\"$KIT\":\"0.60.0\"}}" "file:///nowhere/offline.git"
  add_project "$world" other '{"name":"other"}' "file:///nowhere/other.git"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_equals "practice drift: offline: unreadable: origin is not a GitHub repository" "$out" "a kit clone off GitHub was not printed as unreadable"
  pass "a kit clone whose origin is not on GitHub is unreadable"
}

test_retired_gate_under_another_workflow_name_is_still_reported() {
  local world out
  world=$(make_world self)
  kit_release "$world" v0.69.0
  add_project "$world" checks "{\"name\":\"$KIT\",\"author\":\"Example\"}"
  printf 'jobs:\n  gate:\n    steps:\n      - run: bun src/lint.ts --night\n' > "$world/trees/example_checks/.github/workflows/sweep.yaml"
  printf 'jobs:\n  lint:\n    steps:\n      - run: bun src/lint.ts\n' > "$world/trees/example_checks/.github/workflows/ci.yml"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_equals "practice drift: checks: retired-workflow: sweep.yaml" "$out" "a retired gate under another workflow name went unreported"
  rm "$world/trees/example_checks/.github/workflows/sweep.yaml"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY))")
  assert_equals "practice drift: checks: retired-workflow cleared" "$out" "removing the retired workflow was not reported as cleared"
  pass "a retired gate is reported by what it runs and cleared when removed"
}

test_many_findings_stay_one_capped_line() {
  local world out json i
  world=$(make_world cap)
  add_project "$world" tool '{"name":"tool"}'
  json='['
  for i in $(seq 1 60); do
    json="$json{\"number\":$i,\"html_url\":\"https://github.com/example/tool/issues/$i\",\"created_at\":\"2026-11-01T03:00:00Z\",\"comments\":0,\"user\":{\"login\":\"github-actions[bot]\"},\"labels\":[{\"name\":\"night-run\"}]},"
  done
  gh_fixture "$world" "$(issues_path example/tool)" "${json%,}]"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_lines 1 "$out"
  [ "${#out}" -le 1000 ] || fail "the report line ran past the 1000 character cap: ${#out}"
  pass "many findings stay one capped line"
}

test_missing_configuration_is_one_line() {
  local world out
  world=$(make_world noconfig)
  rm "$world/home/config/practice-drift.json"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "practice drift: no practice drift configuration at " "a missing configuration was silent"
  assert_lines 1 "$out"
  pass "a missing configuration is reported on one line"
}

test_help_names_every_action() {
  local out status=0
  out=$("$CHECK" --help 2>&1) || status=$?
  expect_code 0 "$status" "help exit"
  assert_contains "$out" "arm" "help omits arm"
  assert_contains "$out" "disarm" "help omits disarm"
  assert_contains "$out" "[check]" "help omits check"
  status=0
  "$CHECK" bogus > /dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown action exit"
  pass "help names every action and an unknown action is a usage error"
}

test_arm_and_disarm() {
  local world shim status=0
  world=$(make_world arm)
  FM_HOME="$world/home" "$CHECK" arm > /dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  shim="$world/home/state/practice-drift.check.sh"
  [ -f "$shim" ] && [ -x "$shim" ] || fail "arm did not write an executable check shim"
  [ -f "$world/home/state/practice-drift.check-trust" ] || fail "arm did not bind the check bytes"
  FM_HOME="$world/home" "$CHECK" disarm > /dev/null 2>&1 || status=$?
  expect_code 0 "$status" "disarm exit"
  [ ! -e "$shim" ] || fail "disarm left the check shim behind"
  [ ! -e "$world/home/state/practice-drift.check-trust" ] || fail "disarm left the trust binding behind"
  pass "arm writes and binds the shim, disarm removes it"
}

test_young_release_pull_request_stays_silent_until_a_week_old() {
  local world out
  world=$(make_world youngpr)
  kit_release "$world" v0.69.0
  add_tidy_project "$world" app
  gh_fixture "$world" "repos/example/app/pulls?state=open&per_page=100" \
    '[{"number":9,"title":"chore: release 1.2.0","html_url":"https://github.com/example/app/pull/9","created_at":"2026-10-29T16:00:00Z","user":{"login":"github-actions[bot]"}}]'
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_equals "" "$out" "a 3 day old release pull request was reported"
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 4 * DAY))")
  assert_contains "$out" "release-pr-9: https://github.com/example/app/pull/9 open since 2026-10-29" "the same release pull request at 7 days went unreported"
  pass "a young release pull request stays silent until a week old"
}

test_bot_issue_without_a_drift_label_stays_silent() {
  local world out
  world=$(make_world otherlabel)
  add_project "$world" tool '{"name":"tool"}'
  gh_fixture "$world" "$(issues_path example/tool)" \
    '[{"number":21,"html_url":"https://github.com/example/tool/issues/21","created_at":"2026-10-20T03:00:00Z","comments":0,"user":{"login":"github-actions[bot]"},"labels":[{"name":"dependency-update"}]}]'
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_equals "" "$out" "a bot issue with another label was reported"
  pass "a bot issue with another label stays silent"
}

test_user_owned_private_repo_reports_missing_when_org_read_fails() {
  local world out
  world=$(make_world userorg)
  kit_release "$world" v0.69.0
  add_tidy_project "$world" app
  gh_fixture "$world" "repos/example/app" '{"private":true,"owner":{"type":"User"},"allow_merge_commit":false,"allow_rebase_merge":false}'
  gh_break "$world" "repos/example/app/actions/organization-variables?per_page=30"
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "runs-on: private and sets no CI_RUNS_ON variable" "a user-owned private repository without a repo variable went unreported"
  assert_not_contains "$out" "runs-on unreadable" "a user-owned repository misreported the org read as unreadable"
  pass "a user-owned private repository without a variable reports missing"
}

test_org_repo_with_unread_org_vars_is_unreadable_not_missing() {
  local world out
  world=$(make_world orgvars)
  kit_release "$world" v0.69.0
  add_tidy_project "$world" app
  gh_fixture "$world" "repos/example/app" '{"private":true,"owner":{"type":"Organization"},"allow_merge_commit":false,"allow_rebase_merge":false}'
  gh_fixture "$world" "repos/example/app/actions/organization-variables?per_page=30" '{"total_count":31,"variables":[{"name":"OTHER"}]}'
  out=$(run_check "$world" "$NOV_1_2026_1600")
  assert_contains "$out" "runs-on unreadable" "a truncated org variable page passed as missing"
  assert_not_contains "$out" "sets no CI_RUNS_ON variable" "a truncated org variable page was reported as missing"
  gh_fixture "$world" "repos/example/app/actions/organization-variables?per_page=30" '{"total_count":1,"variables":[{"name":"CI_RUNS_ON"}]}'
  out=$(run_check "$world" "$((NOV_1_2026_1600 + DAY))")
  assert_not_contains "$out" "runs-on" "an org variable present past the default page was reported as missing"
  gh_fixture "$world" "repos/example/app/actions/organization-variables?per_page=30" '{"total_count":31,"variables":[{"name":"OTHER"}]}'
  gh_fixture "$world" "repos/example/app/actions/organization-variables?per_page=30&page=2" '{"total_count":31,"variables":[{"name":"CI_RUNS_ON"}]}'
  out=$(run_check "$world" "$((NOV_1_2026_1600 + 2 * DAY))")
  assert_not_contains "$out" "runs-on" "an org variable on the second page was reported as missing"
  pass "an org repository with unread org variables stays unreadable, not missing"
}

fm_test_run \
  test_tidy_kit_user_is_not_reported_as_drift \
  test_first_sweep_names_each_drifted_practice_on_one_line \
  test_same_findings_next_day_are_silent_and_changes_are_reported \
  test_daily_gate_holds_until_the_sweep_hour \
  test_unreadable_reads_print_every_sweep_and_keep_findings \
  test_unread_kit_release_is_unreadable_not_clean \
  test_issue_prints_when_seen_and_once_more_when_a_week_old_without_a_backlog_row \
  test_young_release_pull_request_stays_silent_until_a_week_old \
  test_bot_issue_without_a_drift_label_stays_silent \
  test_user_owned_private_repo_reports_missing_when_org_read_fails \
  test_org_repo_with_unread_org_vars_is_unreadable_not_missing \
  test_unreadable_backlog_does_not_mark_an_issue_untracked \
  test_kit_clone_without_github_origin_is_unreadable \
  test_retired_gate_under_another_workflow_name_is_still_reported \
  test_many_findings_stay_one_capped_line \
  test_missing_configuration_is_one_line \
  test_help_names_every_action \
  test_arm_and_disarm
