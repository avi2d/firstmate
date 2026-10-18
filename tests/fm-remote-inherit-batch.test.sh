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

test_batch_applies_many_items_in_one_call
test_batch_failure_applies_siblings_and_next_run_converges
test_batch_rejects_empty_and_oversize_frames

echo "# all fm-remote-inherit-batch tests passed"
