#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-tasks-report.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-tasks-report-kind)
HOME_FIX="$TMP_ROOT/home"
mkdir -p "$HOME_FIX"
export HOME="$HOME_FIX"
unset FM_HOME

NOW_EPOCH=$(date -u +%s)
SPAWN_E=$((NOW_EPOCH - 3600))

KHOME="$TMP_ROOT/fm-kind"
mkdir -p "$KHOME/state" "$KHOME/bin"
export FM_TASKS_HOMES="$KHOME"

cat > "$KHOME/bin/fm-fleet-snapshot.sh" <<JSON
#!/usr/bin/env bash
printf '%s\n' '{"backlog":{"records":[]}}'
JSON
chmod +x "$KHOME/bin/fm-fleet-snapshot.sh"

cat > "$KHOME/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown \u00b7 source: none \u00b7 \n'
SH
chmod +x "$KHOME/bin/fm-crew-state.sh"

write_meta() {
  {
    printf 'kind=%s\n' "$2"
    printf 'branch=%s\n' "fm/$1"
    printf 'project=%s\n' "/w/kind"
    printf 'spawn_gen=%s\n' "s${SPAWN_E}.1.1"
    printf 'first_spawn_gen=%s\n' ""
    printf 'worktree=%s\n' ""
    [ -z "$3" ] || printf 'mode=%s\n' "$3"
  } > "$KHOME/state/$1.meta"
}

write_meta k-ship-full ship no-mistakes
write_meta k-ship-cond ship no-mistakes-prod-only
write_meta k-ship-quick ship direct-PR
write_meta k-ship-local ship local-only
write_meta k-ship-bare ship ""
write_meta k-scout scout ""
write_meta k-mate secondmate ""

OUT="$TMP_ROOT/out.json"
bash "$REPORT" >"$OUT" 2>"$TMP_ROOT/stderr.log" || { cat "$TMP_ROOT/stderr.log"; fail "report exits non-zero"; }
[ "$(wc -l <"$OUT")" -eq 1 ] || fail "report is not one line"

kind_of() {
  jq -r --arg id "$1" '.tasks[] | select(.id == $id) | .kind' "$OUT"
}

[ "$(kind_of k-ship-full)" = "full review fix" ] || fail "ship mode=no-mistakes reports full review fix"
[ "$(kind_of k-ship-cond)" = "full review fix" ] || fail "ship mode=no-mistakes-prod-only reports full review fix"
[ "$(kind_of k-ship-quick)" = "quick fix" ] || fail "ship mode=direct-PR reports quick fix"
[ "$(kind_of k-ship-local)" = "local only" ] || fail "ship mode=local-only reports local only"
[ "$(kind_of k-scout)" = "scout" ] || fail "scout reports scout"
[ "$(kind_of k-mate)" = "secondmate" ] || fail "secondmate keeps its raw kind"
[ "$(kind_of k-ship-bare)" = "ship" ] || fail "ship without a recorded mode keeps its raw kind"

pass "tasks report names each task kind in the tui-dash stage vocabulary"
