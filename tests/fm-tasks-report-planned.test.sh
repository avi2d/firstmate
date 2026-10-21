#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-tasks-report.sh"
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# Oracle: the dashboard's PlannedJson row shape (id, title, project, kind,
# home, queuedOn nullable date, hold nullable {kind, reason} with kind
# captain|external|unstated, after = blocked_by ids), in tasks-axi dispatch
# order: ready rows first, then held, then blocked.

TMP_ROOT=$(fm_test_tmproot fm-tasks-report-planned)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX"
export HOME="$HOME_FIX"
unset FM_HOME
unset FM_TASKS_HOMES
unset TASKS_AXI_FILE TASKS_AXI_BACKEND

TODAY=$(date -u +%F)

make_queue_home() {
  mkdir -p "$1/data" "$1/state"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1/data/backlog.md"
  fm_test_tasks_toml "$1/.tasks.toml"
}

HOME_A="$TMP_ROOT/fm-home-a"
HOME_B="$TMP_ROOT/fm-home-b"
make_queue_home "$HOME_A"
make_queue_home "$HOME_B"

FM_HOME="$HOME_A" "$TASKS_AXI" add plan-ready-1 "Ready one" --kind ship --repo checks >/dev/null
FM_HOME="$HOME_A" "$TASKS_AXI" add plan-held-1 "Held one" --kind scout >/dev/null
FM_HOME="$HOME_A" "$TASKS_AXI" hold plan-held-1 --reason "captain pick pending" --kind captain >/dev/null
FM_HOME="$HOME_A" "$TASKS_AXI" add plan-load-1 "Load one" --kind ship >/dev/null
FM_HOME="$HOME_A" "$TASKS_AXI" hold plan-load-1 --reason "runner is full" --kind load >/dev/null
FM_HOME="$HOME_A" "$TASKS_AXI" add plan-blocked-1 "Blocked one" --kind ship --blocked-by plan-ready-1 >/dev/null

OUT="$TMP_ROOT/out.json"
FM_TASKS_HOMES="$HOME_A:$HOME_B" bash "$REPORT" >"$OUT" 2>"$TMP_ROOT/stderr.log" || { cat "$TMP_ROOT/stderr.log"; fail "report exits non-zero"; }
[ "$(wc -l <"$OUT")" -eq 1 ] || fail "report is not one line"

jq -e '(. | keys | sort) == ["generatedAt","orchestrator","overhead","planned","schedules","schemaVersion","tasks"]' "$OUT" >/dev/null || fail "planned key joins the top-level field set"
jq -e '(.planned | map(keys | sort) | unique) == [["after","hold","home","id","kind","project","queuedOn","title"]]' "$OUT" >/dev/null || fail "planned row field set"
jq -e '[.planned[].id] == ["plan-ready-1","plan-held-1","plan-load-1","plan-blocked-1"]' "$OUT" >/dev/null || fail "planned rows read ready, held, then blocked"

jq -e --arg today "$TODAY" '.planned[0] == {id: "plan-ready-1", title: "Ready one", project: "checks", kind: "ship", home: "fm-home-a", queuedOn: $today, hold: null, after: []}' "$OUT" >/dev/null || fail "ready row carries queue fields with no hold and no blockers"

jq -e --arg today "$TODAY" '.planned[1] == {id: "plan-held-1", title: "Held one", project: "?", kind: "scout", home: "fm-home-a", queuedOn: $today, hold: {kind: "captain", reason: "captain pick pending"}, after: []}' "$OUT" >/dev/null || fail "captain-held row carries its hold kind and reason"

jq -e '.planned[2].hold == {kind: "unstated", reason: "runner is full"}' "$OUT" >/dev/null || fail "a non-dashboard hold kind reads as unstated"

jq -e --arg today "$TODAY" '.planned[3] == {id: "plan-blocked-1", title: "Blocked one", project: "?", kind: "ship", home: "fm-home-a", queuedOn: $today, hold: null, after: ["plan-ready-1"]}' "$OUT" >/dev/null || fail "blocked row carries its blocker ids with no hold"

EMPTY_OUT="$TMP_ROOT/empty.json"
FM_TASKS_HOMES="$HOME_B" bash "$REPORT" >"$EMPTY_OUT" 2>"$TMP_ROOT/empty-stderr.log" || { cat "$TMP_ROOT/empty-stderr.log"; fail "empty report exits non-zero"; }
jq -e 'has("planned") | not' "$EMPTY_OUT" >/dev/null || fail "a home with no queued work omits planned"

pass "tasks report carries the queue as planned in dispatch order"
