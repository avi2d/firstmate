#!/usr/bin/env bash
# tests/fm-mac-keepawake.test.sh - Mac sleep prevention and sleep-evidence banner wording.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

KEEPAWAKE="$ROOT/bin/fm-mac-keepawake.sh"
GUARD="$ROOT/bin/fm-guard.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
ORACLE_SLEEP="$ROOT/tests/fixtures/fm-mac-keepawake-pmset-sleep.log"
ORACLE_AWAKE="$ROOT/tests/fixtures/fm-mac-keepawake-pmset-awake.log"
TMP_ROOT=$(fm_test_tmproot fm-mac-keepawake-tests)

mkhome() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

stub_caffeinate() {
  local home=$1
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/caffeinate" <<'SH'
#!/usr/bin/env bash
echo "caffeinate $*" >> "${FM_FAKE_CAFFEINATE_LOG:?}"
n=0
while [ "$n" -lt 120 ]; do sleep 5; n=$((n + 1)); done
SH
  chmod +x "$home/fakebin/caffeinate"
  FM_CAFFEINATE_BIN="$home/fakebin/caffeinate"
  export FM_CAFFEINATE_BIN
  FM_FAKE_CAFFEINATE_LOG="$home/caffeinate.calls"
  export FM_FAKE_CAFFEINATE_LOG
}

hold_session() {
  sleep 120 >/dev/null 2>&1 &
  HOLDER=$!
}

stop_pid() {
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  kill "$1" 2>/dev/null || true
}

stop_keepawake() {
  local pid
  pid=$(cat "$1/.mac-keepawake.pid" 2>/dev/null || true)
  stop_pid "$pid"
  rm -f "$1/.mac-keepawake.pid" "$1/.mac-keepawake.target" 2>/dev/null || true
}

wait_gone() {
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
}

test_away_record_takes_pid_tied_assertion() {
  local home state holder out
  home=$(mkhome away-takes)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'version: 2\nentered: 2026-10-18T20:00:00Z\nentered_epoch: 1792340000\nwords: |-\n  hold the fleet\n' > "$state/.afk-contract"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed with an away record present"; }
  sleep 1
  grep -F "caffeinate -s -i -w $holder" "$home/caffeinate.calls" >/dev/null || { stop_pid "$holder"; fail "stubbed caffeinate did not record the -w pid tie to the session pid"; }
  [ "$(cat "$state/.mac-keepawake.target")" = "$holder" ] || { stop_pid "$holder"; fail "recorded watch target is not the session pid"; }
  out=$(FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" status --state "$state")
  case "$out" in *needed=1*held=1*) ;; *) stop_pid "$holder"; fail "status did not report needed and held: $out" ;; esac
  stop_keepawake "$state"
  stop_pid "$holder"
  pass "away record takes a pid-tied assertion"
}

test_work_start_takes_assertion() {
  local home state holder
  home=$(mkhome work-takes)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'project=x\n' > "$state/job.meta"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed with work in flight"; }
  sleep 1
  grep -F "caffeinate -s -i -w $holder" "$home/caffeinate.calls" >/dev/null || { stop_pid "$holder"; fail "work in flight did not take an assertion tied to the session pid"; }
  stop_keepawake "$state"
  stop_pid "$holder"
  pass "work start takes an assertion"
}

test_idle_and_back_releases() {
  local home state holder recorded
  home=$(mkhome idle-releases)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'version: 2\nentered: 2026-10-18T20:00:00Z\nentered_epoch: 1792340000\nwords: |-\n  hold the fleet\n' > "$state/.afk-contract"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "setup sync failed"; }
  sleep 1
  [ -f "$state/.mac-keepawake.pid" ] || { stop_pid "$holder"; fail "setup sync took no assertion"; }
  recorded=$(cat "$state/.mac-keepawake.pid")
  rm "$state/.afk-contract"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "release sync failed"; }
  [ ! -e "$state/.mac-keepawake.pid" ] || { stop_pid "$holder"; fail "pid file survived the return to idle"; }
  [ ! -e "$state/.mac-keepawake.target" ] || { stop_pid "$holder"; fail "target file survived the return to idle"; }
  wait_gone "$recorded" || { stop_pid "$holder"; fail "recorded assertion process survived the release"; }
  stop_pid "$holder"
  pass "idle fleet and return release the assertion"
}

test_quiet_record_holds_nothing() {
  local home state holder
  home=$(mkhome quiet-holds-nothing)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'version: 2\nentered: 2026-10-18T20:00:00Z\nentered_epoch: 1792340000\nmode: quiet\nwords: -\n' > "$state/.afk-contract"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed on a quiet record"; }
  sleep 1
  [ ! -e "$home/caffeinate.calls" ] || { stop_pid "$holder"; fail "quiet record took an assertion while the captain is present"; }
  stop_pid "$holder"
  pass "quiet record holds nothing"
}

test_linux_stays_untouched() {
  local home state holder
  home=$(mkhome linux-untouched)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'version: 2\nentered: 2026-10-18T20:00:00Z\nentered_epoch: 1792340000\nwords: |-\n  hold the fleet\n' > "$state/.afk-contract"
  printf 'project=x\n' > "$state/job.meta"
  FM_MAC_KEEPAWAKE_UNAME=Linux "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed off Darwin"; }
  sleep 1
  [ ! -e "$home/caffeinate.calls" ] || { stop_pid "$holder"; fail "Linux home took a Mac assertion"; }
  [ ! -e "$state/.mac-keepawake.pid" ] || { stop_pid "$holder"; fail "Linux home wrote assertion state"; }
  stop_pid "$holder"
  pass "Linux homes stay unchanged"
}

test_remote_secondmate_meta_alone_releases() {
  local home state holder out
  home=$(mkhome remote-alone-releases)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  printf 'kind=secondmate\nmode=secondmate\nremote_host=linux\n' > "$state/linux.meta"
  printf 'kind=secondmate\nmode=secondmate\nremote_host=linux-b\n' > "$state/linux-b.meta"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed with only remote metas present"; }
  sleep 1
  [ ! -e "$home/caffeinate.calls" ] || { stop_pid "$holder"; fail "remote secondmate metas alone took a Mac assertion"; }
  out=$(FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" status --state "$state")
  case "$out" in *needed=0*) ;; *) stop_pid "$holder"; fail "status did not report idle with only remote metas: $out" ;; esac
  printf 'project=x\n' > "$state/job.meta"
  FM_MAC_KEEPAWAKE_UNAME=Darwin "$KEEPAWAKE" sync --state "$state" || { stop_pid "$holder"; fail "sync failed after local work appeared"; }
  sleep 1
  grep -F "caffeinate -s -i -w $holder" "$home/caffeinate.calls" >/dev/null || { stop_pid "$holder"; fail "local work beside remote metas did not take an assertion"; }
  stop_keepawake "$state"
  stop_pid "$holder"
  pass "remote secondmate metas alone release the assertion"
}

test_recorded_sleep_sample_reports_slept() {
  local home state
  home=$(mkhome slept-sample)
  state="$home/state"
  FM_MAC_KEEPAWAKE_UNAME=Darwin FM_MAC_KEEPAWAKE_BEAT_EPOCH=1792353664 "$KEEPAWAKE" slept --state "$state" --log-file "$ORACLE_SLEEP" || fail "recorded idle-sleep sample did not report slept against a beat before the sleep"
  FM_MAC_KEEPAWAKE_UNAME=Darwin FM_MAC_KEEPAWAKE_BEAT_EPOCH=1792354573 "$KEEPAWAKE" slept --state "$state" --log-file "$ORACLE_SLEEP" && fail "sample reported slept against a beat after the wake"
  FM_MAC_KEEPAWAKE_UNAME=Darwin FM_MAC_KEEPAWAKE_BEAT_EPOCH=0 "$KEEPAWAKE" slept --state "$state" --log-file "$ORACLE_AWAKE" && fail "sample without sleep entries reported slept"
  FM_MAC_KEEPAWAKE_UNAME=Linux FM_MAC_KEEPAWAKE_BEAT_EPOCH=0 "$KEEPAWAKE" slept --state "$state" --log-file "$ORACLE_SLEEP" && fail "slept reported sleep off Darwin"
  pass "recorded pmset sample drives the slept verdict"
}

test_contract_enter_and_archive_drive_sync() {
  local home state holder
  home=$(mkhome contract-drives)
  state="$home/state"
  stub_caffeinate "$home"
  hold_session
  holder=$HOLDER
  printf '%s\n' "$holder" > "$state/.lock"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_MAC_KEEPAWAKE_UNAME=Darwin "$CONTRACT" enter --words "hold the fleet" >/dev/null || { stop_pid "$holder"; fail "contract enter failed"; }
  sleep 1
  grep -F "caffeinate -s -i -w $holder" "$home/caffeinate.calls" >/dev/null || { stop_pid "$holder"; fail "away entry did not take an assertion"; }
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_MAC_KEEPAWAKE_UNAME=Darwin "$CONTRACT" archive >/dev/null || { stop_pid "$holder"; fail "contract archive failed"; }
  [ ! -e "$state/.mac-keepawake.pid" ] || { stop_pid "$holder"; fail "archive did not release the assertion on return"; }
  stop_keepawake "$state"
  stop_pid "$holder"
  pass "away entry and return drive the assertion"
}

test_guard_banner_names_sleep() {
  local home state err blind
  home=$(mkhome guard-sleep)
  state="$home/state"
  stub_caffeinate "$home"
  blind=$(fm_fakebin "$home/blind")
  fm_fake_blind_ancestry "$blind"
  printf 'project=x\n' > "$state/task.meta"
  err="$home/guard-sleep.err"
  PATH="$blind:$PATH" CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_MAC_KEEPAWAKE_UNAME=Darwin FM_PMSET_LOG_FILE="$ORACLE_SLEEP" FM_CAFFEINATE_BIN="$home/fakebin/caffeinate" "$GUARD" 2>"$err" >/dev/null || fail "guard failed on the sleep fixture"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing on the sleep fixture"
  grep -F 'this Mac went to sleep' "$err" >/dev/null || fail "banner did not name the Mac sleep: $(cat "$err")"
  grep -F 'slept Mac rather than a wedged watcher' "$err" >/dev/null || fail "banner did not separate sleep from a wedged watcher"
  home=$(mkhome guard-awake)
  state="$home/state"
  stub_caffeinate "$home"
  blind=$(fm_fakebin "$home/blind")
  fm_fake_blind_ancestry "$blind"
  printf 'project=x\n' > "$state/task.meta"
  err="$home/guard-awake.err"
  PATH="$blind:$PATH" CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_MAC_KEEPAWAKE_UNAME=Darwin FM_PMSET_LOG_FILE="$ORACLE_AWAKE" FM_CAFFEINATE_BIN="$home/fakebin/caffeinate" "$GUARD" 2>"$err" >/dev/null || fail "guard failed on the awake fixture"
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing on the awake fixture"
  grep -F 'this Mac went to sleep' "$err" >/dev/null && fail "banner blamed sleep with no sleep in the log"
  pass "watcher-down banner names Mac sleep"
}

test_away_record_takes_pid_tied_assertion
test_work_start_takes_assertion
test_idle_and_back_releases
test_quiet_record_holds_nothing
test_linux_stays_untouched
test_remote_secondmate_meta_alone_releases
test_recorded_sleep_sample_reports_slept
test_contract_enter_and_archive_drive_sync
test_guard_banner_names_sleep
