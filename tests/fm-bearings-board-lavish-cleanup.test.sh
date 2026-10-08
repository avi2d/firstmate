#!/usr/bin/env bash
# Cleanup never stops a server the live guard did not start.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_CLEANUP lavish-axi python3 curl

STANDIN=''
CANARY=''
cleanup() {
  if [ -n "$STANDIN" ]; then
    [ -z "$CANARY" ] || lavish-axi end "$CANARY" >/dev/null 2>&1 || true
    lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$STANDIN"
  fi
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
printf '# lavish-axi %s\n' "${VERSION:-version-unknown}"

STANDIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-cleanup.XXXXXX") || fail "cannot create the stand-in lab"
STANDIN=$(cd -P -- "$STANDIN" && pwd -P)
mkdir -p "$STANDIN/lavish-axi"
# The stand-in plays the shared server, so a cleanup that stops the wrong
# server takes the canary down with it.
LAVISH_AXI_STATE_DIR="$STANDIN/lavish-axi"
LAVISH_AXI_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])') \
  || fail "cannot pick a stand-in Lavish port"
LAVISH_AXI_NO_OPEN=1
export LAVISH_AXI_STATE_DIR LAVISH_AXI_PORT LAVISH_AXI_NO_OPEN

CANARY="$STANDIN/canary.html"
printf '<html><body>canary</body></html>\n' > "$CANARY"
lavish-axi "$CANARY" >/dev/null 2>&1 || fail "cannot open the stand-in canary session"
lavish-axi 2>/dev/null | grep -F "$CANARY," | grep -q ',open,' \
  || fail "the stand-in canary session is not listed open"
# A listing cannot tell a live server from a stopped one: sessions survive in
# the store. Only the health endpoint proves the server answers.
curl -fsS -o /dev/null "http://127.0.0.1:$LAVISH_AXI_PORT/health" \
  || fail "the stand-in server does not answer"

set +e
early_out=$(FM_BEARINGS_GUARD_FAIL_EARLY=1 bash "$ROOT/tests/fm-bearings-board-lavish-live-e2e.test.sh" 2>&1)
early_rc=$?
set -e
[ "$early_rc" -ne 0 ] || fail "the injected early failure unexpectedly passed"
case "$early_out" in
  *"injected failure before the private Lavish export"*) ;;
  *) fail "the guard did not fail at the injected point" ;;
esac

curl -fsS -o /dev/null "http://127.0.0.1:$LAVISH_AXI_PORT/health" 2>/dev/null \
  || fail "cleanup after the early failure stopped the pre-existing server"
pass "cleanup after an early failure leaves the pre-existing server alone"
