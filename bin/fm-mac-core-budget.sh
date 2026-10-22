#!/usr/bin/env bash
# Paused Mac heavy starts: hold one per task id, release them when the budget clears.
# A holder line never holds a newline; hold refuses one rather than writing a split record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$SCRIPT_DIR/fm-mac-load-lib.sh"
# shellcheck source=bin/fm-core-budget-lib.sh
. "$SCRIPT_DIR/fm-core-budget-lib.sh"

BUDGET_HOME="${FM_HOME:-$FM_ROOT}"
BUDGET_CONFIG="${FM_CONFIG_OVERRIDE:-$BUDGET_HOME/config}"
BUDGET_STATE="${FM_STATE_OVERRIDE:-$BUDGET_HOME/state}"
WATCH_NAME=mac-core-budget

budget_usage_or_refuse() { # <samples-file>
  local file=$1 usage
  if ! fm_machine_core_budget_record "$file"; then
    echo "error: the core sample cannot be recorded at $file" >&2
    return 2
  fi
  if ! usage=$(fm_machine_core_budget_usage "$file"); then
    echo "error: the core sample log cannot be read (${FM_MACHINE_CORE_BUDGET_ERROR:-unknown})" >&2
    return 2
  fi
  printf '%s\n' "$usage"
}

budget_resolve() {
  BUDGET_CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$BUDGET_HOME" "$BUDGET_CONFIG") || {
    echo "error: could not resolve the root Firstmate home that declares the core budget" >&2
    return 2
  }
  if ! fm_mac_load_config "$BUDGET_CAPACITY_CONFIG"; then
    echo "error: the machine load declaration is unreadable ($FM_MAC_LOAD_ERROR)" >&2
    return 2
  fi
  BUDGET_SAMPLES=$(fm_machine_core_budget_samples_file "$BUDGET_HOME" "$BUDGET_STATE") || {
    echo "error: could not resolve the machine-shared core sample log" >&2
    return 2
  }
  BUDGET_HELD=$(fm_machine_core_budget_held_dir "$BUDGET_HOME" "$BUDGET_STATE") || {
    echo "error: could not resolve the machine-shared held-spawn directory" >&2
    return 2
  }
}

cmd_watch_name() { printf '%s\n' "$WATCH_NAME"; }

cmd_check() { # [--clear]
  local clear=0 usage held=0 f
  [ "${1:-}" != --clear ] || clear=1
  budget_resolve || return 2
  usage=$(budget_usage_or_refuse "$BUDGET_SAMPLES") || return 2
  if [ -d "$BUDGET_HELD" ]; then
    for f in "$BUDGET_HELD"/*; do
      [ -f "$f" ] || continue
      held=$((held + 1))
    done
  fi
  printf 'core-budget: %s core-hours in the trailing hour (budget %s), %s held\n' \
    "$usage" "$FM_MAC_CORE_BUDGET" "$held"
  if fm_machine_core_budget_over "$usage" "$FM_MAC_CORE_BUDGET"; then return 1; fi
  if [ "$clear" = 1 ] && [ "$held" = 0 ]; then return 1; fi
  return 0
}

cmd_hold() { # <id> <pwd> <home> -- <spawn-argv...>
  local id=${1:-} pwd=${2:-} home=${3:-} arg held_file
  shift 3 || { echo "usage: fm-mac-core-budget.sh hold <id> <pwd> <home> -- <spawn-argv...>" >&2; return 2; }
  [ "${1:-}" = -- ] || { echo "usage: fm-mac-core-budget.sh hold <id> <pwd> <home> -- <spawn-argv...>" >&2; return 2; }
  shift
  case "$id" in ''|*/*|*\.\.*) echo "error: refusing a holder id that is not one path segment: $id" >&2; return 2 ;; esac
  case "$pwd" in /*) ;; *) echo "error: refusing a holder working directory that is not absolute" >&2; return 2 ;; esac
  case "$home" in /*) ;; *) echo "error: refusing a holder home that is not absolute" >&2; return 2 ;; esac
  [ "$#" -ge 1 ] || { echo "error: refusing a holder with no spawn argv" >&2; return 2; }
  for arg in "$pwd" "$home" "$@"; do
    case "$arg" in *$'\n'*) echo "error: refusing a holder element holding a newline" >&2; return 2 ;; esac
  done
  budget_resolve || return 2
  mkdir -p "$BUDGET_HELD" || { echo "error: cannot create $BUDGET_HELD" >&2; return 2; }
  held_file="$BUDGET_HELD/$id"
  {
    printf '%s\n' "$pwd" "$home"
    printf '%s\n' "$@"
  } >"$held_file.tmp.$$" || { echo "error: cannot stage the holder for $id" >&2; return 2; }
  mv -f -- "$held_file.tmp.$$" "$held_file" || { echo "error: cannot publish the holder for $id" >&2; return 2; }
  printf 'held: %s (%s)\n' "$id" "$held_file"
}

cmd_release() {
  local lock rc
  budget_resolve || return 2
  lock="$BUDGET_SAMPLES.lock"
  if ! fm_lock_try_acquire "$lock"; then
    printf 'released: another release owns the retry\n'
    return 0
  fi
  cmd_release_locked
  rc=$?
  fm_lock_release "$lock"
  return $rc
}

cmd_release_locked() {
  local usage f id pwd home kept=0 released=0 failed=0 rc
  local -a argv
  budget_resolve || return 2
  if [ ! -d "$BUDGET_HELD" ]; then
    printf 'released: nothing held\n'
    return 0
  fi
  usage=$(budget_usage_or_refuse "$BUDGET_SAMPLES") || return 2
  if fm_machine_core_budget_over "$usage" "$FM_MAC_CORE_BUDGET"; then
    printf 'kept: budget still over at %s of %s core-hours\n' "$usage" "$FM_MAC_CORE_BUDGET"
    return 0
  fi
  for f in "$BUDGET_HELD"/*; do
    [ -f "$f" ] || continue
    id=$(basename "$f")
    holder_read_argv "$f" || { echo "kept $id: its holder cannot be read" >&2; kept=$((kept + 1)); continue; }
    if [ ! -d "$pwd" ]; then echo "kept $id: its working directory is gone" >&2; kept=$((kept + 1)); continue; fi
    if [ ! -d "$home" ]; then echo "kept $id: its home is gone" >&2; kept=$((kept + 1)); continue; fi
    rc=0
    (CDPATH='' cd -- "$pwd" && FM_HOME="$home" "$FM_ROOT/bin/fm-spawn.sh" "${argv[@]}") || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f -- "$f"
      released=$((released + 1))
      printf 'released: %s\n' "$id"
    elif [ "$rc" -eq "$FM_CORE_BUDGET_DEFER_EXIT" ]; then
      kept=$((kept + 1))
      printf 'kept: %s\n' "$id"
    else
      failed=$((failed + 1))
      echo "kept $id: its retry exited $rc" >&2
    fi
  done
  printf 'released: %s released, %s kept, %s failed\n' "$released" "$kept" "$failed"
  [ "$failed" = 0 ]
}

holder_read_argv() { # <holder-file>; sets pwd, home globals above plus argv
  local file=$1 line n=0
  argv=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then pwd=$line
    elif [ "$n" -eq 2 ]; then home=$line
    else argv+=("$line"); fi
  done < "$file" || return 1
  [ "$n" -ge 3 ] || return 1
}

cmd_status() {
  local usage f
  budget_resolve || return 2
  usage=$(budget_usage_or_refuse "$BUDGET_SAMPLES") || return 2
  printf 'core-budget: %s core-hours in the trailing hour (budget %s)\n' "$usage" "$FM_MAC_CORE_BUDGET"
  if [ -d "$BUDGET_HELD" ]; then
    for f in "$BUDGET_HELD"/*; do
      [ -f "$f" ] || continue
      printf 'held: %s\n' "$(basename "$f")"
    done
  fi
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  hold) shift; cmd_hold "$@" ;;
  release) shift; [ "$#" -eq 0 ] || { echo "usage: fm-mac-core-budget.sh release" >&2; exit 2; }; cmd_release ;;
  status) shift; [ "$#" -eq 0 ] || { echo "usage: fm-mac-core-budget.sh status" >&2; exit 2; }; cmd_status ;;
  watch-name) shift; [ "$#" -eq 0 ] || { echo "usage: fm-mac-core-budget.sh watch-name" >&2; exit 2; }; cmd_watch_name ;;
  *) echo "usage: fm-mac-core-budget.sh check [--clear] | hold <id> <pwd> <home> -- <argv...> | release | status | watch-name" >&2; exit 2 ;;
esac
