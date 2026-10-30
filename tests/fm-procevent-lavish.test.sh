#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-lavish-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
new_home() { mkdir -p "$1/state"; fm_test_track_procevent_home "$1"; }

# Lavish's session store is the only record of an open board, so the fixture writes it directly.
lavish_session() {
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "http://127.0.0.1:14387/session/0123456789abcdef"
}

LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
export LAVISH_RELEASE="$TMP_ROOT/lavish-release"
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" != --version ] || { printf '0.1.81\n'; exit 0; }
while [ ! -e "$LAVISH_RELEASE" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$LAVISH_BIN/lavish-axi"

UNOPENED_ART="$TMP_ROOT/unopened-board.html"
printf '<h1>unopened</h1>\n' > "$UNOPENED_ART"
UNOPENED_HOME="$TMP_ROOT/unopened-home"
new_home "$UNOPENED_HOME"
UNOPENED_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$UNOPENED_ART")

set +e
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$UNOPENED_ART" \
  > "$TMP_ROOT/unopened-arm.out" 2> "$TMP_ROOT/unopened-arm.err"
unopened_rc=$?
set -e
[ "$unopened_rc" -ne 0 ] \
  || fail "arm reported a board ready that Lavish has not opened"
assert_not_contains "$(cat "$TMP_ROOT/unopened-arm.out")" "armed: $UNOPENED_ID" \
  "arm printed a ready board for an unopened session"
[ -s "$TMP_ROOT/unopened-arm.err" ] \
  || fail "arm refused an unopened board without a reason"
pass "arm refuses an unopened board with a reason instead of reporting it armed"

UNOPENED_SRC_HOME="$TMP_ROOT/unopened-src-home"
new_home "$UNOPENED_SRC_HOME"
PATH="$LAVISH_BIN:$PATH" pe "$UNOPENED_SRC_HOME" register lavish "$UNOPENED_ID" -- \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$UNOPENED_ART" >/dev/null
set +e
PATH="$LAVISH_BIN:$PATH" pe "$UNOPENED_SRC_HOME" ensure-listening "$UNOPENED_ID" \
  > "$TMP_ROOT/unopened-ensure.out" 2> "$TMP_ROOT/unopened-ensure.err"
unopened_ensure_rc=$?
set -e
[ "$unopened_ensure_rc" -ne 0 ] \
  || fail "ensure-listening reported a running listener for an unopened board"
[ -s "$TMP_ROOT/unopened-ensure.err" ] \
  || fail "ensure-listening refused an unopened board without a reason"
pass "ensure-listening reports a listener that never attached as not running"

lavish_session "$UNOPENED_ART"
set +e
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$UNOPENED_ART" \
  > "$TMP_ROOT/opened-arm.out" 2> "$TMP_ROOT/opened-arm.err"
opened_rc=$?
set -e
[ "$opened_rc" -eq 0 ] \
  || fail "arm did not attach after the board was opened: $(cat "$TMP_ROOT/opened-arm.err")"
assert_contains "$(cat "$TMP_ROOT/opened-arm.out")" "armed: $UNOPENED_ID" \
  "arm did not report the attached board as armed"
pass "a board opened after a refused arm attaches on the next arm"

touch "$LAVISH_RELEASE"
PATH="$LAVISH_BIN:$PATH" FM_HOME="$UNOPENED_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$UNOPENED_ART" >/dev/null 2>&1 || true

SD_ROOT="$TMP_ROOT/state-dir"
SD_HOME="$SD_ROOT/home"
SD_CUSTOM="$SD_ROOT/custom"
mkdir -p "$SD_HOME/.lavish-axi" "$SD_CUSTOM"
SD_BIN=$(fm_fakebin "$SD_ROOT/lavish-stub")
cat > "$SD_BIN/lavish-axi" <<SH
#!/usr/bin/env bash
[ "\${1-}" != --version ] || { printf '0.1.81\n'; exit 0; }
log="$SD_ROOT/polls-\$(basename "\${2-}" .html).log"
printf 'port=%s state_dir=%s\n' "\$LAVISH_AXI_PORT" "\${LAVISH_AXI_STATE_DIR-unset}" >> "\$log"
if [ "\$(wc -l < "\$log")" -le 2 ]; then printf 'session:\n  status: browser_disconnected\n'; exit 0; fi
while [ ! -e "$SD_ROOT/release" ]; do
  [ "\$SECONDS" -lt "\${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$SD_BIN/lavish-axi"
sd_session() {  # <store-dir> <artifact> <port>
  perl -MJSON::PP -MCwd=realpath -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$real} = { key => "k", file => $real, status => "open", url => $url };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$1/state.json" "$2" "http://127.0.0.1:$3/session/0123456789abcdef"
}
sd_run() { env -u LAVISH_AXI_STATE_DIR HOME="$SD_HOME" PATH="$SD_BIN:$PATH" "$@"; }
sd_poll() {  # <board-name> <poll-number> [command retried until that poll arrives...]
  local log="$SD_ROOT/polls-$1.log" n=$2 _
  shift 2
  for _ in $(seq 100); do
    [ "$({ wc -l < "$log"; } 2>/dev/null || echo 0)" -ge "$n" ] && { sed -n "${n}p" "$log"; return 0; }
    [ "$#" -eq 0 ] || "$@" >/dev/null 2>&1 || true
    sleep 0.2
  done
  printf 'board %s never reached poll %s\n' "$1" "$n"
}

SD_ART="$SD_ROOT/own.html"
printf '<h1>own server</h1>\n' > "$SD_ART"
sd_session "$SD_HOME/.lavish-axi" "$SD_ART" 14001
sd_session "$SD_CUSTOM" "$SD_ART" 14002
SD_FM="$SD_ROOT/fm-home"
new_home "$SD_FM"
sd_run LAVISH_AXI_STATE_DIR="$SD_CUSTOM" FM_HOME="$SD_FM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$SD_ART" >/dev/null \
  || fail "arm against a non-default Lavish server failed"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 1)" \
  "the first listener did not poll the board's own server"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 2 sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent.sh" reconcile)" \
  "a listener restart without LAVISH_AXI_STATE_DIR polled the default server"
pass "a listener restart without LAVISH_AXI_STATE_DIR re-arms against the board's own server, not the default"

sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" arm "$SD_ART" >/dev/null \
  || fail "a hand re-arm without LAVISH_AXI_STATE_DIR failed"
assert_equals "port=14002 state_dir=$SD_CUSTOM" "$(sd_poll own 3)" \
  "a hand re-arm without LAVISH_AXI_STATE_DIR polled the default server"
pass "a hand re-arm without LAVISH_AXI_STATE_DIR keeps the board's recorded server instead of the default"

SD_OLD_ART="$SD_ROOT/old.html"
printf '<h1>pre-fix registration</h1>\n' > "$SD_OLD_ART"
sd_session "$SD_HOME/.lavish-axi" "$SD_OLD_ART" 14001
sd_session "$SD_CUSTOM" "$SD_OLD_ART" 14002
SD_OLD_ID=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$SD_OLD_ART")
pe "$SD_FM" register lavish "$SD_OLD_ID" -- \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$SD_OLD_ART" >/dev/null
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent.sh" ensure-listening "$SD_OLD_ID" >/dev/null 2>&1 || true
assert_equals "port=14001 state_dir=unset" "$(sd_poll old 1)" \
  "a registration without a recorded state dir left the default server"
pass "a registration without a recorded state dir still polls the default server"

touch "$SD_ROOT/release"
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" retire "$SD_ART" >/dev/null 2>&1 || true
sd_run FM_HOME="$SD_FM" "$ROOT/bin/fm-procevent-lavish.sh" retire "$SD_OLD_ART" >/dev/null 2>&1 || true

printf '\nall procevent-lavish tests passed\n'
