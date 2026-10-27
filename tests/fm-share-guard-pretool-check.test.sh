#!/usr/bin/env bash
# Behavior tests for the private-board share-guard seatbelt.
# Drives the shell transport through every harness entry form.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-share-guard-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-share-guard)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
BOARD="$TMP_ROOT/board.html"
printf '<h1>board</h1>\n' > "$BOARD"

if ! command -v bun >/dev/null 2>&1; then
  pass "bun absent, skipping"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  pass "jq absent, skipping"
  exit 0
fi

check() {
  env -u FM_LAVISH_SHARE_APPROVED FM_HOME="$HOME_DIR" "$CHECK" "$@"
}

check --command 'lavish-axi share probe.html' >/dev/null 2>&1
[ "$?" -eq 2 ] || { pass "policy runtime unavailable, skipping"; exit 0; }

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case S01 deny 'lavish-axi share board.html'
matrix_case S02 deny 'lavish-axi share board.html --private'
matrix_case S03 deny 'lavish-axi share board.html --password hunter2'
matrix_case S04 deny 'lavish-axi share board.html --site abc --update-key SECRET'
matrix_case S05 deny 'lavish-axi share --unpublish --site abc --update-key SECRET'
matrix_case S06 deny 'sudo lavish-axi share board.html'
matrix_case S07 deny '/opt/homebrew/bin/lavish-axi share board.html'
matrix_case S08 deny 'npx lavish-axi share board.html'
matrix_case S09 deny "bash -c 'lavish-axi share board.html'"
matrix_case S10 deny "bash -lc 'lavish-axi share board.html'"
matrix_case S11 deny "eval 'lavish-axi share board.html'"
matrix_case S12 deny '(lavish-axi share board.html)'
matrix_case S13 deny "echo \"\$(lavish-axi share board.html)\""
matrix_case S14 deny 'FM_LAVISH_SHARE_APPROVED=/tmp/board.html lavish-axi share board.html'
matrix_case S15 deny 'lavish-axi --token SECRET share board.html'
matrix_case S16 deny 'lavish-axi share --site=abc --update-key SECRET board.html'
matrix_case U01 deny 'curl -X POST https://ht-ml.app/abc --data-binary @board.html'
matrix_case U02 deny 'curl https://ht-ml.app/abc -d @board.html'
matrix_case U03 deny 'curl --upload-file board.html https://ht-ml.app/abc'
matrix_case U04 deny 'wget --post-file=board.html https://ht-ml.app/abc'
matrix_case U07 deny 'wget --post-data=board=1 https://ht-ml.app/abc'
matrix_case U08 deny 'curl -F file=@board.html https://ht-ml.app/abc'
matrix_case U05 deny "python3 -c 'import requests; requests.post(\"https://ht-ml.app/x\", data=open(\"b\").read())'"
matrix_case U06 deny 'node -e "fetch(\x27https://ht-ml.app/x\x27,{method:\x27POST\x27})"'
matrix_case A01 allow 'lavish-axi poll board.html'
matrix_case A02 allow 'lavish-axi reply board.html --agent-reply done'
matrix_case A03 allow 'curl https://ht-ml.app/abc'
matrix_case A04 allow 'curl https://example.com --data-binary @board.html'
matrix_case A05 allow 'echo lavish-axi share board.html'
matrix_case A06 allow "echo 'see https://ht-ml.app/abc for the board'"
matrix_case A07 allow '# lavish-axi share board.html'
matrix_case A08 allow 'echo ok'
matrix_case A09 allow 'lavish-axi --help'
matrix_case A10 allow "python3 -c 'import requests; requests.get(\"https://ht-ml.app/x\")'"

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$TMP_ROOT/$id-$entry.out"
  err_file="$TMP_ROOT/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | check >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | check --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | check >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      check --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
  esac

  if [ "$expected" = "deny" ]; then
    [ "$rc" -eq 2 ] || fail "$id via $entry must exit 2, got $rc for: $cmd"
    grep -q 'share-guard' "$err_file" || fail "$id via $entry stderr must name the guard: $(cat "$err_file")"
  else
    [ "$rc" -eq 0 ] || fail "$id via $entry must exit 0, got $rc for: $cmd"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must stay silent on stdout"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must stay silent on stderr"
  fi
}

SWEEP_IDS=" S01 U01 A01 A03 "

test_share_matrix_all_entries() {
  local i entry entries
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    entries="opencode"
    case "$SWEEP_IDS" in
      *" ${MATRIX_IDS[$i]} "*) entries="codex claude grok opencode pi" ;;
    esac
    for entry in $entries; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]}"
  done
}

test_cursor_deny_renders_object() {
  local out rc
  out=$(printf '%s' '{"tool_input":{"command":"lavish-axi share board.html"},"tool_name":"Shell"}' | check --cursor 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || fail "cursor deny must exit 0, got $rc"
  printf '%s' "$out" | jq -e '.permission == "deny"' >/dev/null 2>&1 || fail "cursor deny must render its decision object: $out"
  pass "cursor entry form renders its own deny object"
}

test_grok_deny_carries_stdout_object() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"lavish-axi share board.html"},"toolName":"run_terminal_command"}' | check 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "grok deny must carry decision=deny on stdout: $out"
  pass "grok entry form carries its deny object on stdout"
}

test_claude_deny_keeps_stdout_empty() {
  local out rc
  out=$(printf '%s' '{"tool_input":{"command":"lavish-axi share board.html"},"tool_name":"Bash"}' | check --claude 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude deny must exit 2, got $rc"
  [ -z "$out" ] || fail "claude deny must keep stdout empty: $out"
  pass "claude entry form keeps stdout empty on deny"
}

approve_file() {
  printf '%s %s\n' "$(date +%s)" "$1" > "$HOME_DIR/state/lavish-share-approvals"
}

clear_approvals() {
  rm -f "$HOME_DIR/state/lavish-share-approvals"
}

test_fresh_file_approval_passes() {
  approve_file "$BOARD"
  (CDPATH='' cd -- "$TMP_ROOT" && check --command 'lavish-axi share board.html' >/dev/null 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a fresh approval for the exact bytes must pass"
  clear_approvals
  pass "fresh file approval for the exact bytes passes"
}


test_stale_approval_refuses() {
  printf '%s %s\n' "$(( $(date +%s) - 4000 ))" "$BOARD" > "$HOME_DIR/state/lavish-share-approvals"
  (CDPATH='' cd -- "$TMP_ROOT" && check --command 'lavish-axi share board.html' >/dev/null 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an approval older than the window must refuse"
  clear_approvals
  pass "stale approval refuses"
}

test_edit_after_approval_refuses() {
  approve_file "$BOARD"
  sleep 1
  touch "$BOARD"
  (CDPATH='' cd -- "$TMP_ROOT" && check --command 'lavish-axi share board.html' >/dev/null 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "bytes changed after the approval must refuse"
  clear_approvals
  pass "edit after approval refuses"
}

test_wrong_path_approval_refuses() {
  approve_file "$TMP_ROOT/other.html"
  (CDPATH='' cd -- "$TMP_ROOT" && check --command 'lavish-axi share board.html' >/dev/null 2>&1)
  [ "$?" -eq 2 ] || fail "an approval for another path must refuse"
  clear_approvals
  pass "approval for another path refuses"
}

test_session_env_approval_passes() {
  (CDPATH='' cd -- "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_LAVISH_SHARE_APPROVED="$BOARD" "$CHECK" --command 'lavish-axi share board.html' >/dev/null 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a session approval for the exact path must pass"
  pass "session approval for the exact path passes"
}

test_site_approval_passes_unpublish() {
  printf '%s %s\n' "$(date +%s)" "site:abc" > "$HOME_DIR/state/lavish-share-approvals"
  check --command 'lavish-axi share --unpublish --site abc --update-key SECRET' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a site approval must pass the matching unpublish"
  clear_approvals
  pass "site approval passes the matching unpublish"
}

test_unknown_flag_errors() {
  check --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero"
  pass "unknown CLI flag is rejected"
}

test_share_matrix_all_entries
test_cursor_deny_renders_object
test_grok_deny_carries_stdout_object
test_claude_deny_keeps_stdout_empty
test_fresh_file_approval_passes
test_stale_approval_refuses
test_edit_after_approval_refuses
test_wrong_path_approval_refuses
test_session_env_approval_passes
test_site_approval_passes_unpublish
test_unknown_flag_errors
