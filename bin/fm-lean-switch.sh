#!/usr/bin/env bash
set -eu

usage() {
  cat <<'EOF'
Usage: fm-lean-switch.sh counts <board-dir>
       fm-lean-switch.sh seed-home <old-home> <lean-home> <board-dir>
       fm-lean-switch.sh seed-exec <old-exec-home> <lean-exec-home>
       fm-lean-switch.sh handover <old-home> <lean-home>

Copy what a lean home keeps from an old Firstmate home.
Every command only reads the old side and writes only under the lean side.
docs/lean-switch.md is the runbook that orders these commands.

counts     Print a Backlog.md board's tasks by status, its drafts and its archive.
seed-home  Fill the lean home's empty data/, config/ and projects/.
           Copy the memory files, the board as data/backlog, every task folder
           a ticket names, the kept config files and the project symlinks.
           Write config/backlog-backend as backlog-md.
           Refuse when the copied board counts differ from the source board.
seed-exec  Copy the kept config files of an old execution home into a lean
           execution home that fm-remote-home-seed.sh --exec already seeded.
handover   Park every In Flight ticket of the lean board as a queued hold that
           names the old worker's branch and worktree.
           Refuse, changing nothing, while an old worker record has no
           In Flight ticket to carry it.

Credential files are left behind by name and never opened.
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

HANDOVER_PREFIX='handed over at the lean switch'

physical_dir() {
  [ -d "$1" ] || die "$1: not a directory"
  (cd "$1" && pwd -P)
}

count_files() {
  find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

field_counts() {
  local dir=$1 field=$2
  if [ "$(count_files "$dir")" -eq 0 ]; then
    printf 'queued=0 waiting=0 in_flight=0 done=0 other=0\n'
    return
  fi
  find "$dir" -maxdepth 1 -type f -name '*.md' -exec awk -v field="$field" '
    FNR == 1 { files++; seen = 0 }
    !seen && index($0, field ":") == 1 {
      value = substr($0, length(field) + 2)
      gsub(/^[ \t"]+|[ \t"]+$/, "", value)
      count[value]++
      seen = 1
    }
    END {
      known = count["Queued"] + count["Waiting"] + count["In Flight"] + count["Done"]
      printf "queued=%d waiting=%d in_flight=%d done=%d other=%d\n",
        count["Queued"], count["Waiting"], count["In Flight"], count["Done"], files - known
    }' {} +
}

board_counts() {
  local board=$1
  [ -f "$board/config.yml" ] && [ -d "$board/tasks" ] || die "$board: not a Backlog.md board directory"
  printf 'tasks: %s\n' "$(field_counts "$board/tasks" status)"
  printf 'drafts: %s %s\n' "$(count_files "$board/drafts")" "$(field_counts "$board/drafts" board_status)"
  printf 'archive: tasks=%s drafts=%s\n' "$(count_files "$board/archive/tasks")" "$(count_files "$board/archive/drafts")"
}

require_empty_or_absent() {
  [ ! -L "$1" ] || die "$1: is a symlink"
  [ ! -e "$1" ] || [ -z "$(ls -A "$1")" ] || die "$1: already has content; seed only an empty folder"
}

copy_link_or_file() {
  if [ -L "$1" ]; then
    ln -s "$(readlink "$1")" "$2"
  else
    cp -p "$1" "$2"
  fi
}

config_class() {
  case "$1" in
    claude-accounts|claude-accounts.*|agent-sandbox-claude-token|bws-typesafe-secret-id)
      echo 'credential: left behind unopened; recreate by hand' ;;
    firstmate-role)
      echo 'by hand: a home never grants itself a role' ;;
    herdr-session)
      echo 'left behind: the lean home names its own session' ;;
    backlog-backend)
      echo 'converted' ;;
    daily-session-reset)
      echo 'left behind: lean has no daily reset' ;;
    agent-sandbox|agent-sandbox.off|backend|brief-include.md|calm|crew-dispatch.json|fleet-ledger|\
    fork-upstream.json|fork-upstream.json.off|no-local-tests|practice-drift.json|project-capacity|\
    project-tiers|security-paths|startup-memory-budget|supervision-branch-effort|\
    supervision-branch-model|workflow-owners)
      echo 'copy' ;;
    *)
      echo 'unclassified: left behind, decide by hand' ;;
  esac
}

task_folder_ids() {
  find "$1" -type f -name '*.md' -exec grep -ohE 'data/[A-Za-z0-9][A-Za-z0-9._-]*|^  - old:[A-Za-z0-9][A-Za-z0-9._-]*' {} + \
    | sed -E 's#^data/##; s#^  - old:##' | sort -u
}

seed_home() {
  local old new board
  old=$(physical_dir "$1")
  new=$(physical_dir "$2")
  board=$(physical_dir "$3")
  [ "$old" != "$new" ] || die "the old and lean homes are the same folder"
  [ -d "$old/data" ] || die "$old: has no data/"
  [ -f "$new/bin/fm-backlog-md/cli.cjs" ] || die "$new: is not a lean Firstmate checkout"
  case "$board/" in "$new"/*) die "the board must come from outside the lean home" ;; esac
  require_empty_or_absent "$new/data"
  require_empty_or_absent "$new/config"
  require_empty_or_absent "$new/projects"
  local source_counts
  source_counts=$(board_counts "$board")
  mkdir -p "$new/data" "$new/config" "$new/projects"

  local name
  for name in captain.md captain-shared.md learnings.md projects.md; do
    if [ -f "$old/data/$name" ] && [ ! -L "$old/data/$name" ]; then
      cp -p "$old/data/$name" "$new/data/$name"
      printf 'data copy: %s\n' "$name"
    else
      printf 'data absent: %s\n' "$name"
    fi
  done

  cp -Rp "$board" "$new/data/backlog"
  printf 'data board: %s -> data/backlog\n' "$board"

  local id copied=0 absent=0
  while IFS= read -r id; do
    case "$id" in backlog|*.md) continue ;; esac
    if [ -d "$old/data/$id" ] && [ ! -L "$old/data/$id" ]; then
      cp -Rp "$old/data/$id" "$new/data/$id"
      copied=$((copied + 1))
    else
      absent=$((absent + 1))
      printf 'data task folder absent: %s\n' "$id"
    fi
  done < <(task_folder_ids "$board")
  printf 'data task folders: copied=%s absent=%s\n' "$copied" "$absent"
  printf 'data entries the old home keeps: %s\n' "$(find "$old/data" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

  local path class
  if [ -d "$old/config" ]; then
    for path in "$old/config"/* "$old/config"/.[!.]*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      name=$(basename "$path")
      class=$(config_class "$name")
      if [ "$class" = copy ]; then
        copy_link_or_file "$path" "$new/config/$name"
      fi
      printf 'config %s: %s\n' "$name" "$class"
    done
  fi
  printf 'backlog-md\n' >"$new/config/backlog-backend"
  printf 'config backlog-backend: written as backlog-md\n'

  if [ -d "$old/projects" ]; then
    for path in "$old/projects"/*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      name=$(basename "$path")
      if [ -L "$path" ]; then
        ln -s "$(readlink "$path")" "$new/projects/$name"
        printf 'project link: %s\n' "$name"
      else
        printf 'project clone left behind: %s; add it again with the project-management skill\n' "$name"
      fi
    done
  fi

  local copied_counts
  copied_counts=$(board_counts "$new/data/backlog")
  printf '%s\n' "$copied_counts"
  [ "$copied_counts" = "$source_counts" ] || die "the copied board counts differ from the source board"
  printf 'board counts: match the source board\n'
}

seed_exec() {
  local old new
  old=$(physical_dir "$1")
  new=$(physical_dir "$2")
  [ "$old" != "$new" ] || die "the old and lean execution homes are the same folder"
  [ -f "$new/.fm-exec-home" ] || die "$new: not seeded; run fm-remote-home-seed.sh --exec from the lean home first"
  mkdir -p "$new/config"
  local path name
  for path in "$old/config"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=$(basename "$path")
    case "$name" in
      backlog-backend|herdr-session)
        printf 'config %s: kept as the seed wrote it\n' "$name" ;;
      project-capacity)
        if [ -e "$new/config/$name" ]; then
          printf 'config %s: kept, the lean execution home already has one\n' "$name"
        else
          copy_link_or_file "$path" "$new/config/$name"
          printf 'config %s: copy\n' "$name"
        fi ;;
      *)
        printf 'config %s: %s\n' "$name" "$(config_class "$name")" ;;
    esac
  done
}

ticket_rows() {
  find "$1" -maxdepth 1 -type f -name '*.md' -exec awk '
    function emit() { if (id != "") printf "%s\t%s\t%s\t%s\n", id, status, (old == "" ? "-" : old), (reason == "" ? "-" : reason) }
    FNR == 1 { if (NR > 1) emit(); id = ""; status = ""; old = ""; reason = ""; fence = 0 }
    /^---[ \t]*$/ { fence++; next }
    fence != 1 { next }
    /^id:/ { id = $0; sub(/^id:[ \t]*/, "", id); gsub(/"/, "", id) }
    /^status:/ { status = $0; sub(/^status:[ \t]*/, "", status); gsub(/"/, "", status) }
    /^hold_reason:/ { reason = $0; sub(/^hold_reason:[ \t]*/, "", reason); gsub(/^["\x27]|["\x27]$/, "", reason) }
    /^  - old:/ { value = $0; sub(/^  - old:/, "", value); old = (old == "" ? value : old "," value) }
    END { emit() }' {} +
}

meta_value() {
  awk -v key="$2" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$1"
}

new_home_backlog() {
  env -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$NEW_HOME" "$NEW_HOME/bin/fm-tasks-axi.sh" "$@" >/dev/null
}

handover() {
  local old
  old=$(physical_dir "$1")
  NEW_HOME=$(physical_dir "$2")
  [ "$old" != "$NEW_HOME" ] || die "the old and lean homes are the same folder"
  local tasks="$NEW_HOME/data/backlog/tasks"
  [ -d "$tasks" ] || die "$NEW_HOME: has no board; run seed-home first"
  [ -x "$NEW_HOME/bin/fm-tasks-axi.sh" ] || die "$NEW_HOME: has no bin/fm-tasks-axi.sh"

  local rows carried
  rows=$(ticket_rows "$tasks")
  carried=$(printf '%s\n' "$rows" | awk -F '\t' -v prefix="$HANDOVER_PREFIX" '
    $2 == "In Flight" || index($4, prefix) == 1 { n = split($3, ids, ","); for (i = 1; i <= n; i++) if (ids[i] != "-") print ids[i] }')

  local meta live unmapped=0
  for meta in "$old/state"/*.meta; do
    [ -f "$meta" ] || continue
    live=$(basename "$meta" .meta)
    if [ "$(meta_value "$meta" kind)" = secondmate ]; then
      printf 'second mate kept in the old home: %s\n' "$live"
      continue
    fi
    if ! printf '%s\n' "$carried" | grep -qxF -- "$live"; then
      printf 'unmapped live task: %s\n' "$live"
      unmapped=$((unmapped + 1))
    fi
  done
  [ "$unmapped" -eq 0 ] || die "$unmapped old worker records have no In Flight ticket; land, tear down or ticket them first"

  local id status olds reason first branch worktree route parked=0
  while IFS="$(printf '\t')" read -r id status olds reason; do
    [ "$status" = "In Flight" ] || continue
    first=${olds%%,*}
    meta="$old/state/$first.meta"
    if [ "$first" != "-" ] && [ -f "$meta" ]; then
      branch=$(meta_value "$meta" branch)
      worktree=$(meta_value "$meta" worktree)
      route=$(meta_value "$meta" remote_route)
      reason="$HANDOVER_PREFIX: the old worker $first is stopped and kept, branch ${branch:-unknown}, worktree ${worktree:-unknown}${route:+ on $route}"
    else
      reason="$HANDOVER_PREFIX: the old home had no worker record"
    fi
    # The backlog refuses parentheses in a hold reason.
    reason=$(printf '%s' "$reason" | tr '()' '[]')
    new_home_backlog reopen "$id"
    new_home_backlog hold "$id" --kind parked --reason "$reason"
    printf 'parked: %s - %s\n' "$id" "$reason"
    parked=$((parked + 1))
  done <<EOF
$rows
EOF
  printf 'handover: parked=%s\n' "$parked"
  board_counts "$NEW_HOME/data/backlog"
}

case "${1:-}" in
  counts) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; board_counts "$(physical_dir "$2")" ;;
  seed-home) [ "$#" -eq 4 ] || { usage >&2; exit 2; }; seed_home "$2" "$3" "$4" ;;
  seed-exec) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; seed_exec "$2" "$3" ;;
  handover) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; handover "$2" "$3" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
