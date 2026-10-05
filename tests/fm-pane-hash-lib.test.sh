#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pane-hash-lib.sh
. "$ROOT/bin/fm-pane-hash-lib.sh"

CAPTURES="$ROOT/tests/captures/pi-1.0.2-herdr-0.9.3"
TMP_ROOT=$(fm_test_tmproot fm-pane-hash)
VIEWPORT_READS="$TMP_ROOT/viewport-reads"
VIEWPORT=

fm_backend_visible_capture() {  # <backend> <target> [label]
  printf '%s %s\n' "$1" "$2" >> "$VIEWPORT_READS"
  [ -n "$VIEWPORT" ] || return 1
  printf '%s' "$VIEWPORT"
}

plain_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

capture() { cat "$CAPTURES/$1.capture"; }

hash_with_viewport() {  # <harness> <viewport> [tail40, defaulting to the viewport]
  VIEWPORT=$2
  fm_pane_stale_hash herdr "$1" lab:w1:p1 fm-lab "${3-$2}"
}

rule() {  # <char> <count>
  local out='' i
  for ((i = 0; i < $2; i++)); do out+=$1; done
  printf '%s' "$out"
}

test_digest_is_32_hex() {
  local out
  out=$(hash_with_viewport pi "$(capture fullscreen-viewport-quiet)")
  [[ $out =~ ^[0-9a-f]{32}$ ]] || fail "fm_pane_stale_hash must print a 32-hex digest, got '$out'"
  pass "fm_pane_stale_hash prints the 32-hex digest the watcher's .hash- markers hold"
}

test_other_panes_hash_the_tail_as_plain_digest() {
  local text name backend harness
  : > "$VIEWPORT_READS"
  VIEWPORT=
  for name in regular-tail fullscreen-tail-b; do
    text=$(capture "$name")
    for backend in tmux zellij cmux orca; do
      for harness in pi pi-signed claude codex ''; do
        assert_equals "$(printf '%s' "$text" | plain_digest)" "$(fm_pane_stale_hash "$backend" "$harness" t fm-lab "$text")" \
          "the $name tail on $backend/${harness:-no-harness} must hash as the plain digest"
      done
    done
    for harness in claude codex opencode omp ''; do
      assert_equals "$(printf '%s' "$text" | plain_digest)" "$(fm_pane_stale_hash herdr "$harness" t fm-lab "$text")" \
        "the $name tail on herdr/${harness:-no-harness} must hash as the plain digest"
    done
  done
  [ ! -s "$VIEWPORT_READS" ] || fail "only herdr Pi panes may read the viewport, got: $(cat "$VIEWPORT_READS")"
  pass "every pane but a herdr Pi pane hashes its 40-line tail as the plain digest and never reads the viewport"
}

test_scrollbar_flash_hashes_like_the_quiet_pane() {
  local quiet flash harness
  quiet=$(capture fullscreen-viewport-quiet)
  flash=$(capture fullscreen-viewport-flash)
  assert_not_equals "$(printf '%s' "$quiet" | plain_digest)" "$(printf '%s' "$flash" | plain_digest)" \
    "the fixtures must differ byte-wise or this case proves nothing"
  for harness in pi pi-signed; do
    assert_equals "$(hash_with_viewport "$harness" "$quiet")" "$(hash_with_viewport "$harness" "$flash")" \
      "an unchanged idle fullscreen $harness pane must hash the same with and without its scrollbar column"
  done
  pass "a herdr Pi pane hashes the same with and without the transient scrollbar column"
}

test_rows_above_the_viewport_do_not_reach_the_hash() {
  local a b viewport
  a=$(capture fullscreen-tail-a)
  b=$(capture fullscreen-tail-b)
  assert_not_equals "$a" "$b" "the two recent reads must differ or this case proves nothing"
  viewport=$(capture fullscreen-viewport-quiet)
  assert_equals "$(hash_with_viewport pi "$viewport" "$a")" "$(hash_with_viewport pi "$viewport" "$b")" \
    "two recent reads of one unchanged fullscreen pane must hash the same"
  pass "a herdr Pi pane hashes its viewport, so the varying rows a recent read returns from above it never change the hash"
}

test_regular_viewport_hashes_as_plain_digest() {
  local viewport
  viewport=$(capture regular-viewport)
  assert_equals "$(printf '%s' "$viewport" | plain_digest)" "$(hash_with_viewport pi "$viewport" "$(capture regular-tail)")" \
    "a regular-mode viewport carries no scrollbar, so it must hash as its plain digest"
  pass "a regular-mode herdr Pi viewport hashes as its plain digest"
}

test_unreadable_viewport_fails() {
  if VIEWPORT='' fm_pane_stale_hash herdr pi lab:w1:p1 fm-lab "$(capture regular-tail)" >/dev/null; then
    fail "a herdr Pi pane whose viewport cannot be read must fail rather than hash its tail"
  fi
  pass "a herdr Pi pane whose viewport cannot be read fails rather than hashing something else"
}

test_change_under_the_scrollbar_still_changes_the_hash() {
  local quiet flash changed
  quiet=$(capture fullscreen-viewport-quiet)
  flash=$(capture fullscreen-viewport-flash)
  changed=${flash/LAB_LONG_LINE_110/LAB_LONG_LINE_999}
  assert_not_equals "$flash" "$changed" "the edit must land in the flash fixture"
  assert_not_equals "$(hash_with_viewport pi "$quiet")" "$(hash_with_viewport pi "$changed")" \
    "a real content change on a scrollbar row must still change the hash"
  changed=${quiet/LAB_LONG_LINE_110/LAB_LONG_LINE_999}
  assert_not_equals "$(hash_with_viewport pi "$quiet")" "$(hash_with_viewport pi "$changed")" \
    "a real content change without the scrollbar must still change the hash"
  pass "content changes still change the hash with and without the scrollbar column"
}

test_text_rows_ending_in_a_rule_glyph_keep_their_width() {
  local full quiet flash
  full=$(rule '─' 12)
  quiet="$full"$'\n'" $(rule '─' 10)"$'\n'" text"$'\n'"$full"
  flash="$(rule '─' 11)┃"$'\n'" $(rule '─' 10)┃"$'\n'" text      │"$'\n'"$full"
  assert_equals "$(hash_with_viewport pi "$quiet")" "$(hash_with_viewport pi "$flash")" \
    "a full-width rule keeps its last cell and an indented rule does not gain one"
  pass "the scrollbar strip restores full-width rules without widening indented ones"
}

test_wide_characters_count_two_cells() {
  local full quiet flash
  full=$(rule '─' 10)
  quiet="$full"$'\n'" 中文"$'\n'"$full"
  flash="$full"$'\n'" 中文    ┃"$'\n'"$full"
  assert_equals "$(hash_with_viewport pi "$quiet")" "$(hash_with_viewport pi "$flash")" \
    "a scrollbar row holding wide characters must still be recognized by its display width"
  pass "scrollbar rows are recognized by display width, so wide characters count two cells"
}

test_glyphs_short_of_the_last_column_are_content() {
  local full quiet
  full=$(rule '─' 12)
  quiet="$full"$'\n'" a │ b │"$'\n'" ┃ c"$'\n'"$full"
  assert_equals "$(printf '%s' "$quiet" | plain_digest)" "$(hash_with_viewport pi "$quiet")" \
    "box glyphs that end a row short of the last column are content, not a scrollbar"
  pass "rows ending in a box glyph short of the last column hash unchanged"
}

test_undecodable_viewport_hashes_as_plain_digest() {
  local text
  text=$(printf 'abc\377\n%s\n x     \342\224\203' "$(rule '─' 7)")
  assert_equals "$(printf '%s' "$text" | plain_digest)" "$(hash_with_viewport pi "$text")" \
    "a viewport that is not valid UTF-8 must hash as the plain digest"
  pass "a viewport that is not valid UTF-8 hashes as the plain digest"
}

test_digest_is_32_hex
test_other_panes_hash_the_tail_as_plain_digest
test_scrollbar_flash_hashes_like_the_quiet_pane
test_rows_above_the_viewport_do_not_reach_the_hash
test_regular_viewport_hashes_as_plain_digest
test_unreadable_viewport_fails
test_change_under_the_scrollbar_still_changes_the_hash
test_text_rows_ending_in_a_rule_glyph_keep_their_width
test_wide_characters_count_two_cells
test_glyphs_short_of_the_last_column_are_content
test_undecodable_viewport_hashes_as_plain_digest
