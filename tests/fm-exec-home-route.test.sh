#!/usr/bin/env bash
# Behavior tests for the headless execution-home route: the optional session
# field on remote registry records, dual-registry resolution in fm-on.sh, the
# per-home Herdr session override in the remote control plane, and
# fm-project-mode.sh --placement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-exec-home-route)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

DATA="$TMP_ROOT/data"
mkdir -p "$DATA"
cat > "$DATA/secondmates.md" <<'EOF'
- winbox - Owns winbox delivery (skills, checks) (host: winwsl; root: /home/avi2d/firstmate; home: /home/avi2d/fm-winbox; scope: Owns winbox delivery; judges scope questions; projects: secondmate-ops; added 2026-09-30)
- winbox-ru - Owns the second winbox seat (host: winwsl; root: /home/avi2d/firstmate; home: /home/avi2d/fm-winbox-ru; scope: Overflow winbox work; projects: secondmate-ops; added 2026-09-30)
EOF

legacy="- winbox - Owns winbox delivery (skills, checks) (host: winwsl; root: /home/avi2d/firstmate; home: /home/avi2d/fm-winbox; scope: Owns winbox delivery; judges scope questions; projects: secondmate-ops; added 2026-09-30)"
secondmate_registry_parse_line "$legacy" || fail "a legacy remote record without a session stopped parsing"
[ "$SECONDMATE_REGISTRY_SESSION" = fm-remote ] || fail "a legacy remote record defaulted to '$SECONDMATE_REGISTRY_SESSION' instead of fm-remote"
[ "$SECONDMATE_REGISTRY_HOST" = winwsl ] || fail "legacy host misparsed: $SECONDMATE_REGISTRY_HOST"
[ "$SECONDMATE_REGISTRY_SCOPE" = "Owns winbox delivery; judges scope questions" ] || fail "legacy scope misparsed: $SECONDMATE_REGISTRY_SCOPE"
pass "fm-exec-home-route: a remote record without a session still parses and defaults the session to fm-remote"

with_session="- execone - Headless execution (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-one; session: lab-one; scope: Headless work; projects: scratch; added 2026-11-08)"
secondmate_registry_parse_line "$with_session" || fail "a remote record with a session stopped parsing"
[ "$SECONDMATE_REGISTRY_SESSION" = lab-one ] || fail "the session field misparsed: $SECONDMATE_REGISTRY_SESSION"
[ "$SECONDMATE_REGISTRY_HOME" = /home/avi2d/exec-one ] || fail "the home beside a session misparsed: $SECONDMATE_REGISTRY_HOME"
[ "$SECONDMATE_REGISTRY_SCOPE" = "Headless work" ] || fail "the scope after a session misparsed: $SECONDMATE_REGISTRY_SCOPE"
pass "fm-exec-home-route: a remote record names its Herdr session between the home and the scope"

bad_session="- bad - Bad session (host: h; root: /r; home: /e; session: has space; scope: W; projects: p; added 2026-11-08)"
secondmate_registry_parse_line "$bad_session" && fail "a session with interior whitespace parsed instead of being refused"
pass "fm-exec-home-route: a session value no Herdr session could carry is refused rather than mangled"

cat > "$DATA/remote-homes.md" <<'EOF'
- execone - Headless execution (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-one; session: lab-one; scope: Headless work; projects: scratch; added 2026-11-08)
EOF
[ "$(secondmate_registry_field "$DATA/remote-homes.md" execone session)" = lab-one ] \
  || fail "the session field did not read back lab-one"
[ "$(secondmate_registry_field "$DATA/secondmates.md" winbox session)" = fm-remote ] \
  || fail "the session field did not default to fm-remote for a legacy record"
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

: > "$SSH_LOG"
fm_on winbox fm-remote-file.sh get x >/dev/null 2>&1 \
  || fail "the winbox secondmate route stopped resolving"
assert_contains "$(cat "$SSH_LOG")" "home=/home/avi2d/fm-winbox" "winbox no longer reached its own home"
: > "$SSH_LOG"
fm_on winbox-ru fm-remote-file.sh get x >/dev/null 2>&1 \
  || fail "the winbox-ru secondmate route stopped resolving"
assert_contains "$(cat "$SSH_LOG")" "home=/home/avi2d/fm-winbox-ru" "winbox-ru no longer reached its own home"
pass "fm-exec-home-route: both secondmate routes still reach their own homes unchanged"

: > "$SSH_LOG"
fm_on winwsl fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a host alias shared by two mates resolved instead of being refused"
[ -s "$SSH_LOG" ] && fail "an ambiguous alias dialed before the refusal"
pass "fm-exec-home-route: a host alias shared by two mates is still refused without dialing"

printf -- '- winbox - A colliding execution home (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-two; session: lab-one; scope: Collision; projects: scratch; added 2026-11-08)\n' >> "$DATA/remote-homes.md"
: > "$SSH_LOG"
fm_on winbox fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "an id present in both registries resolved instead of being refused"
[ -s "$SSH_LOG" ] && fail "a cross-registry duplicate id dialed before the refusal"
pass "fm-exec-home-route: an id present in both registries is refused rather than routed to the first match"

cat > "$DATA/remote-homes.md" <<'EOF'
- broken - no fields at all
EOF
fm_on broken fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a malformed execution-home record parsed instead of being refused"
pass "fm-exec-home-route: a malformed execution-home record fails closed with the registry error"

rm -f -- "$DATA/secondmates.md" "$DATA/remote-homes.md"
fm_on anything fm-remote-file.sh get x >/dev/null 2>&1 \
  && fail "a missing pair of registries resolved instead of being refused"
pass "fm-exec-home-route: missing registries are refused with the registry error"

cat > "$DATA/remote-homes.md" <<'EOF'
- execone - Headless execution (host: exec-alias; root: /home/avi2d/exec-root; home: /home/avi2d/exec-one; session: lab-one; scope: Headless work; projects: scratch; added 2026-11-08)
EOF
: > "$SSH_LOG"
fm_on execone fm-remote-file.sh get x >/dev/null 2>&1 \
  || fail "the execution-home route did not resolve with secondmates.md absent"
assert_contains "$(cat "$SSH_LOG")" "home=/home/avi2d/exec-one" "the lone execution-home registry did not route"
pass "fm-exec-home-route: an execution-home registry routes with no secondmate registry present"

MATEHOME="$TMP_ROOT/matehome"
mkdir -p "$MATEHOME/state/parent-route" "$MATEHOME/config" "$MATEHOME/bin"
printf 'm1\n' > "$MATEHOME/.fm-secondmate-home"
printf 'fixture\n' > "$MATEHOME/AGENTS.md"
write_meta() {
  cat > "$MATEHOME/state/parent-route/m1.meta" <<EOF
window=$1:pane1
worktree=/tmp/wt
project=p
backend=herdr
endpoint_task_id=m1
herdr_session=$1
herdr_workspace_id=ws
herdr_tab_id=tab
herdr_pane_id=pane1
EOF
}
run_control() {
  FM_HOME="$MATEHOME" "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>"$TMP_ROOT/control.err"
}
write_meta fm-remote
out=$(run_control route m1) || fail "the default Herdr session stopped validating its own endpoint: $(cat "$TMP_ROOT/control.err")"
assert_contains "$out" "herdr_session=fm-remote" "the default route did not report fm-remote"
pass "fm-exec-home-route: a home without a session record keeps validating against fm-remote"

printf 'lab-x\n' > "$MATEHOME/config/herdr-session"
write_meta lab-x
out=$(run_control route m1) || fail "a recorded Herdr session stopped validating its own endpoint: $(cat "$TMP_ROOT/control.err")"
assert_contains "$out" "herdr_session=lab-x" "the recorded session did not reach the route record"
write_meta fm-remote
run_control route m1 >/dev/null 2>"$TMP_ROOT/control.err" \
  && fail "an endpoint from another session validated against the recorded one"
assert_contains "$(cat "$TMP_ROOT/control.err")" "expected 'lab-x'" "the session mismatch did not name the recorded session"
pass "fm-exec-home-route: a recorded Herdr session replaces the default in endpoint validation"

printf 'bad name!\n' > "$MATEHOME/config/herdr-session"
run_control route m1 >/dev/null 2>"$TMP_ROOT/control.err" \
  && fail "an unsafe recorded session validated instead of being refused"
assert_contains "$(cat "$TMP_ROOT/control.err")" "not a safe session name" "the unsafe session refusal did not name the record"
pass "fm-exec-home-route: an unsafe recorded session is refused rather than launched in"

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
