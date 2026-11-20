#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,

lib_eval() {
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-pi}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-pi}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.pi/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.pi/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.pi, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' pi ;;
  900:args=) printf '%s\n' 'pi' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' pi ;;
  920:args=) printf '%s\n' 'pi' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}


test_competing_pi_cannot_take_a_live_session_lock() {
  local home="$TMP_ROOT/competing" fixture out status=0
  fixture=$(fm_fakebin "$TMP_ROOT/pi")
  ln -s /bin/bash "$fixture/pi"
  mkdir -p "$home/state"
  FM_HOME="$home" LOCK="$ROOT/bin/fm-lock.sh" "$fixture/pi" -c '
    "$LOCK" > "$FM_HOME/state/result" 2>&1 || exit
    printf "%s\n" "$$" > "$FM_HOME/state/ready"
    while [ ! -e "$FM_HOME/state/release" ] && [ "$SECONDS" -lt 15 ]; do sleep 0.05; done
  ' &
  local holder=$!
  local n=0
  while [ ! -s "$home/state/ready" ] && kill -0 "$holder" 2>/dev/null && [ "$n" -lt 80 ]; do
    sleep 0.05
    n=$((n + 1))
  done
  if [ ! -s "$home/state/ready" ]; then
    : > "$home/state/release"
    wait "$holder" || true
    fail "the first Pi could not acquire its lock: $(cat "$home/state/result")"
  fi
  out=$(FM_HOME="$home" "$fixture/pi" -c '"$1"; rc=$?; exit "$rc"' _ "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  local recorded
  recorded=$(<"$home/state/.lock")
  : > "$home/state/release"
  wait "$holder" || fail "the lock holder exited before its release"
  [ "$status" -ne 0 ] || fail "a second Pi took the first Pi's lock"
  assert_contains "$out" "another live firstmate session holds the lock" "the second Pi did not see the live owner"
  [ "$recorded" = "$holder" ] || fail "the second Pi changed the lock to $recorded"
  status=0
  out=$(FM_HOME="$home" "$fixture/pi" -c '"$1"; rc=$?; exit "$rc"' _ "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  expect_code 0 "$status" "the next Pi must reclaim a lock after the owner exits: $out"
  [ "$(<"$home/state/.lock")" != "$holder" ] || fail "reclaim left the original Pi pid in the lock"
  pass "session-lock: a second Pi cannot steal the lock but can reclaim it after the owner exits"
}

test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_pi_cannot_take_a_live_session_lock
