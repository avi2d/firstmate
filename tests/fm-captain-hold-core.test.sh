#!/usr/bin/env bash
# The core captain-hold lifecycle: hold, answer, release, deferral, and the completion gate.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.

## References

- fixture source
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.

## References

- fixture source
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/$id.status" | grep -F 'captain-held [key=route]: tracked by sample-route-call' >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# A captain hold is released only in an attended session: the away posture
# record and the away daemon flag each refuse --release, through `answer` and
# the keyed-answer intake alike, before anything is written. No record and a
# quiet record both release, and a closing answer is not gated by posture.
test_release_is_attended_only() {
  local home show out rc
  home=$(make_home release-attended)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" enter \
    --words 'merge green work' >/dev/null 2>&1 || fail "away entry failed"

  rc=0
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release \
    >/dev/null 2>"$home/away.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "answer --release succeeded while the away record exists"
  assert_grep "attended session" "$home/away.err" \
    "the away refusal did not name the attended-session requirement"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: yes" "the away refusal lifted the hold"
  assert_not_contains "$show" "Resolution mode" "the away refusal wrote a resolution record"

  out=$(printf 'sample-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "away release fixture") \
    && fail "the keyed-answer intake released held work while away"
  assert_contains "$out" "refused: sample-widget" "the intake did not report the away refusal"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: yes" "the intake lifted the hold while away"

  run_captain "$home" hold sample-question --title "Pick the widget colour" \
    --reason "captain must pick the colour" --repo sample >/dev/null \
    || fail "could not hold the question for the captain"
  printf 'Blue.\n' > "$home/blue.txt"
  run_captain "$home" answer sample-question --decision-file "$home/blue.txt" >/dev/null \
    || fail "a closing answer was refused while away"
  show=$(tasks_in "$home" show sample-question --full)
  assert_contains "$show" "state: done" "a closing answer while away did not close the question"

  rm -f "$home/state/.afk-contract"
  printf 'away\n%s\n' "$(date +%s)" > "$home/state/.afk"
  rc=0
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "answer --release succeeded while the away daemon flag exists"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: yes" "the daemon-flag refusal lifted the hold"

  rm -f "$home/state/.afk"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed with no away record"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: no" "an attended release kept the hold"
  assert_contains "$show" "Resolution mode: released" "an attended release recorded no release"

  run_captain "$home" hold sample-widget --reason "second captain go needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'quiet\n%s\n' "$(date +%s)" > "$home/state/.afk"
  FM_AFK_MODE=quiet FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "quiet entry failed"
  printf 'Still ship it.\n' > "$home/go-quiet.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go-quiet.txt" --release >/dev/null \
    || fail "answer --release failed in quiet mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: no" "a quiet-mode release kept the hold"
  pass "a captain hold is released only in an attended session: away refuses, quiet and no record release"
}

# A release that waits behind another task action must recheck the away posture
# once it holds the task control lock: the captain can enter away mode during
# the wait, and the release then refuses with the hold still in place.
test_release_rechecks_away_after_waiting_on_task_lock() {
  local home show rc holder i
  home=$(make_home release-race)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Ship it.\n' > "$home/go-race.txt"

  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" && : > "$3" && sleep 30' _ \
    "$ROOT" "$home/state/.control-sample-widget.lock" "$home/control-held" &
  holder=$!
  for i in $(seq 1 100); do [ -e "$home/control-held" ] && break; sleep 0.1; done
  [ -e "$home/control-held" ] || fail "the task control lock was not taken"

  rc=0
  run_captain "$home" answer sample-widget --decision-file "$home/go-race.txt" --release \
    >/dev/null 2>"$home/race.err" &
  local release_pid=$!
  sleep 1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" enter \
    --words 'merge green work' >/dev/null 2>&1 || fail "away entry failed"
  kill "$holder" 2>/dev/null || true
  pkill -P "$holder" 2>/dev/null || true
  rm -rf "$home/state/.control-sample-widget.lock"
  wait "$release_pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "a release that waited on the task lock lifted the hold after away entry"
  assert_grep "attended session" "$home/race.err" "the late refusal did not name the attended-session requirement"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "held: yes" "the waiting release lifted the hold while the away record exists"
  pass "a release waiting on the task lock rechecks the away posture under the lock"
}

# The hold-set stamp must be durable before the captain hold becomes visible.
# A wrapper observes the real tasks-axi hold boundary, and a forced stamp-write
# failure proves the command never publishes the hold without its timestamp.
test_hold_stamp_precedes_hold_visibility() {
  local home show
  home=$(make_home hold-stamp-order)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-old-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)
- [ ] sample-stamp-failure - Existing task whose stamp fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = sample-stamp-failure ]; then
  exit 92
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-old-call ]; then
  show=$("$REAL_TASKS_AXI" show "$2" --full) || exit 93
  printf '%s\n' "$show" | grep -F 'Captain hold set: 2026-07-14T12:00:00Z' >/dev/null || exit 94
  : > "$FM_HOME/hold-observed-after-stamp"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-old-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "hold was published before its hold-set stamp"
  assert_present "$home/hold-observed-after-stamp" \
    "the tasks-axi hold boundary was not observed"
  show=$(tasks_in "$home" show sample-old-call --full)
  assert_contains "$show" "hold_kind: captain" "the stamped task was not captain-held"
  assert_contains "$show" "Captain hold set: 2026-07-14T12:00:00Z" \
    "the visible captain hold lost its timestamp"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-stamp-failure \
    --reason "captain route choice pending" > "$home/stamp-failure.out" 2> "$home/stamp-failure.err"; then
    fail "hold succeeded after its timestamp update failed"
  fi
  show=$(tasks_in "$home" show sample-stamp-failure --full)
  assert_contains "$show" "held: no" "a failed timestamp update still published the hold"
  assert_contains "$show" 'hold_kind: "-"' "a failed timestamp update retained captain-hold provenance"
  pass "captain holds become visible only after their hold-set timestamp is durable"
}

test_interrupted_answer_preserves_hold_age() {
  local home snap show
  home=$(make_home interrupted-answer-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-interrupted-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-interrupted-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the interrupted-answer fixture"
  printf 'Not urgent in the historical answer.\n' > "$home/interrupted-answer.txt"
  mkdir -p "$home/at-close"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/close-failed-once" ]; then
  cp "$FM_HOME/data/backlog.md" "$FM_HOME/at-close/backlog.md" || exit 93
  : > "$FM_HOME/close-failed-once"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = done ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the forced answer close failure reported success"
  fi
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/at-close" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at interrupted close boundary"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-interrupted-call")
    | .captain_actionable == true
      and .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "an interrupted answer lost the fresh hold age basis: $snap"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/normalize.out" 2> "$home/normalize.err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" "state: done" "the normalization failure undid the successful close"
  run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the closed answer could not normalize on retry"
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" 'body: "Resolution recorded by fm-captain-hold.' \
    "the matching done retry did not restore resolution-first body ordering"
  pass "an interrupted answer preserves its hold age until close retry"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-existing-call - Decide an existing sample task (repo: sample) (kind: captain) (since 2026-06-01)
- [ ] sample-near-marker - Decide a deferred sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  Captain hold set: 2026-07-14T12:00:00Z
  abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij DEFERRED
- [ ] sample-late-marker - Decide a documented sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  This deliberately long decision context fills the bounded display excerpt without changing the durable classification contract. Additional synthetic context keeps extending the body beyond that display boundary while remaining ordinary task prose. More synthetic context places the presentation marker after the excerpt cutoff. DEFERRED

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not hold the existing task"
  FM_CAPTAIN_HOLD_NOW=2026-07-20T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not repeat the existing task hold"
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and $existing.since == "2026-06-01" and $existing.hold_set == "2026-07-14T12:00:00Z"
      and $existing.hold_age_days == 0 and $existing.hold_bucket == "live"
      and ([.backlog.records[] | select(.id == "sample-near-marker")][0].hold_bucket == "live")
      and ([.backlog.records[] | select(.id == "sample-late-marker")][0].hold_bucket == "live")
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate, hold-set age, or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-existing-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == true
      and $existing.hold_age_days == 18 and $existing.hold_bucket == "aged"
  ' >/dev/null || fail "a due deferral did not resurface or a stamped hold did not age from its hold date"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.

## References

- fixture source
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_completion_keeps_an_armed_pr_identity_last() {
  local home id url=https://github.com/example/sample/pull/7
  home=$(make_home armed-pr-completion)
  id=sample-armed-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review an armed sample change" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'pr=%s\n' "$url" >> "$home/state/$id.meta"
  printf 'done: review complete\n' > "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "completion with an armed PR identity failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  bash -c '. "$1"; fm_pr_metadata_identity_parse "$2" && [ "$FM_PR_META_URL" = "$3" ]' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$home/state/$id.meta" "$url" \
    || fail "completion broke the armed PR identity the merge poll authenticates:"$'\n'"$(cat "$home/state/$id.meta")"
  pass "completion keeps an armed PR identity last in the task record"
}

test_completion_replaces_a_pair_recorded_after_pr() {
  local home id=sample-legacy-review url=https://github.com/example/sample/pull/8 meta
  home=$(make_home legacy-completion-after-pr)
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a legacy sample change" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  for out in old-call new-call; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$id" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$id.meta"
  # The previous writer appended the completion pair after an armed pr= line.
  printf 'pr=%s\ndecisions_reviewed=1\ndecision_keys=old-call\n' "$url" >> "$meta"
  printf 'done: review complete\n' > "$home/state/$id.status"
  run_captain "$home" complete "$id" new-call >/dev/null \
    || fail "completion over a legacy record failed"
  assert_equals "decision_keys=new-call,old-call" "$(grep '^decision_keys=' "$meta")" \
    "completion kept a stale inventory alongside the new one"
  assert_equals 1 "$(grep -c '^decisions_reviewed=' "$meta")" "completion duplicated the attestation"
  run_captain "$home" verify "$id" >/dev/null || fail "the rewritten inventory did not verify"
  bash -c '. "$1"; fm_pr_metadata_identity_parse "$2" && [ "$FM_PR_META_URL" = "$3" ]' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$meta" "$url" \
    || fail "completion left a legacy pair after the armed PR identity:"$'\n'"$(cat "$meta")"
  pass "completion replaces a completion pair recorded after pr= by the previous writer"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'blocked [key=access]: waiting\ndone: report complete\nnote: cleanup complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "the shared fold retained a pre-terminal blocker"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  printf 'blocked [key=access]: reopened\nnote: more cleanup\n' >> "$home/state/$id.status"
  if run_captain "$home" complete "$id" --none > "$home/reopened.out" 2> "$home/reopened.err"; then
    fail "completion accepted a genuinely reopened post-terminal decision"
  fi
  if run_captain "$home" verify "$id" > "$home/reopened-verify.out" 2> "$home/reopened-verify.err"; then
    fail "verification accepted a genuinely reopened post-terminal decision"
  fi
  printf 'resolved [key=access]: answered\nfailed: investigation ended\nnote: final cleanup\n' >> "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null || fail "resolved reopening blocked completion"
  run_captain "$home" verify "$id" >/dev/null || fail "resolved reopening blocked verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'blocked [key=route]: waiting\ndone: heartbeat complete\nnote: cleanup complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_release_is_attended_only
test_release_rechecks_away_after_waiting_on_task_lock
test_hold_stamp_precedes_hold_visibility
test_interrupted_answer_preserves_hold_age
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_completion_keeps_an_armed_pr_identity_last
test_completion_replaces_a_pair_recorded_after_pr
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
