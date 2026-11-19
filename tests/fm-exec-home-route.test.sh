#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-exec-home-route)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=bin/fm-remote-registry-lib.sh
. "$ROOT/bin/fm-remote-registry-lib.sh"

DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

legacy="- winbox - Owns winbox delivery (skills, checks) (host: winwsl; root: /home/avi2d/firstmate; home: /home/avi2d/fm-winbox; scope: Owns winbox delivery; judges scope questions; projects: secondmate-ops; added 2026-09-30)"
fm_remote_registry_parse_line "$legacy" || fail "a legacy remote record without a session stopped parsing"
[ "$FM_REMOTE_REGISTRY_SESSION" = fm-remote ] || fail "a legacy remote record defaulted to '$FM_REMOTE_REGISTRY_SESSION' instead of fm-remote"
[ "$FM_REMOTE_REGISTRY_HOST" = winwsl ] || fail "legacy host misparsed: $FM_REMOTE_REGISTRY_HOST"
[ "$FM_REMOTE_REGISTRY_SCOPE" = "Owns winbox delivery; judges scope questions" ] || fail "legacy scope misparsed: $FM_REMOTE_REGISTRY_SCOPE"
pass "fm-exec-home-route: a remote record without a session still parses and defaults the session to fm-remote"

with_session="- execone - Headless execution (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-one; session: lab-one; scope: Headless work; projects: scratch; added 2026-11-08)"
fm_remote_registry_parse_line "$with_session" || fail "a remote record with a session stopped parsing"
[ "$FM_REMOTE_REGISTRY_SESSION" = lab-one ] || fail "the session field misparsed: $FM_REMOTE_REGISTRY_SESSION"
[ "$FM_REMOTE_REGISTRY_HOME" = /home/avi2d/exec-one ] || fail "the home beside a session misparsed: $FM_REMOTE_REGISTRY_HOME"
[ "$FM_REMOTE_REGISTRY_SCOPE" = "Headless work" ] || fail "the scope after a session misparsed: $FM_REMOTE_REGISTRY_SCOPE"
pass "fm-exec-home-route: a remote record names its Herdr session between the home and the scope"

bad_session="- bad - Bad session (host: h; root: /r; home: /e; session: has space; scope: W; projects: p; added 2026-11-08)"
fm_remote_registry_parse_line "$bad_session" && fail "a session with interior whitespace parsed instead of being refused"
pass "fm-exec-home-route: a session value no Herdr session could carry is refused rather than mangled"

cat > "$DATA/remote-homes.md" <<'EOF'
- execone - Headless execution (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-one; session: lab-one; scope: Headless work; projects: scratch; added 2026-11-08)
EOF
[ "$(fm_remote_registry_field "$DATA/remote-homes.md" execone session)" = lab-one ] \
  || fail "the session field did not read back lab-one"
pass "fm-exec-home-route: the session field reads the recorded value and defaults to fm-remote"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SSH_LOG="$TMP_ROOT/ssh.log"
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
printf 'host=%s\n' "$1" >> "$FM_FAKE_SSH_LOG"
printf 'root=%s\n' "$(printf '%s' "$4" | base64 --decode 2>/dev/null || printf '%s' "$4" | base64 -D)" >> "$FM_FAKE_SSH_LOG"
printf 'home=%s\n' "$(printf '%s' "$5" | base64 --decode 2>/dev/null || printf '%s' "$5" | base64 -D)" >> "$FM_FAKE_SSH_LOG"
exit 0
SH
chmod +x "$FAKEBIN/fake-ssh"

fm_on() {
  FM_HOME="$TMP_ROOT/local-home" \
  FM_DATA_OVERRIDE="$DATA" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_LOG="$SSH_LOG" \
  "$ROOT/bin/fm-on.sh" "$@"
}
mkdir -p "$TMP_ROOT/local-home"

: > "$SSH_LOG"
fm_on execone fm-remote-file.sh get x >/dev/null 2>&1 \
  || fail "the execution-home route did not resolve"
assert_contains "$(cat "$SSH_LOG")" "host=exec-alias" "the execution-home route did not reach its SSH alias"
assert_contains "$(cat "$SSH_LOG")" "home=/home/avi2d/exec-one" "the execution-home route did not reach its home"
pass "fm-exec-home-route: an execution-home id resolves to its own host, root, and home"
printf -- '- exectwo - Another execution home (host: exec-alias; root: /scratch/root; home: /scratch/two; scope: Test; projects: scratch; added 2026-11-08)\n' >> "$DATA/remote-homes.md"
: > "$SSH_LOG"
fm_on exec-alias fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a shared host alias resolved instead of being refused"
[ ! -s "$SSH_LOG" ] || fail "an ambiguous alias dialed before the refusal"
pass "a shared host alias does not send a command to the first execution home"


cat > "$DATA/remote-homes.md" <<'EOF'
- broken - no fields at all
EOF
fm_on broken fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a malformed execution-home record parsed instead of being refused"
pass "fm-exec-home-route: a malformed execution-home record fails closed with the registry error"

rm -f -- "$DATA/remote-homes.md"
fm_on anything fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a missing execution-home registry resolved"
pass "a missing registry does not dial"

PLACED="$TMP_ROOT/placed"
mkdir -p "$PLACED"
cat > "$PLACED/projects.md" <<'EOF'
- alpha [direct-PR host=exec-route] - placed after the mode (added 2026-01-01)
- beta [host=exec-route direct-PR +yolo] - placed before the mode (added 2026-01-01)
- gamma [direct-PR] - no placement (added 2026-01-01)
- delta [host= direct-PR] - an empty placement (added 2026-01-01)
EOF
run_placement() {
  FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" --placement "$1" 2>/dev/null
}
[ "$(run_placement alpha)" = exec-route ] || fail "a host token after the mode did not resolve: $(run_placement alpha)"
[ "$(run_placement beta)" = exec-route ] || fail "a host token before the mode did not resolve: $(run_placement beta)"
[ "$(run_placement gamma)" = "" ] || fail "a project with no host token placed itself: $(run_placement gamma)"
[ "$(run_placement delta)" = "" ] || fail "an empty host token placed itself: $(run_placement delta)"
missing_err=$(FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" --placement zz 2>&1 >/dev/null)
[ "$(run_placement zz)" = "" ] || fail "an unknown project placed itself"
[ -n "$missing_err" ] || fail "an unknown project placed itself silently"
pass "fm-exec-home-route: --placement reads the host token in any order and prints nothing when absent"

[ "$(FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" alpha 2>/dev/null)" = "direct-PR off" ] \
  || fail "the host token changed the default posture output"
[ "$(FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" --branch-prefix beta 2>/dev/null)" = "fm/" ] \
  || fail "the host token changed the branch-prefix output"
[ "$(FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" --forge gamma 2>/dev/null)" = "none" ] \
  || fail "the host token changed the forge output"
pass "fm-exec-home-route: the host token leaves the default, branch-prefix, and forge outputs unchanged"

printf -- '- bad [direct-PR host="a;b"] - a hostile placement (added 2026-01-01)\n' >> "$PLACED/projects.md"
bad_out=$(FM_DATA_OVERRIDE="$PLACED" "$ROOT/bin/fm-project-mode.sh" --placement bad 2>"$TMP_ROOT/placement.err")
bad_rc=$?
[ "$bad_rc" -eq 3 ] || fail "a hostile placement did not refuse (rc $bad_rc, got '$bad_out')"
[ -z "$bad_out" ] || fail "a refused placement still handed the caller a route: '$bad_out'"
assert_contains "$(cat "$TMP_ROOT/placement.err")" "malformed host= placement" "the placement refusal did not name the token"
pass "fm-exec-home-route: a hostile host token is refused with nothing on stdout"

echo "# fm-exec-home-route.test.sh: all assertions passed"
