#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-tasks-report.sh"
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# tui-dash abandons this report after 15s, and a loaded host runs it at several
# times the fixture's cost.
BUDGET_SECS=${FM_TASKS_REPORT_BUDGET_SECS:-6}

TMP_ROOT=$(fm_test_tmproot fm-tasks-report-budget)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX"
export HOME="$HOME_FIX"
unset FM_HOME FM_TASKS_HOMES TASKS_AXI_FILE TASKS_AXI_BACKEND

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat >"$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/no-mistakes"
export PATH="$FAKEBIN:$PATH"

TODAY=$(date -u +%F)
SPAWN_E=$(( $(date -u +%s) - 3600 ))
SPAWN_T=$(jq -n --argjson e "$SPAWN_E" -r '$e | strftime("%Y-%m-%dT%H:%M:%SZ")')

EXPECTED_PLANNED="$TMP_ROOT/expected-planned.jsonl"
EXPECTED_LIVE="$TMP_ROOT/expected-live.jsonl"
: >"$EXPECTED_PLANNED"
: >"$EXPECTED_LIVE"

make_home() {  # <name> <ready> <held> <blocked> <live>
  local name=$1 ready=$2 held=$3 blocked=$4 live=$5 home="$TMP_ROOT/$1" i id kind wt
  local held_kinds=(captain external load)
  mkdir -p "$home/data" "$home/state" "$home/bin"
  printf '## In flight\n\n## Queued\n\n## Done\n' >"$home/data/backlog.md"
  fm_test_tasks_toml "$home/.tasks.toml"
  # Rows are added interleaved, so dispatch order differs from queue order.
  for i in $(seq 1 "$held"); do
    id="$name-held-$i"
    FM_HOME="$home" "$TASKS_AXI" add "$id" "Held $i, waiting" --kind scout >/dev/null || fail "fixture add $id"
    kind=${held_kinds[$(( (i - 1) % 3 ))]}
    FM_HOME="$home" "$TASKS_AXI" hold "$id" --reason "reason $i" --kind "$kind" >/dev/null || fail "fixture hold $id"
    case "$kind" in captain|external) ;; *) kind=unstated ;; esac
    jq -nc --arg id "$id" --arg i "$i" --arg home "$name" --arg today "$TODAY" --arg kind "$kind" \
      '{group: 2, row: {id: $id, title: "Held \($i), waiting", project: "?", kind: "scout", home: $home,
        queuedOn: $today, hold: {kind: $kind, reason: "reason \($i)"}, after: []}}' >>"$EXPECTED_PLANNED"
    if [ "$i" -le "$ready" ]; then
      id="$name-ready-$i"
      FM_HOME="$home" "$TASKS_AXI" add "$id" "Ready $i" --kind ship --repo "org/repo-$i" >/dev/null || fail "fixture add $id"
      jq -nc --arg id "$id" --arg i "$i" --arg home "$name" --arg today "$TODAY" \
        '{group: 1, row: {id: $id, title: "Ready \($i)", project: "repo-\($i)", kind: "ship", home: $home,
          queuedOn: $today, hold: null, after: []}}' >>"$EXPECTED_PLANNED"
    fi
  done
  for i in $(seq 1 "$blocked"); do
    id="$name-blocked-$i"
    FM_HOME="$home" "$TASKS_AXI" add "$id" "Blocked $i" --kind ship --blocked-by "$name-ready-1" >/dev/null || fail "fixture add $id"
    jq -nc --arg id "$id" --arg i "$i" --arg home "$name" --arg today "$TODAY" --arg a "$name-ready-1" \
      '{group: 3, row: {id: $id, title: "Blocked \($i)", project: "?", kind: "ship", home: $home,
        queuedOn: $today, hold: null, after: [$a]}}' >>"$EXPECTED_PLANNED"
  done
  for i in $(seq 1 "$live"); do
    id="$name-live-$i"
    wt="$TMP_ROOT/wt-$id"
    mkdir -p "$wt"
    fm_write_meta "$home/state/$id.meta" kind=ship mode=direct-PR "branch=fm/$id" project=/w/checks \
      "spawn_gen=s$SPAWN_E.$i.1" "worktree=$wt"
    jq -nc --arg id "$id" --arg home "$name" --arg t "$SPAWN_T" --arg wt "$wt" \
      '{home: $home, row: {id: $id, title: $id, project: "checks", kind: "quick fix", state: "working",
        detail: "busy", startedAt: $t, firstStartedAt: $t, endedAt: null, folders: [$wt], branches: ["fm/\($id)"]}}' >>"$EXPECTED_LIVE"
  done
  ln -s "$ROOT"/bin/* "$home/bin/"
  rm "$home/bin/fm-crew-state.sh"
  cat >"$home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working \u00b7 source: pane \u00b7 busy\n'
SH
  chmod +x "$home/bin/fm-crew-state.sh"
}

make_home fm-budget-a 6 8 6 4
make_home fm-budget-b 3 4 3 2
HOME_A="$TMP_ROOT/fm-budget-a"
HOME_B="$TMP_ROOT/fm-budget-b"

OUT="$TMP_ROOT/out.json"
start=$(date +%s)
FM_TASKS_HOMES="$HOME_B:$HOME_A" bash "$REPORT" >"$OUT" 2>"$TMP_ROOT/stderr.log" || { cat "$TMP_ROOT/stderr.log"; fail "report exits non-zero"; }
elapsed=$(( $(date +%s) - start ))
[ "$(wc -l <"$OUT")" -eq 1 ] || fail "report is not one line"

# Dispatch order from the report help: each home's ready rows, then held, then
# blocked, homes in sorted path order.
EXPECTED="$TMP_ROOT/expected.json"
jq -n --arg a "$HOME_A" --arg b "$HOME_B" --slurpfile planned "$EXPECTED_PLANNED" --slurpfile live "$EXPECTED_LIVE" '
  ($planned | group_by(.row.home) | map(sort_by(.group) | map(.row)) | add) as $p
  | {schemaVersion: 1,
     orchestrator: {name: "firstmate"},
     tasks: ($live | group_by(.home) | map(map(.row) | sort_by(.id)) | add),
     overhead: [{name: "fm-budget-a", folders: [$a]}, {name: "fm-budget-b", folders: [$b]}],
     schedules: [],
     planned: $p}' >"$EXPECTED"
jq -e '[.planned[].id] | length == 30' "$EXPECTED" >/dev/null || fail "expected fixture holds thirty planned rows"
jq -e '.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$OUT" >/dev/null || fail "generatedAt is an instant"
jq -e '.orchestrator.version | type == "string" and length > 0' "$OUT" >/dev/null || fail "orchestrator version is named"
ACTUAL="$TMP_ROOT/actual.json"
jq -c 'del(.generatedAt, .orchestrator.version)' "$OUT" >"$ACTUAL"
if [ "$(jq -c . "$EXPECTED")" != "$(cat "$ACTUAL")" ]; then
  diff <(jq -c '.planned[]' "$EXPECTED") <(jq -c '.planned[]' "$ACTUAL") >&2
  diff <(jq -c 'del(.planned)' "$EXPECTED") <(jq -c 'del(.planned)' "$ACTUAL") >&2
  fail "report differs from the v1 document the fixture defines, key order included"
fi
pass "a realistic two-home fleet reads as the expected v1 report"

[ "$elapsed" -le "$BUDGET_SECS" ] || fail "report took ${elapsed}s, over the ${BUDGET_SECS}s budget"
pass "a realistic two-home fleet reports within ${BUDGET_SECS}s (took ${elapsed}s)"
