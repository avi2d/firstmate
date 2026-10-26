#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-tui-dash.sh, driven through the real runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-tui-dash)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export TUI_DASH_ALERTS_VERDICTS="$TMP_ROOT/verdicts.jsonl"
ADAPTER="$ROOT/bin/fm-procevent-tui-dash.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/tui-dash" <<'SH'
#!/usr/bin/env bash
[ "$*" = "alerts --json" ] || exit 64
while [ "$SECONDS" -lt 120 ]; do
  for f in "$FAKE_DIR"/emit/*; do
    [ -e "$f" ] || continue
    content=$(cat "$f")
    case "$content" in
      '{'*) printf '%s\n' "$content" ;;
      *) printf '{"schemaVersion":1,"rule":"%s","at":"%s","machine":"linux","stream":%s}\n' "$content" "$(basename "$f")" "$$" ;;
    esac
    rm -f "$f"
  done
  if [ -e "$FAKE_DIR/fail" ]; then
    printf 'the alert settings are not valid\n' >&2
    exit 3
  fi
  sleep 0.1
done
SH
chmod +x "$FAKE_BIN/tui-dash"

new_home() {  # <name>: prints the home and points FAKE_DIR at its own fake stream
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/fake/emit"
  fm_test_track_procevent_home "$home" "$FM_PROCEVENT_CLAIM_ROOT"
  printf '%s\n' "$home"
}

emit() {  # <home> <at> [rule]
  printf '%s\n' "${3:-heavy-load}" > "$1/fake/emit/$2"
}

wait_until() {  # <seconds> <command>...
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

start_once() {  # <home>
  FM_HOME="$1" FAKE_DIR="$1/fake" FM_TUI_DASH_POLL_WINDOW_SECONDS=20 \
    "$RUNNER" start tui-dash-alerts
}

result() { printf '%s/state/procevent-inbox/tui-dash-alerts.%s.result\n' "$1" "$2"; }
tap_pid() { cut -f1 "$1/state/tui-dash-alerts/tap.pid" 2>/dev/null; }
tap_gone() { local pid; pid=$(tap_pid "$1"); [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }
stream_pid() { jq -r .stream "$1"; }

help=$("$ADAPTER" --help 2>&1)
for command_name in arm poll tap classify terminal relisten verdict source-id retire; do
  assert_contains "$help" "fm-procevent-tui-dash.sh $command_name" "help names $command_name"
done
assert_equals tui-dash-alerts "$("$ADAPTER" source-id)" "canonical source id"
"$ADAPTER" relisten || fail "relisten keeps the runner polling"
pass "help, source id and relisten"

H=$(new_home refuse)
if out=$(FM_HOME="$H" "$ADAPTER" arm -- "$TMP_ROOT/no-such-tui-dash" 2>&1); then
  fail "arm accepted a command that does not resolve"
fi
assert_contains "$out" "does not resolve" "arm names the unresolved command"
assert_absent "$H/state/procevent/tui-dash-alerts.source" "a refused arm left a registration"
pass "arm refuses a command that does not resolve"

H=$(new_home stream)
FM_HOME="$H" "$ADAPTER" arm -- "$FAKE_BIN/tui-dash" >/dev/null || fail "arm failed"
start_once "$H" > "$TMP_ROOT/start1.out" 2>&1 &
first=$!
wait_until 10 test -s "$H/state/tui-dash-alerts/tap.pid" || fail "the first poll started no tap"
emit "$H" 2026-10-19T10:00:00Z
wait "$first" || fail "the first runner failed: $(cat "$TMP_ROOT/start1.out")"
emit "$H" 2026-10-19T10:05:00Z long-task
start_once "$H" > "$TMP_ROOT/start2.out" 2>&1 || fail "the second runner failed: $(cat "$TMP_ROOT/start2.out")"
assert_equals '{"schemaVersion":1,"rule":"heavy-load","at":"2026-10-19T10:00:00Z","machine":"linux","stream":'"$(stream_pid "$(result "$H" 1)")"'}' \
  "$(cat "$(result "$H" 1)")" "the captured result is the alert line byte for byte"
assert_equals "$(stream_pid "$(result "$H" 1)")" "$(stream_pid "$(result "$H" 2)")" \
  "both alerts came from one stream that outlived the first runner"
assert_equals "procevent:tui-dash-alerts:1 procevent:tui-dash-alerts:2" \
  "$(awk -F '\t' '$3 == "check" {print $4}' "$H/state/.wake-queue" | sort -u | tr '\n' ' ' | sed 's/ $//')" \
  "each alert became one check wake"
assert_grep 'check: procevent tui-dash tui-dash-alerts 2' "$H/state/.wake-queue" "the second wake names sequence 2"
assert_equals "heavy-load long-task" \
  "$("$ADAPTER" classify "$(result "$H" 1)") $("$ADAPTER" classify "$(result "$H" 2)")" "classify names each rule"
if "$ADAPTER" terminal "$(result "$H" 1)"; then fail "an alert event ended the source"; fi
assert_present "$H/state/procevent/tui-dash-alerts.source" "the source stays registered after alerts"
assert_equals "null null" "$(jq -r .verdict "$TUI_DASH_ALERTS_VERDICTS" | tr '\n' ' ' | sed 's/ $//')" \
  "each arrival is recorded with verdict null"
assert_equals 2026-10-19T10:05:00Z "$(tail -n 1 "$TUI_DASH_ALERTS_VERDICTS" | jq -r .event.at)" \
  "the arrival record carries the event verbatim"
pass "alerts from one long-lived stream become one wake each"

before=$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")
out=$(FM_HOME="$H" "$ADAPTER" verdict 1 "expected load from the night run")
assert_equals "handled: tui-dash-alerts 1" "$out" "verdict acknowledges the result"
judged=$(tail -n 1 "$TUI_DASH_ALERTS_VERDICTS")
assert_equals "expected load from the night run" "$(printf '%s\n' "$judged" | jq -r .verdict)" "the verdict text is recorded"
assert_equals "$(jq -c . "$(result "$H" 1)")" "$(printf '%s\n' "$judged" | jq -c .event)" "the verdict names its event"
assert_equals 1 "$(printf '%s\n' "$judged" | jq -r .schemaVersion)" "the verdict record is schema version 1"
printf '%s\n' "$judged" | jq -e '.recordedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null \
  || fail "recordedAt is not an ISO time"
out=$(FM_HOME="$H" "$ADAPTER" verdict 1 "a second opinion")
assert_equals "already-handled: tui-dash-alerts 1" "$out" "a repeat verdict is reported"
assert_equals $((before + 1)) "$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")" "a repeat verdict records nothing"
if FM_HOME="$H" "$ADAPTER" verdict 2 $'two\nlines' 2>/dev/null; then fail "a multi-line verdict was accepted"; fi
if FM_HOME="$H" "$ADAPTER" verdict 9 "missing" 2>/dev/null; then fail "a verdict for a missing result was accepted"; fi
pass "verdict records the judgment once and acknowledges it"

out=$(FM_HOME="$H" FAKE_DIR="$H/fake" FM_TUI_DASH_POLL_WINDOW_SECONDS=1 "$ADAPTER" poll -- "$FAKE_BIN/tui-dash")
rc=$?
expect_code 75 "$rc" "an empty window"
assert_equals "" "$out" "an empty window prints nothing"
pass "an empty window exits 75 with no output"

touch "$H/fake/fail"
start_once "$H" > "$TMP_ROOT/start3.out" 2>&1 || fail "the stopping runner failed: $(cat "$TMP_ROOT/start3.out")"
assert_equals '{"stopped":{"exitCode":3,"stderr":"the alert settings are not valid"}}' \
  "$(cat "$(result "$H" 3)")" "a stream that ended itself is reported with its exit code and stderr"
assert_equals stopped "$("$ADAPTER" classify "$(result "$H" 3)")" "classify names a stopped stream"
"$ADAPTER" terminal "$(result "$H" 3)" || fail "a stopped stream is not terminal"
assert_absent "$H/state/procevent/tui-dash-alerts.source" "a stopped stream left its source registered"
if FM_HOME="$H" "$ADAPTER" verdict 3 "noted" 2>/dev/null; then fail "a verdict was recorded for a stopped stream"; fi
pass "a stream that ends itself wakes once and retires the source"

printf 'not json\n' > "$TMP_ROOT/garbage.result"
assert_equals unknown "$("$ADAPTER" classify "$TMP_ROOT/garbage.result")" "non-JSON is unknown"
printf '{"schemaVersion":2,"rule":"heavy-load"}\n' > "$TMP_ROOT/future.result"
assert_equals unknown "$("$ADAPTER" classify "$TMP_ROOT/future.result")" "a later schema version is unknown"
if "$ADAPTER" terminal "$TMP_ROOT/future.result"; then fail "an unknown line ended the source"; fi
pass "unrecognised lines classify unknown and keep the source"

H=$(new_home idle)
FM_HOME="$H" "$ADAPTER" arm -- "$FAKE_BIN/tui-dash" >/dev/null || fail "arm failed"
export FM_TUI_DASH_TAP_IDLE_SECONDS=2
out=$(FM_HOME="$H" FAKE_DIR="$H/fake" FM_TUI_DASH_POLL_WINDOW_SECONDS=1 "$ADAPTER" poll -- "$FAKE_BIN/tui-dash")
expect_code 75 $? "the idle home's first window"
first_tap=$(tap_pid "$H")
emit "$H" 2026-10-19T11:00:00Z quota-pace
wait_until 15 tap_gone "$H" || fail "the tap outlived its idle limit"
assert_grep "reason=idle" "$H/state/tui-dash-alerts/tap.exit" "the tap records why it stopped"
start_once "$H" > "$TMP_ROOT/start4.out" 2>&1 || fail "the runner after idle failed: $(cat "$TMP_ROOT/start4.out")"
assert_equals 2026-10-19T11:00:00Z "$(jq -r .at "$(result "$H" 1)")" "an alert spooled before the idle stop is still delivered"
FM_HOME="$H" FAKE_DIR="$H/fake" FM_TUI_DASH_POLL_WINDOW_SECONDS=1 "$ADAPTER" poll -- "$FAKE_BIN/tui-dash" >/dev/null
assert_not_equals "$first_tap" "$(tap_pid "$H")" "a poll with nothing spooled started a fresh tap"
kill -0 "$(tap_pid "$H")" 2>/dev/null || fail "the fresh tap is not running"
unset FM_TUI_DASH_TAP_IDLE_SECONDS
pass "an idle tap stops and a later poll delivers what it spooled"

FM_HOME="$H" "$RUNNER" retire tui-dash-alerts >/dev/null || fail "generic retire failed"
wait_until 10 tap_gone "$H" || fail "the tap outlived its registration"
assert_grep "reason=retired" "$H/state/tui-dash-alerts/tap.exit" "the tap stops when its registration is gone"
pass "the tap stops once its registration is retired"

H=$(new_home retire)
FM_HOME="$H" "$ADAPTER" arm -- "$FAKE_BIN/tui-dash" >/dev/null || fail "arm failed"
FM_HOME="$H" FAKE_DIR="$H/fake" FM_TUI_DASH_POLL_WINDOW_SECONDS=1 "$ADAPTER" poll -- "$FAKE_BIN/tui-dash" >/dev/null
retired_tap=$(tap_pid "$H")
kill -0 "$retired_tap" 2>/dev/null || fail "no tap was running before retire"
out=$(FM_HOME="$H" "$ADAPTER" retire) || fail "adapter retire failed: $out"
assert_contains "$out" "stream stopped: tui-dash-alerts" "retire reports the stopped stream"
! kill -0 "$retired_tap" 2>/dev/null || fail "retire left the tap running"
assert_absent "$H/state/tui-dash-alerts/spool.jsonl" "retire discarded the spool"
assert_absent "$H/state/procevent/tui-dash-alerts.source" "retire dropped the registration"
pass "adapter retire stops the stream at once"

FAKE_TMUX_BIN="$TMP_ROOT/faketmux"
mkdir -p "$FAKE_TMUX_BIN"
cat > "$FAKE_TMUX_BIN/tmux" <<'TMUXSH'
#!/usr/bin/env bash
if [ "${1:-}" = "list-panes" ]; then
  printf '%s\n' '%fixture-pane'
  exit 0
fi
exit 1
TMUXSH
chmod +x "$FAKE_TMUX_BIN/tmux"
export PATH="$FAKE_TMUX_BIN:$PATH"
export FM_CREW_STATE_NO_FORGE=1

write_task() {
  local home=$1 id=$2 busy=$3 line=${4-}
  local wt="$home/wt-$id"
  mkdir -p "$wt"
  cat > "$home/state/$id.meta" <<EOF
worktree=$wt
kind=ship
harness=pi
backend=tmux
window=%fixture-pane
branch=fm/fixture-$id
project=fixture
EOF
  printf 'gentoken1\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=gentoken1 seq=1 state=%s source=pi-ext event=agent_start ts=%s\n' "$busy" "$(date +%s)" > "$home/state/$id.busy-state"
  if [ -n "$line" ]; then
    printf '%s\n' "$line" > "$home/state/$id.status"
  fi
}

write_alert_result() {
  mkdir -p "$1/state/procevent-inbox"
  cat > "$1/state/procevent-inbox/tui-dash-alerts.$2.result"
  printf 'tui-dash\n' > "$1/state/procevent-inbox/tui-dash-alerts.$2.adapter"
}

emit_json() {
  cat > "$1/fake/emit/$2"
}

last_verdict() {
  tail -n 1 "$TUI_DASH_ALERTS_VERDICTS"
}

H=$(new_home routine-working)
write_task "$H" alpha busy 'working: on the routine path'
write_alert_result "$H" 4 <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T12:00:00Z","machine":"linux","task":{"id":"alpha","title":"Alpha","project":"fixture","state":"working","detail":"harness busy (pi-ext)","firstStartedAt":"2026-10-19T11:00:00Z"},"quietSince":"2026-10-19T11:45:00Z","quietMinutes":15,"totalMinutes":60}
JSON
before=$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")
FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.4.result" || fail "a long task under 2h with a busy harness was not silent"
assert_equals $((before + 1)) "$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")" "a routine alert records one verdict"
judged=$(last_verdict)
assert_contains "$(printf '%s\n' "$judged" | jq -r .verdict)" "routine:" "a routine long task records a routine verdict"
assert_contains "$(printf '%s\n' "$judged" | jq -r .verdict)" "busy harness" "the verdict names why the alert stayed quiet"
assert_equals "$(jq -c . "$H/state/procevent-inbox/tui-dash-alerts.4.result")" "$(printf '%s\n' "$judged" | jq -c .event)" "the routine verdict carries the event verbatim"
pass "a long task under 2h with a busy harness is recorded without a wake"

H=$(new_home routine-paused)
write_task "$H" beta idle 'paused: waiting on capacity'
write_alert_result "$H" 5 <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T12:00:00Z","machine":"linux","task":{"id":"beta","title":"Beta","project":"fixture","state":"waiting","detail":"paused","firstStartedAt":"2026-10-19T11:15:00Z"},"quietSince":"2026-10-19T11:45:00Z","quietMinutes":15,"totalMinutes":45}
JSON
FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.5.result" || fail "a long task under 2h on a declared pause was not silent"
assert_contains "$(last_verdict | jq -r .verdict)" "declared pause" "the verdict names the declared pause"
pass "a long task under 2h on a declared pause is recorded without a wake"

H=$(new_home routine-load)
write_alert_result "$H" 6 <<'JSON'
{"schemaVersion":1,"rule":"heavy-load","at":"2026-10-19T12:00:00Z","machine":"linux","since":"2026-10-19T11:55:00Z","crossed":["load"],"limits":{"name":"linux","loadAtLeast":16,"memory":{"availableUnderPercent":15}},"load":[19.41,8.86,8.09],"memory":null,"topProcesses":{"byCpu":[],"byMemory":[]}}
JSON
FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.6.result" || fail "a heavy load on load alone was not silent"
assert_contains "$(last_verdict | jq -r .verdict)" "load alone" "the verdict names the load-only crossing"
pass "a heavy load on load alone is recorded without a wake"

H=$(new_home wake-two-hours)
write_task "$H" gamma busy 'working: past the mark'
write_alert_result "$H" 7 <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T13:00:00Z","machine":"linux","task":{"id":"gamma","title":"Gamma","project":"fixture","state":"working","detail":"harness busy (pi-ext)","firstStartedAt":"2026-10-19T11:00:00Z"},"quietSince":"2026-10-19T12:45:00Z","quietMinutes":15,"totalMinutes":120}
JSON
before=$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.7.result" 2>/dev/null; then
  fail "a long task at exactly 2h stayed silent"
fi
assert_equals "$before" "$(wc -l < "$TUI_DASH_ALERTS_VERDICTS")" "a waking alert records no verdict"
pass "a long task at exactly 2h still wakes"

H=$(new_home wake-blocked)
write_task "$H" delta idle 'blocked: waiting on review'
write_alert_result "$H" 8 <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T12:00:00Z","machine":"linux","task":{"id":"delta","title":"Delta","project":"fixture","state":"blocked","detail":"waiting on review","firstStartedAt":"2026-10-19T11:30:00Z"},"quietSince":"2026-10-19T11:45:00Z","quietMinutes":15,"totalMinutes":30}
JSON
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.8.result" 2>/dev/null; then
  fail "a blocked long task stayed silent"
fi
pass "a long task under 2h in another state still wakes"

H=$(new_home wake-idle-harness)
write_task "$H" epsilon idle 'working: between turns'
write_alert_result "$H" 9 <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T12:00:00Z","machine":"linux","task":{"id":"epsilon","title":"Epsilon","project":"fixture","state":"working","detail":"between turns","firstStartedAt":"2026-10-19T11:00:00Z"},"quietSince":"2026-10-19T11:45:00Z","quietMinutes":15,"totalMinutes":60}
JSON
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.9.result" 2>/dev/null; then
  fail "a working task with an idle harness stayed silent"
fi
pass "a working task without a busy harness still wakes"

H=$(new_home wake-quota)
write_alert_result "$H" 10 <<'JSON'
{"schemaVersion":1,"rule":"quota-pace","at":"2026-10-19T12:00:00Z","window":"five_hour","windowLabel":"session","leftPoints":46,"elapsedFraction":0.5,"resetsAt":"2026-10-19T17:00:00Z","flags":[]}
JSON
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.10.result" 2>/dev/null; then
  fail "a quota-pace alert stayed silent"
fi
pass "every quota-pace alert still wakes"

H=$(new_home wake-memory)
write_alert_result "$H" 11 <<'JSON'
{"schemaVersion":1,"rule":"heavy-load","at":"2026-10-19T12:00:00Z","machine":"linux","since":"2026-10-19T11:55:00Z","crossed":["load","memory"],"limits":{"name":"linux","loadAtLeast":16,"memory":{"availableUnderPercent":15}},"load":[19.41,8.86,8.09],"memory":{"usedBytes":46000000000,"totalBytes":50513698816,"usedPercent":91},"topProcesses":{"byCpu":[],"byMemory":[]}}
JSON
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.11.result" 2>/dev/null; then
  fail "a memory-pressure heavy load stayed silent"
fi
pass "a memory-pressure heavy load still wakes"

H=$(new_home wake-stopped)
mkdir -p "$H/state/procevent-inbox"
printf '{"stopped":{"exitCode":3,"stderr":"the alert settings are not valid"}}\n' > "$H/state/procevent-inbox/tui-dash-alerts.12.result"
printf 'tui-dash\n' > "$H/state/procevent-inbox/tui-dash-alerts.12.adapter"
assert_present "$H/state/procevent-inbox/tui-dash-alerts.12.result" "the stopped fixture exists"
if FM_HOME="$H" "$ADAPTER" silent "$H/state/procevent-inbox/tui-dash-alerts.12.result" 2>/dev/null; then
  fail "a stopped document stayed silent"
fi
printf 'not json\n' > "$TMP_ROOT/silence-garbage.result"
if "$ADAPTER" silent "$TMP_ROOT/silence-garbage.result" 2>/dev/null; then
  fail "an unknown document stayed silent"
fi
pass "stopped and unknown documents still wake"

H=$(new_home routine-runner)
write_task "$H" alpha busy 'working: on the routine path'
FM_HOME="$H" "$ADAPTER" arm -- "$FAKE_BIN/tui-dash" >/dev/null || fail "arm failed"
emit_json "$H" 2026-10-19T12:00:00Z <<'JSON'
{"schemaVersion":1,"rule":"long-task","reason":"quiet","at":"2026-10-19T12:00:00Z","machine":"linux","task":{"id":"alpha","title":"Alpha","project":"fixture","state":"working","detail":"harness busy (pi-ext)","firstStartedAt":"2026-10-19T11:00:00Z"},"quietSince":"2026-10-19T11:45:00Z","quietMinutes":15,"totalMinutes":60}
JSON
start_once "$H" > "$TMP_ROOT/routine-run.out" 2>&1 || fail "the routine runner failed: $(cat "$TMP_ROOT/routine-run.out")"
assert_not_contains "$(cat "$H/state/.wake-queue")" "procevent:tui-dash-alerts:1" "a routine alert queues no wake"
assert_contains "$(last_verdict | jq -r .verdict)" "routine:" "the runner path records the routine verdict"
assert_present "$H/state/procevent-inbox/tui-dash-alerts.1.handled" "a routine alert is acknowledged"
pass "the runner records a routine alert with no wake"

H=$(new_home wake-runner)
FM_HOME="$H" "$ADAPTER" arm -- "$FAKE_BIN/tui-dash" >/dev/null || fail "arm failed"
emit_json "$H" 2026-10-19T12:00:00Z <<'JSON'
{"schemaVersion":1,"rule":"quota-pace","at":"2026-10-19T12:00:00Z","window":"five_hour","windowLabel":"session","leftPoints":46,"elapsedFraction":0.5,"resetsAt":"2026-10-19T17:00:00Z","flags":[]}
JSON
start_once "$H" > "$TMP_ROOT/wake-run.out" 2>&1 || fail "the waking runner failed: $(cat "$TMP_ROOT/wake-run.out")"
assert_contains "$(cat "$H/state/.wake-queue")" "check: procevent tui-dash tui-dash-alerts 1" "a quota alert still queues its wake"
pass "the runner still wakes for a quota alert"
