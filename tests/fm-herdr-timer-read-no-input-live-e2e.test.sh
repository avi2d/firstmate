#!/usr/bin/env bash
# Pi runs offline with an empty config and only a `!` shell command, so no model token is spent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_TIMER_READ_NO_INPUT_LIVE_E2E herdr pi jq perl

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

SESSION="fm-lab-timer-read-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  local status=$?
  trap - EXIT
  herdr_safe_stop_and_delete "$SESSION" || {
    echo "not ok - could not tear down Herdr lab session: $SESSION" >&2
    status=1
  }
  fm_test_cleanup
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(fm_test_tmproot fm-herdr-timer-read) || fail "could not create scratch dir"
TASK=lab-timer-read
LAB_HOME="$SCRATCH/home"
STDIN_LOG="$SCRATCH/stdin.log"
mkdir -p "$SCRATCH/cwd" "$SCRATCH/agent" "$LAB_HOME/state" "$LAB_HOME/data" "$LAB_HOME/config"
fm_test_track_watcher_state "$LAB_HOME/state"

cat > "$SCRATCH/stdin-log.ts" <<'TS'
import { appendFileSync } from "node:fs";

type SessionStartHost = { on(event: "session_start", handler: () => void): void };

export default function (pi: SessionStartHost): void {
  pi.on("session_start", () => {
    const log = process.env.LAB_STDIN_LOG;
    if (!log) return;
    process.stdin.on("data", (chunk: Buffer) => appendFileSync(log, chunk));
  });
}
TS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
in_lab_home() { FM_HOME="$LAB_HOME" "$@"; }

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"

wait_viewport() {  # <needle> <tries>
  local i
  for ((i = 0; i < $2; i++)); do
    fm_backend_visible_capture herdr "$TARGET" 2>/dev/null | grep -q -- "$1" && return 0
    sleep 0.5
  done
  return 1
}

stdin_bytes() { wc -c < "$STDIN_LOG" | tr -d ' '; }

expect_no_stdin() {  # <read>
  local bytes
  sleep 1
  bytes=$(stdin_bytes)
  [ "$bytes" -eq 0 ] || version_fail "$1 wrote $bytes bytes to the idle pi's stdin: $(head -c 240 "$STDIN_LOG" | cat -v)"
}

# Postcondition: TARGET is an idle fullscreen Pi whose transcript is longer than
# the viewport, and STDIN_LOG is empty and proven to record what Pi reads.
start_idle_fullscreen_pi() {
  local ws pane
  ws=$(lab workspace create --label fm-timer-read --cwd "$SCRATCH/cwd" 2>&1) \
    || fail "could not create the lab workspace: $ws"
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "workspace create did not return a root pane id"
  TARGET="$SESSION:$pane"
  : > "$STDIN_LOG"
  lab pane run "$pane" "FM_TASK_ID=$TASK LAB_STDIN_LOG='$STDIN_LOG' PI_CODING_AGENT_DIR='$SCRATCH/agent' PI_OFFLINE=1 pi --no-session --tui-mode fullscreen -e '$SCRATCH/stdin-log.ts'" >/dev/null 2>&1 \
    || fail "could not start pi in the lab pane"
  wait_viewport '^────' 60 || version_fail "fullscreen pi never drew its editor in the lab pane"
  lab pane send-text "$pane" '!seq -f "LAB_LONG_LINE_%g" 1 120' >/dev/null 2>&1 || fail "could not type the shell command"
  sleep 0.5
  lab pane send-keys "$pane" Enter >/dev/null 2>&1 || fail "could not submit the shell command"
  wait_viewport 'LAB_LONG_LINE_120' 60 || version_fail "fullscreen pi never showed the shell command output"
  sleep 3
  [ "$(stdin_bytes)" -gt 0 ] || version_fail "the typed shell command never reached the stdin log, so this guard cannot see what pi reads"
  : > "$STDIN_LOG"
  sleep 3
  [ "$(stdin_bytes)" -eq 0 ] || version_fail "an untouched idle pi read $(stdin_bytes) bytes in 3s, so this guard cannot isolate a read"
  fm_write_meta "$LAB_HOME/state/$TASK.meta" "window=$TARGET" backend=herdr harness=pi kind=ship "worktree=$SCRATCH/cwd"
}

test_timer_reads_do_not_wheel_scroll_an_idle_fullscreen_pi() {
  local lines out
  for lines in 40 1 200; do
    out=$(fm_backend_capture herdr "$TARGET" "$lines") || version_fail "the $lines-line capture could not read the pane"
    [ -n "$out" ] || version_fail "the $lines-line capture returned nothing"
    expect_no_stdin "the $lines-line capture"
  done

  out=$(in_lab_home bash "$ROOT/bin/fm-peek.sh" "$TASK" 2>"$SCRATCH/stderr") || version_fail "fm-peek could not read the pane: $(cat "$SCRATCH/stderr")"
  assert_contains "$out" LAB_LONG_LINE_120 "fm-peek did not return the pane's last transcript line"
  expect_no_stdin "fm-peek"

  out=$(in_lab_home bash "$ROOT/bin/fm-crew-state.sh" "$TASK" 2>"$SCRATCH/stderr") || version_fail "fm-crew-state failed: $out $(cat "$SCRATCH/stderr")"
  assert_contains "$out" 'source: pane' "fm-crew-state did not judge the task from its pane"
  expect_no_stdin "fm-crew-state"

  out=$(FM_POLL=1 FM_SIGNAL_GRACE=1 in_lab_home fm_run_timed 60 bash "$ROOT/bin/fm-watch.sh" 2>&1)
  assert_contains "$out" "stale: $TARGET" "the watcher never polled the idle pane through to its stale wake"
  expect_no_stdin "the watcher's polling"

  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: bounded captures, fm-peek, fm-crew-state, and the watcher's polling write nothing to an idle fullscreen pane"
}

test_scrollback_peek_does_not_stop_at_the_viewport() {
  local viewport_rows scrollback_rows out
  viewport_rows=$(fm_backend_visible_capture herdr "$TARGET" | wc -l | tr -d ' ')
  out=$(in_lab_home bash "$ROOT/bin/fm-peek.sh" "$TASK" 200 --scrollback 2>"$SCRATCH/stderr") \
    || version_fail "fm-peek --scrollback could not read the pane: $(cat "$SCRATCH/stderr")"
  scrollback_rows=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$scrollback_rows" -gt "$viewport_rows" ] || version_fail \
    "fm-peek --scrollback returned $scrollback_rows rows of a transcript longer than the $viewport_rows-row viewport"
  sleep 1
  note "herdr $HERDR_VERSION: the scrollback read returned $scrollback_rows rows past a $viewport_rows-row viewport and wrote $(stdin_bytes) bytes to pi's stdin"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: fm-peek --scrollback reads above the viewport"
}

start_idle_fullscreen_pi
test_timer_reads_do_not_wheel_scroll_an_idle_fullscreen_pi
test_scrollback_peek_does_not_stop_at_the_viewport
