#!/usr/bin/env bash
# Browser-suite workers: always heavy, and their starts are staggered.
# docs/configuration.md "Browser suites" is the operator reference.
#
# Declaration: config/browser-suites in the local root Firstmate home, one
# project name per line plus an optional `@stagger-minutes <minutes>` line.
# A brief also marks its task with a line that is exactly `Browser suite: yes`.
#
# Requires bin/fm-wake-lib.sh (root home, locks) to be sourced first.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_BROWSER_SUITE_DEFER_EXIT=75

fm_browser_suite_config() {  # <config-dir>
  local line lineno=0 value
  FM_BROWSER_SUITE_FILE=${1:-}/browser-suites
  FM_BROWSER_SUITE_PROJECTS=()
  FM_BROWSER_SUITE_STAGGER_SECS=0
  FM_BROWSER_SUITE_ERROR=
  [ -n "${1:-}" ] || return 0
  if [ ! -e "$FM_BROWSER_SUITE_FILE" ] && [ ! -L "$FM_BROWSER_SUITE_FILE" ]; then return 0; fi
  if [ ! -f "$FM_BROWSER_SUITE_FILE" ] || [ ! -r "$FM_BROWSER_SUITE_FILE" ]; then
    FM_BROWSER_SUITE_ERROR="$FM_BROWSER_SUITE_FILE is not a readable regular file"
    return 1
  fi
  local stagger_seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '@stagger-minutes '*)
        value=${line#* }
        case "$value" in
          '' | *[!0-9]* | 0*)
            FM_BROWSER_SUITE_ERROR="$FM_BROWSER_SUITE_FILE line $lineno gives @stagger-minutes a value that is not a positive integer"
            return 1
            ;;
        esac
        if [ "${#value}" -gt 4 ]; then
          FM_BROWSER_SUITE_ERROR="$FM_BROWSER_SUITE_FILE line $lineno gives @stagger-minutes more than four digits"
          return 1
        fi
        if [ "$stagger_seen" = 1 ]; then
          FM_BROWSER_SUITE_ERROR="$FM_BROWSER_SUITE_FILE line $lineno names @stagger-minutes a second time"
          return 1
        fi
        stagger_seen=1
        FM_BROWSER_SUITE_STAGGER_SECS=$((value * 60))
        ;;
      '@'*)
        FM_BROWSER_SUITE_ERROR="$FM_BROWSER_SUITE_FILE line $lineno names an unknown setting"
        return 1
        ;;
      *) FM_BROWSER_SUITE_PROJECTS+=("$line") ;;
    esac
  done < "$FM_BROWSER_SUITE_FILE"
}

# Call after fm_browser_suite_config.
fm_browser_suite_task() {  # <project-name> <brief>
  local name=$1 brief=$2 listed
  for listed in ${FM_BROWSER_SUITE_PROJECTS[@]+"${FM_BROWSER_SUITE_PROJECTS[@]}"}; do
    [ "$listed" = "$name" ] && return 0
  done
  [ -f "$brief" ] && grep -Eq '^[[:space:]]*Browser suite: yes[[:space:]]*$' "$brief"
}

# Every home on the machine shares one stamp, so the gap spans secondmate homes.
fm_browser_suite_stamp_file() {  # <home>
  local root
  root=$(fm_firstmate_root_home "$1") || return 1
  printf '%s/state/browser-suite-last-start\n' "$root"
}

# Admits a start and records it as the latest, or sets FM_BROWSER_SUITE_WAIT_SECS
# and returns 1 while the previous start is inside the gap. Returns 2 when the
# stamp cannot be read or written.
fm_browser_suite_stagger_admit() {  # <stamp-file> <gap-seconds>
  local stamp=$1 gap=$2 lock=$1.lock now last rc=0
  FM_BROWSER_SUITE_WAIT_SECS=0
  FM_BROWSER_SUITE_ERROR=
  [ "$gap" -gt 0 ] || return 0
  now=${FM_BROWSER_SUITE_MOCK_NOW:-$(date -u +%s)}
  mkdir -p "$(dirname "$stamp")" 2>/dev/null || {
    FM_BROWSER_SUITE_ERROR="the directory of $stamp cannot be created"
    return 2
  }
  fm_lock_acquire_wait "$lock" || {
    FM_BROWSER_SUITE_ERROR="the lock $lock cannot be taken"
    return 2
  }
  last=0
  if [ -e "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null) || last=
    case "$last" in
      '' | *[!0-9]*)
        FM_BROWSER_SUITE_ERROR="$stamp does not hold a start time"
        rc=2
        ;;
    esac
  fi
  if [ "$rc" = 0 ] && [ "$now" -lt "$((last + gap))" ]; then
    FM_BROWSER_SUITE_WAIT_SECS=$((last + gap - now))
    rc=1
  fi
  if [ "$rc" = 0 ] && ! { printf '%s\n' "$now" > "$stamp.tmp.$$" && mv -f "$stamp.tmp.$$" "$stamp"; } 2>/dev/null; then
    rm -f "$stamp.tmp.$$"
    FM_BROWSER_SUITE_ERROR="$stamp cannot be written"
    rc=2
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}
