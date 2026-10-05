#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pane-hash-lib.sh
. "$ROOT/bin/fm-pane-hash-lib.sh"

CAPTURES="$ROOT/tests/captures/pi-1.0.2-herdr-0.9.3"
TMP_ROOT=$(fm_test_tmproot fm-pane-hash)
VIEWPORT_READS="$TMP_ROOT/viewport-reads"

fm_backend_visible_capture() {  # <backend> <target> [label]
  printf '%s %s\n' "$1" "$2" >> "$VIEWPORT_READS"
  return 1
}

plain_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

capture() { cat "$CAPTURES/$1.capture"; }

test_digest_is_32_hex() {
  local out
  out=$(fm_pane_stale_hash herdr pi lab:w1:p1 fm-lab "$(capture regular-tail)")
  [[ $out =~ ^[0-9a-f]{32}$ ]] || fail "fm_pane_stale_hash must print a 32-hex digest, got '$out'"
  pass "fm_pane_stale_hash prints the 32-hex digest the watcher's .hash- markers hold"
}

test_panes_hash_the_tail_as_plain_digest() {
  local text name backend harness
  : > "$VIEWPORT_READS"
  for name in regular-tail fullscreen-tail-a fullscreen-tail-b; do
    text=$(capture "$name")
    for backend in herdr tmux zellij cmux orca; do
      for harness in pi pi-signed claude codex opencode omp ''; do
        assert_equals "$(printf '%s' "$text" | plain_digest)" "$(fm_pane_stale_hash "$backend" "$harness" t fm-lab "$text")" \
          "the $name tail on $backend/${harness:-no-harness} must hash as the plain digest"
      done
    done
  done
  [ ! -s "$VIEWPORT_READS" ] || fail "the stale hash must not read the viewport, got: $(cat "$VIEWPORT_READS")"
  pass "every pane hashes its 40-line tail as the plain digest"
}

test_digest_is_32_hex
test_panes_hash_the_tail_as_plain_digest
