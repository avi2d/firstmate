#!/usr/bin/env bash
# Usage: fm-day-review.sh [check] | run [--force] | collect --since <epoch> --until <epoch> | arm | disarm | --help
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TIME_FILE="$CONFIG/day-review"
RECORD="$STATE/.day-review"
BADCONFIG="$STATE/.day-review-badconfig"
OUT="$DATA/day-review"
CHECK_ID="day-review"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTRY="$DATA/secondmates.md"
PY="$SCRIPT_DIR/fm-day-review.py"
DEFAULT_SCHEDULE="21:00 Europe/Moscow"
RECORD_SCHEMA=fm-day-review-v1
SELF_LABEL="first mate"
MAX_LINE=240
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
usage() {
  cat <<'EOF'
Usage:
  fm-day-review.sh [check]   print one wake line when the day review is due, silent otherwise
  fm-day-review.sh run [--force]
                             collect this home and every registered secondmate, write the board,
                             print its path; --force runs before the scheduled time without
                             marking the day done
  fm-day-review.sh collect --since <epoch> --until <epoch>
                             print this home's raw review data as JSON; run reaches remote
                             secondmates through bin/fm-on.sh with this command
  fm-day-review.sh arm       write and register state/day-review.check.sh
  fm-day-review.sh disarm    remove the shim, trust binding, and due records
  fm-day-review.sh --help    print this help
Schedule: config/day-review holds "HH:MM", "HH:MM <IANA time zone>", or off; absent means 21:00 Europe/Moscow.
The review covers the time since the previous review, or one day when none is recorded.
Output: data/day-review/<day>/board.html links full.html beside it; numbers.json holds every figure;
data/day-review/notes.json keeps past advice and lessons; data/day-review/lessons.md lists lessons.
Overrides: FM_DAY_REVIEW_NOW epoch, FM_DAY_REVIEW_SESSION_ROOTS colon list, NM_HOME.
  Exit: 0 written, 1 not due or failed, 2 bad use
EOF
}
now_epoch() {
  printf '%s\n' "${FM_DAY_REVIEW_NOW:-$(date +%s)}"
}
schedule() {
  local line=""
  if [ ! -f "$TIME_FILE" ] || [ -L "$TIME_FILE" ]; then
    printf '%s\n' "$DEFAULT_SCHEDULE"
    return 0
  fi
  line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$TIME_FILE" 2>/dev/null | sed -n '1p')"
  case "$line" in
    off|disabled) printf 'off\n' ;;
    [0-2][0-9]:[0-5][0-9]) printf '%s %s\n' "$line" "${DEFAULT_SCHEDULE#* }" ;;
    [0-2][0-9]:[0-5][0-9]' '?*) printf '%s\n' "$line" ;;
    *) return 1 ;;
  esac
}
record_field() {
  local field="$1" first="" schema="" day="" until=""
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  IFS= read -r first < "$RECORD" 2>/dev/null || return 1
  read -r schema day until <<<"$first"
  [ "$schema" = "$RECORD_SCHEMA" ] || return 1
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  case "$field" in day) printf '%s\n' "$day" ;; until) printf '%s\n' "$until" ;; esac
}
record_stamp() {
  local day="$1" until="$2" tmp="" device=""
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device="$(fm_pr_file_device "$STATE")" || return 1
  tmp="$(umask 077; mktemp "$STATE/.fm-day-review.XXXXXX" 2>/dev/null)" || return 1
  printf '%s %s %s\n' "$RECORD_SCHEMA" "$day" "$until" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD"
}
# Prints "due <day> <since> <until>", waiting, off, or bad-config.
due_line() {
  local force_flag="$1" sched="" force_args=()
  [ "$force_flag" = --force ] && force_args=(--force)
  sched="$(schedule)" || { printf 'bad-config\n'; return 0; }
  [ "$sched" = off ] && { printf 'off\n'; return 0; }
  python3 -I "$PY" due --time "${sched%% *}" --zone "${sched#* }" --now "$(now_epoch)" \
    --last-day "$(record_field day 2>/dev/null || true)" \
    --last-until "$(record_field until 2>/dev/null || printf 0)" ${force_args[@]+"${force_args[@]}"}
}
report_bad_config() {
  local hash="" seen=""
  hash="$(fm_custom_check_sha256 "$TIME_FILE" 2>/dev/null || printf 'unreadable\n')"
  seen="$(cat "$BADCONFIG" 2>/dev/null || true)"
  [ "$seen" = "$hash" ] && return 0
  fm_cap_line "day-review: config/day-review is not \"HH:MM\", \"HH:MM <time zone>\", or off" "$MAX_LINE"
  (umask 077; printf '%s\n' "$hash" > "$BADCONFIG") 2>/dev/null || true
}
do_check() {
  # A parked supervisor cannot act on the wake; the next review still covers the time since the last one.
  [ -e "$STATE/.afk" ] && return 0
  case "$(due_line '')" in
    due\ *) fm_cap_line "day-review due: run bin/fm-day-review.sh run, then open the board it prints with lavish-axi" "$MAX_LINE" ;;
    bad-config) report_bad_config ;;
  esac
  return 0
}
collect_home() {
  local home="$1" since="$2" until="$3" root="" roots=() args=()
  if [ -n "${FM_DAY_REVIEW_SESSION_ROOTS:-}" ]; then
    IFS=: read -r -a roots <<<"$FM_DAY_REVIEW_SESSION_ROOTS"
  else
    roots=("$HOME/.pi/agent/sessions")
    [ -n "${PI_CODING_AGENT_DIR:-}" ] && roots+=("$PI_CODING_AGENT_DIR/sessions")
  fi
  for root in ${roots[@]+"${roots[@]}"}; do
    [ -d "$root" ] && args+=(--session-root "$root")
  done
  python3 -I "$PY" collect --home "$home" --bin "$SCRIPT_DIR" --since "$since" --until "$until" \
    --nm-db "${NM_HOME:-$HOME/.no-mistakes}/state.sqlite" ${args[@]+"${args[@]}"}
}
do_collect() {
  local since="" until=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 || { usage >&2; return 2; } ;;
      --until) until="${2:-}"; shift 2 || { usage >&2; return 2; } ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$since:$until" in *[!0-9:]*|:*|*:) usage >&2; return 2 ;; esac
  collect_home "$FM_HOME" "$since" "$until"
}
collect_secondmate() {
  local n="$1" since="$2" until="$3" out="$4" err="$5"
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$SECONDMATE_REGISTRY_ID" fm-day-review.sh collect \
      --since "$since" --until "$until" > "$out" 2>>"$err" < /dev/null || return 1
  else
    collect_home "$SECONDMATE_REGISTRY_HOME" "$since" "$until" > "$out" 2>>"$err" || return 1
  fi
  [ -s "$out" ]
}
do_run() {
  local force="" line="" day="" since="" until="" dir="" n=0 err="" zone="" inputs=() gaps=() gap_args=() gap=""
  case "${1:-}" in
    --force) force=--force ;;
    '') ;;
    *) usage >&2; return 2 ;;
  esac
  line="$(due_line "$force")"
  case "$line" in
    due\ *) read -r _ day since until <<<"$line" ;;
    off) echo "day review is off in config/day-review"; return 1 ;;
    bad-config) echo "error: config/day-review is not \"HH:MM\", \"HH:MM <time zone>\", or off" >&2; return 1 ;;
    *) echo "not due: the day review already ran today or its time has not come; use --force to run anyway"; return 1 ;;
  esac
  dir="$OUT/$day"
  mkdir -p "$dir/collect" || { echo "error: could not create $dir" >&2; return 1; }
  err="$dir/collect/errors.log"
  : > "$err"
  if collect_home "$FM_HOME" "$since" "$until" > "$dir/collect/0.json" 2>>"$err"; then
    inputs+=("$SELF_LABEL=$dir/collect/0.json")
  else
    gaps+=("The $SELF_LABEL home could not be read, so its work is missing.")
  fi
  if [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" 2>/dev/null || continue
      n=$((n + 1))
      if collect_secondmate "$n" "$since" "$until" "$dir/collect/$n.json" "$err"; then
        inputs+=("$SECONDMATE_REGISTRY_ID=$dir/collect/$n.json")
      else
        gaps+=("The $SECONDMATE_REGISTRY_ID second mate could not be read, so its work is missing.")
      fi
    done < "$REGISTRY"
  fi
  [ "${#inputs[@]}" -gt 0 ] || { echo "error: no home could be read; see $err" >&2; return 1; }
  for gap in ${gaps[@]+"${gaps[@]}"}; do gap_args+=(--gap "$gap"); done
  zone="$(schedule)"
  if ! python3 -I "$PY" merge --since "$since" --until "$until" --zone "${zone#* }" \
    --notes "$OUT/notes.json" ${gap_args[@]+"${gap_args[@]}"} "${inputs[@]}" > "$dir/.numbers.json" 2>>"$err"; then
    rm -f -- "$dir/.numbers.json"
    echo "error: could not build the numbers; see $err" >&2
    return 1
  fi
  mv -f -- "$dir/.numbers.json" "$dir/numbers.json" || return 1
  python3 -I "$PY" render "$dir/numbers.json" --out-dir "$dir" > /dev/null \
    || { echo "error: could not render the board" >&2; return 1; }
  if [ -z "$force" ]; then
    python3 -I "$PY" record "$dir/numbers.json" --notes "$OUT/notes.json" --lessons "$OUT/lessons.md" \
      || { echo "error: could not record the advice for tomorrow" >&2; return 1; }
    record_stamp "$day" "$until" || { echo "error: could not stamp $RECORD" >&2; return 1; }
  fi
  printf 'board: %s\nfull: %s\n' "$dir/board.html" "$dir/full.html"
}
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-day-review.sh.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-day-review.sh") check"
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
  tmp="$(umask 077; mktemp "$STATE/.fm-day-review.XXXXXX" 2>/dev/null)" || return 1
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
  collect) shift; do_collect "$@" ;;
  arm) do_arm ;;
  disarm) do_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
