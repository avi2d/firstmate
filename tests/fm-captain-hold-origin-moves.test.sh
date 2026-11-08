#!/usr/bin/env bash
# Interrupted origin moves inherit nothing; inventories repair and compare identities.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

test_interrupted_origin_move_does_not_inherit_the_previous_answer() {
  local home id=sample-moved-call shown phase failure o rc until_args=()
  for phase in active expired released-replay released-done; do
    for failure in refused interrupted; do
      home=$(make_home "interrupted-origin-move-$phase-$failure")
      for o in origin-a origin-b; do
        tasks_in "$home" add "$o" "Review $o" --kind scout --repo sample >/dev/null \
          || fail "could not create $o"
        write_origin_meta "$home" "$o"
      done
      run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
        --origin origin-a >/dev/null || fail "could not hold the call for A"
      printf 'Release this work.\n' > "$home/answer.txt"
      run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
        || fail "could not release the call for A"
      until_args=()
      [ "$phase" != expired ] || until_args=(--until 2000-01-01)
      case "$phase" in
        active|expired)
          run_captain "$home" hold "$id" --reason "Choose again for A" --origin origin-a \
            ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "could not re-hold the call for A"
          ;;
      esac
      run_captain "$home" complete origin-a "$id" >/dev/null \
        || fail "the genuine call for A did not complete A"

      cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/hold-refused" ] && [ "${1:-}" = update ]; then
  : > "$FM_HOME/restore-refused"
  exit 9
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  : > "$FM_HOME/hold-refused"
  if [ -f "$FM_HOME/interrupt-hold" ]; then
    kill -TERM "$(cat "$FM_HOME/hold-pid")"
  fi
  exit 9
fi
exec "$REAL_TASKS_AXI" "$@"
SH
      chmod +x "$home/fakebin/tasks-axi"
      rc=0
      if [ "$failure" = interrupted ]; then
        : > "$home/interrupt-hold"
        PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
          FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
          FM_CONFIG_OVERRIDE="$home/config" bash -c \
          'printf "%s\n" "$$" > "$FM_HOME/hold-pid"; exec "$@"' _ \
          "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "Choose for B" --origin origin-b \
          > "$home/hold.out" 2> "$home/hold.err" || rc=$?
        [ "$rc" -eq 143 ] || fail "the hold was not interrupted by TERM: $rc"
        assert_absent "$home/restore-refused" "an interrupted hold attempted restoration"
      else
        run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
          > "$home/hold.out" 2> "$home/hold.err" || rc=$?
        [ "$rc" -ne 0 ] || fail "the hold succeeded although the backend refused it"
        assert_present "$home/restore-refused" "the refused hold did not attempt restoration"
      fi
      assert_present "$home/hold-refused" "the failure did not reach the backend hold"
      assert_no_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
        "the move published B before the backend hold"
      shown=$(tasks_in "$home" show "$id" --full)
      assert_contains "$shown" 'Captain hold origin: origin-a' "the failed move lost A's association"
      assert_not_contains "$shown" 'Captain hold origin: origin-b' "the failed move published B's association"
      assert_contains "$shown" 'Captain hold set:' "the fixture did not retain the uncommitted stamp"
      assert_contains "$shown" 'Release this work.' "the failed move lost the earlier answer"
      if [ "$phase" = active ]; then
        assert_contains "$shown" 'held: yes' "the failed move lifted A's active hold"
      else
        assert_contains "$shown" 'held: no' "the failed move created a live hold"
      fi
      if [ "$phase" = expired ]; then
        assert_contains "$shown" 'hold_kind: captain' "the expired fixture lost A's captain annotations"
      fi
      rm "$home/fakebin/tasks-axi"

      if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
        fail "complete accepted the previous call for B"
      fi
      assert_no_grep "decisions_reviewed=1" "$home/state/origin-b.meta" \
        "the refused completion recorded an attestation for B"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
      if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted the previous call for B"
      fi
      case "$phase" in
        released-*)
          if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/incomplete.err"; then
            fail "the verification boundary accepted a released answer beneath an incomplete hold"
          fi
          assert_grep "newer hold never completed" "$home/incomplete.err" "the stamp guard did not refuse the incomplete hold"
          if run_captain "$home" verify origin-a >/dev/null 2> "$home/incomplete-verify.err"; then
            fail "verify accepted a released answer beneath an incomplete hold"
          fi
          if [ "$phase" = released-replay ]; then
            run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
              || fail "could not replay A's earlier answer"
          else
            tasks_in "$home" "done" "$id" --keep 1 >/dev/null || fail "could not complete the released work"
          fi
          shown=$(tasks_in "$home" show "$id" --full)
          assert_contains "$shown" 'Captain hold origin: origin-a' "the subsequent transition changed A's association"
          if run_captain "$home" complete origin-b "$id" >/dev/null 2> "$home/transition-complete.err"; then
            fail "$phase certified B after a failed move"
          fi
          assert_grep "was held for origin origin-a, not origin-b" "$home/transition-complete.err" \
            "the transition did not refuse B on origin provenance"
          if run_captain "$home" verify origin-b >/dev/null 2> "$home/transition-verify.err"; then
            fail "$phase verified B after a failed move"
          fi
          ;;
      esac
      run_captain "$home" complete origin-a "$id" >/dev/null || fail "the surviving call could not complete A"
      run_captain "$home" verify origin-a >/dev/null || fail "the surviving call could not verify A"
      [ "$phase" != released-done ] || continue

      run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b >/dev/null \
        || fail "the interrupted move could not be completed"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "a held call for B did not complete B"
      printf 'Ship it for B.\n' > "$home/answer-b.txt"
      run_captain "$home" answer "$id" --release --decision-file "$home/answer-b.txt" >/dev/null \
        || fail "could not release the call for B"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "the genuine answer for B did not complete B"
      run_captain "$home" verify origin-b >/dev/null \
        || fail "the genuine answer for B did not verify B"
    done
  done
  pass "failed and interrupted origin moves cannot inherit active, expired, replayed, or completed calls"
}

test_historical_self_inventory_has_workable_repair() {
  local home origin=sample-review keep=retained-call replacement=repair-call meta before out
  home=$(make_home historical-self-inventory)
  run_captain "$home" hold "$origin" --title "Old review call" --reason "Choose" >/dev/null \
    || fail "could not create the historical origin"
  write_origin_meta "$home" "$origin"
  for out in "$keep" "$replacement"; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$origin" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$origin.meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$origin" "$keep" >> "$meta"
  before=$(cat "$meta")
  for out in "$replacement" --none; do
    if run_captain "$home" complete "$origin" "$out" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "complete accepted the historical self-inventory"
    fi
    assert_grep "historical decision_keys in $meta still contains $origin" "$home/complete.err" \
      "the historical refusal did not identify the persisted entry"
    assert_grep 'replace only' "$home/complete.err" "the refusal omitted the repair instruction"
  done
  if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify accepted the historical self-inventory"
  fi
  assert_grep "historical decision_keys in $meta still contains $origin" "$home/verify.err" \
    "verify omitted the historical repair instruction"
  assert_equals "$before" "$(cat "$meta")" "refusing a historical inventory changed it"
  sed "s/^decision_keys=$origin,$keep$/decision_keys=$replacement,$keep/" "$meta" > "$meta.repaired"
  mv "$meta.repaired" "$meta"
  run_captain "$home" complete "$origin" "$replacement" >/dev/null \
    || fail "the documented historical repair did not allow completion"
  run_captain "$home" verify "$origin" >/dev/null || fail "the repaired inventory did not verify"
  assert_equals "decision_keys=$replacement,$keep" "$(grep '^decision_keys=' "$meta" | tail -1)" \
    "repair lost a sibling inventory entry"
  if run_captain "$home" complete "$origin" "$origin" >/dev/null 2> "$home/self.err"; then
    fail "repair allowed a new self-inventory"
  fi
  pass "historical self-inventories name a workable repair that preserves sibling entries"
}

test_inventory_compares_backend_identities() {
  local home origin entry shown before
  home=$(make_home backend-identities)
  run_captain "$home" hold fm-o --title "Origin" --reason "Choose" >/dev/null \
    || fail "could not create the canonical origin"
  tasks_in "$home" add fm-other "Other origin" --kind scout --repo sample >/dev/null \
    || fail "could not create the other origin"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = o ] && [ -f "$FM_HOME/fail-identity" ]; then
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "$#" -ge 2 ]; then
  case "$2" in
    o|call|other) set -- "$1" "fm-$2" "${@:3}" ;;
  esac
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  for origin in fm-o o; do
    for entry in fm-o o; do
      write_origin_meta "$home" "$origin"
      if run_captain "$home" complete "$origin" "$entry" > "$home/self.out" 2> "$home/self.err"; then
        fail "complete accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'cannot be its own captain-call inventory entry' "$home/self.err" \
        "the alias refusal did not identify self-inventory"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$entry" >> "$home/state/$origin.meta"
      if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'historical decision_keys' "$home/verify.err" "the alias repair diagnostic was missing"
    done
    write_origin_meta "$home" "$origin"
  done
  run_captain "$home" hold fm-call --title "Separate call" --reason "Choose" --origin o >/dev/null \
    || fail "could not hold a call using the origin alias"
  shown=$(tasks_in "$home" show fm-call --full)
  assert_contains "$shown" 'Captain hold origin: fm-o' "hold did not store the backend origin identity"
  printf '%s\n' "$shown" | sed -n 's/^  body: //p' | jq -r . \
    | sed 's/^Captain hold origin: fm-o$/Captain hold origin: o/' > "$home/legacy-origin.txt"
  tasks_in "$home" update fm-call --body-file "$home/legacy-origin.txt" >/dev/null \
    || fail "could not create a legacy stored alias"
  for origin in fm-o o; do
    for entry in fm-call call; do
      run_captain "$home" complete "$origin" "$entry" >/dev/null \
        || fail "complete refused equivalent origin spellings for $origin/$entry"
      run_captain "$home" verify "$origin" >/dev/null \
        || fail "verify refused equivalent origin spellings for $origin/$entry"
    done
  done
  for origin in fm-other other; do
    write_origin_meta "$home" "$origin"
    if run_captain "$home" complete "$origin" call > "$home/other.out" 2> "$home/other.err"; then
      fail "complete accepted another origin through $origin"
    fi
    assert_grep "was held for origin o, not $origin" "$home/other.err" "the alias mismatch was not identified"
    printf 'decisions_reviewed=1\ndecision_keys=call\n' >> "$home/state/$origin.meta"
    if run_captain "$home" verify "$origin" >/dev/null 2> "$home/other-verify.err"; then
      fail "verify accepted another origin through $origin"
    fi
  done
  : > "$home/fail-identity"
  before=$(cat "$home/state/o.meta")
  if run_captain "$home" complete o fm-call >/dev/null 2> "$home/read.err"; then
    fail "an unreadable backend identity was treated as an absent origin"
  fi
  assert_grep 'could not resolve the backend identity of o' "$home/read.err" "the identity read failure was hidden"
  assert_equals "$before" "$(cat "$home/state/o.meta")" "a failed identity read changed the inventory"
  rm "$home/fail-identity"
  write_origin_meta "$home" report-only
  run_captain "$home" hold report-call --title "Report call" --reason "Choose" --origin report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not record a call"
  run_captain "$home" complete report-only report-call >/dev/null \
    || fail "an origin with metadata but no backlog row could not complete"
  run_captain "$home" verify report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not verify"
  pass "completion and verification compare backend identities for entries and current or stored origins"
}

test_interrupted_origin_move_does_not_inherit_the_previous_answer
test_historical_self_inventory_has_workable_repair
test_inventory_compares_backend_identities
