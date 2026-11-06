#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v unshare >/dev/null 2>&1 ||
  ! unshare -Urpf --mount-proc true >/dev/null 2>&1; then
  printf 'skip: an unprivileged pid namespace is unavailable to count forks\n'
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-idle-forks)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
mkdir -p "$REMOTE_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/state/jobs"
chmod 700 "$TMP_ROOT/state" "$TMP_ROOT/state/jobs"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-mkdir-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'idle fork fixture'

# The record mix an idle winbox queue held when its serving loop forked 173 times a second.
for i in $(seq 1 42); do mkdir -m 700 "$TMP_ROOT/state/jobs/job-empty$i"; done
for i in 1 2 3 4; do
  mkdir -m 700 "$TMP_ROOT/state/jobs/job-done$i"
  printf 'done\n' > "$TMP_ROOT/state/jobs/job-done$i/state"
done

# Inside a fresh pid namespace ns_last_pid counts every fork the serving loop makes.
cat > "$TMP_ROOT/measure.sh" <<'SH'
"$1/bin/fm-remote-job-worker.sh" --serve > "$2/serve.log" 2>&1 &
/bin/sleep 3
read -r before < /proc/sys/kernel/ns_last_pid
/bin/sleep 5
read -r after < /proc/sys/kernel/ns_last_pid
printf '%s\n' "$(( (after - before - 1) / 5 ))"
SH
FORKS=$(HOME="$TMP_ROOT/home" FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  unshare -Urpf --mount-proc bash "$TMP_ROOT/measure.sh" "$REMOTE_ROOT" "$TMP_ROOT") || fail "the serving loop measurement failed: $(cat "$TMP_ROOT/serve.log" 2>/dev/null)"
case "$FORKS" in ''|*[!0-9]*) fail "the serving loop measurement was not a count: $FORKS" ;; esac
[ "$FORKS" -lt 100 ] || fail "an idle serving loop forked $FORKS times a second, at or above the 100 bound"
pass "an idle serving loop forks $FORKS times a second rather than the 173 a second it cost before"

printf 'remote job idle fork tests complete\n'
