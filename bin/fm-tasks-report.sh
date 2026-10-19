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

TMPDIR_WORK="${TMPDIR:-/tmp}/fm-tasks-report-$$"
mkdir -p "$TMPDIR_WORK"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

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
    if [ -n "${FM_HOME:-}" ] && [ -d "${FM_HOME}/state" ]; then
      resolved=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || true
      if [ -n "${resolved:-}" ]; then
        grep -qxF "$resolved" "$seen" 2>/dev/null || echo "$resolved" >>"$seen"
      fi
    fi
  fi
  sort -u "$seen"
}

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
  if command -v timeout >/dev/null 2>&1; then
    FM_HOME="$home" timeout 120 "$snap" --json >"$SNAPS_DIR/$N.json" 2>"$SNAPS_DIR/$N.err" || {
      echo "error: fleet snapshot failed for $home: $(head -c 300 "$SNAPS_DIR/$N.err")" >&2
      exit 1
    }
  else
    FM_HOME="$home" "$snap" --json >"$SNAPS_DIR/$N.json" 2>"$SNAPS_DIR/$N.err" || {
      echo "error: fleet snapshot failed for $home: $(head -c 300 "$SNAPS_DIR/$N.err")" >&2
      exit 1
    }
  fi
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
    worktree=${rest#*$'\t'}
    [ -d "$worktree" ] || continue
    runs=$(cd "$worktree" 2>/dev/null && no-mistakes axi status 2>/dev/null | grep -E '^\s*"[A-Z0-9]+",[^,]+,(running|fixing),' || true)
    [ -n "$runs" ] || continue
    while IFS= read -r line; do
      run=$(printf '%s' "$line" | sed -E 's/^\s*"([A-Z0-9]+)".*/\1/')
      [ -n "$run" ] || continue
      for folder in "$HOME"/.no-mistakes/worktrees/*/"$run"; do
        [ -d "$folder" ] || continue
        key="$home"$'\x1f'"$id"
        jq --arg k "$key" --arg f "$folder" '.[$k] += [$f]' "$PIPES" >"$PIPES.new"
        mv "$PIPES.new" "$PIPES"
      done
    done <<<"$runs"
  done < <(jq -n -r '[inputs | .fm_home as $h | .tasks[]? | select(.paths.worktree.present == true) | "\($h)\t\(.id)\t\(.paths.worktree.path)" ] | .[]' "$SNAPS_DIR"/*.json)
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
        | (if ($t.backlog.since // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then $t.backlog.since + "T00:00:00Z" else null end) as $since
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
          firstStartedAt: ([$started, $since] | map(select(. != null)) | min),
          endedAt: (if $st == "done"
            then (if ($t.backlog.completion.date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then $t.backlog.completion.date + "T23:59:59Z" else $generated_at end)
            else null end),
          folders: ([($t.paths.worktree.path // null) | select(. != null and . != "")] + $extra | unique),
          branches: ([($t.branch // "") | select(. != "")])
        }],
      recent: [$snap.backlog.records[]?
        | select(.state == "done")
        | select((.id as $id | $live | index($id) | not))
        | select((.completion.date // "") >= $yesterday)
        | . as $r
        | (if ($r.completion.date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then $r.completion.date else null end) as $cdate
        | (if ($r.since // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then $r.since + "T00:00:00Z" else null end) as $since
        | (if $cdate == null then $generated_at else $cdate + "T23:59:59Z" end) as $ended
        | {
          id: $r.id,
          title: ((($r.title // $r.id) | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          project: ((($r.repo // "?") | tostring | split("/") | last) | if . == "" then "?" else . end),
          kind: (($r.kind // "") | tostring),
          state: "done",
          detail: ((($r.completion.verb // "done") | tostring) | gsub("[\u0000-\u001f]"; " ") | if length > 300 then .[:297] + "..." else . end),
          startedAt: ($since // $ended),
          firstStartedAt: ($since // $ended),
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
