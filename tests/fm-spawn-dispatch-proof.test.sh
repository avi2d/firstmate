#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-proof)

make_proof_pi_probe() {
  cat > "$1/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode> --approve'
fi
exit 0
SH
  chmod +x "$1/pi"
}

make_proof_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  make_proof_pi_probe "$fakebin"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  fm_test_spawn_home "$home" grok
  printf '%s\n' '{"rules":[{"when":"test work","use":[{"harness":"codex","model":"gpt-5"},{"harness":"grok","model":"grok-4"},{"harness":"pi","model":"claude-bridge/opus-5-5"}]}]}' > "$home/config/crew-dispatch.json"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$launchlog"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_proof_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_proof_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  GROK_HOME="$home/grok-home" \
    FM_FAKE_PI_VERSION="${FM_FAKE_PI_VERSION:-0.84.0}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

write_resolve_out() {
  cat > "$1" <<'EOF'
dispatch-resolve:
  status: clear
  model: jev-latest   latency_ms: 10   tokens: 1/2
  rule: test work (test work)   confidence: 0.9
  probabilities: test work=0.9
  candidate: grok:grok-4  provider=grok  scope=all_models  remaining=50%  spendPriority=10  runway=through_reset  -> eligible
  profile: --harness grok --model grok-4
EOF
}

write_selection_record() {
  cat > "$1" <<'EOF'
dispatch-selection:
rule: rule_1
candidate: codex:gpt-5 provider=codex remaining=10% spendPriority=5 runway=through_reset -> eligible
candidate: grok:grok-4 provider=grok remaining=50% spendPriority=10 runway=through_reset -> eligible
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness grok --model grok-4
EOF
}

test_copied_launch_without_proof_is_refused() {
  local rec id out status
  id=proof-missing-z1
  rec=$(make_proof_case proof-missing "$id")
  read_proof_record "$rec"
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 1 "$status" "a launch with no dispatch proof should refuse: $out"
  assert_contains "$out" 'holds no dispatch proof' "refusal should name the missing proof"
  assert_not_contains "$out" "spawned $id" "a refused spawn must never report success"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a copied launch with no dispatch proof is refused"
}

test_clear_resolver_pick_is_not_refused() {
  local rec id out status
  id=proof-resolve-z2
  rec=$(make_proof_case proof-resolve "$id")
  read_proof_record "$rec"
  write_resolve_out "$HOME_DIR/data/$id/dispatch-resolve.out"
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 0 "$status" "a clear resolver pick should launch: $out"
  assert_contains "$out" "spawned $id" "a covered launch should report success"
  assert_grep 'dispatch_proof=resolve:clear' "$HOME_DIR/state/$id.meta" "resolver proof not recorded in task metadata"
  pass "a clear resolver pick launches without a selection record"
}

test_full_selection_record_is_not_refused() {
  local rec id out status
  id=proof-record-z3
  rec=$(make_proof_case proof-record "$id")
  read_proof_record "$rec"
  write_selection_record "$HOME_DIR/data/$id/dispatch-selection.md"
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 0 "$status" "a full selection record should launch: $out"
  assert_contains "$out" "spawned $id" "a covered launch should report success"
  assert_grep 'dispatch_proof=record:selection' "$HOME_DIR/state/$id.meta" "record proof not recorded in task metadata"
  pass "a full selection record launches"
}

test_selection_record_naming_another_profile_is_refused() {
  local rec id out status
  id=proof-mismatch-z4
  rec=$(make_proof_case proof-mismatch "$id")
  read_proof_record "$rec"
  cat > "$HOME_DIR/data/$id/dispatch-selection.md" <<'EOF'
dispatch-selection:
rule: rule_1
candidate: codex:gpt-5 provider=codex remaining=10% spendPriority=5 runway=through_reset -> eligible
candidate: grok:grok-4 provider=grok remaining=50% spendPriority=10 runway=through_reset -> eligible
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness codex --model gpt-5
EOF
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 1 "$status" "a record naming another profile should refuse: $out"
  assert_contains "$out" 'must equal the launch' "refusal should name the chosen-profile mismatch"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a selection record naming another profile is refused"
}

test_record_with_only_the_copied_opus_candidate_is_refused() {
  local rec id out status
  id=proof-opus-only-z7
  rec=$(make_proof_case proof-opus-only "$id")
  read_proof_record "$rec"
  cat > "$HOME_DIR/data/$id/dispatch-selection.md" <<'EOF'
dispatch-selection:
rule: rule_1
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness pi --model claude-bridge/opus-5-5
EOF
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model claude-bridge/opus-5-5)
  status=$?
  expect_code 1 "$status" "a record with only the copied Opus candidate should refuse: $out"
  assert_contains "$out" 'missing a candidate' "refusal should name the missing candidates"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a record with only the copied Opus candidate is refused"
}

test_record_missing_the_middle_candidate_is_refused() {
  local rec id out status
  id=proof-middle-missing-z8
  rec=$(make_proof_case proof-middle-missing "$id")
  read_proof_record "$rec"
  cat > "$HOME_DIR/data/$id/dispatch-selection.md" <<'EOF'
dispatch-selection:
rule: rule_1
candidate: codex:gpt-5 provider=codex remaining=10% spendPriority=5 runway=through_reset -> eligible
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness codex --model gpt-5
EOF
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex --model gpt-5)
  status=$?
  expect_code 1 "$status" "a record missing the middle candidate should refuse: $out"
  assert_contains "$out" 'missing a candidate' "refusal should name the missing candidate"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a record missing the middle candidate is refused"
}

test_candidate_with_no_quota_reading_is_refused() {
  local rec id out status
  id=proof-no-reading-z9
  rec=$(make_proof_case proof-no-reading "$id")
  read_proof_record "$rec"
  cat > "$HOME_DIR/data/$id/dispatch-selection.md" <<'EOF'
dispatch-selection:
rule: rule_1
candidate: codex:gpt-5 provider=codex remaining=10% spendPriority=5 runway=through_reset -> eligible
candidate: grok:grok-4 provider=grok -> eligible
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness grok --model grok-4
EOF
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 1 "$status" "a candidate with no quota reading should refuse: $out"
  assert_contains "$out" 'no quota reading' "refusal should name the missing quota reading"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a candidate with no quota reading is refused"
}

test_record_naming_an_unknown_rule_is_refused() {
  local rec id out status
  id=proof-unknown-rule-z10
  rec=$(make_proof_case proof-unknown-rule "$id")
  read_proof_record "$rec"
  cat > "$HOME_DIR/data/$id/dispatch-selection.md" <<'EOF'
dispatch-selection:
rule: rule_9
candidate: codex:gpt-5 provider=codex remaining=10% spendPriority=5 runway=through_reset -> eligible
candidate: grok:grok-4 provider=grok remaining=50% spendPriority=10 runway=through_reset -> eligible
candidate: pi:claude-bridge/opus-5-5 provider=claude remaining=80% spendPriority=20 runway=through_reset -> eligible
chosen: --harness grok --model grok-4
EOF
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 1 "$status" "a record naming an unknown rule should refuse: $out"
  assert_contains "$out" 'unknown rule' "refusal should name the unknown rule"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "a record naming an unknown rule is refused"
}

test_stated_captain_override_is_not_refused() {
  local rec id out status
  id=proof-override-z5
  rec=$(make_proof_case proof-override "$id")
  read_proof_record "$rec"
  write_selection_record "$HOME_DIR/data/$id/dispatch-selection.md"
  printf '%s\n' 'override: the captain picked grok for a fast check' >> "$HOME_DIR/data/$id/dispatch-selection.md"
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 0 "$status" "a stated captain override should launch: $out"
  assert_contains "$out" "spawned $id" "an override launch should report success"
  assert_grep 'dispatch_proof=record:override' "$HOME_DIR/state/$id.meta" "override proof not recorded in task metadata"
  pass "a stated captain override launches"
}

test_override_without_a_stated_reason_is_refused() {
  local rec id out status
  id=proof-override-empty-z6
  rec=$(make_proof_case proof-override-empty "$id")
  read_proof_record "$rec"
  write_selection_record "$HOME_DIR/data/$id/dispatch-selection.md"
  printf '%s\n' 'override:' >> "$HOME_DIR/data/$id/dispatch-selection.md"
  out=$(run_proof_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness grok --model grok-4)
  status=$?
  expect_code 1 "$status" "an override without a stated reason should refuse: $out"
  assert_contains "$out" 'no stated reason' "refusal should name the missing reason"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "an override without a stated reason is refused"
}

test_copied_launch_without_proof_is_refused
test_clear_resolver_pick_is_not_refused
test_full_selection_record_is_not_refused
test_selection_record_naming_another_profile_is_refused
test_record_with_only_the_copied_opus_candidate_is_refused
test_record_missing_the_middle_candidate_is_refused
test_candidate_with_no_quota_reading_is_refused
test_record_naming_an_unknown_rule_is_refused
test_stated_captain_override_is_not_refused
test_override_without_a_stated_reason_is_refused

echo "all fm-spawn-dispatch-proof tests passed"
