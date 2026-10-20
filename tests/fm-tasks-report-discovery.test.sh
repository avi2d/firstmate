#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-tasks-report.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-tasks-report-discovery)
EMPTY_HOME="$TMP_ROOT/home"
mkdir -p "$EMPTY_HOME"
export HOME="$EMPTY_HOME"
unset FM_HOME
unset FM_TASKS_HOMES

REPO="$TMP_ROOT/repohome"
mkdir -p "$REPO/bin" "$REPO/state" "$REPO/data"
ln -s "$ROOT"/bin/* "$REPO/bin/"
rm -f "$REPO/bin/fm-tasks-report.sh"
cp "$REPORT" "$REPO/bin/fm-tasks-report.sh"
printf '# Backlog\n' > "$REPO/data/backlog.md"

OUT="$TMP_ROOT/out.json"
bash "$REPO/bin/fm-tasks-report.sh" >"$OUT" 2>"$TMP_ROOT/stderr.log" || { cat "$TMP_ROOT/stderr.log"; fail "report finds the repo home with no homes configured"; }
[ "$(wc -l <"$OUT")" -eq 1 ] || fail "report is not one line"
jq -e --arg repo "$REPO" '(.overhead | sort_by(.name)) == [{name: "repohome", folders: [$repo]}]' "$OUT" >/dev/null || fail "overhead names the serving repo home"
jq -e '.tasks == []' "$OUT" >/dev/null || fail "empty home reports no tasks"

pass "tasks report discovers the serving repo home with FM_TASKS_HOMES unset"
