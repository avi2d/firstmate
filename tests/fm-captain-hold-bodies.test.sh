#!/usr/bin/env bash
# Hold bodies and reason text survive decoding, display, and cleanup.
set -u

# shellcheck source=tests/fm-captain-hold-helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-helpers.sh"

# A shown scalar field is a JSON-encoded bare string, and JSON::PP accepts one
# only when allow_nonref is on. Recent releases default it on, so this case
# forces the older default back off for every perl the command spawns - the same
# rejection a host with JSON::PP 2.27202 produces - then drives both paths that
# read a body back: holding a task for the captain, and the cleanup that retains
# a captain-held row with its deliverable.
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default() {
  local home shim id show probe scout
  home=$(make_home nonref-default)
  shim="$home/no-nonref-default"
  mkdir -p "$shim"
  cat > "$shim/FmNoNonrefDefault.pm" <<'PM'
package FmNoNonrefDefault;
require JSON::PP;
my $new = \&JSON::PP::new;
{
  no warnings 'redefine';
  *JSON::PP::new = sub { my $self = $new->(@_); $self->allow_nonref(0); $self };
}
1;
PM

  # Without this the case would pass on any decode path at all, including the
  # one this regression exists to catch.
  probe=$(printf '%s' '"probe"' | PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    perl -MJSON::PP -e 'local $/; eval { decode_json(<STDIN>) };
      print $@ ? "rejects" : "accepts";')
  [ "$probe" = rejects ] \
    || fail "the simulated older default still accepted a bare scalar"

  id=sample-nonref-body
  tasks_in "$home" add "$id" "Work carrying a body" --kind ship --repo sample \
    --body 'First line of the plan.' >/dev/null \
    || fail "could not create the task carrying a body"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_captain "$home" hold "$id" --reason "captain go needed" >/dev/null \
    || fail "a captain hold failed where allow_nonref is not on by default"
  show=$(tasks_in "$home" show "$id" --full) || fail "the held row disappeared"
  assert_contains "$show" "hold_kind: captain" "the hold lost its captain kind"
  assert_contains "$show" "Captain hold set:" "the hold lost its hold-set stamp"
  assert_contains "$show" "First line of the plan." "the hold lost the original body"

  # Cleanup reads the same body back to append the finished work's deliverable.
  scout=sample-nonref-scout
  mkdir -p "$home/data/$scout"
  tasks_in "$home" add "$scout" "Investigate the sample body decode" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Sample body decode\n\nOne captain choice remains.\n\n## References\n\n- fixture source\n' \
    > "$home/data/$scout/report.md"
  run_captain "$home" hold "$scout" --reason "captain must choose" >/dev/null \
    || fail "could not hold the investigation for the captain"
  complete_through_sibling "$home" "$scout" >/dev/null \
    || fail "the completion gate failed with the origin as its own captain call"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_teardown "$home" "$scout" > "$home/nonref.out" 2> "$home/nonref.err" \
    || fail "cleanup of a captain-held row failed where allow_nonref is not on by default: $(cat "$home/nonref.err")"
  show=$(tasks_in "$home" show "$scout" --full) || fail "the retained row disappeared"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$scout/report.md" \
    "cleanup lost the deliverable it could not decode a body to append to"
  assert_contains "$show" "Captain hold set:" "cleanup lost the hold-set stamp"
  pass "both body-decoding paths work without the allow_nonref default"
}


# Cleanup rewrites a captain-held row's body to append the finished work's
# deliverable, so every byte of that body has to survive the decode. The
# assertions below are on bytes, not characters: a decoder that prints a
# character string to a stream with no :raw layer emits a codepoint at or below
# U+00FF as one latin-1 byte, which is not valid UTF-8, and the comparison of
# decoded strings would not notice.
#
# The two characters go in separate rows on purpose. A string that holds any
# character above U+00FF is printed as UTF-8 whatever the layer, so mixing them
# in one body hides the latin-1 case entirely.

test_retained_body_keeps_its_utf8_bytes() {
  local home accented wide narrow_id wide_id stored
  home=$(make_home retain-utf8)
  # Built from escapes so this file stays ASCII and the intended bytes are
  # explicit: U+00E9 is the latin-1-representable case, U+2014 the wider one.
  accented=$(printf 'caf\xc3\xa9')
  wide=$(printf '\xe2\x80\x94')
  stored="$home/data/backlog.md"

  # A body whose characters are all at or below U+00FF.
  narrow_id=sample-utf8-narrow
  retain_row_with_body "$home" "$narrow_id" "Serve the $accented black, no sugar."
  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  assert_grep "Deliverable of the finished work: report data/$narrow_id/report.md" "$stored" \
    "cleanup did not rewrite the retained body, so nothing decoded it"
  LC_ALL=C grep -qF "$accented" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character at or below U+00FF"
  ! LC_ALL=C grep -q "$(printf '[\xe9]')" "$stored" \
    || fail "the retained body holds a lone latin-1 byte, so it is no longer valid UTF-8"

  # A body carrying a character above U+00FF keeps its bytes and stays quiet.
  wide_id=sample-utf8-wide
  retain_row_with_body "$home" "$wide_id" "Serve it $wide black, no sugar."
  LC_ALL=C grep -qF "$wide" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character above U+00FF"
  assert_no_grep "Wide character" "$home/$wide_id.err" \
    "cleanup warned about a wide character instead of writing raw bytes"

  pass "cleanup preserves every byte of a retained body's non-ASCII characters"
}

# tasks-axi refuses parentheses and line breaks in a hold reason and stores the
# rest on one markdown line. The reason is encoded where it is written and
# decoded wherever it is shown, so prose with every awkward character survives.
test_hold_reason_round_trips_awkward_characters() {
  local home id reason stored json shown start verb fields out raw rc raw_rc mode
  local title legacy body quoted_reason quoted_title quoted_legacy expected_reason until_args=()
  local malformed index=0 malformed_reasons=(
    'fm-hold-v1:/w==' 'fm-hold-v1:bm9ydGg=$' 'fm-hold-v1:bm9ydGg' 'fm-hold-v1:Zh=='
  )
  home=$(make_home reason-round-trip)
  title='Investigate literal %28, "fm-hold-v1:bm9ydGg="'
  legacy='Visit https://example.test/%28literal%29 and %0A; fm-hold-v1:bm9ydGg='
  body=$'fm-hold-v1:bm9ydGg=\n  hold_reason: "%28"\n'
  quoted_title=$(jq -cn --arg value "$title" '$value')
  quoted_legacy=$(jq -cn --arg value "$legacy" '$value')
  tasks_in "$home" add sample-legacy-call "$title" --kind captain --repo sample >/dev/null \
    || fail "could not create the legacy call"
  tasks_in "$home" hold sample-legacy-call --reason "$legacy" --kind captain >/dev/null \
    || fail "could not hold the legacy call"
  printf '%s' "$body" > "$home/legacy-body.txt"
  tasks_in "$home" update sample-legacy-call --body-file "$home/legacy-body.txt" >/dev/null \
    || fail "could not write the legacy body"

  # Historical literal reasons are persisted input, not encoder output.
  for malformed in "${malformed_reasons[@]}"; do
    id="sample-malformed-$index"
    index=$((index + 1))
    tasks_in "$home" add "$id" "Historical reason $index" --kind captain --repo sample >/dev/null \
      || fail "could not create $id"
    tasks_in "$home" hold "$id" --reason "$malformed" --kind captain >/dev/null \
      || fail "could not store the historical literal reason"
    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id" --full) \
        || fail "public $verb failed on historical literal $malformed"
      raw=$(tasks_in "$home" "$verb" "$id" --full)
      assert_equals "$raw" "$out" "public $verb changed historical literal $malformed"
    done
  done

  for id in sample-reason-call sample-dated-call; do
    until_args=()
    reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
    if [ "$id" = sample-dated-call ]; then
      until_args=(--until 2099-01-01)
      reason='fm-hold-v1:bm9ydGg='
    fi
    quoted_reason=$(jq -cn --arg value "$reason" '$value')
    run_captain "$home" hold "$id" --title "$title" --reason "$reason" \
      --repo sample ${until_args[@]+"${until_args[@]}"} >/dev/null \
      || fail "hold refused the reason for $id"
    stored=$(grep "^- \[ \] $id " "$home/data/backlog.md") \
      || fail "the held row is not on one backlog line"
    assert_contains "$stored" "(hold: fm-hold-v1:" "the persisted reason has no encoding marker"
    assert_contains "$stored" "(hold-kind: captain)" "the reason broke the hold-kind tag"

    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id") \
        || fail "public $verb failed for $id"
      shown=$(printf '%s\n' "$out" | sed -n 's/^  hold_reason: //p')
      printf '%s\n' "$shown" | jq -e --arg reason "$reason" '. == $reason' >/dev/null \
        || fail "public $verb changed the reason for $id"
      assert_contains "$out" "  title: $quoted_title" "public $verb changed the title"
    done
    for fields in hold_reason,body body,hold_reason,hold_until; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list --fields "$fields") \
        || fail "public list failed with $fields"
      assert_contains "$out" "$quoted_reason" "public list changed the reason with $fields"
      assert_contains "$out" "$quoted_title" "public list changed the title with $fields"
      raw=$(tasks_in "$home" list --fields "$fields" | grep '^  sample-legacy-call,')
      shown=$(printf '%s\n' "$out" | grep '^  sample-legacy-call,')
      assert_equals "$raw" "$shown" "public list changed legacy or unrelated fields"
      for malformed in "${malformed_reasons[@]}"; do
        assert_contains "$out" "$malformed" "public list changed historical literal $malformed"
      done
    done
    json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
    printf '%s' "$json" | jq -e --arg id "$id" --arg reason "$reason" --arg title "$title" \
      '.backlog.records[] | select(.id == $id) | .hold_reason == $reason and .title == $title' >/dev/null \
      || fail "fleet changed the reason or title for $id"
    printf '%s' "$json" | jq -e --arg reason "$legacy" --arg title "$title" \
      '.backlog.records[] | select(.id == "sample-legacy-call") |
       .hold_reason == $reason and .title == $title and .body_lines[0] == "fm-hold-v1:bm9ydGg="' >/dev/null \
      || fail "fleet changed legacy or unrelated fields"
    for malformed in "${malformed_reasons[@]}"; do
      printf '%s' "$json" | jq -e --arg reason "$malformed" \
        'any(.backlog.records[]; .hold_reason == $reason)' >/dev/null \
        || fail "fleet changed historical literal $malformed"
    done
  done

  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show sample-legacy-call --full)
  raw=$(tasks_in "$home" show sample-legacy-call --full)
  assert_equals "$raw" "$out" "public show changed legacy or unrelated fields"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list)
  raw=$(tasks_in "$home" list)
  assert_equals "$raw" "$out" "public list changed output with no reason column"
  for verb in show list; do
    out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" --help)
    raw=$(tasks_in "$home" "$verb" --help)
    assert_equals "$raw" "$out" "public $verb changed help output"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show nonexistent-call 2>&1)
  rc=$?
  raw=$(tasks_in "$home" show nonexistent-call 2>&1)
  raw_rc=$?
  [ "$raw_rc" -ne 0 ] || fail "the missing-task fixture unexpectedly exists"
  expect_code "$raw_rc" "$rc" "public show missing task"
  assert_equals "$raw" "$out" "public show changed a read error"

  expected_reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
  quoted_reason=$(jq -cn --arg value "$expected_reason" '$value')
  for mode in tool manual fallback; do
    case "$mode" in
      manual) printf 'manual\n' > "$home/config/backlog-backend" ;;
      fallback)
        rm "$home/config/backlog-backend"
        cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'read failed: literal %%28 and fm-hold-v1:bm9ydGg=\n' >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
        chmod +x "$home/fakebin/tasks-axi"
        ;;
    esac
    start=$(PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-session-start.sh" 2>&1 || true)
    assert_contains "$start" "$quoted_reason" "startup $mode changed the encoded reason"
    assert_contains "$start" 'Investigate literal %28' "startup $mode changed the title"
    assert_contains "$start" "$legacy" "startup $mode changed the legacy reason"
    assert_contains "$start" '"fm-hold-v1:bm9ydGg="' "startup $mode decoded a reason twice"
    for malformed in "${malformed_reasons[@]}"; do
      assert_contains "$start" "$malformed" "startup $mode changed historical literal $malformed"
    done
    if [ "$mode" = fallback ]; then
      assert_contains "$start" 'read failed: literal %28 and fm-hold-v1:bm9ydGg=' \
        "startup changed unrelated error text"
    fi
  done
  rm "$home/fakebin/tasks-axi"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-afk-return.sh" check 2>&1 || true)
  assert_contains "$out" "$quoted_reason" "return brief changed the encoded reason"
  assert_contains "$out" "$quoted_title" "return brief changed the title"
  assert_contains "$out" "$quoted_legacy" "return brief changed the legacy reason"
  for malformed in "${malformed_reasons[@]}"; do
    assert_contains "$out" "$malformed" "return brief changed historical literal $malformed"
  done
  pass "marked hold reasons round-trip through public reads, fleet, startup, and return without changing other fields"
}

test_hold_reason_round_trips_awkward_characters
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default
test_retained_body_keeps_its_utf8_bytes
