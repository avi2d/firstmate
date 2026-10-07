#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-ff-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-remote-inherit-batch)

install_batch_transport() {
  local fakebin=$1 mode=${2:-current}
  FM_BATCH_TRANSPORT_MODE=$mode FM_BATCH_TRANSPORT_ROOT=$ROOT
  export FM_BATCH_TRANSPORT_MODE FM_BATCH_TRANSPORT_ROOT
  cat > "$fakebin/batch-ssh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'call\n' >> "$FM_BATCH_CALL_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = batch-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_home=$(printf '%s' "$5" | base64 --decode 2>/dev/null || printf '%s' "$5" | base64 -D)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode 2>/dev/null || printf '%s' "$6" | base64 -D)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
if [ "$FM_BATCH_TRANSPORT_MODE" = old-host ] && [ "${args[1]}" = batch ]; then
  printf 'Host-local lifecycle control for the remote secondmate home selected by fm-on.\n'
  printf 'usage: fm-remote-inherit.sh put <allowlisted-relative-path> <bytes> <sha256> <generation>\n'
  exit 2
fi
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$FM_BATCH_TRANSPORT_ROOT/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fakebin/batch-ssh"
}

write_batch_registry() {
  local primary=$1 remote=$2
  printf -- '- batched - Test route (host: batch-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-30)\n' \
    "$ROOT" "$remote" > "$primary/data/secondmates.md"
}

run_batch_push() {
  local primary=$1 fakebin=$2 generation=$3
  FM_HOME="$primary" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONFIG_OVERRIDE="$primary/config" FM_DATA_OVERRIDE="$primary/data" \
    FM_SSH_BIN="$fakebin/batch-ssh" \
    FM_INHERITABLE_CONFIG='crew-harness backlog-backend' \
    "$ROOT/bin/fm-remote-inherit-push.sh" batched "$generation"
}

batch_record() {
  local rel=$1 bytes=$2 hash=$3 payload=$4 b64
  if [ "$payload" = - ]; then
    printf 'absent %s 0 %s\n' "$rel" "$hash"
  else
    b64=$(base64 < "$payload" | tr -d '\n')
    printf 'put %s %s %s\ncontent %s\n' "$rel" "$bytes" "$hash" "$b64"
  fi
}

empty_sha() {
  : > "$TMP_ROOT/empty-probe"
  fm_inherit_sha256 "$TMP_ROOT/empty-probe"
}

test_batch_applies_many_items_in_one_call() {
  local home payload bytes hash out
  home="$TMP_ROOT/many/home"
  payload="$TMP_ROOT/many/a.txt"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf 'dispatch-bytes\n' > "$payload"
  printf 'existing-backend\n' > "$home/config/backlog-backend"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload")
  existing_bytes=$(LC_ALL=C wc -c < "$home/config/backlog-backend" | tr -d ' ')
  existing_hash=$(fm_inherit_sha256 "$home/config/backlog-backend")

  {
    batch_record config/crew-harness "$bytes" "$hash" "$payload"
    batch_record config/backlog-backend "$existing_bytes" "$existing_hash" "$home/config/backlog-backend"
    batch_record data/captain-shared.md 0 "$(empty_sha)" -
  } > "$TMP_ROOT/many/batch.in"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_INHERITABLE_CONFIG='crew-harness backlog-backend' \
    "$ROOT/bin/fm-remote-inherit.sh" batch 3 < "$TMP_ROOT/many/batch.in" 2>&1) \
    || fail "a well-formed batch should apply: $out"
  assert_contains "$out" "pushed: config/crew-harness" "the new item was not pushed"
  assert_contains "$out" "unchanged: config/backlog-backend" "the identical item was not reported unchanged"
  assert_contains "$out" "unchanged: data/captain-shared.md" "the absent item was not reported unchanged"
  cmp -s "$payload" "$home/config/crew-harness" || fail "the pushed bytes do not match the payload"
  pass "batch applies many items in one receiver call"
}

test_batch_failure_applies_siblings_and_next_run_converges() {
  local home payload bytes hash out
  home="$TMP_ROOT/partial/home"
  payload="$TMP_ROOT/partial/a.txt"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf 'good-bytes\n' > "$payload"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload")

  {
    batch_record config/crew-harness "$bytes" "$hash" "$payload"
    printf 'put config/not-inherited 5 %s\ncontent aGVsbG8=\n' \
      "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  } > "$TMP_ROOT/partial/batch.in"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_INHERITABLE_CONFIG='crew-harness backlog-backend' \
    "$ROOT/bin/fm-remote-inherit.sh" batch 5 < "$TMP_ROOT/partial/batch.in" 2>&1)
  expect_code 1 "$?" "a batch with a bad item must fail: $out"
  assert_contains "$out" "pushed: config/crew-harness" "the good sibling was not applied"
  assert_contains "$out" "error: path is not inherited material: config/not-inherited" \
    "the bad item did not carry its own diagnostic"
  cmp -s "$payload" "$home/config/crew-harness" || fail "the good sibling's bytes did not land"

  {
    batch_record config/crew-harness "$bytes" "$hash" "$payload"
  } > "$TMP_ROOT/partial/retry.in"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_INHERITABLE_CONFIG='crew-harness backlog-backend' \
    "$ROOT/bin/fm-remote-inherit.sh" batch 6 < "$TMP_ROOT/partial/retry.in" 2>&1) \
    || fail "the retry should converge: $out"
  assert_contains "$out" "unchanged: config/crew-harness" "the retry did not converge"
  pass "batch failure applies siblings and the next run converges"
}

test_batch_rejects_empty_and_oversize_frames() {
  local home out
  home="$TMP_ROOT/framing/home"
  mkdir -p "$home/config" "$home/data" "$home/state"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_INHERITABLE_CONFIG='crew-harness' \
    "$ROOT/bin/fm-remote-inherit.sh" batch 1 < /dev/null 2>&1)
  expect_code 1 "$?" "an empty batch must be refused: $out"
  {
    i=0
    while [ "$i" -lt 65 ]; do
      printf 'absent config/crew-harness 0 %s\n' "$(empty_sha)"
      i=$((i + 1))
    done
  } > "$TMP_ROOT/framing/many.in"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_INHERITABLE_CONFIG='crew-harness' \
    "$ROOT/bin/fm-remote-inherit.sh" batch 1 < "$TMP_ROOT/framing/many.in" 2>&1)
  expect_code 1 "$?" "an oversize batch must be refused: $out"
  pass "batch rejects empty and oversize frames"
}

test_push_sends_all_items_over_one_transport_call() {
  local primary remote fakebin out
  primary="$TMP_ROOT/one-call/primary"
  remote="$TMP_ROOT/one-call/remote"
  mkdir -p "$primary/config" "$primary/data" "$remote/config" "$remote/data" "$remote/state"
  printf 'harness-pin\n' > "$primary/config/crew-harness"
  printf 'backend-pin\n' > "$primary/config/backlog-backend"
  write_batch_registry "$primary" "$remote"
  fakebin="$TMP_ROOT/one-call/fakebin"
  mkdir -p "$fakebin"
  install_batch_transport "$fakebin"
  export FM_BATCH_CALL_LOG="$TMP_ROOT/one-call/calls"
  : > "$FM_BATCH_CALL_LOG"

  out=$(run_batch_push "$primary" "$fakebin" 4 2>&1) \
    || fail "the batched push should succeed: $out"
  assert_contains "$out" "pushed: config/crew-harness" "the first item was not pushed"
  assert_contains "$out" "pushed: config/backlog-backend" "the second item was not pushed"
  [ "$(wc -l < "$FM_BATCH_CALL_LOG" | tr -d ' ')" = 1 ] \
    || fail "the push used $(wc -l < "$FM_BATCH_CALL_LOG") transport calls instead of one"
  cmp -s "$primary/config/crew-harness" "$remote/config/crew-harness" \
    || fail "the first item's bytes do not match"
  cmp -s "$primary/config/backlog-backend" "$remote/config/backlog-backend" \
    || fail "the second item's bytes do not match"
  pass "push sends all items over one transport call"
}

test_push_maps_old_host_batch_refusal_to_updatefirstmate() {
  local primary remote fakebin out reason
  primary="$TMP_ROOT/old-host/primary"
  remote="$TMP_ROOT/old-host/remote"
  mkdir -p "$primary/config" "$primary/data" "$remote/config" "$remote/data" "$remote/state"
  printf 'harness-pin\n' > "$primary/config/crew-harness"
  write_batch_registry "$primary" "$remote"
  fakebin="$TMP_ROOT/old-host/fakebin"
  mkdir -p "$fakebin"
  install_batch_transport "$fakebin" old-host
  export FM_BATCH_CALL_LOG="$TMP_ROOT/old-host/calls"
  : > "$FM_BATCH_CALL_LOG"

  out=$(run_batch_push "$primary" "$fakebin" 4 2>&1)
  expect_code 1 "$?" "an old host's usage refusal must fail the push: $out"
  reason=$(remote_inherit_failure_reason "$out")
  assert_contains "$reason" "run /updatefirstmate" \
    "the old-host refusal does not say how to fix it (got: $reason)"
  pass "push maps an old host's batch refusal to /updatefirstmate"
}

test_batch_applies_many_items_in_one_call
test_batch_failure_applies_siblings_and_next_run_converges
test_batch_rejects_empty_and_oversize_frames
test_push_sends_all_items_over_one_transport_call
test_push_maps_old_host_batch_refusal_to_updatefirstmate

echo "# all fm-remote-inherit-batch tests passed"
