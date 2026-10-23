#!/usr/bin/env bash
# tests/fm-watch-ready-capacity.test.sh - bin/fm-ready-capacity.sh and the
# watcher hook behind it: waiting work with room to run wakes the supervisor
# once per distinct dispatchable set, and stays silent without room, under the
# away record, or from an unreadable backlog.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
READY="$ROOT/bin/fm-ready-capacity.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-ready-capacity-tests)

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# touch -t takes a local-time stamp, not an epoch, on both platforms.
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# A home with a queued pair for one declared project, under no other load.
make_ready_home() {  # <name>; prints the home dir
  local home=$1
  home=$(make_case "$1")
  mkdir -p "$home/config" "$home/data" "$home/projects/projA"
  fm_test_tasks_toml "$home/.tasks.toml"
  (cd "$home/projects/projA" && git init -q)
  printf 'projA 5
' > "$home/config/project-capacity"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add task-one "First task" --repo projA >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add task-two "Second task" --repo projA >/dev/null
  printf '%s
' "$home"
}

home_add_holder() {  # <home>; one worker place on the declared project
  printf '%s
' "kind=ship" "project=$1/projects/projA" > "$1/state/holder.meta"
}

watch_home_bg() {  # <home> <out>; a quiet-fleet watcher in the background
  local home=$1 out=$2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_MAC_LOAD_MOCK_5MIN=1 "$WATCH" > "$out" &
}

ack_queue() {  # <home>; acknowledge the queued wake the way a handling supervisor does
  local err=$1/state/.ack.err sequence generation
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" >/dev/null 2>"$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

queue_ready_rows() {  # <home>; durably queued ready-capacity wakes
  [ -f "$1/state/.wake-queue" ] || { printf '0
'; return 0; }
  grep -cF "$(printf '\tcheck\tready-capacity\t')" "$1/state/.wake-queue" || true
}

test_helper_lists_dispatchable() {
  local home out rc
  home=$(make_ready_home helper-lists)
  out=$(FM_HOME="$home" FM_MAC_LOAD_MOCK_5MIN=1 "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "dispatchable queue exited $rc instead of 0"
  [ "$out" = "task-one
task-two" ] || fail "dispatchable queue reported [$out]"
  pass "the helper lists every ready item the gates admit"
}

test_helper_empty_at_capacity() {
  local home out rc
  home=$(make_ready_home helper-capacity)
  printf 'projA 1
' > "$home/config/project-capacity"
  home_add_holder "$home"
  out=$(FM_HOME="$home" FM_MAC_LOAD_MOCK_5MIN=1 "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "capped project exited $rc instead of 0"
  [ -z "$out" ] || fail "capped project reported [$out]"
  pass "a project at its declared capacity admits nothing further"
}

test_helper_empty_when_loaded() {
  local home out rc
  home=$(make_ready_home helper-loaded)
  out=$(FM_HOME="$home" FM_MAC_LOAD_MOCK_5MIN=99 "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "loaded machine exited $rc instead of 0"
  [ -z "$out" ] || fail "loaded machine reported [$out]"
  pass "a machine past its load gate admits nothing"
}

test_helper_empty_when_heavy_capped() {
  local home out rc
  home=$(make_ready_home helper-heavy)
  printf 'projA 5
@heavy-limit 1
' > "$home/config/project-capacity"
  home_add_holder "$home"
  out=$(FM_HOME="$home" FM_MAC_LOAD_MOCK_5MIN=1 "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "heavy-capped machine exited $rc instead of 0"
  [ -z "$out" ] || fail "heavy-capped machine reported [$out]"
  pass "a machine at its heavy limit admits nothing"
}

test_helper_unreadable_backlog_is_exit_two() {
  local home out rc
  home=$(make_ready_home helper-unreadable)
  out=$(FM_HOME="$home" PATH=/usr/bin:/bin "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] || fail "unreadable backlog exited $rc instead of 2"
  [ -z "$out" ] || fail "unreadable backlog reported [$out]"
  pass "an unreadable backlog refuses without a report"
}

test_helper_skips_held() {
  local home out rc
  home=$(make_ready_home helper-held)
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" hold task-one --reason waiting --kind captain >/dev/null
  out=$(FM_HOME="$home" FM_MAC_LOAD_MOCK_5MIN=1 "$READY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "held-item queue exited $rc instead of 0"
  [ "$out" = task-two ] || fail "held-item queue reported [$out]"
  pass "held work never counts as dispatchable"
}

test_watcher_fires_once_per_set() {
  local home out pid marker
  home=$(make_ready_home watcher-fires); out="$home/watch.out"
  watch_home_bg "$home" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "ready work did not wake the supervisor: $(cat "$out")"; }
  grep -F "check: ready-capacity: 2 queued task(s) ready with room to run: task-one task-two" "$out" >/dev/null     || fail "ready work woke without naming its set: $(cat "$out")"
  [ "$(queue_ready_rows "$home")" = 1 ] || fail "ready work left no single durable check row"
  marker="$home/state/.ready-capacity-notified"
  [ "$(cat "$marker")" = "task-one
task-two" ] || fail "the fired set was not recorded"
  pass "ready work with room wakes the supervisor once, naming its set"
}

test_watcher_same_set_absorbs() {
  local home out pid streak
  home=$(make_ready_home watcher-dedupe); out="$home/watch.out"
  watch_home_bg "$home" "$out" >/dev/null
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "dedupe fixture did not fire first: $(cat "$out")"; }
  ack_queue "$home" || fail "dedupe fixture could not acknowledge the first wake"
  rm -f "$out"
  set_mtime $(( $(date +%s) - 7200 )) "$home/state/.last-heartbeat"
  watch_home_bg "$home" "$out"
  pid=$!
  if ! wait_poll_cycle "$home/state" "$pid"; then
    reap "$pid"; fail "unchanged set exited instead of absorbing: $(cat "$out")"
  fi
  streak=$(cat "$home/state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] || { reap "$pid"; fail "absorbed dedupe did not advance the backoff streak"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "unchanged set re-fired: $(cat "$out")"; }
  [ "$(queue_ready_rows "$home")" = 0 ] || { reap "$pid"; fail "unchanged set queued again"; }
  reap "$pid"
  pass "an unchanged dispatchable set stays silent"
}

test_watcher_changed_set_fires() {
  local home out pid
  home=$(make_ready_home watcher-changed); out="$home/watch.out"
  watch_home_bg "$home" "$out" >/dev/null
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "changed-set fixture did not fire first: $(cat "$out")"; }
  ack_queue "$home" || fail "changed-set fixture could not acknowledge the first wake"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add task-three "Third task" --repo projA >/dev/null
  rm -f "$out"
  set_mtime $(( $(date +%s) - 7200 )) "$home/state/.last-heartbeat"
  watch_home_bg "$home" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "changed set did not wake: $(cat "$out")"; }
  grep -F "check: ready-capacity: 3 queued task(s) ready with room to run: task-one task-three task-two" "$out" >/dev/null     || fail "changed set woke without its new content: $(cat "$out")"
  [ "$(queue_ready_rows "$home")" = 1 ] || fail "changed set left no single fresh durable check row"
  pass "a changed dispatchable set wakes again with its new content"
}

test_watcher_away_record_absorbs() {
  local home out pid streak
  home=$(make_ready_home watcher-away); out="$home/watch.out"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null
  touch "$home/state/.last-heartbeat"
  set_mtime $(( $(date +%s) - 7200 )) "$home/state/.last-heartbeat"
  watch_home_bg "$home" "$out"
  pid=$!
  if ! wait_poll_cycle "$home/state" "$pid"; then
    reap "$pid"; fail "away record exited instead of absorbing: $(cat "$out")"
  fi
  streak=$(cat "$home/state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] || { reap "$pid"; fail "away absorb did not advance the backoff streak"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "away record fired: $(cat "$out")"; }
  [ ! -s "$home/state/.wake-queue" ] || { reap "$pid"; fail "away record queued a wake"; }
  reap "$pid"
  pass "ready work under the away record waits for the return"
}

test_watcher_no_headroom_absorbs() {
  local home out pid streak
  home=$(make_ready_home watcher-full); out="$home/watch.out"
  printf 'projA 1
' > "$home/config/project-capacity"
  home_add_holder "$home"
  touch "$home/state/.last-heartbeat"
  set_mtime $(( $(date +%s) - 7200 )) "$home/state/.last-heartbeat"
  watch_home_bg "$home" "$out"
  pid=$!
  if ! wait_poll_cycle "$home/state" "$pid"; then
    reap "$pid"; fail "full project exited instead of absorbing: $(cat "$out")"
  fi
  streak=$(cat "$home/state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] || { reap "$pid"; fail "full-project absorb did not advance the backoff streak"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "full project fired: $(cat "$out")"; }
  [ ! -s "$home/state/.wake-queue" ] || { reap "$pid"; fail "full project queued a wake"; }
  [ ! -e "$home/state/.ready-capacity-notified" ] || { reap "$pid"; fail "an absorb committed a fired-set record"; }
  reap "$pid"
  pass "ready work without room stays silent and records nothing"
}

test_watcher_foreign_home_absorbs() {
  local homeA homeB out pid streak
  homeA=$(make_ready_home watcher-foreign-a)
  homeB=$(make_ready_home watcher-foreign-b)
  out="$homeB/watch.out"
  touch "$homeB/state/.last-heartbeat"
  set_mtime $(( $(date +%s) - 7200 )) "$homeB/state/.last-heartbeat"
  PATH="$homeA/fakebin:$PATH" FM_HOME="$homeA" FM_STATE_OVERRIDE="$homeB/state" FM_CREW_STATE_BIN="$homeA/fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_MAC_LOAD_MOCK_5MIN=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$homeB/state" "$pid"; then
    reap "$pid"; fail "foreign home exited instead of absorbing: $(cat "$out")"
  fi
  streak=$(cat "$homeB/state/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -ge 1 ] || { reap "$pid"; fail "foreign-home absorb did not advance the backoff streak"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "foreign home fired: $(cat "$out")"; }
  [ ! -s "$homeB/state/.wake-queue" ] || { reap "$pid"; fail "foreign home queued a wake"; }
  reap "$pid"
  pass "a watcher observing foreign state never dispatches on it"
}

test_helper_lists_dispatchable
test_helper_empty_at_capacity
test_helper_empty_when_loaded
test_helper_empty_when_heavy_capped
test_helper_unreadable_backlog_is_exit_two
test_helper_skips_held
test_watcher_fires_once_per_set
test_watcher_same_set_absorbs
test_watcher_changed_set_fires
test_watcher_away_record_absorbs
test_watcher_no_headroom_absorbs
test_watcher_foreign_home_absorbs
