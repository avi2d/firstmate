#!/usr/bin/env bash
# Hold origins follow backend holds, and refuse self-entries and foreign origins.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

# A refused hold must never read as a recorded one. The gate used to accept the
# origin as its own inventory whenever the origin row looked durable, so a hold
# that failed just before `complete <origin> <origin>` left a satisfied gate
# with no captain call recorded.
test_origin_is_never_its_own_inventory_entry() {
  local home id
  home=$(make_home origin-self-inventory)
  id=sample-self-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample self review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  if run_captain "$home" hold "$id" --reason "" >/dev/null 2> "$home/hold.err"; then
    fail "hold accepted an empty reason"
  fi
  if run_captain "$home" complete "$id" "$id" > "$home/self.out" 2> "$home/self.err"; then
    fail "complete accepted the origin as its own inventory after a failed hold"
  fi
  assert_grep "cannot be its own captain-call inventory entry" "$home/self.err" \
    "the refusal does not say why the origin was rejected"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  # Holding the origin row itself must not let it vouch for itself either.
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold the origin row"
  if run_captain "$home" complete "$id" "$id" > "$home/held.out" 2> "$home/held.err"; then
    fail "complete accepted a held origin row as its own inventory"
  fi
  pass "complete refuses the origin as its own captain-call inventory"
}

# `hold --origin` records which origin a call was held for, and `complete`
# refuses a task held for a different origin. A hold recorded before that
# record existed, or without --origin, still verifies and is flagged.
test_complete_refuses_an_entry_held_for_another_origin() {
  local home id other o out
  home=$(make_home origin-mismatch)
  id=sample-first-review
  other=sample-second-review
  for o in "$id" "$other"; do
    mkdir -p "$home/data/$o"
    tasks_in "$home" add "$o" "Investigate $o" --kind scout --repo sample --start >/dev/null \
      || fail "could not create the $o fixture"
    write_origin_meta "$home" "$o"
    printf 'done: report complete\n' > "$home/state/$o.status"
  done
  run_captain "$home" hold sample-other-call --title "Call for the second review" \
    --reason "captain must decide" --repo sample --origin "$other" >/dev/null \
    || fail "could not hold the call recorded for the second review"
  if run_captain "$home" complete "$id" sample-other-call > "$home/mismatch.out" 2> "$home/mismatch.err"; then
    fail "complete accepted an entry held for a different origin"
  fi
  assert_grep "was held for origin $other, not $id" "$home/mismatch.err" \
    "the refusal does not name both origins"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  run_captain "$home" hold sample-own-call --title "Call for the first review" \
    --reason "captain must decide" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the call recorded for the first review"
  out=$(run_captain "$home" complete "$id" sample-own-call) \
    || fail "complete refused an entry held for its own origin"
  assert_not_contains "$out" "no recorded origin" \
    "an entry with a recorded origin was flagged as unrecorded"

  tasks_in "$home" add sample-old-call "Call held before origins were recorded" --kind captain --repo sample >/dev/null \
    || fail "could not create the older call"
  tasks_in "$home" hold sample-old-call --reason "captain must decide" --kind captain >/dev/null \
    || fail "could not hold the older call"
  out=$(run_captain "$home" complete "$other" sample-old-call) \
    || fail "complete refused an older hold with no recorded origin"
  assert_contains "$out" "no recorded origin on: sample-old-call" \
    "an older hold with no recorded origin was not flagged"
  pass "complete refuses an entry held for another origin and flags one with none recorded"
}

test_hold_origins_follow_backend_holds() {
  local home phase timing failure id shown origin out parent channel occurrence until_args=()
  for phase in new active released; do
    for timing in plain dated; do
      home=$(make_home "origin-failure-$phase-$timing")
      parent=$(make_home "origin-parent-$phase-$timing")
      channel="$parent/state/origin-mate.status"
      occurrence=1
      [ "$phase" != released ] || occurrence=2
      id=sample-call
      for origin in origin-a origin-b; do
        tasks_in "$home" add "$origin" "Review $origin" --kind scout --repo sample >/dev/null \
          || fail "could not create $origin"
        write_origin_meta "$home" "$origin"
      done
      if [ "$phase" != new ]; then
        run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
          --origin origin-a >/dev/null || fail "could not establish the original association"
      fi
      if [ "$phase" = released ]; then
        printf 'Release this work.\n' > "$home/answer.txt"
        run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
          || fail "could not release the original hold"
      fi
      cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = origin-b ] && [ -f "$FM_HOME/fail-lookup" ]; then
  : > "$FM_HOME/lookup-refused"
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "${1:-}" = update ]; then
  previous=''
  for arg in "$@"; do
    if [ "$previous" = --body-file ] && grep -qx 'Captain hold origin: origin-b' "$arg"; then
      [ -f "$FM_HOME/backend-held" ] || exit 8
      "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-origin-write" || exit $?
      if [ -f "$FM_HOME/fail-write" ]; then
        channel="$(sed -n 's/^parent_home=//p' "$FM_HOME/.fm-secondmate-parent")/state/origin-mate.status"
        [ ! -f "$channel" ] || cp "$channel" "$FM_HOME/parent-before-origin-write"
        : > "$FM_HOME/write-refused"
        exit 9
      fi
    fi
    previous=$arg
  done
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  if [ -f "$FM_HOME/fail-hold" ]; then
    : > "$FM_HOME/hold-refused"
    exit 9
  fi
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/backend-held"
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
SH
      chmod +x "$home/fakebin/tasks-axi"
      until_args=()
      [ "$timing" != dated ] || until_args=(--until 2099-01-01)
      for failure in lookup hold write; do
        if [ "$failure" = write ]; then
          printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
            > "$home/.fm-secondmate-parent"
          printf 'origin-mate\n' > "$home/.fm-secondmate-home"
        fi
        : > "$home/fail-$failure"
        if run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for B" \
          --origin origin-b ${until_args[@]+"${until_args[@]}"} > "$home/hold.out" 2> "$home/hold.err"; then
          fail "$phase $timing hold succeeded despite an origin $failure failure"
        fi
        assert_present "$home/$failure-refused" "the failure did not reach the origin $failure"
        if [ "$failure" = lookup ]; then
          assert_absent "$home/before-backend-hold" "$phase $timing origin lookup failure reached the backend hold"
        else
          assert_present "$home/before-backend-hold" "$phase $timing failure never reached the backend hold"
          assert_no_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
            "the backend hold saw the new association before succeeding"
          rm "$home/before-backend-hold"
        fi
        if [ "$failure" = write ]; then
          assert_present "$home/backend-held" "the origin write preceded backend success"
          assert_grep 'held: yes' "$home/before-origin-write" "the origin write did not follow a live hold"
          assert_grep 'hold_kind: captain' "$home/before-origin-write" "the origin write did not follow a captain hold"
          assert_present "$home/parent-before-origin-write" "the verified hold was not published before the origin write"
          assert_grep "needs-decision [key=captain-hold-$id-$occurrence]: captain hold $id: Choose for B" \
            <(sed -E 's/ \[at=[0-9]+\]//' "$home/parent-before-origin-write") \
            "the origin-write failure stranded the hold without its parent event"
          assert_equals 1 "$(grep -Fc "needs-decision [key=captain-hold-$id-$occurrence]" "$channel")" \
            "the failed origin write did not publish exactly one parent decision"
        fi
        shown=$(tasks_in "$home" show "$id" --full)
        assert_not_contains "$shown" 'Captain hold origin: origin-b' \
          "$phase $timing origin $failure failure published the new association"
        if [ "$phase" = active ] || [ "$failure" = write ]; then
          assert_contains "$shown" 'held: yes' "an origin $failure failure lost the successful hold"
        else
          assert_contains "$shown" 'held: no' "$phase $timing origin $failure failure left the task held"
        fi
        if [ "$phase" != new ]; then
          assert_contains "$shown" 'Captain hold origin: origin-a' \
            "$phase $timing origin $failure failure lost the original association"
        fi
        rm "$home/fail-$failure"
        rm -f "$home/backend-held" "$home/before-origin-write"
        if [ "$phase" = new ] && [ "$failure" = write ]; then
          out=$(run_captain "$home" complete origin-b "$id") \
            || fail "the unrecorded successful hold was not durable"
          assert_contains "$out" "no recorded origin on: $id" "the unrecorded hold was claimed to have an origin"
          run_captain "$home" verify origin-b >/dev/null || fail "the unrecorded hold could not verify"
          continue
        fi
        if [ "$phase" = new ] && run_captain "$home" complete origin-a "$id" \
          > "$home/unrelated.out" 2> "$home/unrelated.err"; then
          fail "$timing origin $failure failure satisfied an unrelated inventory"
        fi
        if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
          fail "$phase $timing origin $failure failure satisfied completion for B"
        fi
        printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
        if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
          fail "$phase $timing origin $failure failure verified an inventory for B"
        fi
        if [ "$phase" != new ]; then
          run_captain "$home" complete origin-a "$id" >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated completion for A"
          run_captain "$home" verify origin-a >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated verification for A"
        fi
      done
      run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
        ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "$phase $timing successful retry failed"
      assert_present "$home/before-backend-hold" "the successful retry did not reach the backend hold"
      shown=$(cat "$home/before-backend-hold")
      assert_not_contains "$shown" 'Captain hold origin: origin-b' "the backend hold ran with the new association already published"
      if [ "$phase" != new ]; then
        assert_contains "$shown" 'Captain hold origin: origin-a' "the backend hold lost the old association before succeeding"
      fi
      assert_grep 'held: yes' "$home/before-origin-write" "the successful origin write preceded a live hold"
      shown=$(tasks_in "$home" show "$id" --full)
      assert_contains "$shown" 'held: yes' "the successful retry did not hold the task"
      assert_contains "$shown" 'Captain hold origin: origin-b' "a successful hold lost its association"
      assert_not_contains "$shown" 'Captain hold origin: origin-a' "a successful hold retained the old association"
      assert_equals 1 "$(grep -Fc "needs-decision [key=captain-hold-$id-$occurrence]" "$channel")" \
        "retrying the origin write duplicated the parent decision"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "a successful hold could not complete B"
      run_captain "$home" verify origin-b >/dev/null || fail "a successful hold could not verify B"
      if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/old-origin.err"; then
        fail "a successful reassociation still certified A"
      fi
    done
  done
  pass "new, active, and released holds publish origins after backend success with and without deferral"
}

test_hold_origins_follow_backend_holds
test_origin_is_never_its_own_inventory_entry
test_complete_refuses_an_entry_held_for_another_origin
