#!/usr/bin/env bash
# Behavior tests for symlinked inheritable config on remote routes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-remote-inherit-symlink)

# Fake transport that runs the real receiver in the fake remote home, case-for-
# case the same decode fm-on.sh feeds a real ssh.
install_fake_transport() {
  local fakebin=$1
  cat > "$fakebin/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fakebin/inherit-ssh"
}

# Run the real sender against the fake remote home through the fake transport.
run_remote_push() {
  local primary=$1 remote=$2 fakebin=$3 generation=$4
  FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_DATA_OVERRIDE="$primary/data" \
    FM_SSH_BIN="$fakebin/inherit-ssh" \
    FM_INHERITABLE_CONFIG=crew-dispatch.json \
    "$ROOT/bin/fm-remote-inherit-push.sh" inherit "$generation"
}

write_registry() {
  local primary=$1 remote=$2
  printf -- '- inherit - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-30)\n' \
    "$ROOT" "$remote" > "$primary/data/secondmates.md"
}

# Direct receiver call: the same public entrypoint the fake transport runs.
remote_put_config() {
  local home=$1 payload=$2 generation=$3 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash remote inheritance payload"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    put config/crew-dispatch.json "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

test_receiver_leaves_own_symlink_destination_untouched() {
  local home skills payload out
  home="$TMP_ROOT/receiver-symlink/home"
  skills="$TMP_ROOT/receiver-symlink/skills/harness/firstmate"
  payload="$TMP_ROOT/receiver-symlink/payload.json"
  mkdir -p "$home/config" "$home/data" "$home/state" "$skills"
  printf '%s\n' '{"profiles": "remote skills bytes"}' > "$skills/crew-dispatch.json"
  ln -s "$skills/crew-dispatch.json" "$home/config/crew-dispatch.json"
  printf '%s\n' '{"profiles": "primary bytes"}' > "$payload"

  out=$(remote_put_config "$home" "$payload" 1) \
    || fail "receiver should succeed when the destination is the mate's own symlink: $out"
  assert_contains "$out" "unchanged: config/crew-dispatch.json" \
    "receiver did not report unchanged for the mate's symlink"
  [ -L "$home/config/crew-dispatch.json" ] \
    || fail "receiver replaced the mate's own symlink with a regular file"
  assert_equals "$skills/crew-dispatch.json" "$(readlink "$home/config/crew-dispatch.json")" \
    "the symlink target should be the mate's own skills file"
  assert_grep 'remote skills bytes' "$skills/crew-dispatch.json" \
    "receiver wrote through the mate's symlink into its skills clone"
  pass "receiver leaves the mate's own symlink destination untouched"
}

test_sender_follows_source_symlink_into_regular_destination() {
  local primary remote skills fakebin out
  primary="$TMP_ROOT/sender-follow/primary"
  remote="$TMP_ROOT/sender-follow/remote"
  skills="$TMP_ROOT/sender-follow/skills/harness/firstmate"
  mkdir -p "$primary/config" "$primary/data" "$remote/config" "$remote/data" "$remote/state" "$skills"
  printf '%s\n' '{"profiles": "shared dispatch bytes"}' > "$skills/crew-dispatch.json"
  ln -s "$skills/crew-dispatch.json" "$primary/config/crew-dispatch.json"
  write_registry "$primary" "$remote"
  fakebin="$TMP_ROOT/sender-follow/fakebin"
  mkdir -p "$fakebin"
  install_fake_transport "$fakebin"

  out=$(run_remote_push "$primary" "$remote" "$fakebin" 1) \
    || fail "push with a symlinked source should succeed: $out"
  assert_contains "$out" "pushed: config/crew-dispatch.json" \
    "a regular destination should receive the inherited bytes"
  [ -f "$remote/config/crew-dispatch.json" ] && [ ! -L "$remote/config/crew-dispatch.json" ] \
    || fail "regular destination should become a regular file, not a link"
  cmp -s "$skills/crew-dispatch.json" "$remote/config/crew-dispatch.json" \
    || fail "regular destination did not receive the symlink target bytes"
  pass "sender follows a source symlink and publishes its target bytes"
}

test_sender_push_preserves_remote_own_symlink() {
  local primary remote skills remote_skills fakebin out
  primary="$TMP_ROOT/sender-preserve/primary"
  remote="$TMP_ROOT/sender-preserve/remote"
  skills="$TMP_ROOT/sender-preserve/skills/harness/firstmate"
  remote_skills="$TMP_ROOT/sender-preserve/remote-skills/harness/firstmate"
  mkdir -p "$primary/config" "$primary/data" "$remote/config" "$remote/data" "$remote/state" "$skills" "$remote_skills"
  printf '%s\n' '{"profiles": "shared dispatch bytes"}' > "$skills/crew-dispatch.json"
  ln -s "$skills/crew-dispatch.json" "$primary/config/crew-dispatch.json"
  printf '%s\n' '{"profiles": "remote local bytes"}' > "$remote_skills/crew-dispatch.json"
  ln -s "$remote_skills/crew-dispatch.json" "$remote/config/crew-dispatch.json"
  write_registry "$primary" "$remote"
  fakebin="$TMP_ROOT/sender-preserve/fakebin"
  mkdir -p "$fakebin"
  install_fake_transport "$fakebin"

  out=$(run_remote_push "$primary" "$remote" "$fakebin" 1) \
    || fail "push to a mate-owned symlink destination should succeed: $out"
  assert_contains "$out" "unchanged: config/crew-dispatch.json" \
    "push should leave the remote's own symlink destination unchanged"
  [ -L "$remote/config/crew-dispatch.json" ] \
    || fail "push replaced the remote's own symlink destination"
  assert_equals "$remote_skills/crew-dispatch.json" "$(readlink "$remote/config/crew-dispatch.json")" \
    "the remote symlink should still point at its own skills clone"
  assert_grep 'remote local bytes' "$remote_skills/crew-dispatch.json" \
    "push wrote through the remote symlink into its skills clone"
  pass "sender push leaves the remote's own symlink destination untouched"
}

test_dangling_source_symlink_still_refused() {
  local primary remote fakebin out status
  primary="$TMP_ROOT/sender-dangling/primary"
  remote="$TMP_ROOT/sender-dangling/remote"
  mkdir -p "$primary/config" "$primary/data" "$remote/config" "$remote/data" "$remote/state"
  ln -s "$primary/missing-dispatch.json" "$primary/config/crew-dispatch.json"
  write_registry "$primary" "$remote"
  fakebin="$TMP_ROOT/sender-dangling/fakebin"
  mkdir -p "$fakebin"
  install_fake_transport "$fakebin"

  out=$(run_remote_push "$primary" "$remote" "$fakebin" 1 2>&1)
  status=$?
  expect_code 1 "$status" "a dangling source symlink must be refused: $out"
  [ ! -e "$remote/config/crew-dispatch.json" ] && [ ! -L "$remote/config/crew-dispatch.json" ] \
    || fail "a dangling source symlink treated as absence left a destination behind"
  pass "sender still refuses a source symlink that resolves outside a regular file"
}

test_receiver_leaves_own_symlink_destination_untouched
test_sender_follows_source_symlink_into_regular_destination
test_sender_push_preserves_remote_own_symlink
test_dangling_source_symlink_still_refused

echo "# all fm-remote-inherit-symlink tests passed"