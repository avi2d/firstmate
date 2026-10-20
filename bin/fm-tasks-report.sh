#!/usr/bin/env bash
set -eu

export TZ=UTC
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: fm-tasks-report.sh [--help]
Print the tasks report v1 for tui-dash, one JSON object on one line.
FM_TASKS_HOMES overrides machine discovery with a colon-separated home list.
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

meta_last() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
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

collect_home_snapshot() {
  local home=$1 snap_bin=$2 out=$3
  local snap_dir crew_state work meta id kind branch project spawn_gen first_spawn_gen worktree present remote_host
  local pids="" batch=0 rc=0 contrib_pid=""
  snap_dir=$(dirname "$snap_bin")
  crew_state="$snap_dir/fm-crew-state.sh"
  [ -x "$crew_state" ] || crew_state="$SCRIPT_DIR/fm-crew-state.sh"
  work="$TMPDIR_WORK/home-$4"
  mkdir -p "$work"
  : >"$work/base.jsonl"
  : >"$work/obs.jsonl"
  : >"$work/live.tsv"
  if command -v timeout >/dev/null 2>&1; then
    FM_HOME="$home" timeout 120 "$snap_bin" --contribution-input >"$work/contrib.json" 2>"$work/contrib.err" &
  else
    FM_HOME="$home" "$snap_bin" --contribution-input >"$work/contrib.json" 2>"$work/contrib.err" &
  fi
  contrib_pid=$!
  for meta in "$home"/state/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_last "$meta" kind)
    [ -n "$kind" ] || kind=ship
    branch=$(meta_last "$meta" branch)
    project=$(meta_last "$meta" project)
    spawn_gen=$(meta_last "$meta" spawn_gen)
    first_spawn_gen=$(meta_last "$meta" first_spawn_gen)
    worktree=$(meta_last "$meta" worktree)
    present=false
    if [ -n "$worktree" ] && [ -e "$worktree" ]; then present=true; fi
    jq -n --arg id "$id" --arg kind "$kind" --arg branch "$branch" --arg project "$project" \
      --arg spawn_gen "$spawn_gen" --arg first_spawn_gen "$first_spawn_gen" \
      --arg worktree "$worktree" --argjson worktree_present "$present" \
      '{id:$id,kind:$kind,branch:$branch,project:$project,spawn_gen:$spawn_gen,first_spawn_gen:$first_spawn_gen,worktree:$worktree,worktree_present:$worktree_present}' >>"$work/base.jsonl"
    remote_host=$(meta_last "$meta" remote_host)
    if [ -n "$remote_host" ]; then
      # An observation only surfaces for a live task, and reading a status
      # file walks it line by line, which costs seconds on large secondmate logs.
      case "${spawn_gen#s}" in [0-9]*) observe_remote_stub "$id" "$kind" "$home/state/$id.status" "$work/obs.jsonl" ;; esac
      continue
    fi
    printf '%s\t%s\t%s\n' "$id" "$kind" "$home/state/$id.status" >>"$work/live.tsv"
  done
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
  [ "$rc" -eq 0 ] || return 1
  wait "$contrib_pid" || {
    echo "error: fleet snapshot failed for $home: $(head -c 300 "$work/contrib.err")" >&2
    return 1
  }
  jq -n --arg fm_home "$home" \
    --slurpfile base "$work/base.jsonl" \
    --slurpfile obs "$work/obs.jsonl" \
    --slurpfile contrib "$work/contrib.json" '
    ($contrib[0].backlog) as $backlog
    | def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
      ($obs | map({key:.id, value:.}) | from_entries) as $o
    | {
      schema: "fm-fleet-snapshot.v1",
      fm_home: $fm_home,
      backlog: $backlog,
      tasks: ([$base[]
        | .id as $id
        | ($o[$id] // {}) as $ob
        | {
          id: $id,
          kind: .kind,
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

HOMES_FILE="$TMPDIR_WORK/homes"
discover_homes >"$HOMES_FILE" || exit 1
[ -s "$HOMES_FILE" ] || {
  echo "error: no firstmate homes found under $HOME" >&2
  exit 1
}

ORCH_VERSION="unknown"
if git -C "$SCRIPT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  ORCH_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)
fi
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%F)
YESTERDAY=$(jq -n --arg d "$TODAY" '$d | strptime("%Y-%m-%d") | mktime - 86400 | strftime("%Y-%m-%d")' -r)

SNAPS_DIR="$TMPDIR_WORK/snaps"
mkdir -p "$SNAPS_DIR"
N=0
while IFS= read -r home; do
  [ -n "$home" ] || continue
  N=$((N + 1))
  snap="$home/bin/fm-fleet-snapshot.sh"
  [ -x "$snap" ] || snap="$SCRIPT_DIR/fm-fleet-snapshot.sh"
  collect_home_snapshot "$home" "$snap" "$SNAPS_DIR/$N.json" "$N" || exit 1
  jq -e '.schema == "fm-fleet-snapshot.v1"' "$SNAPS_DIR/$N.json" >/dev/null || {
    echo "error: unexpected snapshot schema for $home" >&2
    exit 1
  }
done <"$HOMES_FILE"

PIPES="$TMPDIR_WORK/pipes.json"
echo '{}' >"$PIPES"
if command -v no-mistakes >/dev/null 2>&1; then
  while IFS= read -r row; do
    home=${row%%$'\t'*}
    rest=${row#*$'\t'}
    id=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    branch=${rest%%$'\t'*}
    worktree=${rest#*$'\t'}
    [ -d "$worktree" ] || continue
    nm_out=$(cd "$worktree" 2>/dev/null && no-mistakes axi status 2>/dev/null || true)
    [ -n "$nm_out" ] || continue
    block_id=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*id: "([A-Z0-9]+)".*/\1/p' | head -1)
    block_status=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*status: ([A-Za-z]+).*/\1/p' | head -1)
    block_branch=$(printf '%s' "$nm_out" | sed -n -E 's/^[[:space:]]*branch: ([^[:space:]]+).*/\1/p' | head -1)
    runs=$(printf '%s' "$nm_out" | grep -E '^[[:space:]]*"[A-Z0-9]+",[^,]+,(running|fixing),' || true)
    if [ -n "$block_id" ] && { [ "$block_status" = running ] || [ "$block_status" = fixing ]; }; then
      runs=$(printf '  "%s",%s,%s,\n%s' "$block_id" "$block_branch" "$block_status" "$runs")
    fi
    [ -n "$runs" ] || continue
    while IFS= read -r line; do
      run=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"([A-Z0-9]+)".*/\1/')
      run_branch=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"[A-Z0-9]+",([^,]+),.*/\1/')
      [ -n "$run" ] || continue
      [ "$run_branch" = "$branch" ] || continue
      for folder in "$HOME"/.no-mistakes/worktrees/*/"$run"; do
        [ -d "$folder" ] || continue
        key="$home"$'\x1f'"$id"
        jq --arg k "$key" --arg f "$folder" '.[$k] += [$f]' "$PIPES" >"$PIPES.new"
        mv "$PIPES.new" "$PIPES"
      done
    done <<<"$runs"
  done < <(jq -n -r '[inputs | .fm_home as $h | .tasks[]? | select(.paths.worktree.present == true) | (.branch // "") as $b | "\($h)\t\(.id)\t\($b)\t\(.paths.worktree.path)" ] | .[]' "$SNAPS_DIR"/*.json)
fi

jq -c -s --arg generated_at "$GENERATED_AT" --arg yesterday "$YESTERDAY" \
  --arg orch_version "$ORCH_VERSION" --slurpfile pipes "$PIPES" '
  ($pipes[0] // {}) as $pipes
  | (map(
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
          kind: (($t.kind // "") | tostring),
          state: $st,
          detail: ((($t.current_state.detail // "") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          startedAt: $started,
          firstStartedAt: ($first // $started),
          endedAt: (if $st == "done" then $generated_at else null end),
          folders: ([($t.paths.worktree.path // null) | select(. != null and . != "")] + $extra | unique),
          branches: ([($t.branch // "") | select(. != "")])
        }],
      recent: [$snap.backlog.records[]?
        | select(.state == "done")
        | select((.id as $id | $live | index($id) | not))
        | select((.completion.date // "") >= $yesterday)
        | . as $r
        | $generated_at as $ended
        | {
          id: $r.id,
          title: ((($r.title // $r.id) | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          project: ((($r.repo // "?") | tostring | split("/") | last) | if . == "" then "?" else . end),
          kind: (($r.kind // "") | tostring),
          state: "done",
          detail: ((($r.completion.verb // "done") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          startedAt: $ended,
          firstStartedAt: $ended,
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
  | {
    schemaVersion: 1,
    generatedAt: $generated_at,
    orchestrator: {name: "firstmate", version: $orch_version},
    tasks: ([$homes[].live[]] + [$homes[].recent[]]),
    overhead: [$homes[].overhead[]],
    schedules: [$homes[].sched[]]
  }
' "$SNAPS_DIR"/*.json
