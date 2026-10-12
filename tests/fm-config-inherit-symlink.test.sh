#!/usr/bin/env bash
# Local propagation leaves a secondmate-owned config symlink in place.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-inherit-symlink)

run_local_propagate() {
  local src=$1 dest=$2 report=$3
  FM_INHERITABLE_CONFIG=crew-dispatch.json FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$src" "$dest"
}

test_local_propagate_leaves_matching_destination_symlink() {
  local primary home skills report out
  primary="$TMP_ROOT/dest-link/primary"
  home="$TMP_ROOT/dest-link/home"
  skills="$TMP_ROOT/dest-link/skills/harness/firstmate"
  report="$TMP_ROOT/dest-link/report.tsv"
  mkdir -p "$primary/config" "$home/config" "$skills"
  printf '%s\n' '{"profiles": "shared bytes"}' > "$primary/config/crew-dispatch.json"
  printf '%s\n' '{"profiles": "shared bytes"}' > "$skills/crew-dispatch.json"
  ln -s "$skills/crew-dispatch.json" "$home/config/crew-dispatch.json"

  out=$(run_local_propagate "$primary/config" "$home/config" "$report" 2>&1) \
    || fail "propagation past a matching destination symlink should succeed: $out"
  [ -L "$home/config/crew-dispatch.json" ] \
    || fail "propagation replaced a link that already resolves to the primary bytes"
  assert_equals "$skills/crew-dispatch.json" "$(readlink "$home/config/crew-dispatch.json")" \
    "the symlink should still point at the mate's own file"
  assert_grep "$(printf 'crew-dispatch.json\tunchanged')" "$report" \
    "the report should record the preserved link as unchanged"
  pass "local propagation leaves a matching destination symlink in place"
}

test_local_propagate_still_copies_regular_destination() {
  local primary home report
  primary="$TMP_ROOT/regular/primary"
  home="$TMP_ROOT/regular/home"
  report="$TMP_ROOT/regular/report.tsv"
  mkdir -p "$primary/config" "$home/config"
  printf '%s\n' '{"profiles": "primary bytes"}' > "$primary/config/crew-dispatch.json"

  run_local_propagate "$primary/config" "$home/config" "$report" \
    || fail "propagation into a regular destination should succeed"
  cmp -s "$primary/config/crew-dispatch.json" "$home/config/crew-dispatch.json" \
    || fail "regular destination did not receive the primary bytes"
  assert_grep "$(printf 'crew-dispatch.json\tpushed')" "$report" \
    "the report should record the copy as pushed"
  pass "local propagation still copies into a regular destination"
}

test_local_propagate_follows_source_symlink() {
  local primary home skills report
  primary="$TMP_ROOT/source-link/primary"
  home="$TMP_ROOT/source-link/home"
  skills="$TMP_ROOT/source-link/skills/harness/firstmate"
  report="$TMP_ROOT/source-link/report.tsv"
  mkdir -p "$primary/config" "$home/config" "$skills"
  printf '%s\n' '{"profiles": "shared bytes"}' > "$skills/crew-dispatch.mac.json"
  ln -s "$skills/crew-dispatch.mac.json" "$primary/config/crew-dispatch.json"

  run_local_propagate "$primary/config" "$home/config" "$report" \
    || fail "propagation from a source symlink should succeed on the same machine"
  [ -f "$home/config/crew-dispatch.json" ] && [ ! -L "$home/config/crew-dispatch.json" ] \
    || fail "regular destination should become a regular file, not a link"
  cmp -s "$skills/crew-dispatch.mac.json" "$home/config/crew-dispatch.json" \
    || fail "regular destination did not receive the symlink target bytes"
  pass "local propagation follows a source symlink on the same machine"
}

test_local_propagate_leaves_matching_destination_symlink
test_local_propagate_still_copies_regular_destination
test_local_propagate_follows_source_symlink

echo "# all fm-config-inherit-symlink tests passed"
