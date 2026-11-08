#!/usr/bin/env bash
# End-to-end seed of a headless execution home over the deterministic generic
# SSH boundary: the seed records the route, gates on the readiness probe, and
# provisions a home with no charter, no board, and a per-route Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-exec-seed)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SSH_COUNT="$TMP_ROOT/ssh.count"
ORIGIN="$TMP_ROOT/alpha.git"
SEED_DATE=$(date +%F)
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT"
cleanup() {
  local pid
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    FM_REMOTE_JOB_STATE="$TMP_ROOT/remote-jobs"
    fm_remote_job_stop_worker_tree "$pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'

git init -q --bare "$ORIGIN"
git -C "$PARENT/projects" init -q -b main scratch
git -C "$PARENT/projects/scratch" config user.email test@example.com
git -C "$PARENT/projects/scratch" config user.name Test
printf 'scratch\n' > "$PARENT/projects/scratch/README.md"
git -C "$PARENT/projects/scratch" add README.md
git -C "$PARENT/projects/scratch" commit -qm init
git -C "$PARENT/projects/scratch" remote add origin "file://$ORIGIN"
git -C "$PARENT/projects/scratch" push -q -u origin main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
cat > "$PARENT/data/projects.md" <<EOF
- scratch [direct-PR] - a fixture scratch project (added $SEED_DATE)
EOF
cat > "$PARENT/data/secondmates.md" <<'EOF'
- winbox - Owns winbox overflow (host: winwsl; root: /home/avi2d/firstmate; home: /home/avi2d/fm-winbox; scope: Overflow work; projects: other; added 2026-09-30)
EOF

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = exec-alias ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_name=$(perl -MMIME::Base64=decode_base64 -e 'print((split(/\0/, decode_base64($ARGV[0])))[0])' "$argv_b64")
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. The real doctor's
# execution-home wording is asserted below against the real binary; this
# boundary owns only what the seed does with a ready verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'ok: remote execution-home readiness confirmed on this host\n'
  exit 0
fi
cd "$FM_FAKE_REMOTE_CWD" || exit 93
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

export FM_HOME="$PARENT"
export FM_ROOT_OVERRIDE="$REMOTE_ROOT"
export FM_SSH_BIN="$FAKEBIN/fake-ssh"
export FM_FAKE_SSH_COUNT="$SSH_COUNT"
export FM_FAKE_REMOTE_CWD="$REMOTE_ROOT/bin"
export FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux

seed() { "$REMOTE_ROOT/bin/fm-remote-home-seed.sh" "$@" 2>"$TMP_ROOT/seed.err"; }
ssh_count() { cat "$SSH_COUNT" 2>/dev/null || echo 0; }

seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" \
  || fail "the execution-home seed failed: $(cat "$TMP_ROOT/seed.err")"
assert_contains "$(cat "$TMP_ROOT/seed.out")" "provisioned: $REMOTE_HOME projects=1" \
  "the seed did not report the provisioned execution home"
pass "fm-remote-exec-seed: --exec seeds the route and reports the provisioned home"

REG="$PARENT/data/remote-homes.md"
[ -f "$REG" ] || fail "the seed wrote no execution-home registry"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "the registry holds no single execone record: $(cat "$REG")"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
[ "$(secondmate_registry_field "$REG" execone host)" = exec-alias ] || fail "the registry host misrecorded"
[ "$(secondmate_registry_field "$REG" execone root)" = "$REMOTE_ROOT" ] || fail "the registry root misrecorded"
[ "$(secondmate_registry_field "$REG" execone home)" = "$REMOTE_HOME" ] || fail "the registry home misrecorded"
[ "$(secondmate_registry_field "$REG" execone session)" = lab-x ] || fail "the registry session misrecorded"
[ "$(secondmate_registry_field "$REG" execone projects)" = scratch ] || fail "the registry projects misrecorded"
pass "fm-remote-exec-seed: the registry records the route with its per-route session"

[ "$(cat "$REMOTE_HOME/.fm-exec-home")" = execone ] || fail "the execution marker misrecorded"
[ -e "$REMOTE_HOME/.fm-secondmate-home" ] && fail "the execution home carries a secondmate marker"
[ "$(cat "$REMOTE_HOME/config/backlog-backend")" = manual ] || fail "the execution home did not opt out of the task board"
[ "$(cat "$REMOTE_HOME/config/herdr-session")" = lab-x ] || fail "the execution home did not record its Herdr session"
[ -d "$REMOTE_HOME/projects/scratch/.git" ] || fail "the execution home did not clone its project"
[ -d "$REMOTE_HOME/.git" ] || fail "the execution home is not a Firstmate checkout"
[ -e "$REMOTE_HOME/data/charter.md" ] && fail "the execution home scaffolded a charter it never reads"
grep -q '^- scratch ' "$REMOTE_HOME/data/projects.md" || fail "the execution home lost its project record"
pass "fm-remote-exec-seed: the provisioned home is headless, boardless, and bound to its session"

out=$(FM_HOME="$PARENT" "$REMOTE_ROOT/bin/fm-on.sh" execone fm-remote-doctor.sh 2>"$TMP_ROOT/seed.err") \
  || fail "the seeded route did not carry the readiness probe: $(cat "$TMP_ROOT/seed.err")"
assert_contains "$out" "ok: remote execution-home readiness confirmed on this host" \
  "the readiness probe did not travel the seeded route"
pass "fm-remote-exec-seed: the seeded route carries the readiness probe"

out=$(FM_HOME="$PARENT" "$REMOTE_ROOT/bin/fm-on.sh" execone fm-remote-file.sh get config/backlog-backend 2>"$TMP_ROOT/seed.err") \
  || fail "the seeded route did not carry the file read: $(cat "$TMP_ROOT/seed.err")"
[ "$out" = manual ] || fail "the remote file read returned '$out' instead of manual"
pass "fm-remote-exec-seed: the seeded route reads the remote backlog backend as manual"

before=$(ssh_count)
seed --exec execone exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-other" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "an id already bound to a different home reseeded instead of being refused"
assert_contains "$(cat "$TMP_ROOT/seed.err")" "already registered to a different" "the duplicate refusal did not name the binding"
[ "$(ssh_count)" = "$before" ] || fail "a refused duplicate id dialed the host"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "a refused duplicate rewrote the registry"
pass "fm-remote-exec-seed: an id bound to a different home is refused without dialing"

seed --exec winbox exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-clash" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "an id from the secondmate registry seeded instead of being refused"
assert_contains "$(cat "$TMP_ROOT/seed.err")" "already registered in" "the cross-registry refusal did not name the binding"
assert_contains "$(cat "$TMP_ROOT/seed.err")" "secondmates.md" "the cross-registry refusal did not name the other registry"
pass "fm-remote-exec-seed: an id present in the secondmate registry is refused"

before=$(ssh_count)
seed --exec --session 'bad name' badid exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-bad" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "an unsafe session seeded instead of being refused"
[ "$(ssh_count)" = "$before" ] || fail "a refused session dialed the host"
[ -f "$PARENT/data/remote-homes.md" ] && grep -q '^- badid ' "$REG" && fail "a refused session wrote a registry record"
pass "fm-remote-exec-seed: an unsafe session is refused before anything is written or dialed"

seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  || fail "a same-route rerun stopped converging: $(cat "$TMP_ROOT/seed.err")"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "a same-route rerun duplicated the registry record"
pass "fm-remote-exec-seed: a same-route rerun converges with a single registry record"

KINDHOME="$TMP_ROOT/doctor-kind"
mkdir -p "$KINDHOME"
printf 'execone\n' > "$KINDHOME/.fm-exec-home"
exec_out=$(FM_HOME="$KINDHOME" "$ROOT/bin/fm-remote-doctor.sh" 2>&1) || true
assert_contains "$exec_out" "execution home" "the readiness report did not name the execution home kind"
rm -f -- "$KINDHOME/.fm-exec-home"
mate_out=$(FM_HOME="$KINDHOME" "$ROOT/bin/fm-remote-doctor.sh" 2>&1) || true
assert_contains "$mate_out" "second mate" "the readiness report stopped naming the secondmate kind"
pass "fm-remote-exec-seed: the real readiness report names the home kind it inspected"

echo "# fm-remote-exec-seed.test.sh: all assertions passed"
