#!/usr/bin/env bash
# fm-ready-capacity.sh - print the ready backlog items this machine can start now.
#
# Read-only: lists waiting work with room to run, reusing the spawn gate's own
# admission code, so a quiet fleet with a non-empty ready queue wakes its
# supervisor once instead of sitting idle until the next teardown. The watcher
# calls this on its absorbed-heartbeat path; the supervisor still decides and
# dispatches, and bin/fm-spawn.sh re-validates every gate at dispatch.
#
# Output: one task id per line, in ready order, for every ready item the spawn
# gates admit: the machine-wide load gates pass, and the item's project is
# under its declared per-project capacity, declares none, or is a secondmate,
# which never holds a worker place. A project the ready row names but no
# resolvable clone or holder record pins down counts no holders: no record
# names that project's path, so nothing provable holds a place.
# An empty report with status 0 means nothing dispatchable right now (no ready
# items, or the gates refuse them all, exactly as a dispatch attempt would).
# Status 2 with no report means the ready list itself could not be read, so
# the caller keeps its fired-set marker rather than mistaking an unreadable
# backlog for an empty one.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first - the same owners
# bin/fm-project-capacity-lib.sh names. No side effects on source.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-mac-load-lib.sh
. "$SCRIPT_DIR/fm-mac-load-lib.sh"

no_room() { exit 0; }

unreadable() {
  printf 'fm-ready-capacity: %s\n' "$*" >&2
  exit 2
}

# The ready queue this home dispatches from. Held and blocked items never
# appear: tasks-axi ready lists unblocked, unheld queued work only.
ready_out=$("$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>/dev/null) \
  || unreadable "the ready queue could not be read"

# Parse the ready[N]{columns}: rows beneath it, one id per row. Column order
# comes from the header, so a reordered listing still resolves; only fields
# past the last needed one may hold commas (the trailing title).
ready_ids=$(printf '%s\n' "$ready_out" | LC_ALL=C awk '
  /^ready\[[0-9]+\]\{/ {
    header = $0
    sub(/^ready\[[0-9]+\]\{/, "", header)
    sub(/\}:[[:space:]]*$/, "", header)
    n = split(header, cols, ",")
    for (i = 1; i <= n; i++) {
      if (cols[i] == "id") id_col = i
      else if (cols[i] == "kind") kind_col = i
      else if (cols[i] == "repo") repo_col = i
    }
    if (id_col == "" || repo_col == "") exit 1
    rows = 1
    next
  }
  rows && /^[[:space:]]/ {
    sub(/^[[:space:]]+/, "")
    # The row fields before the trailing title hold no commas.
    m = split($0, f, ",")
    if (m < repo_col) next
    kind = (kind_col == "" ? "task" : f[kind_col])
    print f[id_col] "\t" kind "\t" f[repo_col]
    next
  }
  { rows = 0 }
') || unreadable "the ready listing could not be parsed"
[ -n "$ready_ids" ] || no_room

# The spawn gate's own machine-wide admission, in its order: an unreadable
# declaration, an unreadable load average, or unreadable task records refuse
# a fresh start rather than guessing, so each refuses here too.
CAPACITY_CONFIG=$(fm_project_capacity_config_dir "$FM_HOME" "$CONFIG") \
  || no_room
if fm_mac_load_gate_active; then
  fm_mac_load_config "$CAPACITY_CONFIG" || no_room
  LOADAVG=$(fm_mac_loadavg_5min) || no_room
  fm_mac_load_high "$LOADAVG" && no_room
  fm_mac_heavy_count "$STATE" "" || no_room
  [ "$FM_MAC_HEAVY_COUNT" -lt "$FM_MAC_HEAVY_LIMIT" ] || no_room
fi
if fm_linux_load_gate_active "$CAPACITY_CONFIG"; then
  fm_linux_load_config "$CAPACITY_CONFIG" || no_room
  LOADAVG=$(fm_mac_loadavg_5min) || no_room
  fm_linux_load_high "$LOADAVG" && no_room
  fm_linux_heavy_count "$STATE" "" "$CAPACITY_CONFIG" || no_room
  [ "$FM_LINUX_HEAVY_COUNT" -lt "$FM_LINUX_HEAVY_LIMIT" ] || no_room
fi

# One admission verdict per distinct project, mirroring bin/fm-spawn.sh: the
# declaration is matched by directory name, holders by shared project lock.
# Secondmates never hold a worker place and skip this gate as they do there.
repo_admits() {  # <repo>; 0 when a fresh worker for it fits
  local repo=$1 name dir lock candidate holder project base
  case "$repo" in
    */*) name=${repo##*/} ;;
    *) name=$repo ;;
  esac
  fm_project_capacity_lookup "$CAPACITY_CONFIG" "$name" || return 1
  [ -n "$FM_PROJECT_CAPACITY" ] || return 0
  dir=
  candidate="$PROJECTS/$name"
  [ -d "$candidate" ] && dir=$candidate
  if [ -z "$dir" ]; then
    for holder in "$STATE"/*.meta; do
      [ -f "$holder" ] && [ ! -L "$holder" ] || continue
      project=$(fm_meta_get "$holder" project)
      [ -n "$project" ] || continue
      base=${project##*/}
      [ "$base" = "$name" ] && [ -d "$project" ] && { dir=$project; break; }
    done
  fi
  [ -n "$dir" ] || return 0
  lock=$(fm_treehouse_project_lock_path "$dir") || return 1
  fm_project_capacity_occupants "$lock" "$dir" "$STATE" "" || return 1
  [ "$FM_PROJECT_CAPACITY_OCCUPANTS" -lt "$FM_PROJECT_CAPACITY" ]
}

admitted_repos=
while IFS="$(printf '\t')" read -r id kind repo; do
  [ -n "$id" ] || continue
  case "$admitted_repos" in
    *"|$repo=1|"*) admit=1 ;;
    *"|$repo=0|"*) admit=0 ;;
    *)
      if [ "$kind" = secondmate ]; then
        admit=1
      elif repo_admits "$repo"; then
        admit=1
      else
        admit=0
      fi
      admitted_repos="$admitted_repos|$repo=$admit|"
      ;;
  esac
  [ "$admit" = 1 ] && printf '%s\n' "$id"
done <<EOF
$ready_ids
EOF
exit 0
