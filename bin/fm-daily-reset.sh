#!/usr/bin/env bash
# Usage: fm-daily-reset.sh [check] | run [--force] [id...] | arm | disarm | --help
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TIME_FILE="$CONFIG/daily-session-reset"
RECORD="$STATE/.daily-reset"
BADCONFIG="$STATE/.daily-reset-badconfig"
CHECK_ID=daily-reset
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTRY="$DATA/secondmates.md"
RESTART_BIN="${FM_DAILY_RESET_RESTART_BIN:-$SCRIPT_DIR/fm-secondmate-restart.sh}"
DEFAULT_TIME=04:00
RECORD_SCHEMA=fm-daily-reset-v1
MAX_LINE=240
. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-check-lib.sh"
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
. "$SCRIPT_DIR/fm-backend.sh"
. "$SCRIPT_DIR/fm-busy-lib.sh"
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
usage() {
  cat <<'EOF'
Usage:
  fm-daily-reset.sh [check]   print one wake line when reset is due, silent otherwise
  fm-daily-reset.sh run [--force] [id...]
  fm-daily-reset.sh arm       write and register state/daily-reset.check.sh
  fm-daily-reset.sh disarm    remove the shim, trust binding, and records
  fm-daily-reset.sh --help    print this help
  Exit: 0 clean, 1 not due or failed, 2 bad use, 3 some mates skipped or unrestarted
EOF
}
today_now() {
  local day="" hm=""
  day="${FM_DAILY_RESET_TODAY:-}"
  hm="${FM_DAILY_RESET_NOW:-}"
  [ -n "$day" ] || day="$(date +%F)"
  [ -n "$hm" ] || hm="$(date +%H:%M)"
  printf '%s %s\n' "$day" "$hm"
}
sched_time() {
  local raw="" line=""
  if [ ! -f "$TIME_FILE" ] || [ -L "$TIME_FILE" ]; then
    printf '%s\n' "$DEFAULT_TIME"
    return 0
  fi
  raw="$(cat "$TIME_FILE" 2>/dev/null || true)"
  line="$(printf '%s\n' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed -n '1p')"
  case "$line" in
    off|disabled) printf 'off\n'; return 0 ;;
  esac
  case "$line" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  case "$line" in
    2[4-9]:*) return 1 ;;
  esac
  printf '%s\n' "$line"
}
record_date() {
  local first=""
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r first < "$RECORD" 2>/dev/null || return 1
  case "$first" in
    "$RECORD_SCHEMA "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$first" | sed -e 's/^[^ ]* //'
}
record_stamp() {
  local day="" tmp="" device=""
  day="$1"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device="$(fm_pr_file_device "$STATE")" || return 1
  tmp="$(umask 077; mktemp "$STATE/.fm-daily-reset.XXXXXX" 2>/dev/null)" || return 1
  printf '%s %s\n' "$RECORD_SCHEMA" "$day" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD"
}
due_state() {
  local sched="" today="" now="" last=""
  sched="$(sched_time)" || { printf 'bad-config\n'; return 0; }
  [ "$sched" = off ] && { printf 'disabled\n'; return 0; }
  [ -e "$STATE/.afk" ] && { printf 'parked\n'; return 0; }
  today="$(today_now)"
  now="${today##* }"
  today="${today%% *}"
  case "$now" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) printf 'bad-config\n'; return 0 ;;
  esac
  case "$now" in
    2[4-9]:*) printf 'bad-config\n'; return 0 ;;
  esac
  [ "$now" \< "$sched" ] && { printf 'waiting\n'; return 0; }
  last="$(record_date 2>/dev/null || true)"
  [ "$last" = "$today" ] && { printf 'waiting\n'; return 0; }
  printf 'due\n'
}
config_hash() {
  fm_custom_check_sha256 "$TIME_FILE" 2>/dev/null || printf 'unreadable\n'
}
report_bad_config() {
  local hash="" seen=""
  hash="$(config_hash)"
  seen="$(cat "$BADCONFIG" 2>/dev/null || true)"
  [ "$seen" = "$hash" ] && return 0
  fm_cap_line "daily-reset: config/daily-session-reset is not HH:MM or off" "$MAX_LINE"
  (umask 077; printf '%s\n' "$hash" > "$BADCONFIG") 2>/dev/null || true
}
do_check() {
  case "$(due_state)" in
    due) fm_cap_line "daily-reset due: run bin/fm-daily-reset.sh run to persist open records and reset supervisor sessions" "$MAX_LINE" ;;
    bad-config) report_bad_config ;;
  esac
  return 0
}
registry_ids() {
  local line=""
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ -n "$SECONDMATE_REGISTRY_ID" ] || continue
    printf '%s\n' "$SECONDMATE_REGISTRY_ID"
  done < "$REGISTRY"
  return 0
}
valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
print_main_half() {
  cat <<'EOF'
main-session half (Pi grants session replacement to user-initiated commands only):
1. Persist this session's open work now, following the /stow skill's
   "Open-record persistence" section and nothing else from that skill.
2. Ask the captain to start a fresh session (/new). The reset lands when they do.
EOF
}
do_run() {
  local force=0
  if [ "${1:-}" = "--force" ]; then force=1; shift; fi
  if [ "$force" -eq 0 ]; then
    case "$(due_state)" in
      due) ;;
      *) echo "daily-reset: not due; pass --force to run anyway" >&2; return 1 ;;
    esac
  fi
  local today="" rc=0 skipped=0
  today="$(today_now | cut -d' ' -f1)"
  local ids=() rest=() id="" verdict=""
  if [ "$#" -gt 0 ]; then
    for id in "$@"; do
      valid_id "$id" || { echo "error: invalid secondmate id: $id" >&2; return 2; }
      ids+=("$id")
    done
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      ids+=("$id")
    done < <(registry_ids)
  fi
  if [ "${#ids[@]}" -gt 0 ]; then
    for id in "${ids[@]}"; do
      verdict="$(fm_busy_classify_meta "$STATE/$id.meta" "$id" "$STATE" 2>/dev/null || true)"
      [ -n "$verdict" ] || verdict="unknown classify-failed"
      case "$verdict" in
        busy" "*) printf 'skip: %s is mid-turn (%s); retry tomorrow\n' "$id" "$verdict"; skipped=$((skipped + 1)) ;;
        *) rest+=("$id") ;;
      esac
    done
  fi
  if [ "${#rest[@]}" -gt 0 ]; then
    "$RESTART_BIN" "${rest[@]}"
    rc=$?
  else
    printf 'no secondmates to restart\n'
  fi
  print_main_half
  record_stamp "$today" || { echo "error: could not stamp $RECORD" >&2; return 1; }
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  if [ "$skipped" -ne 0 ]; then return 3; fi
}
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-daily-reset.sh.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-daily-reset.sh") check"
}
shim_write() {
  local want="" device="" tmp=""
  want="$1"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device="$(fm_pr_file_device "$STATE")" || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp="$(umask 077; mktemp "$STATE/.fm-daily-reset.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}
do_arm() {
  local want=""
  want="$(shim_content "$FM_HOME")" || { echo "error: could not render the check shim" >&2; return 1; }
  shim_write "$want" || { echo "error: could not write $CHECK_SHIM" >&2; return 1; }
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" || { echo "error: could not register the check" >&2; return 1; }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}
do_disarm() {
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" 2>/dev/null || true
  rm -f -- "$CHECK_SHIM" "$RECORD" "$BADCONFIG"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}
case "${1-check}" in
  check) do_check ;;
  run) shift; do_run "$@" ;;
  arm) do_arm ;;
  disarm) do_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
