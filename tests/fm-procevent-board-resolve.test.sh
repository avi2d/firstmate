#!/usr/bin/env bash
# A board answer closes the worker matching key through fm-send --resolve-key,
# because the worker never writes its own resolved line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-board-resolve)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  mkdir -p "$1/data" "$1/state" "$1/config" "$1/projects"
  fm_test_tasks_toml "$1/.tasks.toml"
  cat > "$1/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$1"
}

# The ring must succeed, so the stub reports an empty composer verdict.
make_stubs() {
  local fb="$1/stubbin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\u256d\u2500\u2500\u2500\u2500\u256e\n\u2502    \u2502\n\u2570\u2500\u2500\u2500\u2500\u256f\n'; exit 0 ;;
  list-windows)
    printf '%s\n' fm-site-build elsewhere
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  # Sleep stays real: the runner's bounded readiness waits become scheduling
  # races under a no-op sleep, and a loaded machine then fails the run.
  cat > "$fb/sleep" <<SH
#!/usr/bin/env bash
exec "$(command -v sleep)" "$@"
SH
  chmod +x "$fb/sleep"
}

tasks_in() {
  (cd "$1" && shift && tasks-axi "$@")
}

run_lavish() {
  local home=$1; shift
  PATH="$home/stubbin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_captain() {
  local home=$1; shift
  PATH="$home/stubbin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_procevent() {
  local home=$1; shift
  PATH="$home/stubbin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SEND_SETTLE=0 \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

drain_out() {
  FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

test_board_answer_closes_matching_worker_key() {
  local home sid artifact payload out show
  home="$TMP_ROOT/board-resolve"
  make_home "$home" >/dev/null
  make_stubs "$home"
  tasks_in "$home" add site-build "Build the site" --kind ship --repo sample >/dev/null || fail "could not create the worker task"
  mkdir -p "$home/worktree-site-build"
  fm_write_meta "$home/state/site-build.meta" "window=sess:fm-site-build" "worktree=$home/worktree-site-build" "project=sample" "kind=ship"
  printf 'needs-decision [key=website-details-native-lint]: pick the native lint rule\n' > "$home/state/site-build.status"
  printf 'working: building the site pages\n' >> "$home/state/site-build.status"
  run_captain "$home" hold website-details-native-lint --title "Captain call: native lint" --reason "captain lint choice pending" --repo sample >/dev/null || fail "could not hold the native-lint call"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=website-details-native-lint]' >/dev/null || fail "precondition: the worker decision should list as open before the answer"
  artifact="$home/review.html"
  printf '<h1>Site review</h1>\n' > "$artifact"
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null || fail "could not bind the review source to the keyed-answer intake"
  payload="$home/board-payload.txt"
  cat > "$payload" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "1","Native lint: strict\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"website-details-native-lint\",\n  \"selection\": \"strict\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(1)",choice,"Native lint: strict"
EOF
  run_procevent "$home" register-task lavish "$sid" site-build -- cat "$payload" >/dev/null || fail "could not register the worker-owned review source"
  run_procevent "$home" start "$sid" >/dev/null 2>&1 || fail "the review source run failed"
  show=$(tasks_in "$home" show website-details-native-lint --full --file "$home/data/backlog.md") || fail "the answered call disappeared"
  assert_contains "$show" "state: done" "the board answer did not close the held call"
  [ -f "$home/state/site-build.inbox/001.msg" ] || fail "the worker-owned feedback never reached the worker inbox"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/site-build.status" | grep -qF 'resolved [key=website-details-native-lint]: answered: strict' || fail "the worker decision was not closed through the answer path"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=website-details-native-lint]' >/dev/null; then fail "the answered worker decision still lists as open"; fi
  pass "a board answer closes the worker's matching keyed decision"
}

test_board_answer_closes_matching_worker_key
