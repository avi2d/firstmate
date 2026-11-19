#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the execution-home readiness checks.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <route> [backend]
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_probe() { # <bin-dir> <route> [doctor-args...]
  local bin_dir=$1 id=$2 out rc
  shift 2
  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" </dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <route> [backend]
  local bin_dir=$1 id=$2 backend=${3:-any} rc
  local -a doctor_args=()
  case "$backend" in
    any) ;;
    herdr) doctor_args=(--backend herdr) ;;
    *) echo "error: unsupported remote backend '$backend'" >&2; return 1 ;;
  esac

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    # A remote still on the herdr-only doctor refuses the flag entirely; bare
    # is the same request there.
    fm_remote_readiness_probe "$bin_dir" "$id"
    rc=$?
  fi
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" --fix ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id" --fix
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id"
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}
