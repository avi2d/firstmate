#!/usr/bin/env bash
# Behavior tests for the private-board share-guard seatbelt.
# Drives the shell transport through the Pi primary's --command entry form.
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
  local id=$1 expected=$2 cmd=$3 out_file err_file rc
  out_file="$TMP_ROOT/$id.out"
  err_file="$TMP_ROOT/$id.err"
  check --command "$cmd" >"$out_file" 2>"$err_file"
  rc=$?

  if [ "$expected" = "deny" ]; then
    [ "$rc" -eq 2 ] || fail "$id must exit 2, got $rc for: $cmd"
    [ ! -s "$out_file" ] || fail "$id deny must keep stdout empty: $(cat "$out_file")"
    grep -q 'share-guard' "$err_file" || fail "$id stderr must name the guard: $(cat "$err_file")"
  else
    [ "$rc" -eq 0 ] || fail "$id must exit 0, got $rc for: $cmd"
    [ ! -s "$out_file" ] || fail "$id allow must stay silent on stdout"
    [ ! -s "$err_file" ] || fail "$id allow must stay silent on stderr"
  fi
}

test_share_matrix() {
  local i
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_COMMANDS[$i]}"
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]}"
  done
}

test_missing_command_is_a_usage_error() {
  local rc
  printf '%s' '{"tool_input":{"command":"lavish-axi share board.html"}}' | check >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a call without --command must exit 2 with usage, not read stdin, got $rc"
  pass "a call without --command is a usage error"
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

expect_allow() {
  local label=$1 cmd=$2 rc
  (CDPATH='' cd -- "$ROOT" && check --command "$cmd" >"$TMP_ROOT/allow.out" 2>"$TMP_ROOT/allow.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "$label must pass, got $rc: $(cat "$TMP_ROOT/allow.err")"
  [ ! -s "$TMP_ROOT/allow.out" ] && [ ! -s "$TMP_ROOT/allow.err" ] || fail "$label must stay silent"
}

expect_deny() {
  local label=$1 cmd=$2 rc
  (CDPATH='' cd -- "$ROOT" && check --command "$cmd" >/dev/null 2>"$TMP_ROOT/deny.err")
  rc=$?
  [ "$rc" -eq 2 ] || fail "$label must refuse, got $rc"
  grep -q 'share-guard' "$TMP_ROOT/deny.err" || fail "$label must name the guard: $(cat "$TMP_ROOT/deny.err")"
}

write_case_script() {
  local path=$1 extra=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
pe_register "$H" lavish shared-src -- "$BLOCKER" "payload"
case "$out" in
  handled:*) echo shared ;;
esac
SH
  printf '%s\n' "$extra" >> "$path"
}

pad_past_scan_cap() {
  local path=$1 i
  for ((i = 0; i < 9000; i++)); do printf ': padding line %05d for the scan cap
' "$i"; done >> "$path"
}

test_procevent_suite_runs_are_not_refused_as_unclassifiable() {
  expect_allow "the procevent suite run" 'bash tests/fm-procevent.test.sh && bash tests/fm-procevent-lavish.test.sh'
  pass "procevent suite runs that only mention lavish pass"
}

test_suite_run_beside_a_real_share_still_refuses() {
  expect_deny "a suite run chained to a share" 'bash tests/fm-procevent-lavish.test.sh && lavish-axi share board.html'
  pass "a suite run chained to a real share still refuses"
}

test_mention_in_unreadable_script_is_not_refused() {
  local small="$TMP_ROOT/mention-small.sh" large="$TMP_ROOT/mention-large.sh"
  write_case_script "$small" 'echo "lavish-axi poll board.html"'
  write_case_script "$large" 'echo "lavish-axi poll board.html"'
  pad_past_scan_cap "$large"
  expect_allow "an unreadable script that only mentions lavish" "bash $small # lavish"
  expect_allow "an oversized script that only mentions lavish" "bash $large # lavish"
  pass "a script naming lavish and shared words without a publish passes"
}

test_publish_in_unreadable_script_still_refuses() {
  local small="$TMP_ROOT/publish-small.sh" large="$TMP_ROOT/publish-large.sh"
  write_case_script "$small" 'lavish-axi --token SECRET share board.html'
  write_case_script "$large" 'lavish-axi --token SECRET share board.html'
  pad_past_scan_cap "$large"
  expect_deny "an unreadable script that publishes" "bash $small # lavish"
  expect_deny "an oversized script that publishes" "bash $large # lavish"
  pass "a script that publishes among the same words still refuses"
}

test_unknown_flag_errors() {
  check --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero"
  pass "unknown CLI flag is rejected"
}

test_share_matrix
test_missing_command_is_a_usage_error
test_fresh_file_approval_passes
test_stale_approval_refuses
test_edit_after_approval_refuses
test_wrong_path_approval_refuses
test_session_env_approval_passes
test_site_approval_passes_unpublish
test_procevent_suite_runs_are_not_refused_as_unclassifiable
test_suite_run_beside_a_real_share_still_refuses
test_mention_in_unreadable_script_is_not_refused
test_publish_in_unreadable_script_still_refuses
test_unknown_flag_errors
