#!/usr/bin/env bash
# The trigger index derives from skill descriptions; this pins that derivation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skill-trigger-index.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-trigger-index)

make_skill() {
  local root=$1 name=$2 invocable=$3 desc=$4
  mkdir -p "$root/.agents/skills/$name"
  cat > "$root/.agents/skills/$name/SKILL.md" <<EOF
---
name: $name
description: $desc
user-invocable: $invocable
metadata:
  internal: true
---

# $name
EOF
}

make_index_file() {
  local root=$1
  mkdir -p "$root/.agents/skills/agent-skill-trigger-index"
  cat > "$root/.agents/skills/agent-skill-trigger-index/SKILL.md" <<'EOF'
---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# placeholder
EOF
}

expect_failure_with() {
  local needle=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure naming '$needle'"
  assert_contains "$out" "$needle" "failure did not name '$needle'"
}

test_repo_index_is_current() {
  "$CHECK" --check >/dev/null || fail "committed index drifted from skill descriptions"
  pass "committed index matches every agent-only skill description"
}

test_missing_extra_and_drift_fail() {
  local repo="$TMP_ROOT/names"
  make_skill "$repo" alpha false "Load when alpha fires."
  make_skill "$repo" beta false "Load when beta fires."
  make_index_file "$repo"
  "$CHECK" --write --root "$repo" >/dev/null
  "$CHECK" --check --root "$repo" >/dev/null || fail "freshly written index did not check clean"
  make_skill "$repo" gamma false "Load when gamma fires."
  expect_failure_with "missing from index: gamma" "$CHECK" --check --root "$repo"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  printf -- '- `phantom` - Load when nothing fires.\n' >> "$repo/.agents/skills/agent-skill-trigger-index/SKILL.md"
  expect_failure_with "index names unknown skill: phantom" "$CHECK" --check --root "$repo"
  pass "missing and unknown skill names fail the check"
}

test_wording_drift_fails() {
  local repo="$TMP_ROOT/drift"
  make_skill "$repo" alpha false "Load when alpha fires."
  make_index_file "$repo"
  "$CHECK" --write --root "$repo" >/dev/null
  make_skill "$repo" alpha false "Load whenever alpha fires instead."
  expect_failure_with "wording drifted" "$CHECK" --check --root "$repo"
  pass "reworded descriptions fail until the index is rewritten"
}

test_stub_target_must_resolve() {
  local repo="$TMP_ROOT/stub"
  make_skill "$repo" alpha false "Load when alpha fires."
  make_skill "$repo" old-stub false "Renamed pointer. Load missing-target instead; this stub only redirects."
  make_index_file "$repo"
  expect_failure_with "stub old-stub must name its redirect target" "$CHECK" --check --root "$repo"
  make_skill "$repo" old-stub false "Renamed pointer. Load alpha instead; this stub only redirects."
  "$CHECK" --write --root "$repo" >/dev/null
  "$CHECK" --check --root "$repo" >/dev/null || fail "resolvable stub did not check clean"
  pass "dangling stub redirects fail while resolvable ones pass"
}

test_non_agent_entries_excluded() {
  local repo="$TMP_ROOT/scope"
  make_skill "$repo" alpha false "Load when alpha fires."
  make_skill "$repo" captain-thing true "Use when the captain invokes /thing."
  mkdir -p "$repo/.agents/skills/bodiless-mod"
  make_index_file "$repo"
  local out
  out=$("$CHECK" --root "$repo")
  assert_contains "$out" "- \`alpha\` - Load when alpha fires." "agent-only skill missing from output"
  assert_not_contains "$out" "captain-thing" "captain-invocable skill leaked into the index"
  assert_not_contains "$out" "bodiless-mod" "entry without SKILL.md leaked into the index"
  assert_not_contains "$out" "placeholder" "stale body survived regeneration"
  pass "captain-invocable skills, SKILL.md-less entries, and the index itself stay out"
}

test_repo_index_is_current
test_missing_extra_and_drift_fail
test_wording_drift_fails
test_stub_target_must_resolve
test_non_agent_entries_excluded
