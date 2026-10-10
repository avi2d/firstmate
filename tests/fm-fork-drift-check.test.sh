#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-fork-drift-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-drift-check)

fm_git_identity fmtest fmtest@example.invalid

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

seed_pair() {
  local dir="$TMP_ROOT/$1" up fork work
  mkdir -p "$dir"
  up="$dir/upstream.git"
  fork="$dir/fork.git"
  work="$dir/work"
  git init --bare -q "$up"
  git init --bare -q "$fork"
  git --git-dir="$up" symbolic-ref HEAD refs/heads/main
  git --git-dir="$fork" symbolic-ref HEAD refs/heads/main
  git init -b main -q "$work"
  git -C "$work" commit -q --allow-empty -m seed
  git -C "$work" push -q "$up" main
  git -C "$work" push -q "$fork" main
  printf '%s %s %s\n' "$up" "$fork" "$work"
}

advance() {
  git -C "$3" commit -q --allow-empty -m "$2"
  git -C "$3" push -q "$1" main
}

write_config() {
  printf '%s\n' "$2" > "$1/config/fork-upstream.json"
}

head_config() {
  local fork=$1 upstream=$2 trigger="upstream-head"
  [ $# -lt 3 ] || trigger=$3
  printf '{"forks":[{"project":"demo","fork":"%s","upstream":"%s","trigger":"%s"}]}' "$fork" "$upstream" "$trigger"
}

run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" FM_FORK_DRIFT_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

test_current_fork_is_silent() {
  local home up fork work out
  home=$(make_home current)
  read -r up fork work < <(seed_pair current)
  write_config "$home" "$(head_config "$fork" "$up")"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "check reported drift for a current fork: $(cat "$out")"
  pass "a current fork stays silent"
}

test_upstream_move_fires_once() {
  local home up fork work out report sha
  home=$(make_home move)
  read -r up fork work < <(seed_pair move)
  write_config "$home" "$(head_config "$fork" "$up")"
  out="$home/out.txt"
  run_check "$home" "$out"
  advance "$up" second "$work"
  run_check "$home" "$out"
  report=$(cat "$out")
  sha=$(git ls-remote "$up" refs/heads/main | awk '{ print substr($1, 1, 12) }')
  assert_contains "$report" "fork drift:" "the report is missing its prefix"
  assert_contains "$report" "demo is 1 behind / 0 ahead" "the report does not name the behind and ahead counts"
  assert_contains "$report" "$sha" "the report does not name the upstream head"
  assert_contains "$report" "fork-drift-sync" "the report does not name the skill that owns the wake"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must be exactly one line for the wake record"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the same upstream head reported twice: $(cat "$out")"
  pass "an upstream move fires once and then stays silent"
}

test_second_move_fires_again() {
  local home up fork work out
  home=$(make_home again)
  read -r up fork work < <(seed_pair again)
  write_config "$home" "$(head_config "$fork" "$up")"
  out="$home/out.txt"
  run_check "$home" "$out"
  advance "$up" second "$work"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "the first upstream move did not fire"
  advance "$up" third "$work"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "demo is 2 behind / 0 ahead" "a second upstream move did not fire again"
  pass "a newer upstream head fires again after an earlier one was reported"
}

test_fork_ahead_stays_silent() {
  local home up fork work out
  home=$(make_home ahead)
  read -r up fork work < <(seed_pair ahead)
  write_config "$home" "$(head_config "$fork" "$up")"
  out="$home/out.txt"
  run_check "$home" "$out"
  advance "$fork" local-only "$work"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "check woke on fork commits upstream does not have: $(cat "$out")"
  pass "a fork ahead of its upstream stays silent"
}

test_release_fires_once() {
  local home up fork work out report
  home=$(make_home release)
  read -r up fork work < <(seed_pair release)
  write_config "$home" "$(head_config "$fork" "$up" release)"
  out="$home/out.txt"
  advance "$up" second "$work"
  git -C "$work" tag v1.0.0
  git -C "$work" push -q "$up" v1.0.0
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "demo upstream published v1.0.0 (1 behind / 0 ahead)" "a new release did not fire"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the same release reported twice: $(cat "$out")"
  advance "$up" third "$work"
  git -C "$work" tag v2.0.0
  git -C "$work" push -q "$up" v2.0.0
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "demo upstream published v2.0.0" "a newer release did not fire"
  pass "a new release fires once per tag"
}

test_absent_config_does_nothing() {
  local home out
  home=$(make_home absent)
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "check reported without a registry: $(cat "$out")"
  [ ! -e "$home/state/.fork-drift" ] || fail "check wrote a record without a registry"
  pass "an absent registry stays silent"
}

test_unreadable_upstream_reports() {
  local home fork out
  home=$(make_home unreadable)
  fork="$TMP_ROOT/unreadable/fork.git"
  git init --bare -q "$fork"
  write_config "$home" "$(head_config "$fork" "$TMP_ROOT/unreadable/missing.git")"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "demo check failed" "an unreadable upstream was swallowed instead of reported"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the same failure nagged twice: $(cat "$out")"
  pass "an unreadable upstream reports once instead of nagging"
}

test_invalid_config_reports() {
  local home out
  home=$(make_home invalid)
  write_config "$home" '{"forks":[{"project":"demo"}]}'
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "fork upstream registry" "an invalid registry was swallowed instead of reported"
  pass "an invalid registry reports instead of running blind"
}

test_daily_gate_holds_then_releases() {
  local home up fork work out
  home=$(make_home gate)
  read -r up fork work < <(seed_pair gate)
  write_config "$home" "$(head_config "$fork" "$up")"
  out="$home/out.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" "$CHECK" >"$out" 2>&1
  advance "$up" second "$work"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" "$CHECK" >"$out" 2>&1
  [ ! -s "$out" ] || fail "the daily gate probed twice in one day: $(cat "$out")"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "demo is 1 behind" "the missed change was dropped instead of reported late"
  pass "the daily gate holds probes and never drops a missed change"
}

test_arm_and_disarm() {
  local home up fork work shim
  home=$(make_home arm)
  read -r up fork work < <(seed_pair arm)
  write_config "$home" "$(head_config "$fork" "$up")"
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1
  expect_code 0 "$?" "arm exit"
  shim="$home/state/fork-drift.check.sh"
  [ -f "$shim" ] && [ ! -L "$shim" ] || fail "arm did not write the check shim"
  [ -x "$shim" ] || fail "the check shim is not executable"
  [ -f "$home/state/fork-drift.check-trust" ] || fail "arm did not bind the check bytes"
  FM_HOME="$home" "$CHECK" disarm >/dev/null 2>&1
  expect_code 0 "$?" "disarm exit"
  [ ! -e "$shim" ] || fail "disarm left the check shim behind"
  [ ! -e "$shim" ] || fail "disarm left the check shim behind"
  [ ! -e "$home/state/fork-drift.check-trust" ] || fail "disarm left the trust binding behind"
  pass "arm writes and binds the shim, disarm removes it"
}

test_current_fork_is_silent
test_upstream_move_fires_once
test_second_move_fires_again
test_fork_ahead_stays_silent
test_release_fires_once
test_absent_config_does_nothing
test_unreadable_upstream_reports
test_invalid_config_reports
test_daily_gate_holds_then_releases
test_arm_and_disarm
