#!/usr/bin/env bash
# Default-on live guard for the herdr Pi scrollbar strip in bin/fm-pane-hash-lib.sh.
# Pi runs offline with an empty config and only a `!` shell command, so no model token is spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_PI_FULLSCREEN_SCROLLBAR_LIVE_E2E herdr pi jq perl

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

SESSION="fm-lab-pi-scrollbar-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-scrollbar.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
mkdir -p "$SCRATCH/cwd" "$SCRATCH/agent"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
# shellcheck source=bin/fm-pane-hash-lib.sh
. "$ROOT/bin/fm-pane-hash-lib.sh"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"

plain_digest() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

scrollbar_rows() { printf '%s\n' "$1" | grep -cE '[┃│]$' || true; }

wait_capture() {  # <target> <needle> <tries>
  local i
  for ((i = 0; i < $3; i++)); do
    fm_backend_capture herdr "$1" 40 2>/dev/null | grep -q -- "$2" && return 0
    sleep 0.5
  done
  return 1
}

# start_long_transcript <mode>: sets TARGET to an idle Pi pane whose transcript
# is longer than the viewport.
start_long_transcript() {
  local mode=$1 ws pane target
  ws=$(lab workspace create --label "fm-pi-scrollbar-$mode" --cwd "$SCRATCH/cwd" 2>&1) \
    || fail "could not create the lab workspace: $ws"
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "workspace create did not return a root pane id"
  target="$SESSION:$pane"
  lab pane run "$pane" "PI_CODING_AGENT_DIR='$SCRATCH/agent' PI_OFFLINE=1 pi --no-session --tui-mode $mode" >/dev/null 2>&1 \
    || fail "could not start pi in the $mode pane"
  wait_capture "$target" '^────' 60 || version_fail "pi --tui-mode $mode never drew its editor in the lab pane"
  lab pane send-text "$pane" '!seq -f "LAB_LONG_LINE_%g" 1 120' >/dev/null 2>&1 || fail "could not type the shell command"
  sleep 0.5
  lab pane send-keys "$pane" Enter >/dev/null 2>&1 || fail "could not submit the shell command"
  wait_capture "$target" 'LAB_LONG_LINE_120' 60 || version_fail "pi --tui-mode $mode never showed the shell command output"
  sleep 3
  TARGET=$target
}

test_fullscreen_scrollbar_flash_hashes_like_the_quiet_pane() {
  local target quiet_tail quiet quiet_hash flash_tail flash flash_hash
  start_long_transcript fullscreen
  target=$TARGET
  quiet_tail=$(fm_backend_capture herdr "$target" 40)
  sleep 3
  quiet=$(fm_backend_visible_capture herdr "$target")
  quiet_hash=$(fm_pane_stale_hash herdr pi "$target" '' "$quiet_tail") || version_fail "the stale hash could not read the fullscreen pane"
  fm_backend_capture herdr "$target" 40 >/dev/null
  sleep 0.3
  flash_tail=$(fm_backend_capture herdr "$target" 40)
  flash=$(fm_backend_visible_capture herdr "$target")
  flash_hash=$(fm_pane_stale_hash herdr pi "$target" '' "$flash_tail") || version_fail "the stale hash could not read the fullscreen pane"
  [ "$(scrollbar_rows "$flash")" -gt "$(scrollbar_rows "$quiet")" ] && [ "$flash_tail" != "$quiet_tail" ] || version_fail \
    "fullscreen pi drew no scrollbar after a long herdr read (scrollbar rows: quiet $(scrollbar_rows "$quiet"), flash $(scrollbar_rows "$flash")), so this guard no longer exercises the strip"
  [ "$quiet_hash" = "$flash_hash" ] || version_fail \
    "an unchanged idle fullscreen pi pane hashes differently with its scrollbar column; quiet:"$'\n'"$quiet"$'\n'"flash:"$'\n'"$flash"
  note "fullscreen pi $PI_VERSION under herdr $HERDR_VERSION: scrollbar rows quiet $(scrollbar_rows "$quiet"), flash $(scrollbar_rows "$flash")"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a fullscreen pane hashes the same with and without its transient scrollbar"
}

test_regular_pane_hashes_its_viewport_as_plain_digest() {
  local target viewport
  start_long_transcript regular
  target=$TARGET
  fm_backend_capture herdr "$target" 40 >/dev/null
  sleep 0.3
  viewport=$(fm_backend_visible_capture herdr "$target")
  [ "$(scrollbar_rows "$viewport")" -eq 0 ] || version_fail "regular-mode pi drew a scrollbar column:"$'\n'"$viewport"
  [ "$(fm_pane_stale_hash herdr pi "$target" '' '')" = "$(printf '%s' "$viewport" | plain_digest)" ] || version_fail \
    "a regular-mode pi viewport no longer hashes as its plain digest:"$'\n'"$viewport"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a regular-mode pane draws no scrollbar and hashes its viewport as the plain digest"
}

test_fullscreen_scrollbar_flash_hashes_like_the_quiet_pane
test_regular_pane_hashes_its_viewport_as_plain_digest
