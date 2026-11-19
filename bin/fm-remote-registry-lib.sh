#!/usr/bin/env bash

FM_REMOTE_REGISTRY_LINE=
FM_REMOTE_REGISTRY_ERROR=

fm_remote_registry_error() { printf '%s\n' "$FM_REMOTE_REGISTRY_ERROR"; }

fm_remote_registry_lock_path() { printf '%s/.remote-registry.lock\n' "$1"; }

fm_remote_registry_parse_line() {
  local line=$1
  local remote_re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*(session:[[:space:]]*([^;]*);[[:space:]]*)?scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  [[ "$line" =~ $remote_re ]] || return 1
  FM_REMOTE_REGISTRY_ID=${BASH_REMATCH[1]}
  FM_REMOTE_REGISTRY_HOST=${BASH_REMATCH[3]}
  FM_REMOTE_REGISTRY_ROOT=${BASH_REMATCH[4]}
  FM_REMOTE_REGISTRY_HOME=${BASH_REMATCH[5]}
  FM_REMOTE_REGISTRY_SESSION=${BASH_REMATCH[7]:-}
  FM_REMOTE_REGISTRY_SESSION=${FM_REMOTE_REGISTRY_SESSION#"${FM_REMOTE_REGISTRY_SESSION%%[![:space:]]*}"}
  FM_REMOTE_REGISTRY_SESSION=${FM_REMOTE_REGISTRY_SESSION%"${FM_REMOTE_REGISTRY_SESSION##*[![:space:]]}"}
  FM_REMOTE_REGISTRY_SCOPE=${BASH_REMATCH[8]}
  FM_REMOTE_REGISTRY_PROJECTS=${BASH_REMATCH[9]}
  [ -n "$FM_REMOTE_REGISTRY_HOME" ] && [ -n "$FM_REMOTE_REGISTRY_SCOPE" ] || return 1
  [ -n "$FM_REMOTE_REGISTRY_HOST" ] && [ -n "$FM_REMOTE_REGISTRY_ROOT" ] || return 1
  FM_REMOTE_REGISTRY_SESSION=${FM_REMOTE_REGISTRY_SESSION:-fm-remote}
  case "$FM_REMOTE_REGISTRY_SESSION" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

fm_remote_registry_line_for_id() {
  local reg=$1 id=$2 line count=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "- $id" ] || case "$line" in "- $id "*) ;; *) continue ;; esac
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    FM_REMOTE_REGISTRY_LINE=$line
  done < "$reg"
  [ "$count" -eq 1 ] || return 1
  fm_remote_registry_parse_line "$FM_REMOTE_REGISTRY_LINE"
}

fm_remote_registry_field() {
  local reg=$1 id=$2 key=$3
  fm_remote_registry_line_for_id "$reg" "$id" || return 1
  case "$key" in
    host) printf '%s\n' "$FM_REMOTE_REGISTRY_HOST" ;;
    root) printf '%s\n' "$FM_REMOTE_REGISTRY_ROOT" ;;
    home) printf '%s\n' "$FM_REMOTE_REGISTRY_HOME" ;;
    session) printf '%s\n' "${FM_REMOTE_REGISTRY_SESSION:-fm-remote}" ;;
    scope) printf '%s\n' "$FM_REMOTE_REGISTRY_SCOPE" ;;
    projects) printf '%s\n' "$FM_REMOTE_REGISTRY_PROJECTS" ;;
    *) return 1 ;;
  esac
}

fm_remote_registry_validate_bindings() {
  local reg=$1 expected_id=${2:-} expected_home=${3:-}
  local tmp snapshot bindings line id host root home home_key duplicate_homes duplicate_ids overlaps expected_home_key
  local matched_host='' matched_home=''
  FM_REMOTE_REGISTRY_ERROR=
  case "$expected_id" in *[!A-Za-z0-9._-]*) FM_REMOTE_REGISTRY_ERROR="invalid route id: $expected_id"; return 1 ;; esac
  if [ ! -f "$reg" ] || [ -L "$reg" ]; then
    FM_REMOTE_REGISTRY_ERROR="execution-home registry is unavailable or unsafe: $reg"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-registry.XXXXXX") || {
    FM_REMOTE_REGISTRY_ERROR="could not create execution-home registry validation state"
    return 1
  }
  snapshot="$tmp/registry"
  bindings="$tmp/bindings"
  if ! cat "$reg" > "$snapshot" 2>/dev/null || ! : > "$bindings"; then
    rm -rf -- "$tmp"
    FM_REMOTE_REGISTRY_ERROR="execution-home registry is unavailable or unsafe: $reg"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        if ! fm_remote_registry_parse_line "$line"; then
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="malformed execution-home registry entry: $line"
          return 1
        fi
        id=$FM_REMOTE_REGISTRY_ID
        host=$FM_REMOTE_REGISTRY_HOST
        root=$FM_REMOTE_REGISTRY_ROOT
        home=$FM_REMOTE_REGISTRY_HOME
        case "$home" in
          /*) ;;
          *)
            rm -rf -- "$tmp"
            FM_REMOTE_REGISTRY_ERROR="unsafe non-absolute execution home for $id: $home"
            return 1
            ;;
        esac
        case "$home$host$root" in
          *$'\t'*|*$'\n'*|*$'\r'*)
            rm -rf -- "$tmp"
            FM_REMOTE_REGISTRY_ERROR="unsafe execution-home route for $id"
            return 1
            ;;
        esac
        case "$host" in ''|-*|*[!A-Za-z0-9._-]*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="unsafe SSH host alias for $id: $host"
          return 1
          ;;
        esac
        case "$root" in /*) ;; *)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="unsafe non-absolute remote root for $id: $root"
          return 1
          ;;
        esac
        case "/$root/" in */../*|*/./*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="remote code root contains traversal components for $id: $root"
          return 1
          ;;
        esac
        case "/$home/" in */../*|*/./*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="remote home contains traversal components for $id: $home"
          return 1
          ;;
        esac
        case "$root$home" in *'//'*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="remote route contains an empty path component for $id"
          return 1
          ;;
        esac
        if [ "$root" = "$home" ]; then
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="overlapping remote root and home for $id: $root"
          return 1
        fi
        case "$home/" in "$root/"*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="remote home for $id is inside its code root: $home"
          return 1
          ;;
        esac
        case "$root/" in "$home/"*)
          rm -rf -- "$tmp"
          FM_REMOTE_REGISTRY_ERROR="remote code root for $id is inside its home: $root"
          return 1
          ;;
        esac
        home_key="ssh:$host:$home"
        printf '%s\t%s\n' "$home_key" "$id" >> "$bindings"
        if [ -n "$expected_id" ] && [ "$id" = "$expected_id" ]; then
          matched_host=$host
          matched_home=$home
        fi
        ;;
    esac
  done < "$snapshot"
  duplicate_homes=$(awk -F '\t' '
    {
      if ($1 in owner) {
        print $1 ": " owner[$1] ", " $2
        bad=1
      } else {
        owner[$1]=$2
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    FM_REMOTE_REGISTRY_ERROR="duplicate execution home assignment: $duplicate_homes"
    return 1
  }
  duplicate_ids=$(awk -F '\t' '
    {
      if ($2 in home) {
        print $2 ": " home[$2] ", " $1
        bad=1
      } else {
        home[$2]=$1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    FM_REMOTE_REGISTRY_ERROR="duplicate route id assignment: $duplicate_ids"
    return 1
  }
  overlaps=$(awk -F '\t' '
    function ancestor(a, b) { return a != b && index(b, a "/") == 1 }
    {
      for (i = 1; i <= count; i++) {
        if (ancestor($1, path[i])) {
          print $1 " (" $2 ") contains " path[i] " (" id[i] ")"
          bad=1
        } else if (ancestor(path[i], $1)) {
          print path[i] " (" id[i] ") contains " $1 " (" $2 ")"
          bad=1
        }
      }
      count++
      path[count]=$1
      id[count]=$2
    }
    END { exit bad ? 1 : 0 }
  ' "$bindings" 2>/dev/null) || {
    rm -rf -- "$tmp"
    FM_REMOTE_REGISTRY_ERROR="overlapping execution home assignment: $overlaps"
    return 1
  }
  rm -rf -- "$tmp"
  if [ -n "$expected_id" ] && [ -z "$matched_home" ]; then
    FM_REMOTE_REGISTRY_ERROR="no registry binding for route $expected_id"
    return 1
  fi
  if [ -n "$expected_home" ]; then
    expected_home_key="ssh:$matched_host:$expected_home"
    if [ -z "$expected_home_key" ] || [ "$expected_home_key" != "ssh:$matched_host:$matched_home" ]; then
      FM_REMOTE_REGISTRY_ERROR="route $expected_id is registered at $matched_home, not $expected_home"
      return 1
    fi
  fi
  return 0
}
