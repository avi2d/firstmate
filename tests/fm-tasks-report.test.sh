#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-tasks-report.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TUI_DASH_CONTRACT_SOURCE="tui-dash packages/schema/src/contract/tasks.ts and recorded fixture tests/fixtures/tasks/winbox.json"
[ -n "$TUI_DASH_CONTRACT_SOURCE" ] || exit 1

TMP_ROOT=$(fm_test_tmproot fm-tasks-report)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX"
export HOME="$HOME_FIX"
unset FM_HOME
unset FM_TASKS_HOMES

TODAY=$(date -u +%F)
PLUS7=$(jq -n --arg d "$TODAY" '$d | strptime("%Y-%m-%d") | mktime + 7*86400 | strftime("%Y-%m-%d")' -r)
MINUS3=$(jq -n --arg d "$TODAY" '$d | strptime("%Y-%m-%d") | mktime - 3*86400 | strftime("%Y-%m-%d")' -r)
NOON=$(jq -n --arg d "$TODAY" '$d + "T12:00:00Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime')

WT_A="$TMP_ROOT/wt-a"
WT_C="$TMP_ROOT/wt-c"
mkdir -p "$WT_A" "$WT_C"
RUN_LIVE="01K7LIVE000000000000000001"
RUN_DONE="01K7DONE000000000000000002"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$RUN_LIVE"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$RUN_DONE"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "axi" ]; then
  printf '%s\n' 'current_branch: main' 'runs_on_current_branch: 2' 'runs[2]{id,branch,status,head,pr}:' '  "$RUN_LIVE",fm/alpha-ship,running,aaaa1111,""' '  "$RUN_DONE",fm/alpha-ship,completed,bbbb2222,""'
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"

make_home() {
  mkdir -p "$1/state" "$1/bin"
}

write_snap() {
  cat > "$1/bin/fm-fleet-snapshot.sh" <<SH
#!/usr/bin/env bash
cat "$2"
SH
  chmod +x "$1/bin/fm-fleet-snapshot.sh"
}

ALPHA="$HOME_FIX/fm-alpha"
BETA="$HOME_FIX/fm-beta"
make_home "$ALPHA"
make_home "$BETA"

ALPHA_SNAP="$TMP_ROOT/alpha.json"
BETA_SNAP="$TMP_ROOT/beta.json"
cat > "$ALPHA_SNAP" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "fm_home": "$ALPHA",
  "tasks": [
    {
      "id": "alpha-ship", "kind": "ship", "branch": "fm/alpha-ship",
      "project": "/w/checks", "spawn_gen": "s${NOON}.1.1",
      "paths": {"worktree": {"present": true, "path": "$WT_A"}},
      "current_state": {"state": "working", "detail": "validating"},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Alpha ship", "since": "$MINUS3", "completion": {"date": null, "verb": null}, "raw": "SECRET-MARKER-RAW"}
    },
    {
      "id": "alpha-parked", "kind": "scout", "branch": "fm/alpha-parked",
      "project": "/w/tui-dash", "spawn_gen": "s${NOON}.2.2",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "parked", "detail": ""},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Alpha parked", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "alpha-paused", "kind": "ship", "branch": "fm/alpha-paused",
      "project": "/w/checks", "spawn_gen": "s${NOON}.3.3",
      "paths": {"worktree": {"present": true, "path": "$WT_C"}},
      "current_state": {"state": "paused", "detail": "waiting on load"},
      "hints": {"blocked_event": false, "pending_decision": true},
      "backlog": {"title": "Alpha paused", "since": null, "completion": {"date": null, "verb": null}}
    }
  ],
  "backlog": {"records": [
    {"id": "alpha-done-recent", "title": "Recent done", "repo": "tui-dash", "kind": "ship", "state": "done", "done": null, "hold_until": null, "hold_reason": null, "since": null, "completion": {"date": "$TODAY", "verb": "merged"}, "body_lines": ["SECRET-MARKER-BODY"]},
    {"id": "alpha-done-old", "title": "Old done", "repo": "tui-dash", "kind": "ship", "state": "done", "done": null, "hold_until": null, "hold_reason": null, "since": null, "completion": {"date": "$MINUS3", "verb": "merged"}},
    {"id": "alpha-hold", "title": "Held", "repo": "checks", "kind": "ship", "state": "queued", "done": null, "hold_until": "$PLUS7", "hold_reason": "revisit", "since": "$TODAY", "completion": {"date": null, "verb": null}}
  ]}
}
JSON
cat > "$BETA_SNAP" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "fm_home": "$BETA",
  "tasks": [
    {
      "id": "beta-wait", "kind": "ship", "branch": "fm/beta-wait",
      "project": "/w/website", "spawn_gen": "s${NOON}.4.4",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "unknown", "detail": ""},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Beta wait", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "beta-blocked", "kind": "ship", "branch": "fm/beta-blocked",
      "project": "/w/website", "spawn_gen": "s${NOON}.5.5",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "working", "detail": "stuck"},
      "hints": {"blocked_event": true, "pending_decision": false},
      "backlog": {"title": "Beta blocked", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "beta-livedone", "kind": "ship", "branch": "fm/beta-livedone",
      "project": "/w/skills", "spawn_gen": "s${NOON}.6.6",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "done", "detail": "landed"},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Beta livedone", "since": null, "completion": {"date": "$TODAY", "verb": "merged"}}
    }
  ],
  "backlog": {"records": []}
}
JSON
write_snap "$ALPHA" "$ALPHA_SNAP"
write_snap "$BETA" "$BETA_SNAP"

OUT="$TMP_ROOT/out.json"
bash "$REPORT" >"$OUT" 2>"$TMP_ROOT/stderr.log" || { cat "$TMP_ROOT/stderr.log"; fail "report exits non-zero"; }
[ "$(wc -l <"$OUT")" -eq 1 ] || fail "report is not one line"


jq -e '(. | keys | sort) == ["generatedAt","orchestrator","overhead","schedules","schemaVersion","tasks"]' "$OUT" >/dev/null || fail "top-level field set"
jq -e '.schemaVersion == 1' "$OUT" >/dev/null || fail "schemaVersion is 1"
jq -e '.orchestrator.name == "firstmate" and (.orchestrator.version | type == "string" and length > 0)' "$OUT" >/dev/null || fail "orchestrator identity"
jq -e '.generatedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime > 0' "$OUT" >/dev/null || fail "generatedAt is an instant"
jq -e '(.tasks | map(keys | sort) | unique) == [["branches","detail","endedAt","firstStartedAt","folders","id","kind","project","startedAt","state","title"]]' "$OUT" >/dev/null || fail "task field set"
jq -e '[.tasks[].state] | inside(["working","waiting","parked","blocked","done"])' "$OUT" >/dev/null || fail "task states are contract states"
jq -e '[.tasks[] | select(.state == "done") | .endedAt != null] | all' "$OUT" >/dev/null || fail "done tasks carry endedAt"
jq -e '[.tasks[] | select(.state != "done") | .endedAt == null] | all' "$OUT" >/dev/null || fail "live tasks carry null endedAt"
jq -e '[.tasks[] | ((.startedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $s | (.firstStartedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $f | $f <= $s)] | all' "$OUT" >/dev/null || fail "firstStartedAt precedes startedAt"
jq -e '[.tasks[].id] | contains(["alpha-ship","alpha-parked","alpha-paused","beta-wait","beta-blocked","beta-livedone","alpha-done-recent"])' "$OUT" >/dev/null || fail "live and recent-done tasks listed"
jq -e '[.tasks[].id] | index("alpha-done-old") | not' "$OUT" >/dev/null || fail "done tasks older than a day dropped"
jq -e '.tasks[] | select(.id == "alpha-ship") | .state == "working" and .branches == ["fm/alpha-ship"] and .project == "checks"' "$OUT" >/dev/null || fail "alpha-ship identity"
jq -e --arg wt "$WT_A" --arg run "$HOME_FIX/.no-mistakes/worktrees/deadbee/$RUN_LIVE" '.tasks[] | select(.id == "alpha-ship") | .folders | contains([$wt, $run])' "$OUT" >/dev/null || fail "alpha-ship folders hold worktree and live pipeline folder"
jq -e --arg dead "$HOME_FIX/.no-mistakes/worktrees/deadbee/$RUN_DONE" '.tasks[] | select(.id == "alpha-ship") | .folders | index($dead) | not' "$OUT" >/dev/null || fail "completed pipeline folder excluded"
jq -e --arg since "${MINUS3}T00:00:00Z" '.tasks[] | select(.id == "alpha-ship") | .firstStartedAt == $since' "$OUT" >/dev/null || fail "relaunch-proof firstStartedAt from since"
jq -e '.tasks[] | select(.id == "alpha-parked") | .state == "parked" and .folders == []' "$OUT" >/dev/null || fail "parked task without worktree"
jq -e '.tasks[] | select(.id == "alpha-paused") | .state == "waiting"' "$OUT" >/dev/null || fail "paused maps to waiting"
jq -e '.tasks[] | select(.id == "beta-wait") | .state == "waiting"' "$OUT" >/dev/null || fail "unknown maps to waiting"
jq -e '.tasks[] | select(.id == "beta-blocked") | .state == "blocked"' "$OUT" >/dev/null || fail "blocked event escalates to blocked"
jq -e --arg end "${TODAY}T23:59:59Z" '.tasks[] | select(.id == "beta-livedone") | .state == "done" and .endedAt == $end' "$OUT" >/dev/null || fail "live done task ends on completion date"
jq -e '.tasks[] | select(.id == "alpha-done-recent") | .state == "done" and .branches == ["fm/alpha-done-recent"] and .folders == []' "$OUT" >/dev/null || fail "recent done keeps branch, drops folders"
jq -e --arg at "${PLUS7}T00:00:00Z" '.schedules == [{name: "alpha-hold", at: $at, detail: "revisit"}]' "$OUT" >/dev/null || fail "dated hold listed as schedule"
jq -e --arg a "$ALPHA" --arg b "$BETA" '(.overhead | sort_by(.name)) == [{name: "fm-alpha", folders: [$a]}, {name: "fm-beta", folders: [$b]}]' "$OUT" >/dev/null || fail "overhead names each home"
! grep -q "SECRET-MARKER" "$OUT" || fail "prompt-adjacent record text leaks into output"

pass "tasks report v1 matches the tui-dash fixture field set"
