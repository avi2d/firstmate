#!/usr/bin/env bash
# Captain holds migrated to the Beads backend, and pre-collapse and legacy identity resolution.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

test_verify_resolves_a_hold_migrated_to_beads_notes() {
  local fixture home beads scout
  require_tasks_axi_beads "verify against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-notes)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-beads-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "Origin: herald-retire
Decision key: github-delete
State: awaiting captain decision.

migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_scout_with_attested_inventory "$home" "$scout" \
    herald-retire-decision-github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the attested legacy id through its migrated beads row"
  pass "verify resolves a captain hold migrated to a beads row with a marker note"
}

# A tasks-axi stub that knows ONLY the row ids it is given. The real
# beads-capable tasks-axi resolves a bare legacy id onto its prefixed row
# itself, answering before any migration lookup runs; against this stub the
# migrated-hold resolution order is what has to answer.
write_known_rows_stub() {  # <fakebin> <row-id...>
  local fb=$1 known
  shift
  known=$(printf '%s|' "$@")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '  --kind captain'
    ;;
  show)
    case "${2:-}" in
      @KNOWN@) ;;
      *) printf 'error: no task %s in this backlog\ncode: NOT_FOUND\n' "${2:-}" >&2; exit 1 ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$2"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain' '  body: ""'
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@KNOWN@%${known%|}%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

test_verify_resolves_a_hold_migrated_under_the_configured_prefix() {
  local fixture home scout out
  require_tasks_axi_beads "verify against a prefix-migrated hold" || return 0
  fixture=$(make_beads_home migrated-prefix)
  home=${fixture%%|*}
  scout=sample-prefix-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-other-legacy-row \
    "Second migrated hold" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the prefix-migrated fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-other-legacy-row \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the prefix-migrated fixture row"
  # No row in this graph carries a marker note, so the narrowed prefix guess is
  # the only resolution left for the attested legacy id.
  write_known_rows_stub "$(fm_fakebin "$home")" fm-other-legacy-row
  write_scout_with_attested_inventory "$home" "$scout" other-legacy-row

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the legacy id under the configured prefix"
  out=$(run_captain "$home" complete "$scout" other-legacy-row) \
    || fail "the completion gate refused the prefix-resolved hold"
  assert_contains "$out" "other-legacy-row=fm-other-legacy-row" \
    "completion did not name the row the prefix guess attested against"
  pass "verify resolves a captain hold whose id is the legacy id under the configured prefix"
}

# The prefix guess is a name, not evidence: when a row actually carries the
# migration marker, that row is the one attested even though an unrelated
# captain-held task occupies the <prefix>-<legacy id> name.
test_marker_noted_row_wins_over_a_prefix_namesake() {
  local fixture home beads scout row out
  require_tasks_axi_beads "prefer a marker-noted row over a prefix namesake" || return 0
  fixture=$(make_beads_home migrated-marker-wins)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-marker-wins-scout
  for row in fm-dual-row fm-marked-dual-row fm-solo-row; do
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$row" "Captain call $row" \
      --repo sample) >/dev/null 2>&1 || fail "could not create the fixture row $row"
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$row" --kind captain \
      --reason "captain must decide") >/dev/null 2>&1 \
      || fail "could not hold the fixture row $row"
  done
  bdrow "$beads" note fm-marked-dual-row \
    "migrated from data/backlog.md id dual-row on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_known_rows_stub "$(fm_fakebin "$home")" \
    fm-dual-row fm-marked-dual-row fm-solo-row
  write_scout_with_attested_inventory "$home" "$scout" "dual-row,solo-row"

  out=$(run_captain "$home" complete "$scout" dual-row solo-row) \
    || fail "the completion gate refused an inventory carrying both migrated shapes"
  assert_not_contains "$out" "dual-row=fm-dual-row" \
    "the bare prefix namesake shadowed the row carrying the migration marker"
  assert_contains "$out" "solo-row=fm-solo-row" \
    "completion did not name the row the prefix guess attested against"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve both migrated shapes after completion"
  pass "the marker-noted row wins over an unrelated row holding the prefix namesake"
}

test_complete_accepts_a_migrated_inventory_on_beads() {
  local fixture home scout
  require_tasks_axi_beads "complete against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-complete)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-complete-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  mkdir -p "$home/data/$scout"
  printf '# Report\n\nThe investigation finished.\n\n## References\n\n- fixture source\n' > "$home/data/$scout/report.md"

  run_captain "$home" complete "$scout" herald-retire-decision-github-delete >/dev/null \
    || fail "the completion gate refused an inventory resolved through a migrated beads row"
  assert_grep "decision_keys=herald-retire-decision-github-delete" \
    "$home/state/$scout.meta" \
    "the attestation did not record the attested legacy id"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve the attested legacy id after completion"
  pass "the completion gate attests an inventory resolved through a migrated beads row"
}

test_verify_names_the_unresolvable_legacy_id_once() {
  local fixture home scout err rc
  require_tasks_axi_beads "verify an unresolvable beads legacy id" || return 0
  fixture=$(make_beads_home migrated-absent)
  home=${fixture%%|*}
  scout=sample-absent-scout
  write_scout_with_attested_inventory "$home" "$scout" ghost-legacy-id

  rc=0
  err=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an attested id that resolves to nothing"
  assert_contains "$err" "ghost-legacy-id" \
    "the refusal did not name the id it could not resolve"
  [ "$(printf '%s\n' "$err" | grep -c '^fm-captain-hold:')" = 1 ] \
    || fail "the refusal emitted more than one line: $err"
  pass "an unresolvable legacy id is refused once, naming the id"
}

test_verify_resolves_a_pre_collapse_key_through_its_derived_marker() {
  local fixture home beads scout
  require_tasks_axi_beads "verify a derived pre-collapse key" || return 0
  fixture=$(make_beads_home migrated-derived)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-derived-scout
  # The row was migrated under the DERIVED pre-collapse identity, keyed by a
  # bare decision key the origin's old metadata attests.
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-dec-call \
    "Migrated pre-collapse call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the derived-marker fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-dec-call \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the derived-marker fixture row"
  bdrow "$beads" note fm-dec-call \
    "migrated from data/backlog.md id $scout-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the derived-id marker note"
  write_scout_with_attested_inventory "$home" "$scout" github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not probe the derived pre-collapse identity for its migrated row"
  pass "a pre-collapse key resolves through its derived identity's migration marker"
}

# The captain-hold mutation wrapper must address the configured backend like
# the transition library does: on a beads-configured home its hold/answer/done
# calls reach tasks-axi with no markdown file override. Fully portable - the
# stubbed tasks-axi fakes the beads backend, so no bd or beads-capable install
# is needed.
test_captain_hold_mutations_address_the_beads_backend() {
  local home id fb log
  home="$TMP_ROOT/captain-stub-beads/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"
EOF
  id=fm-stub-held-row
  fb=$(fm_fakebin "$home")
  log="$home/tasks-axi-calls"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "@LOG@"
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads update received a markdown file override' >&2
        exit 1
        ;;
    esac
    stub_prev=
    stub_path=
    for stub_arg in "$@"; do
      if [ "$stub_prev" = --body-file ]; then stub_path=$stub_arg; fi
      stub_prev=$stub_arg
    done
    [ -n "$stub_path" ] && cp -- "$stub_path" "@HOME@/last-body"
    printf 'ok: update %s\n' "${2:-}"
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain' ; exit 0 ;;
      *" --file "*)
        printf '%s\n' 'error: beads hold received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: hold %s\n' "${2:-}"
    ;;
  done)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads done received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: done %s\n' "${2:-}"
    ;;
  show)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads show received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "@ID@"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain'
    if [ -f "@HOME@/last-body" ]; then
      printf '%s' '  body: '
      perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)' < "@HOME@/last-body"
      printf '\n'
    else
      printf '%s\n' '  body: ""'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s|@HOME@|$home|g; s|@ID@|$id|g; s|@LOG@|$log|g" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"

  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain must decide" >/dev/null \
    || fail "holding on a beads-configured home failed without a markdown backlog"
  assert_grep "hold $id" "$log" \
    "the captain-hold mutation never reached the configured backend"

  decision="$home/captain-decision.txt"
  printf 'Ship the gold-only plan.\n' > "$decision"
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$decision" >/dev/null \
    || fail "answering on a beads-configured home failed without a markdown backlog"
  assert_grep "update $id --body-file" "$log" \
    "the captain answer never reached the configured backend"
  assert_grep "done $id" "$log" \
    "the captain answer close never reached the configured backend"
  assert_no_grep " --file " "$log" \
    "a captain-hold mutation passed a markdown file override to a beads home"
  pass "captain-hold mutations address the beads backend without a markdown override"
}

# A Beads workspace with due.required and no types.custom captain type is the
# live fleet shape. hold must still create a fresh captain row there: waive
# due rather than invent one, and map to native type task rather than register
# a Beads captain issue type.
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type() {
  local fixture home beads id show issue_type
  require_tasks_axi_beads "captain-hold create under due.required without types.custom" || return 0
  fixture=$(make_beads_home due-required-no-custom-type)
  home=${fixture%%|*}
  beads=${fixture##*|}
  printf '\ndue:\n    required: true\n' >> "$beads/config.yaml"
  if bdrow "$beads" create "raw task" --id fm-raw-task --type task --json >/dev/null 2>&1; then
    fail "bd created a task without --due; the due.required fixture is not in force"
  fi
  if bdrow "$beads" create "raw captain" --id fm-raw-captain --type captain --due 2099-01-01 --json >/dev/null 2>&1; then
    fail "bd accepted --type captain; the fixture still has a types.custom captain registration"
  fi
  id=fm-fresh-captain-call
  run_captain "$home" hold "$id" --title "Choose the sample route" \
    --reason "captain must decide" --repo sample >/dev/null \
    || fail "hold could not create a captain row under due.required without types.custom"
  show=$(tasks_in "$home" show "$id") || fail "the created captain row is missing"
  assert_contains "$show" "hold_kind: captain" \
    "the created row is not captain-held"
  assert_contains "$show" "kind: captain" \
    "the created row lost its captain backlog kind"
  issue_type=$(bdrow "$beads" show "$id" --json \
    | jq -r 'if type == "array" then .[0].issue_type else .issue_type end')
  [ "$issue_type" = task ] \
    || fail "create did not map to native Beads type task, got ${issue_type:-empty}"
  pass "hold creates a captain row when Beads requires due and has no captain type"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n\n## References\n\n- fixture source\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

test_legacy_identities_keep_working
test_verify_resolves_a_hold_migrated_to_beads_notes
test_verify_resolves_a_hold_migrated_under_the_configured_prefix
test_marker_noted_row_wins_over_a_prefix_namesake
test_complete_accepts_a_migrated_inventory_on_beads
test_verify_names_the_unresolvable_legacy_id_once
test_verify_resolves_a_pre_collapse_key_through_its_derived_marker
test_captain_hold_mutations_address_the_beads_backend
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type
