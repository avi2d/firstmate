#!/usr/bin/env bash
# Captain holds owned by a secondmate home.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n\n## References\n\n- fixture source\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\] \\[at=[0-9]+\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

test_secondmate_reconcile_publishes_before_request_retirement() {
  local parent mate channel evidence out show rc request
  parent=$(make_home reconcile-parent-channel)
  mate=$(make_home reconcile-channel-mate)
  printf 'reconcile-channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  channel="$parent/state/reconcile-channel-mate.status"
  evidence="$mate/reconcile-evidence.txt"

  tasks_in "$mate" add reconcile-channel-call "Verify the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the reconcile channel call"
  run_captain "$mate" hold reconcile-channel-call --reason "verify current release state" >/dev/null \
    || fail "could not hold the reconcile channel call"
  request_reconciles "$mate" reconcile-board reconcile-channel-call \
    || fail "could not request the channel reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  request="$mate/state/reconcile-requests/reconcile-channel-call.request"

  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" reconcile close reconcile-channel-call \
    --evidence-file "$evidence" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed reconcile request retirement reported success"
  assert_contains "$out" "reconcile-channel-call" \
    "the reconcile retirement failure did not name its task: $out"
  show=$(tasks_in "$mate" show reconcile-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the reconciled close"
  assert_contains "$show" "Resolution mode: reconciled" \
    "request retirement failure lost the reconciled resolution mode"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the parent resolution was not published before retirement failed: $(cat "$channel")"

  run_captain "$mate" reconcile close reconcile-channel-call --evidence-file "$evidence" >/dev/null \
    || fail "the closed reconciliation could not finish publication and retirement"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the reconciliation retry duplicated or changed its parent resolution: $(cat "$channel")"
  tasks_in "$mate" add answer-channel-call "Answer the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the normal-answer channel call"
  run_captain "$mate" hold answer-channel-call --reason "captain answer needed" >/dev/null \
    || fail "could not hold the normal-answer channel call"
  request_reconciles "$mate" reconcile-board answer-channel-call \
    || fail "could not create the normal-answer retry trigger"
  printf 'Proceed with the release.\n' > "$mate/answer.txt"
  request="$mate/state/reconcile-requests/answer-channel-call.request"
  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed normal-answer request retirement reported success"
  show=$(tasks_in "$mate" show answer-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the captain answer"
  [ -f "$request" ] || fail "the normal-answer retry trigger retired after its forced failure"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal answer did not publish before retirement failed: $(cat "$channel")"
  run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" >/dev/null \
    || fail "the normal-answer retry could not finish request retirement"
  [ ! -e "$request" ] || fail "the normal-answer retry left its request pending"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal-answer retry duplicated its parent resolution: $(cat "$channel")"
  pass "secondmate resolutions publish before retiring durable retry triggers"
}

test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_secondmate_reconcile_publishes_before_request_retirement
