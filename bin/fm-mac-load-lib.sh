#!/usr/bin/env bash
# Refuse a heavy worker start while this Mac is saturated.
# The one-minute average dips fast, so the five-minute average judges a start.

# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_MAC_LOAD_DEFER_EXIT=75
FM_MAC_LOAD_LIMIT=10
FM_MAC_HEAVY_LIMIT=4

fm_mac_load_config() {  # <config-dir>
  FM_MAC_LOAD_LIMIT=10
  FM_MAC_HEAVY_LIMIT=4
  FM_MAC_LOAD_ERROR=
  local file=${1:-}/project-capacity line lineno=0 name value seen=
  [ -n "${1:-}" ] || return 0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_MAC_LOAD_ERROR="$file is not a readable regular file"
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
            FM_MAC_LOAD_ERROR="$file line $lineno gives $name a limit that is not a positive integer"
            return 1
            ;;
        esac
        if [ "${#value}" -gt 6 ]; then
          FM_MAC_LOAD_ERROR="$file line $lineno gives $name a limit longer than six digits"
          return 1
        fi
        case "$seen" in
          *"|$name|"*)
            FM_MAC_LOAD_ERROR="$file line $lineno names $name a second time"
            return 1
            ;;
        esac
        seen="$seen|$name|"
        if [ "$name" = '@heavy-limit' ]; then FM_MAC_HEAVY_LIMIT=$value
        else FM_MAC_LOAD_LIMIT=$value; fi
        ;;
      '@'*)
        FM_MAC_LOAD_ERROR="$file line $lineno names an unknown machine-wide setting"
        return 1
        ;;
    esac
  done < "$file"
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
      printf '%s\n' "$raw" | awk '{gsub(/[{}]/, ""); print $3}'
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
