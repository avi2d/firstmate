#!/usr/bin/env bash
# Per-home remote status feed through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-feed)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/w1" "$CLAIMS"
ADAPTER="$ROOT/bin/fm-procevent-remote-feed.sh"
FEED="$ROOT/bin/fm-remote-status-feed.sh"
ROUTE=winhome
SID="remote-feed-$ROUTE"

cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/remote-homes.md" <<EOF
- $ROUTE - Winbox execution home (host: remote-mac; root: $ROOT; home: $REMOTE; session: fm-lab-test; scope: workers; projects: scratch; added 2026-11-09)
EOF
printf 'remote_route=%s\n' "$ROUTE" > "$PARENT/state/w1.meta"
printf 'remote_route=%s\n' "$ROUTE" > "$PARENT/state/w2.meta"
printf '# Lab report\n\nAll green.\n' > "$REMOTE/data/w1/report.md"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "${FM_FEED_TRANSPORT_ERROR:-}" != 1 ] || exit 255
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_FEED_WAIT_SECONDS="${FM_REMOTE_FEED_WAIT_SECONDS:-5}" \
  "$@"
}

remote_home_env() {
  FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$ROOT" "$@"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

empty_hash() { sha256_file /dev/null; }

feed_result() {
  remote_home_env "$FEED" 0 > "$1"
}

test_host_feed_multiplexes_tasks() {
  printf 'working [at=100]: first line\n' >> "$REMOTE/state/w1.status"
  printf 'scout [at=101]: second task\n' >> "$REMOTE/state/w2.status"
  (printf 'w1 %s %s\n' 0 "$(empty_hash)"; printf 'w2 %s %s\n' 0 "$(empty_hash)") | feed_result "$TMP_ROOT/two.result"
  assert_grep 'schema=fm-remote-feed.v1' "$TMP_ROOT/two.result" "host feed omits the envelope schema"
  assert_grep 'tasks=2' "$TMP_ROOT/two.result" "host feed reports the wrong task count"
  assert_grep 'first line' "$TMP_ROOT/two.result" "host feed loses the first task delta"
  assert_grep 'second task' "$TMP_ROOT/two.result" "host feed loses the second task delta"
  pass "host feed multiplexes one delta block per grown task"
}

test_host_feed_empty_window() {
  h1=$(sha256_file "$REMOTE/state/w1.status")
  s1=$(wc -c < "$REMOTE/state/w1.status" | tr -d ' ')
  h2=$(sha256_file "$REMOTE/state/w2.status")
  s2=$(wc -c < "$REMOTE/state/w2.status" | tr -d ' ')
  rc=0
  (printf 'w1 %s %s\n' "$s1" "$h1"; printf 'w2 %s %s\n' "$s2" "$h2") | feed_result "$TMP_ROOT/empty.result" || rc=$?
  [ "$rc" -eq 75 ] || fail "quiet host feed returned $rc instead of 75"
  pass "quiet host feed exits with the empty-window status"
}

test_host_feed_continuity_break() {
  h1=$(sha256_file "$REMOTE/state/w1.status")
  s1=$(wc -c < "$REMOTE/state/w1.status" | tr -d ' ')
  printf 'short\n' > "$REMOTE/state/w1.status"
  (printf 'w1 %s %s\n' "$s1" "$h1") | feed_result "$TMP_ROOT/broken.result"
  assert_grep 'status=continuity-broken' "$TMP_ROOT/broken.result" "truncated host log does not surface a continuity break"
  assert_grep 'reason=truncated' "$TMP_ROOT/broken.result" "continuity break omits its reason"
  pass "truncated host log surfaces a continuity break with its reason"
}

test_host_feed_rejects_bad_vector() {
  rc=0
  (printf 'w1/../x %s %s\n' 0 "$(empty_hash)") | feed_result "$TMP_ROOT/bad.result" || rc=$?
  [ "$rc" -eq 1 ] || fail "bad cursor vector returned $rc instead of 1"
  pass "host feed refuses a cursor vector with an unsafe task id"
}

test_classify_names_window_kinds() {
  [ "$("$ADAPTER" classify "$TMP_ROOT/two.result")" = delta ] || fail "delta window misclassified"
  [ "$("$ADAPTER" classify "$TMP_ROOT/broken.result")" = continuity-broken ] || fail "break-only window misclassified"
  printf 'not a feed\n' > "$TMP_ROOT/junk.result"
  [ "$("$ADAPTER" classify "$TMP_ROOT/junk.result")" = malformed ] || fail "junk window misclassified"
  pass "classify names delta, break-only, and malformed windows"
}

reset_w1() {
  rm -f -- "$PARENT/state/w1.status" "$PARENT/state/.remote-feed-mirrored-w1"
  rm -rf -- "$PARENT/state/remote-feeds/$ROUTE"
  rm -f -- "$PARENT/state/w2.status" "$PARENT/state/.remote-feed-mirrored-w2"
  : > "$REMOTE/state/w1.status"
  : > "$REMOTE/state/w2.status"
}
feed_empty_vector() {
  (printf 'w1 %s %s\n' 0 "$(empty_hash)"; printf 'w2 %s %s\n' 0 "$(empty_hash)") | feed_result "$1"
}

test_ingest_appends_and_dedups() {
  reset_w1
  printf 'working [at=100]: first line\nnote [at=101]: second line\n' >> "$REMOTE/state/w1.status"
  feed_empty_vector "$TMP_ROOT/ingest.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/ingest.result" > "$TMP_ROOT/ingest.out" \
    || fail "delta ingest failed"
  assert_grep 'first line' "$PARENT/state/w1.status" "ingest loses the first mirrored line"
  assert_grep 'second line' "$PARENT/state/w1.status" "ingest loses the second mirrored line"
  before=$(wc -c < "$PARENT/state/w1.status" | tr -d ' ')
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/ingest.result" 9 > "$TMP_ROOT/ingest9.out" \
    || fail "sequenced ingest failed"
  [ -f "$PARENT/state/remote-feeds/$ROUTE/w1.9.ingested" ] \
    || fail "sequenced ingest leaves no receipt"
  after=$(wc -c < "$PARENT/state/w1.status" | tr -d ' ')
  [ "$before" = "$after" ] || fail "replay appends bytes a second time"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/ingest.result" 9 > "$TMP_ROOT/replay.out" \
    || fail "receipted replay failed"
  assert_grep 'appended=0' "$TMP_ROOT/replay.out" "receipted replay reports appended bytes"
  pass "ingest mirrors new lines once and replays silently"
}
test_break_escalates_and_adopts() {
  reset_w1
  printf 'working [at=100]: first line\nnote [at=101]: second line\n' >> "$REMOTE/state/w1.status"
  feed_empty_vector "$TMP_ROOT/break-base.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/break-base.result" >/dev/null \
    || fail "baseline ingest failed"
  h1=$(sha256_file "$REMOTE/state/w1.status")
  s1=$(wc -c < "$REMOTE/state/w1.status" | tr -d ' ')
  printf 'rewritten log\n' > "$REMOTE/state/w1.status"
  (printf 'w1 %s %s\n' "$s1" "$h1"; printf 'w2 %s %s\n' 0 "$(empty_hash)") | feed_result "$TMP_ROOT/break.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/break.result" 3 > "$TMP_ROOT/break.out" \
    || fail "break ingest failed"
  assert_grep 'remote-feed-continuity-w1' "$PARENT/state/w1.status" "break escalates nowhere" 
  assert_grep 'breaks=1' "$TMP_ROOT/break.out" "break ingest hides the break"
  ht=$(sha256_file "$REMOTE/state/w1.status")
  st=$(wc -c < "$REMOTE/state/w1.status" | tr -d ' ')
  printf 'working [at=102]: after rewrite\n' >> "$REMOTE/state/w1.status"
  (printf 'w1 %s %s\n' "$st" "$ht") | feed_result "$TMP_ROOT/after.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/after.result" 4 >/dev/null \
    || fail "post-adopt ingest failed"
  assert_grep 'after rewrite' "$PARENT/state/w1.status" "adopted cursor misses the next delta"
  pass "break escalates into its own stream and the proven prefix is adopted"
}
test_documents_land_in_task_tree() {
  reset_w1
  rm -rf -- "$PARENT/data/w1" "$PARENT/data/other"
  printf 'scout [at=200]: draft ready report=data/w1/report.md\n' >> "$REMOTE/state/w1.status"
  feed_empty_vector "$TMP_ROOT/docs.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/docs.result" >/dev/null \
    || fail "document ingest failed"
  [ -f "$PARENT/data/w1/report.md" ] || fail "offered report never lands"
  cmp "$REMOTE/data/w1/report.md" "$PARENT/data/w1/report.md" \
    || fail "landed report differs from the offered bytes"
  assert_grep 'report=data/w1/report.md' "$PARENT/state/w1.status" "mirrored line loses the pointer"
  h1=$(sha256_file "$REMOTE/state/w1.status")
  s1=$(wc -c < "$REMOTE/state/w1.status" | tr -d ' ')
  printf 'scout [at=201]: other tree report=data/other/report.md\n' >> "$REMOTE/state/w1.status"
  (printf 'w1 %s %s\n' "$s1" "$h1") | feed_result "$TMP_ROOT/docs-outside.result"
  remote_env "$ADAPTER" ingest "$ROUTE" "$TMP_ROOT/docs-outside.result" >/dev/null \
    || fail "outside-tree ingest failed"
  [ ! -e "$PARENT/data/other" ] || fail "outside-tree pointer transfers a document"
  assert_grep 'remote document did not transfer for w1: data/other/report.md' "$PARENT/state/w1.status" "outside-tree pointer leaves no note"
  pass "task-tree documents land byte-identical and outside pointers leave a note"
}
test_ensure_armed_is_idempotent() {
  remote_env "$ADAPTER" ensure-armed "$ROUTE" > "$TMP_ROOT/ensure1.out" || fail "ensure-armed failed"
  remote_env "$ADAPTER" ensure-armed "$ROUTE" > "$TMP_ROOT/ensure2.out" || fail "ensure-armed is not idempotent"
  assert_grep "armed: $SID" "$TMP_ROOT/ensure2.out" "ensure-armed names the wrong source"
  pass "ensure-armed registers once and rejoins afterwards"
}

test_runner_applies_one_window() {
  reset_w1
  remote_env "$ADAPTER" ensure-armed "$ROUTE" >/dev/null || fail "round-trip arm failed"
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  STARTER=$!
  printf 'working [at=300]: round trip line\n' >> "$REMOTE/state/w1.status"
  handled=''
  attempt=0
  while [ -z "$handled" ] && [ "$attempt" -lt 600 ]; do
    attempt=$((attempt + 1))
    for candidate in "$PARENT/state/procevent-inbox/$SID".*.handled; do
      [ -e "$candidate" ] || continue
      handled=$candidate
      break
    done
    sleep 0.05
  done
  kill "$STARTER" 2>/dev/null || true
  [ -n "$handled" ] || fail "runner leaves no handled marker for the applied window"
  assert_grep 'round trip line' "$PARENT/state/w1.status" "handled window never reaches the mirrored stream"
  listed=$(remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | awk -v id="$SID" 'NR > 1 && $1 == id { print $1; exit }')
  [ "$listed" = "$SID" ] || fail "handle does not re-arm the next vector-anchored source"
  remote_env "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  pass "runner captures, autohandles, and re-arms one window"
}

fm_test_run \
  test_host_feed_multiplexes_tasks \
  test_host_feed_empty_window \
  test_host_feed_continuity_break \
  test_host_feed_rejects_bad_vector \
  test_classify_names_window_kinds \
  test_ingest_appends_and_dedups \
  test_break_escalates_and_adopts \
  test_documents_land_in_task_tree \
  test_ensure_armed_is_idempotent \
  test_runner_applies_one_window
