#!/usr/bin/env bash
# Tests for bin/fm-decisions-unfiled.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-decisions-unfiled.sh"
TMP_ROOT=$(fm_test_tmproot fm-decisions-unfiled-tests)

write_captain() {
  printf '%s\n' "$@" > "$TMP_ROOT/home/data/captain.md"
}

write_record() {
  local name=$1 date=$2 words=$3
  {
    printf '# %s\n\nDate: %s\n\n## The captain'"'"'s words\n\n' "$name" "$date"
    printf '> %s\n' "$words"
  } > "$TMP_ROOT/home/projects/decisions/docs/adr/$name.md"
}

fresh_world() {
  rm -rf "${TMP_ROOT:?}/home"
  mkdir -p "$TMP_ROOT/home/data" "$TMP_ROOT/home/projects/decisions/docs/adr"
}

test_same_date_filed_stays_silent_and_unfiled_is_listed() {
  fresh_world
  write_captain \
    '- 2026-09-15: Force determinism: "write the program rather than a rule".' \
    '- 2026-09-15: Merge authority: "I merge green work myself".'
  write_record 0001-first "2026-09-15" "write the program rather than a rule"

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed on fixtures with one filed and one unfiled ruling"
  assert_contains "$out" "2026-09-15" "listed line lost the ruling date"
  assert_contains "$out" "Merge authority" "unfiled ruling was not listed"
  assert_not_contains "$out" "Force determinism" "filed ruling was listed as unfiled"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] \
    || fail "expected exactly one listed line, got: $out"
  pass "same-date filed ruling stays silent while the unfiled one is listed"
}

test_record_quote_of_bullet_counts_as_cited() {
  fresh_world
  write_captain '- 2026-09-15: Merge authority: "I merge green work myself".'
  write_record 0001-first "2026-09-15" "I merge green work myself"

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed on a fully filed fixture"
  [ -z "$out" ] || fail "fully filed rulings printed output: $out"
  pass "quoted ruling stays silent when every ruling is filed"
}

test_bullet_holding_the_record_quote_counts_as_cited() {
  fresh_world
  write_captain '- 2026-09-15: Merge authority, settled on the fleet board. He chose "I merge green work myself" over review-everything.'
  write_record 0001-first "2026-09-15" "I merge green work myself"

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed when the bullet holds the record quote"
  [ -z "$out" ] || fail "cited ruling printed output: $out"
  pass "bullet holding the record quote stays silent"
}

test_source_record_without_words_cites_nothing() {
  fresh_world
  write_captain '- 2026-09-21: Testing direction: "especially interested in mutation testing".'
  printf '# source\n\nDate: 2026-09-21\n\nEvidence only, especially interested in mutation testing.\n' \
    > "$TMP_ROOT/home/projects/decisions/docs/adr/0045-source.md"

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed on a source-record-only fixture"
  assert_contains "$out" "Testing direction" "source record hid an uncited ruling"
  pass "source record without a words section cites nothing"
}

test_empty_records_list_everything() {
  fresh_world
  write_captain '- 2026-09-15: Merge authority: "I merge green work myself".'

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed with an empty records directory"
  assert_contains "$out" "Merge authority" "empty harvest listed nothing"
  pass "empty records directory lists every ruling"
}

test_absent_clone_and_absent_captain_stay_silent() {
  fresh_world
  write_captain '- 2026-09-15: Merge authority: "I merge green work myself".'
  rm -rf "$TMP_ROOT/home/projects/decisions"

  local out
  out=$("$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed with the decisions clone absent"
  [ -z "$out" ] || fail "absent clone printed output: $out"

  out=$("$CHECK" --captain "$TMP_ROOT/home/data/no-such-file.md" \
    --decisions "$TMP_ROOT/home/projects/decisions") \
    || fail "check failed with captain.md absent"
  [ -z "$out" ] || fail "absent captain.md printed output: $out"
  pass "absent clone and absent captain stay silent"
}

test_check_writes_nothing() {
  fresh_world
  write_captain '- 2026-09-15: Merge authority: "I merge green work myself".'
  write_record 0001-first "2026-09-15" "I merge green work myself"
  local before after
  before=$(find "$TMP_ROOT/home" -type f -exec sha256sum {} + | sort)
  "$CHECK" --captain "$TMP_ROOT/home/data/captain.md" \
    --decisions "$TMP_ROOT/home/projects/decisions" >/dev/null \
    || fail "check failed on a fully filed fixture"
  after=$(find "$TMP_ROOT/home" -type f -exec sha256sum {} + | sort)
  [ "$before" = "$after" ] || fail "check modified its inputs"
  pass "check is read-only"
}

test_same_date_filed_stays_silent_and_unfiled_is_listed
test_record_quote_of_bullet_counts_as_cited
test_bullet_holding_the_record_quote_counts_as_cited
test_source_record_without_words_cites_nothing
test_empty_records_list_everything
test_absent_clone_and_absent_captain_stay_silent
test_check_writes_nothing

echo "# fm-decisions-unfiled.test.sh: all assertions passed"
