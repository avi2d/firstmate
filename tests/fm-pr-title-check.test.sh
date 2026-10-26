#!/usr/bin/env bash
# Tests for bin/fm-pr-title-check.sh: the pull request title rule that
# bin/fm-pr-merge.sh applies before any merge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-title-check.sh"

expect_title() {
  local want=$1 title=$2 rc
  set +e
  "$CHECK" "$title" > /dev/null 2>&1
  rc=$?
  set -e
  expect_code "$want" "$rc" "title '$title'"
}

test_kit_accepted_titles_pass() {
  expect_title 0 'feat(scope): add x'
  expect_title 0 'feat: add x'
  expect_title 0 'feat(scope)!: add x'
  expect_title 0 'theme(scope): add x'
  expect_title 0 'unslop: add x'
  expect_title 0 'feat: iOS support'
  expect_title 0 'feat(): add x'
  expect_title 0 'chore: release 1.2.3'
  expect_title 0 'feat: add x (#12)'
  pass "the title rule accepts every conventional title the checks kit accepts"
}

test_upstream_sync_titles_pass() {
  expect_title 0 'Merge upstream main ffb2aca0 into fork main'
  expect_title 0 "Merge branch 'main' into fix"
  expect_title 0 'Merge pull request #5 from x/y'
  expect_title 0 'Merge tag v1.2.3'
  expect_title 0 'Revert "feat: add x"'
  expect_title 0 'fixup! feat: add x'
  pass "the title rule passes the upstream sync and revert titles the kit ignores"
}

test_kit_rejected_titles_are_refused() {
  expect_title 1 'update stuff'
  expect_title 1 'frobnicate(scope): add x'
  expect_title 1 'Add x'
  expect_title 1 'feat: Add x'
  expect_title 1 'feat: Pascal Case'
  expect_title 1 'FEAT: add x'
  expect_title 1 'Feat: add x'
  expect_title 1 'feat(scope):add x'
  expect_title 1 'Merge foo'
  pass "the title rule refuses every non-conventional title the checks kit refuses"
}

test_bare_type_and_nested_scope_are_refused_stricter_than_the_kit() {
  expect_title 1 'feat:'
  expect_title 1 'feat(a)(b): add x'
  pass "the title rule refuses a bare type and a nested scope that the kit lets through"
}

test_title_of_89_characters_passes() {
  local title
  title="feat: $(printf 'a%.0s' $(seq 1 83))"
  expect_title 0 "$title"
  pass "the title rule passes an 89-character title"
}

test_title_of_90_characters_is_refused() {
  local title
  title="feat: $(printf 'a%.0s' $(seq 1 84))"
  expect_title 1 "$title"
  pass "the title rule refuses a 90-character title"
}

test_kit_accepted_titles_pass
test_upstream_sync_titles_pass
test_kit_rejected_titles_are_refused
test_bare_type_and_nested_scope_are_refused_stricter_than_the_kit
test_title_of_89_characters_passes
test_title_of_90_characters_is_refused
