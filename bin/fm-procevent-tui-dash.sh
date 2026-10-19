#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

SOURCE_ID=tui-dash-alerts
ADAPTER=tui-dash
TAP_DIR="$STATE/tui-dash-alerts"
SPOOL="$TAP_DIR/spool.jsonl"
CURSOR="$TAP_DIR/cursor"
HEARTBEAT="$TAP_DIR/heartbeat"
TAP_PID="$TAP_DIR/tap.pid"
TAP_EXIT="$TAP_DIR/tap.exit"
TAP_STDERR="$TAP_DIR/tap.stderr"
START_LOCK="$TAP_DIR/start.lock"
STDERR_TAIL_BYTES=2048

usage() {
  cat <<'USAGE'
tui-dash alert-stream process-event adapter.

Usage:
  fm-procevent-tui-dash.sh arm [-- <tui-dash command>...]
  fm-procevent-tui-dash.sh poll -- <tui-dash command>...
  fm-procevent-tui-dash.sh tap -- <tui-dash command>...
  fm-procevent-tui-dash.sh classify <result-file>
  fm-procevent-tui-dash.sh terminal <result-file>
  fm-procevent-tui-dash.sh relisten
  fm-procevent-tui-dash.sh verdict <sequence> <verdict>
  fm-procevent-tui-dash.sh source-id
  fm-procevent-tui-dash.sh retire

arm        Register source tui-dash-alerts so every alert event that
           "<tui-dash command> alerts --json" prints becomes its own durable
           "check: procevent tui-dash tui-dash-alerts <sequence>" wake whose
           captured result is that one JSON line, byte for byte.
           The command defaults to tui-dash; any argv after -- replaces it,
           for example a wrapper that runs a checkout through bun.
           The command is stored in the registration, and its first element
           must resolve when arming.
poll       The blocking child the generic runner executes; never run it in a
           conversational turn. It keeps one detached tap of the alert stream
           alive, prints the next complete line the tap spooled past its
           cursor, and exits. When FM_TUI_DASH_POLL_WINDOW_SECONDS (default
           300) pass with no line, it exits 75 with no output so the runner
           polls again under the same claim. When the stream command ended by
           itself and every spooled line was delivered, it prints one stopped
           document instead.
tap        The detached stream holder poll starts; never run it directly.
           It runs "<tui-dash command> alerts --json" in a session of its own,
           appends its stdout to the spool, and stops the stream when no poll
           has touched the heartbeat for FM_TUI_DASH_TAP_IDLE_SECONDS (default
           1800) or the registration is gone. The stream outlives each runner,
           so tui-dash keeps its episodes and quiet clocks between alerts.
classify   Print quota-pace, heavy-load or long-task for an alert event,
           stopped for a stopped document, and unknown otherwise.
terminal   Exit 0 only for a stopped document, so the generic runner retires
           the source instead of restarting a stream that keeps failing.
relisten   Exit 0: an empty window keeps the runner polling.
verdict    Record firstmate's one-line judgment of the captured alert event at
           <sequence> in the tui-dash verdict record, then acknowledge the
           result through "fm-procevent.sh handled". A repeat call for an
           acknowledged sequence records nothing and prints already-handled.
           A stopped or unknown result takes the generic handled instead.
source-id  Print the canonical source id.
retire     Retire the registration, stop the tap, and discard its spool.

Verdict record, owned by tui-dash: append-only JSON lines at
TUI_DASH_ALERTS_VERDICTS, else ~/.local/state/tui-dash/alerts-verdicts.jsonl.
Each line is {"schemaVersion":1,"event":<alert event>,"verdict":null|"<text>",
"recordedAt":"<ISO time>"}. poll appends verdict null as each alert event
reaches the runner, and verdict appends the judged line.

Stopped document, the captured result when the stream command ended itself:
  {"stopped":{"exitCode":<n>,"stderr":"<bounded tail of its stderr>"}}

Durability boundary: the cursor moves once a line is written to the runner,
so a runner killed between that write and its durable capture loses that one
event. A stream restarted after its tap stopped, for idle or a crash, starts
every tui-dash rule fresh.
USAGE
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

whole_seconds() {  # <variable-name> <value> <default>
  local value=${2:-$3}
  case "$value" in ''|*[!0-9]*|0) die "$1 must be a positive whole number of seconds" ;; esac
  printf '%s\n' "$value"
}

verdict_file() {
  printf '%s\n' "${TUI_DASH_ALERTS_VERDICTS:-$HOME/.local/state/tui-dash/alerts-verdicts.jsonl}"
}

registration_present() {
  [ -f "$(fm_procevent_registry_dir "$STATE")/$SOURCE_ID.source" ]
}

prepare_tap_dir() {
  (umask 077; mkdir -p "$TAP_DIR") || die "cannot prepare $TAP_DIR"
  [ -d "$TAP_DIR" ] && [ ! -L "$TAP_DIR" ] || die "unsafe tap directory: $TAP_DIR"
}

write_atomic() {  # <path> <content>
  local tmp
  tmp=$(umask 077; mktemp "$1.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# One write(2) with O_APPEND, so a concurrent appender cannot interleave a line.
append_line() {  # <path> <line>
  (umask 077; mkdir -p "$(dirname "$1")") || return 1
  perl -e '
    my ($path, $line) = @ARGV;
    open my $out, ">>", $path or exit 1;
    my $bytes = "$line\n";
    my $written = syswrite($out, $bytes);
    exit 1 unless defined $written && $written == length $bytes;
    close $out or exit 1;
  ' "$1" "$2"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cursor_offset() {
  local offset=0
  [ ! -f "$CURSOR" ] || IFS= read -r offset < "$CURSOR" || offset=0
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  printf '%s\n' "$offset"
}

# Prints the offset after the next complete line, then the line itself.
next_line() {  # <offset>
  [ -f "$SPOOL" ] || return 1
  perl -e '
    my ($path, $offset) = @ARGV;
    open my $in, "<", $path or exit 1;
    seek($in, $offset, 0) or exit 1;
    my $line = <$in>;
    exit 1 unless defined $line && $line =~ /\n\z/;
    print tell($in), "\n", $line;
  ' "$SPOOL" "$1"
}

heartbeat_age() {
  perl -e '
    my @stat = stat($ARGV[0]) or exit 1;
    my $age = time - $stat[9];
    print(($age < 0 ? 0 : $age), "\n");
  ' "$HEARTBEAT"
}

tap_alive() {
  local pid identity
  [ -f "$TAP_PID" ] || return 1
  IFS=$'\t' read -r pid identity < "$TAP_PID" || return 1
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ]
}

tap_exit_reason() {
  [ -f "$TAP_EXIT" ] || return 1
  sed -n 's/^reason=//p' "$TAP_EXIT"
}

# Only safe while no tap is appending to the spool.
compact_spool() {
  local offset tmp
  [ -f "$SPOOL" ] || return 0
  offset=$(cursor_offset)
  [ "$offset" -gt 0 ] || return 0
  tmp=$(umask 077; mktemp "$SPOOL.XXXXXX") || return 1
  if ! tail -c "+$((offset + 1))" "$SPOOL" > "$tmp" || ! mv -f -- "$tmp" "$SPOOL"; then
    rm -f -- "$tmp"
    return 1
  fi
  write_atomic "$CURSOR" 0
}

start_tap() {  # <command>...
  local waited=0
  fm_lock_acquire_wait "$START_LOCK" || return 1
  if tap_alive; then
    fm_lock_release "$START_LOCK"
    return 0
  fi
  if ! compact_spool; then
    fm_lock_release "$START_LOCK"
    return 1
  fi
  rm -f -- "$TAP_EXIT" "$TAP_PID"
  # An inherited runner output pipe would keep the runner from ever reading
  # this poll's end of file, so the tap closes every descriptor it inherits.
  perl -MPOSIX=setsid -e '
    my $pid = fork;
    exit 1 unless defined $pid;
    exit 0 if $pid;
    setsid() >= 0 or exit 1;
    POSIX::close($_) for 3 .. 1023;
    exec @ARGV or exit 127;
  ' "$SCRIPT_DIR/fm-procevent-tui-dash.sh" tap -- "$@" </dev/null >/dev/null 2>&1 || {
    fm_lock_release "$START_LOCK"
    return 1
  }
  while [ ! -s "$TAP_PID" ] && [ ! -e "$TAP_EXIT" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  fm_lock_release "$START_LOCK"
  [ -s "$TAP_PID" ] || [ -e "$TAP_EXIT" ]
}

stopped_document() {
  local code tail_text=''
  code=$(sed -n 's/^rc=//p' "$TAP_EXIT")
  case "$code" in ''|*[!0-9]*) code=1 ;; esac
  [ ! -f "$TAP_STDERR" ] || tail_text=$(tail -c "$STDERR_TAIL_BYTES" "$TAP_STDERR")
  jq -cn --argjson code "$code" --arg stderr "$tail_text" '{stopped: {exitCode: $code, stderr: $stderr}}'
}

alert_shaped() {  # <line>
  printf '%s\n' "$1" \
    | jq -e 'type == "object" and (.schemaVersion | type) == "number" and (.rule | type) == "string"' >/dev/null 2>&1
}

record_arrival() {  # <line>
  local record
  alert_shaped "$1" || return 0
  record=$(jq -cn --argjson event "$1" --arg at "$(now_iso)" \
    '{schemaVersion: 1, event: $event, verdict: null, recordedAt: $at}') || return 1
  append_line "$(verdict_file)" "$record"
}

require_command_tail() {  # -- <command>...
  [ "${1-}" = -- ] || usage
  [ "$#" -ge 2 ] || die "the tui-dash command needs at least one element"
}

cmd_arm() {
  local -a command=(tui-dash)
  if [ "$#" -gt 0 ]; then
    require_command_tail "$@"
    shift
    command=("$@")
  fi
  command -v "${command[0]}" >/dev/null 2>&1 || die "the tui-dash command does not resolve: ${command[0]}"
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-tui-dash.sh" poll -- "${command[@]}" || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf 'command: %s\n' "${command[*]}"
}

cmd_poll() {
  local window deadline offset found line next reason
  require_command_tail "$@"
  shift
  window=$(whole_seconds FM_TUI_DASH_POLL_WINDOW_SECONDS "${FM_TUI_DASH_POLL_WINDOW_SECONDS-}" 300) || exit 1
  prepare_tap_dir
  deadline=$((SECONDS + window))
  while :; do
    : > "$HEARTBEAT" || die "cannot touch the tap heartbeat"
    offset=$(cursor_offset)
    if found=$(next_line "$offset"); then
      next=${found%%$'\n'*}
      line=${found#*$'\n'}
      line=${line%$'\n'}
      if [ -z "$line" ]; then
        write_atomic "$CURSOR" "$next" || die "cannot advance the spool cursor"
        continue
      fi
      printf '%s\n' "$line" || exit 1
      write_atomic "$CURSOR" "$next" || die "cannot advance the spool cursor"
      record_arrival "$line" || printf 'warning: cannot record the alert arrival in %s\n' "$(verdict_file)" >&2
      exit 0
    fi
    if ! tap_alive; then
      reason=$(tap_exit_reason 2>/dev/null || true)
      if [ "$reason" = exited ]; then
        stopped_document || exit 1
        rm -f -- "$TAP_EXIT"
        exit 0
      fi
      start_tap "$@" || die "cannot start the tui-dash alert stream"
      continue
    fi
    [ "$SECONDS" -lt "$deadline" ] || exit 75
    sleep 1
  done
}

cmd_tap() {
  local idle child rc=0 reason age
  require_command_tail "$@"
  shift
  idle=$(whole_seconds FM_TUI_DASH_TAP_IDLE_SECONDS "${FM_TUI_DASH_TAP_IDLE_SECONDS-}" 1800) || exit 1
  prepare_tap_dir
  : > "$TAP_STDERR"
  "$@" alerts --json </dev/null >> "$SPOOL" 2>> "$TAP_STDERR" &
  child=$!
  write_atomic "$TAP_PID" "$$"$'\t'"$(fm_pid_identity "$$")" || { kill "$child" 2>/dev/null; exit 1; }
  while :; do
    if ! kill -0 "$child" 2>/dev/null; then
      wait "$child"
      rc=$?
      reason=exited
      break
    fi
    if ! age=$(heartbeat_age 2>/dev/null) || [ "$age" -gt "$idle" ]; then
      reason=idle
      break
    fi
    if ! registration_present; then
      reason=retired
      break
    fi
    sleep 1
  done
  write_atomic "$TAP_EXIT" "reason=$reason"$'\n'"rc=$rc" || true
  [ "$reason" != exited ] || exit 0
  # The stream command can spawn helpers of its own, and they share this group.
  if [ "$(perl -e 'print getpgrp(), "\n"')" = "$$" ]; then
    trap '' TERM
    kill -TERM -- "-$$" 2>/dev/null || true
  else
    kill -TERM "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
  exit 0
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  jq -r '
    if type != "object" then "unknown"
    elif .schemaVersion == 1 and (.rule == "quota-pace" or .rule == "heavy-load" or .rule == "long-task") then .rule
    elif has("stopped") and (has("rule") | not) then "stopped"
    else "unknown"
    end
  ' "$file" 2>/dev/null | head -n 1 | grep -E '^(quota-pace|heavy-load|long-task|stopped)$' || printf 'unknown\n'
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = stopped ]
}

cmd_verdict() {
  local seq=${1-} text=${2-} result record
  [ "$#" -eq 2 ] || usage
  case "$seq" in ''|*[!0-9]*) die "sequence must be a whole number: $seq" ;; esac
  [ -n "$text" ] || die "the verdict needs text"
  case "$text" in *$'\n'*|*$'\r'*) die "the verdict must be one line" ;; esac
  result="$(fm_procevent_inbox_dir "$STATE")/$SOURCE_ID.$seq.result"
  [ -f "$result" ] && [ ! -L "$result" ] || die "no captured result: $SOURCE_ID $seq"
  [ "$(fm_procevent_result_adapter "$result" 2>/dev/null)" = "$ADAPTER" ] \
    || die "the result was not captured by the $ADAPTER adapter: $SOURCE_ID $seq"
  if fm_procevent_is_handled "$STATE" "$SOURCE_ID" "$seq"; then
    printf 'already-handled: %s %s\n' "$SOURCE_ID" "$seq"
    return 0
  fi
  case "$(cmd_classify "$result")" in
    quota-pace|heavy-load|long-task) ;;
    *) die "the result is not an alert event; acknowledge it with fm-procevent.sh handled $SOURCE_ID $seq" ;;
  esac
  record=$(jq -c --arg verdict "$text" --arg at "$(now_iso)" \
    '{schemaVersion: 1, event: ., verdict: $verdict, recordedAt: $at}' "$result") \
    || die "cannot build the verdict record"
  append_line "$(verdict_file)" "$record" || die "cannot append the verdict to $(verdict_file)"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$SOURCE_ID" "$seq"
}

stop_tap() {
  local pid identity waited=0
  tap_alive || return 0
  IFS=$'\t' read -r pid identity < "$TAP_PID" || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  while tap_alive && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! tap_alive
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" || exit 1
  [ -d "$TAP_DIR" ] || return 0
  stop_tap || die "the tui-dash alert stream did not stop; its pid is in $TAP_PID"
  rm -f -- "$SPOOL" "$CURSOR" "$HEARTBEAT" "$TAP_PID" "$TAP_EXIT" "$TAP_STDERR"
  printf 'stream stopped: %s\n' "$SOURCE_ID"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  tap)       shift; cmd_tap "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  relisten)  shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  verdict)   shift; cmd_verdict "$@" ;;
  source-id) shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
