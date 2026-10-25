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
NOW_EPOCH=$(date -u +%s)
SPAWN_E=$((NOW_EPOCH - 3600))
FIRST_E=$((NOW_EPOCH - 7200))
SPAWN_T=$(jq -n --argjson e "$SPAWN_E" -r '$e | strftime("%Y-%m-%dT%H:%M:%SZ")')
FIRST_T=$(jq -n --argjson e "$FIRST_E" -r '$e | strftime("%Y-%m-%dT%H:%M:%SZ")')
iso() { jq -n --argjson e "$1" -r '$e | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
ARCH_START=$((NOW_EPOCH - 5400))
ARCH_DONE=$((NOW_EPOCH - 1800))
LOG_START=$((NOW_EPOCH - 4000))
LOG_DONE=$((NOW_EPOCH - 2500))
LIVE_DONE=$((NOW_EPOCH - 900))

WT_A="$TMP_ROOT/wt-a"
WT_B="$TMP_ROOT/wt-b"
WT_C="$TMP_ROOT/wt-c"
mkdir -p "$WT_A" "$WT_B" "$WT_C"
BLOCK_LIVE="01M59YM5QJX75TTNNAW2ZQ0AKH"
BLOCK_DONE="01M59OLD0000000000000000000"
CSV_LIVE="9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z9Z"
CSV_OTHER="8Y8Y8Y8Y8Y8Y8Y8Y8Y8Y8Y8Y"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$BLOCK_LIVE"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$BLOCK_DONE"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$CSV_LIVE"
mkdir -p "$HOME_FIX/.no-mistakes/worktrees/deadbee/$CSV_OTHER"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "axi" ] && [ "\$PWD" = "$WT_A" ]; then
  printf '%s\n' 'run:' '  id: "$BLOCK_LIVE"' '  branch: fm/alpha-ship' '  status: running' '  head: abc123'
  printf '%s\n' 'run:' '  id: "$BLOCK_DONE"' '  branch: fm/alpha-ship' '  status: completed' '  head: def456'
  exit 0
fi
if [ "\${1:-}" = "axi" ] && [ "\$PWD" = "$WT_B" ]; then
  printf '%s\n' 'runs[2]{id,branch,status,head}:' '  "$CSV_LIVE",fm/beta-wait,running,aaaa1111' '  "$CSV_OTHER",fm/beta-other,running,bbbb2222'
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
      "project": "/w/checks", "spawn_gen": "s${SPAWN_E}.1.1", "first_spawn_gen": "s${FIRST_E}.9.9",
      "paths": {"worktree": {"present": true, "path": "$WT_A"}},
      "current_state": {"state": "working", "detail": "validating"},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Alpha ship", "since": "$MINUS3", "completion": {"date": null, "verb": null}, "raw": "SECRET-MARKER-RAW"}
    },
    {
      "id": "alpha-parked", "kind": "scout", "branch": "fm/alpha-parked",
      "project": "/w/tui-dash", "spawn_gen": "s${SPAWN_E}.2.2",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "parked", "detail": ""},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Alpha parked", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "alpha-paused", "kind": "ship", "branch": "fm/alpha-paused",
      "project": "/w/checks", "spawn_gen": "s${SPAWN_E}.3.3",
      "paths": {"worktree": {"present": true, "path": "$WT_C"}},
      "current_state": {"state": "paused", "detail": "waiting on load"},
      "hints": {"blocked_event": false, "pending_decision": true},
      "backlog": {"title": "Alpha paused", "since": null, "completion": {"date": null, "verb": null}}
    }
  ],
  "backlog": {"records": [
    {"id": "alpha-done-recent", "title": "Recent done", "repo": "tui-dash", "kind": "ship", "state": "done", "done": null, "hold_until": null, "hold_reason": null, "since": null, "completion": {"date": "$TODAY", "verb": "merged"}, "body_lines": ["SECRET-MARKER-BODY"]},
    {"id": "alpha-done-archived", "title": "Archived done", "repo": "checks", "kind": "ship", "state": "done", "done": null, "hold_until": null, "hold_reason": null, "since": null, "completion": {"date": "$TODAY", "verb": "merged"}},
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
      "project": "/w/website", "spawn_gen": "s${SPAWN_E}.4.4",
      "paths": {"worktree": {"present": true, "path": "$WT_B"}},
      "current_state": {"state": "unknown", "detail": ""},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Beta wait", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "beta-blocked", "kind": "ship", "branch": "fm/beta-blocked",
      "project": "/w/website", "spawn_gen": "s${SPAWN_E}.5.5",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "working", "detail": "stuck"},
      "hints": {"blocked_event": true, "pending_decision": false},
      "backlog": {"title": "Beta blocked", "since": null, "completion": {"date": null, "verb": null}}
    },
    {
      "id": "beta-livedone", "kind": "ship", "branch": "fm/beta-livedone",
      "project": "/w/skills", "spawn_gen": "s${SPAWN_E}.6.6",
      "paths": {"worktree": {"present": false}},
      "current_state": {"state": "done", "detail": "landed"},
      "hints": {"blocked_event": false, "pending_decision": false},
      "backlog": {"title": "Beta livedone", "since": null, "completion": {"date": "$TODAY", "verb": "merged"}}
    }
  ],
  "backlog": {"records": [
    {"id": "beta-done-logged", "title": "Logged done", "repo": "website", "kind": "scout", "state": "done", "done": null, "hold_until": null, "hold_reason": null, "since": null, "completion": {"date": "$TODAY", "verb": "reported"}}
  ]}
}
JSON
write_snap "$ALPHA" "$ALPHA_SNAP"
write_snap "$BETA" "$BETA_SNAP"

write_meta() {
  local home=$1 id=$2 kind=$3 branch=$4 project=$5 spawn=$6 first=$7 worktree=$8
  {
    printf 'kind=%s\n' "$kind"
    printf 'branch=%s\n' "$branch"
    printf 'project=%s\n' "$project"
    printf 'spawn_gen=%s\n' "$spawn"
    printf 'first_spawn_gen=%s\n' "$first"
    printf 'worktree=%s\n' "$worktree"
  } > "$home/state/$id.meta"
}

write_crew_stub() {
  cat > "$1/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  alpha-ship) printf 'state: working \u00b7 source: run-step \u00b7 validating\n' ;;
  alpha-parked) printf 'state: parked \u00b7 source: status-log \u00b7 \n' ;;
  alpha-paused) printf 'state: paused \u00b7 source: status-log \u00b7 waiting on load\n' ;;
  beta-wait) printf 'state: unknown \u00b7 source: none \u00b7 \n' ;;
  beta-blocked) printf 'state: working \u00b7 source: status-log \u00b7 stuck\n' ;;
  beta-livedone) printf 'state: done \u00b7 source: status-log \u00b7 landed\n' ;;
  *) printf 'state: unknown \u00b7 source: none \u00b7 \n' ;;
esac
SH
  chmod +x "$1/bin/fm-crew-state.sh"
}

write_meta "$ALPHA" alpha-ship ship fm/alpha-ship /w/checks "s${SPAWN_E}.1.1" "s${FIRST_E}.9.9" "$WT_A"
write_meta "$ALPHA" alpha-parked scout fm/alpha-parked /w/tui-dash "s${SPAWN_E}.2.2" "" ""
write_meta "$ALPHA" alpha-paused ship fm/alpha-paused /w/checks "s${SPAWN_E}.3.3" "" ""
write_meta "$BETA" beta-wait ship fm/beta-wait /w/website "s${SPAWN_E}.4.4" "" "$WT_B"
write_meta "$BETA" beta-blocked ship fm/beta-blocked /w/website "s${SPAWN_E}.5.5" "" ""
write_meta "$BETA" beta-livedone ship fm/beta-livedone /w/skills "s${SPAWN_E}.6.6" "" ""
write_crew_stub "$ALPHA"
write_crew_stub "$BETA"
printf '%s\n' "blocked [key=net] [at=$NOW_EPOCH]: CI runner unreachable" > "$BETA/state/beta-blocked.status"
printf '%s\n' "working [at=$SPAWN_E]: setup done" "done [at=$LIVE_DONE]: landed" > "$BETA/state/beta-livedone.status"
mkdir -p "$ALPHA/state/status-archive/alpha-done-archived"
printf '%s\n' "working [at=$((NOW_EPOCH - 900000))]: setup done" "done [at=$((NOW_EPOCH - 899000))]: PR https://example.invalid/pr/1" \
  > "$ALPHA/state/status-archive/alpha-done-archived/$((NOW_EPOCH - 898000)).111.status"
printf '%s\n' "working [at=$ARCH_START]: setup done" \
  "blocked [key=ci] [at=$((ARCH_START + 60))]: runner quotes [at=1]" \
  "resolved [key=ci] [at=$((ARCH_START + 120))]: runner back" \
  "done [at=$ARCH_DONE]: PR https://example.invalid/pr/2" \
  "working [at=$((ARCH_DONE + 300))]: answering a follow-up" \
  > "$ALPHA/state/status-archive/alpha-done-archived/$((ARCH_DONE + 600)).222.status"
mkdir -p "$BETA/data/beta-done-logged"
printf '%s\n' "working [at=$((NOW_EPOCH - 800000))]: setup done" "done [at=$((NOW_EPOCH - 799000))]: report ready" \
  > "$BETA/data/beta-done-logged/status.log"
printf '%s\n' "working [at=$LOG_START]: setup done" "done [at=$LOG_DONE]: report ready" \
  > "$BETA/data/beta-done-logged/status.1.log"

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
jq -e '[.tasks[].firstStartedAt | test("T00:00:00Z$")] | any | not' "$OUT" >/dev/null || fail "no task starts at midnight"
jq -e --arg now "$(date -u +%s)" '[.tasks[] | select(.state == "done") | ((.endedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) | . <= ($now | tonumber))] | all' "$OUT" >/dev/null || fail "done tasks end no later than the read"
jq -e '[.tasks[].id] | contains(["alpha-ship","alpha-parked","alpha-paused","beta-wait","beta-blocked","beta-livedone","alpha-done-recent"])' "$OUT" >/dev/null || fail "live and recent-done tasks listed"
jq -e '[.tasks[].id] | index("alpha-done-old") | not' "$OUT" >/dev/null || fail "done tasks older than a day dropped"
jq -e '.tasks[] | select(.id == "alpha-ship") | .state == "working" and .branches == ["fm/alpha-ship"] and .project == "checks"' "$OUT" >/dev/null || fail "alpha-ship identity"
jq -e --arg wt "$WT_A" --arg run "$HOME_FIX/.no-mistakes/worktrees/deadbee/$BLOCK_LIVE" '.tasks[] | select(.id == "alpha-ship") | .folders | contains([$wt, $run])' "$OUT" >/dev/null || fail "alpha-ship folders hold worktree and running run-block folder"
jq -e --arg dead "$HOME_FIX/.no-mistakes/worktrees/deadbee/$BLOCK_DONE" '.tasks[] | select(.id == "alpha-ship") | .folders | index($dead) | not' "$OUT" >/dev/null || fail "completed run-block folder excluded"
jq -e --arg first "${FIRST_T}" --arg start "${SPAWN_T}" '.tasks[] | select(.id == "alpha-ship") | .firstStartedAt == $first and .startedAt == $start' "$OUT" >/dev/null || fail "firstStartedAt reads the earliest recorded launch, startedAt the latest spawn"
jq -e --arg wt "$WT_B" --arg run "$HOME_FIX/.no-mistakes/worktrees/deadbee/$CSV_LIVE" '.tasks[] | select(.id == "beta-wait") | .folders | contains([$wt, $run])' "$OUT" >/dev/null || fail "beta-wait folders hold worktree and running list folder"
jq -e --arg other "$HOME_FIX/.no-mistakes/worktrees/deadbee/$CSV_OTHER" '.tasks[] | select(.id == "beta-wait") | .folders | index($other) | not' "$OUT" >/dev/null || fail "other-branch pipeline folder excluded"
jq -e --arg start "${SPAWN_T}" '.tasks[] | select(.id == "alpha-parked") | .firstStartedAt == $start and .startedAt == $start' "$OUT" >/dev/null || fail "missing first launch falls back to the latest spawn"
jq -e '.tasks[] | select(.id == "alpha-parked") | .state == "parked" and .folders == []' "$OUT" >/dev/null || fail "parked task without worktree"
jq -e '.tasks[] | select(.id == "alpha-paused") | .state == "waiting"' "$OUT" >/dev/null || fail "paused maps to waiting"
jq -e '.tasks[] | select(.id == "beta-wait") | .state == "waiting"' "$OUT" >/dev/null || fail "unknown maps to waiting"
jq -e '.tasks[] | select(.id == "beta-blocked") | .state == "blocked"' "$OUT" >/dev/null || fail "blocked event escalates to blocked"
jq -e --arg start "${SPAWN_T}" --arg end "$(iso "$LIVE_DONE")" '.tasks[] | select(.id == "beta-livedone") | .state == "done" and .startedAt == $start and .firstStartedAt == $start and .endedAt == $end' "$OUT" >/dev/null || fail "live done task starts at spawn and ends at its recorded done line"
jq -e --arg start "$(iso "$ARCH_START")" --arg end "$(iso "$ARCH_DONE")" '.tasks[] | select(.id == "alpha-done-archived") | .startedAt == $start and .firstStartedAt == $start and .endedAt == $end' "$OUT" >/dev/null || fail "archived done task spans its latest archived status stream, first line to done line"
jq -e --arg start "$(iso "$LOG_START")" --arg end "$(iso "$LOG_DONE")" '.tasks[] | select(.id == "beta-done-logged") | .startedAt == $start and .firstStartedAt == $start and .endedAt == $end' "$OUT" >/dev/null || fail "done task spans its latest status log under data"
jq -e '.tasks[] | select(.id == "alpha-done-recent") | .startedAt == .endedAt and .firstStartedAt == .endedAt' "$OUT" >/dev/null || fail "finished record without launch instants reads start as end"
jq -e '.tasks[] | select(.id == "alpha-done-recent") | .state == "done" and .branches == ["fm/alpha-done-recent"] and .folders == []' "$OUT" >/dev/null || fail "recent done keeps branch, drops folders"
jq -e --arg at "${PLUS7}T00:00:00Z" '.schedules == [{name: "alpha-hold", at: $at, detail: "revisit"}]' "$OUT" >/dev/null || fail "dated hold listed as schedule"
jq -e --arg a "$ALPHA" --arg b "$BETA" '(.overhead | sort_by(.name)) == [{name: "fm-alpha", folders: [$a]}, {name: "fm-beta", folders: [$b]}]' "$OUT" >/dev/null || fail "overhead names each home"
! grep -q "SECRET-MARKER" "$OUT" || fail "prompt-adjacent record text leaks into output"

pass "tasks report v1 matches the tui-dash fixture field set"
