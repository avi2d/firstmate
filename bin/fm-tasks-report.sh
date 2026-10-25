#!/usr/bin/env bash
set -eu

export TZ=UTC
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: fm-tasks-report.sh [--help]
Print the tasks report v1 for tui-dash, one JSON object on one line.
FM_TASKS_HOMES overrides machine discovery with a colon-separated home list.
Each home's queued work also appears as a top-level planned array of
(id, title, project, kind, home, queuedOn, hold, after) rows in tasks-axi
dispatch order: ready rows first, then held, then blocked. The planned key is
omitted when no home has queued work. A home whose queue cannot be read
contributes no rows.
Exit 0 prints the report, exit 1 names the home or input that stopped it.
EOF
  exit 0
fi
[ $# -eq 0 ] || { echo "error: no arguments expected (got '$*')" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

CS_TIMEOUT="${FM_SNAPSHOT_CREW_STATE_TIMEOUT:-10}"
READ_CONCURRENCY=8

TMPDIR_WORK="${TMPDIR:-/tmp}/fm-tasks-report-$$"
mkdir -p "$TMPDIR_WORK"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

read_meta() {
  local line
  m_kind='' m_mode='' m_branch='' m_project='' m_spawn_gen='' m_first_spawn_gen='' m_worktree='' m_remote_host=''
  [ -r "$1" ] || return 0
  # The last line for a key wins.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) m_kind=${line#kind=} ;;
      mode=*) m_mode=${line#mode=} ;;
      branch=*) m_branch=${line#branch=} ;;
      project=*) m_project=${line#project=} ;;
      spawn_gen=*) m_spawn_gen=${line#spawn_gen=} ;;
      first_spawn_gen=*) m_first_spawn_gen=${line#first_spawn_gen=} ;;
      worktree=*) m_worktree=${line#worktree=} ;;
      remote_host=*) m_remote_host=${line#remote_host=} ;;
    esac
  done <"$1"
}

planned_section_ids() {
  awk -v sec="$2" '
    index($0, sec "[") == 1 { in_sec = 1; next }
    in_sec == 1 && /^  / { line = substr($0, 3); sub(/,.*$/, "", line); print line; next }
    in_sec == 1 { exit }
  ' "$1"
}

planned_row() {
  local home=$1 name=$2 id=$3 out=$4
  FM_HOME="$home" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full >"$out.show" 2>/dev/null || return 0
  jq -R -n --arg id "$id" --arg home "$name" '
    [inputs] as $lines
    | def field($k): ("  " + $k + ": ") as $p
        | first($lines[] | select(startswith($p)) | .[($p | length):]) // "";
      def unquote: if length >= 2 and startswith("\"") and endswith("\"") then .[1:-1] else . end;
      def value: unquote | if . == "-" or . == "none" then "" else . end;
      (field("title") | unquote) as $title
    | (field("repo") | value) as $repo
    | (field("kind") | value) as $kind
    | (field("created") | value) as $created
    | (field("blocked_by") | value) as $blocked_by
    | (field("held") | value) as $held
    | (field("hold_reason") | value) as $hold_reason
    | (field("hold_kind") | value) as $hold_kind
    | (field("blocked") | value) as $blocked
    | (($repo | split("/") | last) // "" | if . == "" then "?" else . end) as $project
    | {
      group: (if $held == "yes" then "held" elif $blocked == "yes" then "blocked" else "other" end),
      row: {id: $id, title: $title, project: $project, kind: $kind, home: $home,
        queuedOn: (if $created == "" then null else $created end),
        hold: (if $held == "yes"
          then {kind: (if $hold_kind == "captain" or $hold_kind == "external" then $hold_kind else "unstated" end), reason: $hold_reason}
          else null end),
        after: ($blocked_by | if . == "" then [] else split(",") end)}
    }' <"$out.show" >"$out.json" || rm -f "$out.json"
}

collect_home_planned() {
  local home=$1 out=$2 tag=$3
  local name work ready_ids queued_ids id unique_ids pids="" batch=0 p
  printf '[]' >"$out"
  name=$(basename "$home")
  work="$TMPDIR_WORK/planned-$tag"
  mkdir -p "$work/rows"
  FM_HOME="$home" "$SCRIPT_DIR/fm-tasks-axi.sh" ready >"$work/ready" 2>/dev/null || return 0
  FM_HOME="$home" "$SCRIPT_DIR/fm-tasks-axi.sh" list --state queued >"$work/queued" 2>/dev/null || return 0
  ready_ids=$(planned_section_ids "$work/ready" ready)
  queued_ids=$(planned_section_ids "$work/queued" tasks)
  [ -n "$queued_ids" ] || return 0
  for id in $ready_ids; do printf '%s\n' "$id"; done >"$work/ready.ids"
  for id in $queued_ids; do printf '%s\n' "$id"; done >"$work/queued.ids"
  unique_ids=$(awk '!seen[$0]++' "$work/queued.ids")
  # Each show starts its own tasks-axi, so the reads run side by side.
  for id in $unique_ids; do
    planned_row "$home" "$name" "$id" "$work/rows/$id" &
    pids="$pids $!"
    batch=$((batch + 1))
    if [ "$batch" -ge "$READ_CONCURRENCY" ]; then
      for p in $pids; do wait "$p" || true; done
      pids=""
      batch=0
    fi
  done
  for p in $pids; do wait "$p" || true; done
  for id in $unique_ids; do
    [ -f "$work/rows/$id.json" ] && cat "$work/rows/$id.json"
  done | jq -s --rawfile ready "$work/ready.ids" --rawfile queued "$work/queued.ids" '
    (map({key: .row.id, value: .}) | from_entries) as $rec
    | ($ready | split("\n") | map(select(. != ""))) as $r
    | ($queued | split("\n") | map(select(. != ""))) as $q
    | [($r[] | select($rec[.] != null)),
       (("held", "blocked", "other") as $pass | $q[] | select($rec[.].group == $pass))]
    | reduce .[] as $id ({seen: {}, ids: []};
        if .seen[$id] then . else .seen[$id] = true | .ids += [$id] end)
    | [.ids[] | $rec[.].row]' >"$out"
}

discover_homes() {
  local dir resolved seen="$TMPDIR_WORK/seen"
  : >"$seen"
  if [ -n "${FM_TASKS_HOMES:-}" ]; then
    local IFS=:
    for dir in $FM_TASKS_HOMES; do
      [ -n "$dir" ] || continue
      resolved=$(cd "$dir" 2>/dev/null && pwd -P) || {
        echo "error: tasks home not readable: $dir" >&2
        return 1
      }
      grep -qxF "$resolved" "$seen" 2>/dev/null || echo "$resolved" >>"$seen"
    done
  else
    for dir in "$HOME"/fm-*; do
      [ -d "$dir/state" ] || continue
      resolved=$(cd "$dir" 2>/dev/null && pwd -P) || continue
      grep -qxF "$resolved" "$seen" 2>/dev/null || echo "$resolved" >>"$seen"
    done
    resolved=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || resolved=""
    # A bare checkout can carry an empty state dir without being a home; the backlog marks one that is lived in.
    if [ -n "$resolved" ] && [ -d "$resolved/state" ] && [ -f "$resolved/data/backlog.md" ]; then
      grep -qxF "$resolved" "$seen" 2>/dev/null || echo "$resolved" >>"$seen"
    fi
    if [ -n "${FM_HOME:-}" ] && [ -d "${FM_HOME}/state" ]; then
      resolved=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || true
      if [ -n "${resolved:-}" ]; then
        grep -qxF "$resolved" "$seen" 2>/dev/null || echo "$resolved" >>"$seen"
      fi
    fi
  fi
  sort -u "$seen"
}

open_blocked() {
  local status_file=$1 kind=$2 state=$3 source=$4
  local open_tsv open_json
  open_tsv=$(status_open_decisions "$status_file" "$kind")
  if [ "$kind" != secondmate ] && \
     { { { [ "$source" = run-step ] || [ "$source" = pane ]; } \
         && [ "$state" != parked ] && [ "$state" != blocked ]; } \
       || { [ "$state" = "done" ] || [ "$state" = "failed" ]; }; }; then
    open_tsv=""
  fi
  open_json=$(printf '%s' "$open_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
  printf '%s' "$open_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end'
}

observe_task() {
  local crew_state=$1 home=$2 id=$3 kind=$4 status_file=$5 out=$6
  local raw rest state source detail blocked sep
  raw=$(fm_run_timed "$CS_TIMEOUT" env FM_HOME="$home" "$crew_state" "$id" 2>/dev/null || true)
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  blocked=$(open_blocked "$status_file" "$kind" "$state" "$source")
  jq -n --arg id "$id" --arg state "$state" --arg detail "$detail" --argjson blocked "$blocked" \
    '{id:$id,state:$state,detail:$detail,blocked:($blocked == 1)}' >>"$out"
}

observe_remote_stub() {
  local id=$1 kind=$2 status_file=$3 out=$4
  local blocked
  blocked=$(open_blocked "$status_file" "$kind" unknown none)
  jq -n --arg id "$id" --argjson blocked "$blocked" \
    '{id:$id,state:"unknown",detail:"remote endpoint liveness not probed by this report",blocked:($blocked == 1)}' >>"$out"
}

stream_span() {  # <status-file> -> span_start span_end
  local line verb at last=''
  span_start='' span_end=''
  while IFS= read -r line || [ -n "$line" ]; do
    _fm_status_at_epoch "$line" at || continue
    if [ -z "$span_start" ] || [ "$at" -lt "$span_start" ]; then span_start=$at; fi
    last=$at
    status_line_verb "$line" verb
    case "$verb" in done|failed) span_end=$at ;; esac
  done <"$1"
  [ -n "$span_end" ] || span_end=$last
}

collect_home_spans() {  # <home> <work>
  local home=$1 work=$2 id f
  : >"$work/spans.tsv"
  while IFS= read -r id; do
    case "$id" in ''|*/*|.*) continue ;; esac
    for f in "$home/state/status-archive/$id"/*.status "$home/data/$id"/status.log "$home/data/$id"/status.[0-9]*.log; do
      [ -f "$f" ] || continue
      stream_span "$f"
      [ -z "$span_end" ] || printf 'archived\t%s\t%s\t%s\n' "$id" "$span_start" "$span_end" >>"$work/spans.tsv"
    done
  done < <(jq -r '.backlog.records[]? | select(.state == "done") | .id' "$work/contrib.json")
  while IFS= read -r id; do
    [ -f "$home/state/$id.status" ] || continue
    stream_span "$home/state/$id.status"
    [ -z "$span_end" ] || printf 'live\t%s\t%s\t%s\n' "$id" "$span_start" "$span_end" >>"$work/spans.tsv"
  done < <(jq -r 'select(.state == "done") | .id' "$work/obs.jsonl")
}

pipeline_folders() {  # <home> <id> <branch> <worktree>
  local home=$1 id=$2 branch=$3 worktree=$4
  local nm_out block_id block_status block_branch runs line run run_branch folder
  [ -d "$worktree" ] || return 0
  nm_out=$(cd "$worktree" 2>/dev/null && no-mistakes axi status 2>/dev/null || true)
  [ -n "$nm_out" ] || return 0
  block_id=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*id: "([A-Z0-9]+)".*/\1/p' | head -1)
  block_status=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*status: ([A-Za-z]+).*/\1/p' | head -1)
  block_branch=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*branch: ([^[:space:]]+).*/\1/p' | head -1)
  runs=$(printf '%s' "$nm_out" | grep -E '^[[:space:]]*"[A-Z0-9]+",[^,]+,(running|fixing),' || true)
  if [ -n "$block_id" ] && { [ "$block_status" = running ] || [ "$block_status" = fixing ]; }; then
    runs=$(printf '  "%s",%s,%s,\n%s' "$block_id" "$block_branch" "$block_status" "$runs")
  fi
  [ -n "$runs" ] || return 0
  while IFS= read -r line; do
    run=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"([A-Z0-9]+)".*/\1/')
    run_branch=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"[A-Z0-9]+",([^,]+),.*/\1/')
    [ -n "$run" ] || continue
    [ "$run_branch" = "$branch" ] || continue
    for folder in "$HOME"/.no-mistakes/worktrees/*/"$run"; do
      [ -d "$folder" ] || continue
      printf '%s\x1f%s\t%s\n' "$home" "$id" "$folder"
    done
  done <<<"$runs"
}

collect_home_pipelines() {  # <home> <work>
  local home=$1 work=$2 id branch worktree n=0 pids="" batch=0 p
  mkdir -p "$work/pipes"
  # The unit separator keeps an empty branch as its own field, which a tab would collapse.
  while IFS=$'\x1f' read -r id branch worktree; do
    n=$((n + 1))
    pipeline_folders "$home" "$id" "$branch" "$worktree" >"$work/pipes/$n.tsv" &
    pids="$pids $!"
    batch=$((batch + 1))
    if [ "$batch" -ge "$READ_CONCURRENCY" ]; then
      for p in $pids; do wait "$p" || true; done
      pids=""
      batch=0
    fi
  done <"$work/pipes.in"
  for p in $pids; do wait "$p" || true; done
}

collect_home_snapshot() {
  local home=$1 snap_bin=$2 out=$3
  local snap_dir crew_state work meta id kind mode branch project spawn_gen first_spawn_gen worktree present remote_host
  local pids="" batch=0 rc=0 contrib_pid="" pipes_pid=""
  snap_dir=$(dirname "$snap_bin")
  crew_state="$snap_dir/fm-crew-state.sh"
  [ -x "$crew_state" ] || crew_state="$SCRIPT_DIR/fm-crew-state.sh"
  work="$TMPDIR_WORK/home-$4"
  mkdir -p "$work"
  : >"$work/base.jsonl"
  : >"$work/obs.jsonl"
  : >"$work/live.tsv"
  : >"$work/pipes.in"
  if command -v timeout >/dev/null 2>&1; then
    FM_HOME="$home" timeout 120 "$snap_bin" --contribution-input >"$work/contrib.json" 2>"$work/contrib.err" &
  else
    FM_HOME="$home" "$snap_bin" --contribution-input >"$work/contrib.json" 2>"$work/contrib.err" &
  fi
  contrib_pid=$!
  for meta in "$home"/state/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    read_meta "$meta"
    kind=$m_kind
    [ -n "$kind" ] || kind=ship
    mode=$m_mode
    branch=$m_branch
    project=$m_project
    spawn_gen=$m_spawn_gen
    first_spawn_gen=$m_first_spawn_gen
    worktree=$m_worktree
    present=false
    if [ -n "$worktree" ] && [ -e "$worktree" ]; then present=true; fi
    jq -n --arg id "$id" --arg kind "$kind" --arg mode "$mode" --arg branch "$branch" --arg project "$project" \
      --arg spawn_gen "$spawn_gen" --arg first_spawn_gen "$first_spawn_gen" \
      --arg worktree "$worktree" --argjson worktree_present "$present" \
      '{id:$id,kind:$kind,mode:$mode,branch:$branch,project:$project,spawn_gen:$spawn_gen,first_spawn_gen:$first_spawn_gen,worktree:$worktree,worktree_present:$worktree_present}' >>"$work/base.jsonl"
    [ "$present" = false ] || printf '%s\x1f%s\x1f%s\n' "$id" "$branch" "$worktree" >>"$work/pipes.in"
    remote_host=$m_remote_host
    if [ -n "$remote_host" ]; then
      # An observation only surfaces for a live task, and reading a status
      # file walks it line by line, which costs seconds on large secondmate logs.
      case "${spawn_gen#s}" in [0-9]*) observe_remote_stub "$id" "$kind" "$home/state/$id.status" "$work/obs.jsonl" ;; esac
      continue
    fi
    printf '%s\t%s\t%s\n' "$id" "$kind" "$home/state/$id.status" >>"$work/live.tsv"
  done
  if [ "$HAVE_NO_MISTAKES" = 1 ]; then
    collect_home_pipelines "$home" "$work" &
    pipes_pid=$!
  fi
  while IFS="$TAB" read -r id kind status_path; do
    [ -n "${id:-}" ] || continue
    observe_task "$crew_state" "$home" "$id" "$kind" "$status_path" "$work/obs.jsonl" &
    pids="$pids $!"
    batch=$((batch + 1))
    if [ "$batch" -ge "$READ_CONCURRENCY" ]; then
      for p in $pids; do wait "$p" || rc=1; done
      pids=""
      batch=0
    fi
  done <"$work/live.tsv"
  for p in $pids; do wait "$p" || rc=1; done
  [ -z "$pipes_pid" ] || wait "$pipes_pid" || true
  [ "$rc" -eq 0 ] || return 1
  wait "$contrib_pid" || {
    echo "error: fleet snapshot failed for $home: $(head -c 300 "$work/contrib.err")" >&2
    return 1
  }
  collect_home_spans "$home" "$work"
  jq -n --arg fm_home "$home" \
    --slurpfile base "$work/base.jsonl" \
    --slurpfile obs "$work/obs.jsonl" \
    --slurpfile contrib "$work/contrib.json" \
    --rawfile spans "$work/spans.tsv" '
    ($contrib[0].backlog) as $backlog
    | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
      ($obs | map({key:.id, value:.}) | from_entries) as $o
    | {
      schema: "fm-fleet-snapshot.v1",
      fm_home: $fm_home,
      backlog: $backlog,
      spans: (reduce ($spans | split("\n")[] | select(. != "") | split("\t")) as [$where, $id, $start, $end] ({live: {}, archived: {}};
        ({start: ($start | tonumber), end: ($end | tonumber)}) as $span
        | if (.[$where][$id].end // -1) < $span.end then .[$where][$id] = $span else . end)),
      tasks: ([$base[]
        | .id as $id
        | ($o[$id] // {}) as $ob
        | {
          id: $id,
          kind: .kind,
          mode: (.mode // ""),
          branch: (if .branch == "" then null else .branch end),
          project: .project,
          spawn_gen: (if .spawn_gen == "" then null else .spawn_gen end),
          first_spawn_gen: (if .first_spawn_gen == "" then null else .first_spawn_gen end),
          paths: {worktree: {path: (if .worktree == "" then null else .worktree end), present: .worktree_present}},
          current_state: {state: ($ob.state // "unknown"), detail: ($ob.detail // "")},
          hints: {blocked_event: ($ob.blocked // false)},
          backlog: backlog_by_id($id)
        }]
        | sort_by(.id))
    }' >"$out"
}

TAB=$(printf '\t')
HAVE_NO_MISTAKES=0
if command -v no-mistakes >/dev/null 2>&1; then HAVE_NO_MISTAKES=1; fi

HOMES_FILE="$TMPDIR_WORK/homes"
discover_homes >"$HOMES_FILE" || exit 1
[ -s "$HOMES_FILE" ] || {
  echo "error: no firstmate homes found under $HOME" >&2
  exit 1
}

ORCH_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null) || ORCH_VERSION=""
[ -n "$ORCH_VERSION" ] || ORCH_VERSION="unknown"
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%F)
YESTERDAY=$(jq -n --arg d "$TODAY" '$d | strptime("%Y-%m-%d") | mktime - 86400 | strftime("%Y-%m-%d")' -r)

SNAPS_DIR="$TMPDIR_WORK/snaps"
mkdir -p "$SNAPS_DIR"
PLANNED_DIR="$TMPDIR_WORK/planned"
mkdir -p "$PLANNED_DIR"
N=0
while IFS= read -r home; do
  [ -n "$home" ] || continue
  N=$((N + 1))
  snap="$home/bin/fm-fleet-snapshot.sh"
  [ -x "$snap" ] || snap="$SCRIPT_DIR/fm-fleet-snapshot.sh"
  collect_home_snapshot "$home" "$snap" "$SNAPS_DIR/$N.json" "$N" 2>"$TMPDIR_WORK/snap-$N.err" &
  SNAP_PIDS[N]=$!
  collect_home_planned "$home" "$PLANNED_DIR/$N.json" "$N" 2>"$TMPDIR_WORK/planned-$N.err" &
  PLANNED_PIDS[N]=$!
done <"$HOMES_FILE"
# Homes are read side by side, and the first failing home in discovery order is the one named.
N=0
while IFS= read -r home; do
  [ -n "$home" ] || continue
  N=$((N + 1))
  rc=0
  wait "${PLANNED_PIDS[N]}" || rc=1
  cat "$TMPDIR_WORK/planned-$N.err" >&2
  [ "$rc" -eq 0 ] || exit 1
  wait "${SNAP_PIDS[N]}" || rc=1
  cat "$TMPDIR_WORK/snap-$N.err" >&2
  [ "$rc" -eq 0 ] || exit 1
  jq -e '.schema == "fm-fleet-snapshot.v1"' "$SNAPS_DIR/$N.json" >/dev/null || {
    echo "error: unexpected snapshot schema for $home" >&2
    exit 1
  }
done <"$HOMES_FILE"

PIPES="$TMPDIR_WORK/pipes.json"
cat "$TMPDIR_WORK"/home-*/pipes/*.tsv 2>/dev/null | jq -R -n '
  reduce (inputs | split("\t") | [.[0], (.[1:] | join("\t"))]) as [$k, $f] ({}; .[$k] += [$f])' >"$PIPES"

jq -s 'add // []' "$PLANNED_DIR"/*.json >"$TMPDIR_WORK/planned.json"

jq -c -s --arg generated_at "$GENERATED_AT" --arg yesterday "$YESTERDAY" \
  --arg orch_version "$ORCH_VERSION" --slurpfile pipes "$PIPES" --slurpfile planned "$TMPDIR_WORK/planned.json" '
  ($pipes[0] // {}) as $pipes
  | def stage_kind($kind; $mode):
      if $kind == "ship" and ($mode == "no-mistakes" or $mode == "no-mistakes-prod-only") then "full review fix"
      elif $kind == "ship" and $mode == "direct-PR" then "quick fix"
      elif $kind == "ship" and $mode == "local-only" then "local only"
      elif $kind == "scout" then "scout"
      else $kind end;
    def iso: if . == null then null else strftime("%Y-%m-%dT%H:%M:%SZ") end;
    (map(
    . as $snap | ($snap.fm_home // "?") as $home
    | ([$snap.tasks[]? | .id]) as $live
    | {
      live: [$snap.tasks[]?
        | select((.spawn_gen // "") | test("^s[0-9]+"))
        | . as $t
        | ($t.spawn_gen | capture("^s(?<e>[0-9]+)") | .e | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ")) as $started
        | (if (($t.first_spawn_gen // "") | test("^s[0-9]+")) then ($t.first_spawn_gen | capture("^s(?<e>[0-9]+)") | .e | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ")) else null end) as $first
        | (($t.current_state.state // "") as $raw
          | ($t.hints // {}) as $h
          | (if $raw == "working" then "working"
             elif $raw == "parked" then "parked"
             elif $raw == "blocked" then "blocked"
             elif $raw == "done" then "done"
             else "waiting" end) as $m
          | if $m != "done" and ($h.blocked_event // false) then "blocked" else $m end) as $st
        | (($home + "\u001f" + $t.id) as $key | ($pipes[$key] // [])) as $extra
        | {
          id: $t.id,
          title: ((($t.backlog.title // $t.id) | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          project: ((($t.project // $t.backlog.repo // "?") | tostring | split("/") | last) | if . == "" then "?" else . end),
          kind: stage_kind((($t.kind // "") | tostring); (($t.mode // "") | tostring)),
          state: $st,
          detail: ((($t.current_state.detail // "") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          startedAt: $started,
          firstStartedAt: ($first // $started),
          endedAt: (if $st == "done" then ($snap.spans.live[$t.id].end | iso) // $generated_at else null end),
          folders: ([($t.paths.worktree.path // null) | select(. != null and . != "")] + $extra | unique),
          branches: ([($t.branch // "") | select(. != "")])
        }],
      recent: [$snap.backlog.records[]?
        | select(.state == "done")
        | select((.id as $id | $live | index($id) | not))
        | select((.completion.date // "") >= $yesterday)
        | . as $r
        | ($snap.spans.archived[$r.id] // null) as $span
        | (($span.end | iso) // $generated_at) as $ended
        | (($span.start | iso) // $ended) as $started
        | {
          id: $r.id,
          title: ((($r.title // $r.id) | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          project: ((($r.repo // "?") | tostring | split("/") | last) | if . == "" then "?" else . end),
          kind: stage_kind((($r.kind // "") | tostring); ""),
          state: "done",
          detail: ((($r.completion.verb // "done") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          startedAt: $started,
          firstStartedAt: $started,
          endedAt: $ended,
          folders: [],
          branches: ["fm/" + $r.id]
        }],
      overhead: [{name: ($home | split("/") | last), folders: [$home]}],
      sched: [$snap.backlog.records[]?
        | select(.hold_until != null and .state != "done" and .done == null)
        | . as $r
        | (($r.hold_until | tostring)) as $u
        | {
          name: $r.id,
          at: (if $u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then $u + "T00:00:00Z" else $u end),
          detail: ((($r.hold_reason // "comes back to the queue") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end)
        }]
    })) as $homes
  | ($planned[0] // []) as $planned_all
  | {
    schemaVersion: 1,
    generatedAt: $generated_at,
    orchestrator: {name: "firstmate", version: $orch_version},
    tasks: ([$homes[].live[]] + [$homes[].recent[]]),
    overhead: [$homes[].overhead[]],
    schedules: [$homes[].sched[]]
  } as $report
  | if ($planned_all | length) == 0 then $report else ($report + {planned: $planned_all}) end
' "$SNAPS_DIR"/*.json
