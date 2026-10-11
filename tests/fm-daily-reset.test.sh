#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-daily-reset)
CHECK="$ROOT/bin/fm-daily-reset.sh"
TODAY=2026-10-10

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s' "$home"
}

do_check() {
  FM_HOME="$1" FM_DAILY_RESET_TODAY="$TODAY" FM_DAILY_RESET_NOW="$2" "$CHECK" check 2>&1
}

make_stub() {
  local stub="$TMP_ROOT/stub-$1.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >> "$FM_DAILY_RESET_STUB_LOG"
exit "${FM_DAILY_RESET_STUB_EXIT:-0}"
EOF
  chmod +x "$stub"
  printf '%s' "$stub"
}

stub_log() {
  printf '%s' "$TMP_ROOT/stub-$1.log"
}

run_forced() {
  FM_HOME="$1" FM_DAILY_RESET_TODAY="$TODAY" FM_DAILY_RESET_NOW=05:00 \
    FM_DAILY_RESET_RESTART_BIN="$2" FM_DAILY_RESET_STUB_LOG="$3" \
    "$CHECK" run --force ${4:+"$4"} ${5:+"$5"} 2>&1
}

add_mate() {
  local home="$1" id="$2" kind="$3" ev="agent_settled"
  printf -- '- %s - test mate (home: /tmp/%s-home; scope: test; projects: none; added 2026-10-10)\n' "$id" "$id" >> "$home/data/secondmates.md"
  printf 'kind=secondmate\nharness=pi\nwindow=fm-%s\n' "$id" > "$home/state/$id.meta"
  [ "$kind" = "none" ] && return 0
  [ "$kind" = "busy" ] && ev="agent_start"
  printf 'testgen01\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=testgen01 seq=3 state=%s source=pi-ext event=%s ts=1791662808\n' "$kind" "$ev" > "$home/state/$id.busy-state"
}

test_due_fires_once_per_day() {
  local home out rc=0 stub run_out log
  home=$(make_home due-once)
  out=$(do_check "$home" 05:00) || rc=$?
  [ "$rc" = 0 ] || fail "due check failed: $out"
  case "$out" in *"daily-reset due"*) ;; *) fail "expected one due line, got: $out" ;; esac
  stub=$(make_stub due-once)
  log=$(stub_log due-once)
  run_out=$(run_forced "$home" "$stub" "$log") || rc=$?
  [ "$rc" = 0 ] || fail "run failed: $run_out"
  assert_grep "fm-daily-reset-v1 $TODAY" "$home/state/.daily-reset" "run did not stamp the day"
  out=$(do_check "$home" 06:00)
  [ -z "$out" ] || fail "second check the same day should stay silent: $out"
}

test_before_time_is_silent() {
  local home out
  home=$(make_home early)
  out=$(do_check "$home" 03:59)
  [ -z "$out" ] || fail "check before the configured time should stay silent: $out"
}

test_off_disables() {
  local home out rc=0
  home=$(make_home off)
  printf 'off\n' > "$home/config/daily-session-reset"
  out=$(do_check "$home" 05:00)
  [ -z "$out" ] || fail "disabled check should stay silent: $out"
  out=$(FM_HOME="$home" FM_DAILY_RESET_TODAY="$TODAY" FM_DAILY_RESET_NOW=05:00 "$CHECK" run 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "disabled run without --force should refuse, got $rc: $out"
}

test_bad_config_reports_once() {
  local home out
  home=$(make_home badconfig)
  printf 'someday\n' > "$home/config/daily-session-reset"
  out=$(do_check "$home" 05:00)
  case "$out" in *"not HH:MM or off"*) ;; *) fail "expected a config line, got: $out" ;; esac
  out=$(do_check "$home" 05:00)
  [ -z "$out" ] || fail "repeated bad config should stay silent until edited: $out"
}

test_parked_stays_silent() {
  local home out
  home=$(make_home parked)
  : > "$home/state/.afk"
  out=$(do_check "$home" 05:00)
  [ -z "$out" ] || fail "check while parked should stay silent: $out"
}

test_busy_mate_skipped_idle_mate_restarted() {
  local home stub out rc=0 log
  home=$(make_home mixed)
  add_mate "$home" m-busy busy
  add_mate "$home" m-idle idle
  stub=$(make_stub mixed)
  log=$(stub_log mixed)
  : > "$log"
  out=$(run_forced "$home" "$stub" "$log") || rc=$?
  [ "$rc" = 3 ] || fail "expected exit 3 with one skip, got $rc: $out"
  case "$out" in *"skip: m-busy is mid-turn"*) ;; *) fail "expected a busy skip line, got: $out" ;; esac
  assert_grep 'm-idle' "$log" "idle mate never reached the restart"
  case "$(cat "$log")" in *"m-busy"*) fail "busy mate reached the restart" ;; esac
  case "$out" in *"fresh session"*) ;; *) fail "run should print the main-session half, got: $out" ;; esac
}

test_unknown_mate_rides_the_restart_gate() {
  local home stub out rc=0 log
  home=$(make_home strange)
  add_mate "$home" m-strange none
  stub=$(make_stub strange)
  log=$(stub_log strange)
  : > "$log"
  out=$(run_forced "$home" "$stub" "$log") || rc=$?
  [ "$rc" = 0 ] || fail "run failed: $out"
  assert_grep 'm-strange' "$log" "unobservable mate never reached the restart gate"
}

test_restart_failure_still_stamps_for_tomorrow() {
  local home stub out rc=0 log
  home=$(make_home failing)
  add_mate "$home" m-idle idle
  stub=$(make_stub failing)
  log=$(stub_log failing)
  out=$(FM_DAILY_RESET_STUB_EXIT=3 run_forced "$home" "$stub" "$log") || rc=$?
  [ "$rc" = 3 ] || fail "expected the restart exit to propagate, got $rc: $out"
  assert_grep "fm-daily-reset-v1 $TODAY" "$home/state/.daily-reset" "failed pass did not stamp the day for retry tomorrow"
}

test_run_refuses_when_not_due() {
  local home stub out rc=0 log
  home=$(make_home notdue)
  add_mate "$home" m-idle idle
  stub=$(make_stub notdue)
  log=$(stub_log notdue)
  printf 'fm-daily-reset-v1 %s\n' "$TODAY" > "$home/state/.daily-reset"
  out=$(FM_HOME="$home" FM_DAILY_RESET_TODAY="$TODAY" FM_DAILY_RESET_NOW=05:00 FM_DAILY_RESET_RESTART_BIN="$stub" "$CHECK" run 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "run when not due should refuse, got $rc: $out"
  [ ! -e "$log" ] || fail "refused run still invoked the restart"
}

test_invalid_id_is_refused() {
  local home stub out rc=0 log
  home=$(make_home badid)
  stub=$(make_stub badid)
  log=$(stub_log badid)
  out=$(run_forced "$home" "$stub" "$log" 'nope!') || rc=$?
  [ "$rc" = 2 ] || fail "invalid id should exit 2, got $rc: $out"
}

test_explicit_ids_skip_the_rest() {
  local home stub out rc=0 log
  home=$(make_home subset)
  add_mate "$home" m-busy busy
  add_mate "$home" m-idle idle
  stub=$(make_stub subset)
  log=$(stub_log subset)
  : > "$log"
  out=$(run_forced "$home" "$stub" "$log" m-idle) || rc=$?
  [ "$rc" = 0 ] || fail "subset run failed: $out"
  assert_grep 'm-idle' "$log" "named mate never reached the restart"
}

test_arm_and_disarm() {
  local home out shim
  home=$(make_home arming)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1)
  case "$out" in *"armed: state/daily-reset.check.sh"*) ;; *) fail "arm failed: $out" ;; esac
  shim="$home/state/daily-reset.check.sh"
  [ -f "$shim" ] || fail "arm left no shim"
  out=$(FM_DAILY_RESET_TODAY="$TODAY" FM_DAILY_RESET_NOW=05:00 "$shim" 2>&1)
  case "$out" in *"daily-reset due"*) ;; *) fail "shim did not run the check, got: $out" ;; esac
  FM_HOME="$home" "$CHECK" disarm >/dev/null 2>&1
  assert_absent "$shim" "disarm left the check shim"
  assert_absent "$home/state/daily-reset.check-trust" "disarm left the trust binding"
}

test_due_fires_once_per_day
test_before_time_is_silent
test_off_disables
test_bad_config_reports_once
test_parked_stays_silent
test_busy_mate_skipped_idle_mate_restarted
test_unknown_mate_rides_the_restart_gate
test_restart_failure_still_stamps_for_tomorrow
test_run_refuses_when_not_due
test_invalid_id_is_refused
test_explicit_ids_skip_the_rest
test_arm_and_disarm
pass "fm-daily-reset"
