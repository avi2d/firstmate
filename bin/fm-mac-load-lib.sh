#!/usr/bin/env bash
# Refuse a heavy worker start while this Mac is saturated.
# The one-minute average dips fast, so the five-minute average judges a start.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_MAC_LOAD_DEFER_EXIT=75
FM_MAC_LOAD_LIMIT=10
FM_MAC_HEAVY_LIMIT=4

fm_machine_load_config() {  # <load-default> <heavy-default> <config-dir>
  FM_MACHINE_LOAD_LIMIT=$1
  FM_MACHINE_HEAVY_LIMIT=$2
  FM_MACHINE_LOAD_ERROR=
  local file=${3:-}/project-capacity line lineno=0 name value seen=
  [ -n "${3:-}" ] || return 0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_MACHINE_LOAD_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '@heavy-limit '*|'@load-limit '*)
        name=${line%% *}
        value=${line#* }
        case "$value" in
          '' | *[!0-9]* | 0*)
            FM_MACHINE_LOAD_ERROR="$file line $lineno gives $name a limit that is not a positive integer"
            return 1
            ;;
        esac
        if [ "${#value}" -gt 6 ]; then
          FM_MACHINE_LOAD_ERROR="$file line $lineno gives $name a limit longer than six digits"
          return 1
        fi
        case "$seen" in
          *"|$name|"*)
            FM_MACHINE_LOAD_ERROR="$file line $lineno names $name a second time"
            return 1
            ;;
        esac
        seen="$seen|$name|"
        if [ "$name" = '@heavy-limit' ]; then FM_MACHINE_HEAVY_LIMIT=$value
        else FM_MACHINE_LOAD_LIMIT=$value; fi
        ;;
      '@'*)
        FM_MACHINE_LOAD_ERROR="$file line $lineno names an unknown machine-wide setting"
        return 1
        ;;
    esac
  done < "$file"
}

fm_mac_load_config() {  # <config-dir>
  FM_MAC_LOAD_LIMIT=10
  FM_MAC_HEAVY_LIMIT=4
  FM_MAC_LOAD_ERROR=
  if ! fm_machine_load_config 10 4 "${1:-}"; then
    FM_MAC_LOAD_LIMIT=$FM_MACHINE_LOAD_LIMIT
    FM_MAC_HEAVY_LIMIT=$FM_MACHINE_HEAVY_LIMIT
    FM_MAC_LOAD_ERROR=$FM_MACHINE_LOAD_ERROR
    return 1
  fi
  FM_MAC_LOAD_LIMIT=$FM_MACHINE_LOAD_LIMIT
  FM_MAC_HEAVY_LIMIT=$FM_MACHINE_HEAVY_LIMIT
  return 0
}

fm_mac_load_gate_active() {
  [ "${FM_MAC_LOAD_GATE_FORCE:-0}" = 1 ] && return 0
  [ "$(uname -s)" = Darwin ]
}

fm_mac_loadavg_5min() {
  local raw
  if [ -n "${FM_MAC_LOAD_MOCK_5MIN:-}" ]; then
    printf '%s\n' "$FM_MAC_LOAD_MOCK_5MIN"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      raw=$(sysctl -n vm.loadavg 2>/dev/null) || return 1
      printf '%s\n' "$raw" | awk '{gsub(/[{}]/, ""); print $2}'
      ;;
    Linux)
      awk '{print $2}' /proc/loadavg 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
}

# Every ship or scout holds a place; the record this start replaces does not.
fm_mac_load_high() {  # <five-minute-average>
  awk -v avg="$1" -v limit="$FM_MAC_LOAD_LIMIT" 'BEGIN { exit !(avg + 0 >= limit + 0) }'
}

fm_mac_heavy_count() {  # <first-state> <own-id>
  local first=$1 self=$2 state meta kind id label
  FM_MAC_HEAVY_COUNT=0
  FM_MAC_HEAVY_IDS=
  FM_MAC_LOAD_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_MAC_LOAD_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_MAC_LOAD_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_MAC_LOAD_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_MAC_HEAVY_COUNT=$((FM_MAC_HEAVY_COUNT + 1))
      FM_MAC_HEAVY_IDS="${FM_MAC_HEAVY_IDS:+$FM_MAC_HEAVY_IDS, }$label"
    done
  done
  return 0
}

# The winbox load gate extends the Mac gate to a Linux host that two Firstmate
# homes share without a common local root. Each home lists the other in
# config/winbox-load-siblings, so a heavy start waits while the five-minute
# average is high or six heavy workers already run across both homes.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_WINBOX_LOAD_DEFER_EXIT=75
FM_WINBOX_LOAD_LIMIT=16
FM_WINBOX_HEAVY_LIMIT=6

fm_winbox_load_config() {  # <config-dir>
  FM_WINBOX_LOAD_LIMIT=16
  FM_WINBOX_HEAVY_LIMIT=6
  FM_WINBOX_LOAD_ERROR=
  if ! fm_machine_load_config 16 6 "${1:-}"; then
    FM_WINBOX_LOAD_LIMIT=$FM_MACHINE_LOAD_LIMIT
    FM_WINBOX_HEAVY_LIMIT=$FM_MACHINE_HEAVY_LIMIT
    FM_WINBOX_LOAD_ERROR=$FM_MACHINE_LOAD_ERROR
    return 1
  fi
  FM_WINBOX_LOAD_LIMIT=$FM_MACHINE_LOAD_LIMIT
  FM_WINBOX_HEAVY_LIMIT=$FM_MACHINE_HEAVY_LIMIT
  return 0
}

fm_winbox_load_gate_active() {  # [config-dir]
  [ "$(uname -s)" = Linux ] || return 1
  [ "${FM_WINBOX_LOAD_GATE_FORCE:-0}" = 1 ] && return 0
  [ -n "${1:-}" ] || return 1
  [ -e "$1/winbox-load-siblings" ] || [ -L "$1/winbox-load-siblings" ]
}

fm_winbox_load_high() {  # <five-minute-average>
  awk -v avg="$1" -v limit="$FM_WINBOX_LOAD_LIMIT" 'BEGIN { exit !(avg + 0 >= limit + 0) }'
}

# Every line of <config-dir>/winbox-load-siblings names one sibling Firstmate
# home by absolute path. A missing file lists no siblings, while an unreadable
# or malformed one refuses rather than undercounts.
fm_winbox_sibling_homes() {  # <config-dir>
  local file=${1:-}/winbox-load-siblings line
  FM_WINBOX_SIBLINGS=()
  FM_WINBOX_SIBLING_ERROR=
  [ -n "${1:-}" ] || return 0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    FM_WINBOX_SIBLING_ERROR="$file is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      /*) ;;
      *)
        FM_WINBOX_SIBLING_ERROR="$file names a home that is not an absolute path: $line"
        return 1
        ;;
    esac
    if [ ! -d "$line" ]; then
      FM_WINBOX_SIBLING_ERROR="$file names an unavailable home: $line"
      return 1
    fi
    FM_WINBOX_SIBLINGS+=("$line")
  done < "$file"
}

# Every ship or scout holds a place across the sibling homes; the record this
# start replaces does not.
fm_winbox_heavy_count() {  # <first-state> <own-id> <config-dir>
  local first=$1 self=$2 config=${3:-} state meta kind id label
  local saved_home sib sib_state known existing
  local -a all_states sib_states
  FM_WINBOX_HEAVY_COUNT=0
  FM_WINBOX_HEAVY_IDS=
  FM_WINBOX_LOAD_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_WINBOX_LOAD_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  all_states=("${FM_LOCAL_FIRSTMATE_STATES[@]}")
  if ! fm_winbox_sibling_homes "$config"; then
    FM_WINBOX_LOAD_ERROR=$FM_WINBOX_SIBLING_ERROR
    return 1
  fi
  for sib in ${FM_WINBOX_SIBLINGS[@]+"${FM_WINBOX_SIBLINGS[@]}"}; do
    sib=$(CDPATH='' cd -- "$sib" 2>/dev/null && pwd -P) || {
      FM_WINBOX_LOAD_ERROR="sibling Firstmate home is unavailable: $sib"
      return 1
    }
    saved_home=${FM_HOME:-}
    FM_HOME=$sib
    if ! fm_local_firstmate_state_dirs "$sib/state"; then
      FM_WINBOX_LOAD_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
      FM_HOME=$saved_home
      return 1
    fi
    sib_states=("${FM_LOCAL_FIRSTMATE_STATES[@]}")
    FM_HOME=$saved_home
    for sib_state in ${sib_states[@]+"${sib_states[@]}"}; do
      known=0
      for existing in ${all_states[@]+"${all_states[@]}"}; do
        if [ "$existing" = "$sib_state" ] || [ "$existing" -ef "$sib_state" ]; then
          known=1
        fi
      done
      [ "$known" = 1 ] || all_states+=("$sib_state")
    done
  done
  for state in ${all_states[@]+"${all_states[@]}"}; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_WINBOX_LOAD_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_WINBOX_LOAD_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_WINBOX_HEAVY_COUNT=$((FM_WINBOX_HEAVY_COUNT + 1))
      FM_WINBOX_HEAVY_IDS="${FM_WINBOX_HEAVY_IDS:+$FM_WINBOX_HEAVY_IDS, }$label"
    done
  done
  return 0
}
