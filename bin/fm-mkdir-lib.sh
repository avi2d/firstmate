#!/usr/bin/env bash
# Exclusive creation of a directory used as a lock or claim.
# This file is sourced by scripts and has no side effects on source.

# mkdir alone cannot decide ownership: uutils coreutils mkdir, which Ubuntu
# installs as /usr/bin/mkdir, reports success to a racing caller whose
# directory another process created a moment earlier. The owner is whichever
# caller then creates this marker inside it, because a noclobber redirect is
# bash's own O_EXCL open with no coreutils program in between.
FM_MKDIR_OWNER_MARKER=.fm-mkdir-owner

fm_mkdir_exclusive() {
  local path=$1
  mkdir -- "$path" || return 1
  if ! (set -C; : > "$path/$FM_MKDIR_OWNER_MARKER") 2>/dev/null; then
    # rmdir succeeds only while no racer holds the marker.
    rmdir -- "$path" 2>/dev/null
    return 1
  fi
}

# The marker stays until release: a racer can still sit between its mkdir and
# its marker open, and must find the marker taken.
fm_mkdir_exclusive_release() { # <path>...
  local path markers=()
  [ "$#" -gt 0 ] || return 0
  for path in "$@"; do markers+=("$path/$FM_MKDIR_OWNER_MARKER"); done
  rm -f -- "${markers[@]}" || return 1
  rmdir -- "$@"
}
