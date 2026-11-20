#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_pi_signed_preserves_identity_with_pi_supervision_protocol() {
  local out ordinary
  out=$("$RENDER" --harness pi-signed)
  assert_contains "$out" "primary harness: pi-signed" \
    "pi-signed supervision normalized the visible runtime identity to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed did not reuse Pi's authoritative supervision protocol"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" \
    "pi-signed ordinary-wake semantics diverged from Pi"
  out=$("$RENDER" --harness pi-signed --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" \
    "pi-signed repair semantics diverged from Pi"
  pass "pi-signed keeps its identity while sharing Pi's supervision protocol"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_contains "$out" "MAIN must not re-drain, re-run, or acknowledge it" "pi snippet lost merged-event ownership"
  assert_contains "$out" "MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a settled routine outcome" "pi snippet imposed a mechanical sailboat treatment"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

test_literal_paths_in_rendered_snippets() {
  local name home harness out
  for name in normal 'R&D "double" '''single''' home'; do
    home="$TMP_ROOT/$name"
    for harness in pi pi-signed; do
      out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$RENDER" --harness "$harness")
      assert_not_contains "$out" '__FM_' "$harness: literal path leaked a placeholder"
      assert_contains "$out" "$home/.pi/extensions/fm-primary-pi-watch.ts" "Pi watch path changed"
      assert_contains "$out" "$home/.pi/extensions/fm-primary-turnend-guard.ts" "Pi turn-end path changed"
    done
  done
  pass "Pi snippets preserve literal ampersands, quotes and spaces in paths"
}

test_read_only_repair() {
  local out
  out=$("$RENDER" --harness pi --read-only 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  out=$("$RENDER" --harness pi --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"
  assert_not_contains "$out" "fm_watch_arm_pi" "read-only repair offered to arm a cycle"
  out=$("$RENDER" --harness pi --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "repair did not direct Pi to its own tool"
  pass "read-only cannot arm and the lock owner drains wakes before repair"
}

test_unknown_fallback
test_pi_signed_preserves_identity_with_pi_supervision_protocol
test_pi_snippet_uses_effective_extension_path
test_literal_paths_in_rendered_snippets
test_read_only_repair
