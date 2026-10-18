#!/usr/bin/env bash
# fm-sandbox-quiet kills only proven nono sandbox log streams under a root.
# Portable: the fixture tree is real processes with faked argv, and every
# verdict comes from the live process table, never from source bytes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sandbox-quiet)
SB="$ROOT/bin/fm-sandbox-quiet.sh"
FIX="$TMP_ROOT/tree.py"
cat >"$FIX" <<'PYEOF'
import os, sys
root = sys.argv[1]
pairs = sys.argv[2:]
for i in range(0, len(pairs), 2):
    mid, leaf = pairs[i], pairs[i + 1]
    child = os.fork()
    if child == 0:
        grandchild = os.fork()
        if grandchild == 0:
            os.execvp("sleep", [leaf, "25"])
            os._exit(1)
        os.execvp("sleep", [mid, "25"])
        os._exit(1)
os.execvp("sleep", [root, "25"])
PYEOF

STREAM_TAIL='senderImagePath CONTAINS "/Sandbox"'
LEAF_A="/usr/bin/log stream --style ndjson --level debug tokenA $STREAM_TAIL"
LEAF_B="/usr/bin/log stream --style ndjson --level debug tokenB $STREAM_TAIL"
LEAF_C="/usr/bin/log stream --style ndjson --level debug tokenC $STREAM_TAIL"

python3 "$FIX" "quiet-root-A" nono "$LEAF_A" notnono "$LEAF_B" & ROOT_A_TREE=$!
python3 "$FIX" "quiet-root-B" nono "$LEAF_C" & ROOT_B_TREE=$!
sleep 1
trap 'for pat in token[A] token[B] token[C] "^(notnono|nono) 25$" "^quiet-root-[AB] 25$"; do pkill -9 -f "$pat" 2>/dev/null || true; done' EXIT
PID_A=$(pgrep -f 'tokenA' | head -1)
PID_B=$(pgrep -f 'tokenB' | head -1)
PID_C=$(pgrep -f 'tokenC' | head -1)
[ -n "${PID_A:-}" ] || fail "fixture leaf A runs"
[ -n "${PID_B:-}" ] || fail "fixture leaf B runs"
[ -n "${PID_C:-}" ] || fail "fixture leaf C runs"
pass "fixture trees run under two roots"

ROOT_A=$(pgrep -f '^quiet-root-A' | head -1)
[ -n "${ROOT_A:-}" ] || fail "root A resolves"
OUT=$("$SB" --wait 3 "$ROOT_A") || fail "quiet exits zero on a killable stream"
case "$OUT" in *"quieted $PID_A"*) pass "quiet names the stream it stopped" ;;
*) fail "quiet names the stream it stopped: $OUT" ;;
esac
if [ -n "$(LC_ALL=C ps -o stat= -p "$PID_A" 2>/dev/null | tr -d '[:space:]' | tr -d 'Z')" ]; then fail "proven nono stream survives"; fi
pass "proven nono stream under the root is stopped"
if kill -0 "$PID_B" 2>/dev/null; then pass "stream under a non-nono parent is kept"; else fail "stream under a non-nono parent is kept"; fi
if kill -0 "$PID_C" 2>/dev/null; then pass "stream under another root is kept"; else fail "stream under another root is kept"; fi

if "$SB" --wait 1 999999 2>/dev/null; then pass "quiet on a dead root stays silent and green"; else fail "quiet on a dead root stays silent and green"; fi
if "$SB" 1 2>/dev/null; then fail "pid 1 refused"; else pass "pid 1 refused"; fi
if "$SB" notapid 2>/dev/null; then fail "non-numeric root refused"; else pass "non-numeric root refused"; fi

kill "$ROOT_A_TREE" "$ROOT_B_TREE" 2>/dev/null || true
sleep 1
for pat in 'token[A]' 'token[B]' 'token[C]' '^(notnono|nono) 25$' '^quiet-root-[AB] 25$'; do
  pkill -9 -f "$pat" 2>/dev/null || true
done
