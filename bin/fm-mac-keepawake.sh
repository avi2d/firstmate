#!/usr/bin/env bash
# caffeinate -w dies with the session, so no daemon holds this.
set -u

KM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$KM_DIR/.." && pwd)}"
KM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$KM_ROOT}}"
KM_STATE="${FM_STATE_OVERRIDE:-$KM_HOME/state}"
KM_CAFFEINATE="${FM_CAFFEINATE_BIN:-caffeinate}"
KM_PMSET="${FM_PMSET_BIN:-pmset}"

km_usage() {
  printf "%s\n" "usage: fm-mac-keepawake.sh sync [--state <dir>] [--pid <pid>]" "       fm-mac-keepawake.sh release [--state <dir>]" "       fm-mac-keepawake.sh status [--state <dir>]" "       fm-mac-keepawake.sh slept [--state <dir>] [--log-file <path>]";
}

km_uname() {
  if [ -n "${FM_MAC_KEEPAWAKE_UNAME:-}" ]; then
    printf "%s\n" "$FM_MAC_KEEPAWAKE_UNAME"
  else
    uname
  fi
}

km_state_arg() {
  local state="$KM_STATE"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  printf "%s\n" "$state"
}

km_pid_arg() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) printf "%s\n" "${2:-}"; return 0 ;;
      *) shift ;;
    esac
  done
  return 1
}

km_away_present() {
  local state=$1
  [ -e "$state/.afk" ] && return 0
  [ -e "$state/.afk-contract" ] || return 1
  ! grep -q '^mode: quiet' "$state/.afk-contract" 2>/dev/null
}

km_work_in_flight() {
  local state=$1 meta
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || return 1
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then
      continue
    fi
    return 0
  done
  return 1
}

km_pid_alive() {
  case "${1:-}" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

km_session_pid() {
  local state=$1 explicit=${2:-} pid=""
  if [ -n "$explicit" ]; then
    printf "%s\n" "$explicit"
    return 0
  fi
  if [ -n "${FM_MAC_KEEPAWAKE_PID:-}" ]; then
    printf "%s\n" "$FM_MAC_KEEPAWAKE_PID"
    return 0
  fi
  pid=$(sed -n '1p' "$state/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf "%s\n" "$pid"
}

km_recorded() {
  local state=$1 pid target args
  pid=$(cat "$state/.mac-keepawake.pid" 2>/dev/null || true)
  target=$(cat "$state/.mac-keepawake.target" 2>/dev/null || true)
  km_pid_alive "$pid" || return 1
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  case "$args" in *caffeinate*) ;; *) return 1 ;; esac
  printf '%s %s\n' "$pid" "$target"
}

km_stop_recorded() {
  local state=$1 pid
  pid=$(cat "$state/.mac-keepawake.pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
  rm -f "$state/.mac-keepawake.pid" "$state/.mac-keepawake.target" 2>/dev/null || true
}

km_cmd_sync() {
  local state pid="" rec="" target="" fresh=""
  state=$(km_state_arg "$@")
  pid=$(km_pid_arg "$@" || true)
  [ "$(km_uname)" = Darwin ] || return 0
  mkdir -p "$state" 2>/dev/null || return 0
  if ! km_away_present "$state" && ! km_work_in_flight "$state"; then
    km_stop_recorded "$state"
    return 0
  fi
  pid=$(km_session_pid "$state" "$pid" || true)
  [ -n "$pid" ] || return 0
  if ! km_pid_alive "$pid"; then
    rec=$(km_recorded "$state" || true)
    [ -n "$rec" ] && km_stop_recorded "$state"
    return 0
  fi
  rec=$(km_recorded "$state" || true)
  if [ -n "$rec" ]; then
    target=${rec#* }
    [ "$target" = "$pid" ] && return 0
  fi
  km_stop_recorded "$state"
  "$KM_CAFFEINATE" -s -i -w "$pid" >/dev/null 2>&1 &
  fresh=$!
  km_pid_alive "$fresh" || return 0
  printf '%s\n' "$fresh" > "$state/.mac-keepawake.pid" || true
  printf '%s\n' "$pid" > "$state/.mac-keepawake.target" || true
}

km_cmd_release() {
  local state
  state=$(km_state_arg "$@")
  km_stop_recorded "$state"
}

km_cmd_status() {
  local state needed=0 held=0 rec=""
  state=$(km_state_arg "$@")
  if [ "$(km_uname)" != Darwin ]; then
    printf 'keepawake: off (not Darwin)\n'
    return 0
  fi
  (km_away_present "$state" || km_work_in_flight "$state") && needed=1
  rec=$(km_recorded "$state" || true)
  [ -n "$rec" ] && held=1
  printf 'keepawake: needed=%s held=%s %s\n' "$needed" "$held" "$rec"
}

km_beat_epoch() {
  local state=$1 beat
  if [ -n "${FM_MAC_KEEPAWAKE_BEAT_EPOCH:-}" ]; then
    printf "%s\n" "$FM_MAC_KEEPAWAKE_BEAT_EPOCH"
    return 0
  fi
  beat="$state/.last-watcher-beat"
  [ -e "$beat" ] || { printf '0\n'; return 0; }
  if [ "$(km_uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$beat" 2>/dev/null || printf '0\n'
  else
    stat -c %Y "$beat" 2>/dev/null || printf '0\n'
  fi
}

km_ts_epoch() {
  local ts=$1 epoch=""
  epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$ts" +%s 2>/dev/null) && { printf "%s\n" "$epoch"; return 0; }
  epoch=$(date -d "$ts" +%s 2>/dev/null) && { printf "%s\n" "$epoch"; return 0; }
  return 1
}

km_slept_scan() {
  local beat=$1 line ts epoch=""
  while IFS= read -r line; do
    case "$line" in *Entering\ Sleep*) ;; *) continue ;; esac
    ts=$(printf '%s' "$line" | cut -c1-25)
    case "$ts" in ????-??-??\ ??:??:??\ ?????) ;; *) [ "$beat" = 0 ] && return 0; continue ;; esac
    epoch=$(km_ts_epoch "$ts" || true)
    [ -n "$epoch" ] || { [ "$beat" = 0 ] && return 0; continue; }
    [ "$epoch" -ge "$beat" ] && return 0
  done
  return 1
}

km_cmd_slept() {
  local state="" log_file="" beat=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) state=${2:-}; shift 2 ;;
      --log-file) log_file=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$state" ] || state="$KM_STATE"
  [ "$(km_uname)" = Darwin ] || return 1
  [ -z "$log_file" ] && log_file=${FM_PMSET_LOG_FILE:-}
  beat=$(km_beat_epoch "$state")
  case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
  if [ -n "$log_file" ]; then
    [ -r "$log_file" ] || { echo "keepawake: cannot read log file $log_file" >&2; return 1; }
    km_slept_scan "$beat" < "$log_file"
    return
  fi
  "$KM_PMSET" -g log 2>/dev/null | tail -n 400 | { km_slept_scan "$beat"; }
}

km_main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { km_usage >&2; return 2; }
  shift
  case "$cmd" in
    sync) km_cmd_sync "$@" ;;
    release) km_cmd_release "$@" ;;
    status) km_cmd_status "$@" ;;
    slept) km_cmd_slept "$@" ;;
    -h|--help|help) km_usage ;;
    *) km_usage >&2; return 2 ;;
  esac
}

km_main "$@"
