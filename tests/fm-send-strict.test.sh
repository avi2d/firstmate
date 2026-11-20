#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get")
    if [ "${3:-}" = w1:p9 ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane read") printf '{"result":{"text":"──────\n\n──────\n$0.00"}}\n' ;;
  "pane send-keys") [ "${4:-}" != "${FM_FAKE_HERDR_FAIL_KEY:-}" ] ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:w1:p2" "backend=herdr" "kind=ship" "harness=pi"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists: $(cat "$err")"
  got=$(cat "$log")
  assert_contains "$got" "pane send-text w1:p2 : Firstmate instruction waiting" \
    "exact id should ring the doorbell at the meta target"
  assert_contains "$got" "pane send-keys w1:p2 enter --session sess" "exact id should submit the doorbell with Enter"
  grep -qF 'lost dispatch' "$home/state/mpf-lane-m8.inbox/001.msg" \
    || fail "exact id should record the steer in the task inbox"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_help_prints_usage() {
  local home="$TMP_ROOT/help" out err rc
  mkdir -p "$home/state"
  out="$TMP_ROOT/help.out"; err="$TMP_ROOT/help.err"
  env -u FM_HOME "$SEND" --help >"$out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-send --help without FM_HOME should print usage and exit 0"
  assert_contains "$(cat "$out")" "Usage: fm-send.sh <target>" "--help should print the header usage line"
  assert_contains "$(cat "$out")" "--resolve-key" "--help should print the header contract"
  [ ! -s "$err" ] || fail "fm-send --help wrote to stderr: $(cat "$err")"
  FM_HOME="$home" "$SEND" --help >"$out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-send --help with FM_HOME should not treat the flag as a target"
  assert_contains "$(cat "$out")" "Usage: fm-send.sh <target>" "--help with FM_HOME should print usage"
  pass "fm-send --help prints the header usage before FM_HOME and target resolution"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_guess_session() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to Herdr"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not guess a Herdr session"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to Herdr"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before contacting Herdr"
}

test_absent_explicit_pane_never_receives_key() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:w1:p9 --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "absent explicit Herdr target should fail"
  assert_contains "$(cat "$err")" "not a live Herdr endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=herdr" "dead explicit target diagnostic should name the tried backend"
  assert_no_grep "pane send-" "$log" "dead explicit target still attempted a send"
  pass "fm-send strict: explicit Herdr panes must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; herdr_log="$dir/herdr.log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit: $(cat "$err")"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:w1:p2" "backend=herdr" "kind=ship" "harness=pi"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello from the user" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "pane send-text w1:p2 : Firstmate instruction waiting" \
    "healthy send should ring the doorbell at the meta target"
  assert_contains "$got" "pane send-keys w1:p2 enter --session sess" "healthy send should submit the doorbell with Enter"
  grep -qF 'hello from the user' "$home/state/lane-ok.inbox/001.msg" \
    || fail "healthy send should record the steer in the task inbox"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends record the steer and ring once"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:w1:p2" "backend=herdr" "kind=ship" "harness=pi"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "pane send-keys w1:p2 escape --session sess" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_HERDR_FAIL_KEY=escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "pane send-keys w1:p2 escape --session sess" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_help_prints_usage
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_guess_session
test_prefixless_herdr_pane_id_fails
test_absent_explicit_pane_never_receives_key
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
