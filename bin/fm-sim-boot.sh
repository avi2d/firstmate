#!/usr/bin/env bash
# fm-sim-boot.sh - the one machine-wide way to boot an iOS Simulator.
# A booted device is the mutex: boot refuses while another device is booted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$SCRIPT_DIR/fm-mac-load-lib.sh"
if ! fm_mac_load_config "${FM_MAC_LOAD_CONFIG_DIR:-}"; then
  echo "error: simctl boot refused: the machine load declaration is unreadable ($FM_MAC_LOAD_ERROR)" >&2
  exit 1
fi

XCRUN="${FM_SIM_BOOT_XCRUN:-xcrun}"
BOOT_DIR="${FM_SIM_BOOT_DIR:-$HOME/Library/Caches/firstmate/sim-boot}"

usage() {
  printf 'usage: fm-sim-boot.sh boot [--device UDID-or-name] [--wait SECS]\n'
  printf '       fm-sim-boot.sh boot --create NAME DEVICETYPE [RUNTIME] [--wait SECS]\n'
  printf '       fm-sim-boot.sh status | shutdown\n'
}

fail() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
gate_closed() { printf 'deferred: %s\n' "$1" >&2; exit "$FM_MAC_LOAD_DEFER_EXIT"; }

need_darwin() {
  [ "${FM_SIM_BOOT_FORCE:-0}" = 1 ] && return 0
  [ "$(uname -s)" = Darwin ] || fail "simulator boot runs on a Mac"
}

boot_dir() {
  mkdir -p "$BOOT_DIR" 2>/dev/null || fail "cannot write the boot gate $BOOT_DIR"
}

load_now() {
  local avg
  avg=$(fm_mac_loadavg_5min) || fail "cannot read the five-minute load average"
  printf '%s\n' "$avg"
}

devices_json() {
  "$XCRUN" simctl list devices -j 2>/dev/null || fail "simctl cannot list devices"
}

sim_devices() {
  devices_json | python3 "$SCRIPT_DIR/fm-sim-boot-devices.py"
}

booted_udids() { sim_devices | awk -F'\t' '$2 == "Booted" { print $1 }'; }

preferred_device() {
  local warm
  warm=$(sim_devices | awk -F'\t' '$2 == "Shutdown" && $3 == "yes" && $4 ~ /iPhone/ && $6 != "" { print $6 "\t" $5 "\t" $1 }' | sort -r | head -1 | cut -f3)
  if [ -n "$warm" ]; then printf '%s\n' "$warm"; return 0; fi
  sim_devices | awk -F'\t' '$2 == "Shutdown" && $3 == "yes" && $4 ~ /iPhone/ { print $5 "\t" $1 }' | sort -r | head -1 | cut -f2
}

resolve_device() {
  local sel=$1 match n
  [ -n "$sel" ] || { preferred_device; return; }
  match=$(sim_devices | awk -F'\t' -v s="$sel" '$1 == s || $4 == s { print $1 }')
  [ -n "$match" ] || fail "no simulator matches $sel; pick an existing device from status" 2
  n=$(printf '%s\n' "$match" | wc -l)
  [ "$n" -eq 1 ] || fail "several simulators match $sel; name one UDID" 2
  printf '%s\n' "$match"
}

device_state() {
  sim_devices | awk -F'\t' -v u="$1" '$1 == u { print $2; exit }'
}

device_last_used() {
  sim_devices | awk -F'\t' -v u="$1" '$1 == u { print $6; exit }'
}

cmd_status() {
  local avg booted
  need_darwin
  avg=$(load_now)
  printf 'five-minute load average is %s (limit %s)\n' "$avg" "$FM_MAC_LOAD_LIMIT"
  booted=$(booted_udids)
  if [ -z "$booted" ]; then printf 'booted simulators: none\n';
  else printf 'booted simulators:\n%s\n' "$booted"; fi
}

cmd_shutdown() {
  need_darwin
  "$XCRUN" simctl shutdown all 2>/dev/null || fail "simctl cannot shut devices down"
  rm -f "$BOOT_DIR/holder"
  printf 'simulators shut down\n'
}

cmd_boot() {
  local selector="" wait_secs=0 create="" name="" dtype="" runtime="" deadline udid state avg booted
  while [ $# -gt 0 ]; do
    case "$1" in
      --device) selector=${2:-}; shift 2 ;;
      --device=*) selector=${1#--device=}; shift ;;
      --wait) wait_secs=${2:-0}; shift 2 ;;
      --wait=*) wait_secs=${1#--wait=}; shift ;;
      --create)
        create=1; [ $# -ge 3 ] || fail "--create takes NAME DEVICETYPE [RUNTIME]"
        name=$2; dtype=$3; runtime=; shift 3
        case "${1:-}" in -*) ;; "") ;; *) runtime=$1; shift ;; esac
        ;;
      -h|--help) usage; return 0 ;;
      *) fail "unknown boot argument $1" ;;
    esac
  done
  need_darwin
  boot_dir
  case "$wait_secs" in ''|*[!0-9]*) fail "--wait takes seconds" ;; esac
  deadline=$((SECONDS + wait_secs))
  while :; do
    if mkdir "$BOOT_DIR/booting.lock.d" 2>/dev/null; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || gate_closed "another boot is already starting; wait for it"
    sleep 5
  done
  trap 'rmdir "$BOOT_DIR/booting.lock.d" 2>/dev/null || true' EXIT
  while :; do
    avg=$(load_now)
    if fm_mac_load_high "$avg"; then
      [ "$SECONDS" -lt "$deadline" ] || gate_closed "five-minute load average is $avg (limit $FM_MAC_LOAD_LIMIT); no simulator boots now"
      sleep 5; continue
    fi
    if [ -n "$create" ]; then
      booted=$(booted_udids)
      if [ -n "$booted" ]; then
        [ "$SECONDS" -lt "$deadline" ] || gate_closed "a simulator is already booted ($booted); use it instead of creating one"
        sleep 5; continue
      fi
      if [ -n "$runtime" ]; then udid=$("$XCRUN" simctl create "$name" "$dtype" "$runtime" 2>/dev/null);
      else udid=$("$XCRUN" simctl create "$name" "$dtype" 2>/dev/null); fi
      [ -n "$udid" ] || fail "simctl cannot create $name"
    else
      udid=$(resolve_device "$selector") || exit "$?"
      [ -n "$udid" ] || fail "no existing simulator can boot; create one explicitly with --create" 2
    fi
    if [ -n "${create:-}" ]; then state=Shutdown
    else state=$(device_state "$udid") || exit "$?"; fi
    if [ "$state" = Booted ]; then printf '%s already booted\n' "$udid"; return 0; fi
    [ "$state" = Shutdown ] || fail "simulator $udid is $state, not Shutdown"
    booted=$(booted_udids)
    if [ -n "$booted" ]; then
      [ "$SECONDS" -lt "$deadline" ] || gate_closed "a simulator is already booted ($booted); one boots at a time"
      sleep 5; continue
    fi
    [ -n "$(device_last_used "$udid")" ] || printf 'note: %s never booted; its first boot compiles and takes minutes\n' "$udid" >&2
    "$XCRUN" simctl boot "$udid" >/dev/null 2>&1 || fail "simctl cannot boot $udid"
    printf '%s\t%s\n' "$udid" "$$" > "$BOOT_DIR/holder"
    printf '%s booted\n' "$udid"
    return 0
  done
}

case "${1:-}" in
  boot) shift; cmd_boot "$@" ;;
  status) cmd_status ;;
  shutdown) shift; cmd_shutdown ;;
  ''|-h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
