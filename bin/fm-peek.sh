#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
set -eu

usage() {
  cat <<'EOF'
Usage: fm-peek.sh <target> [lines=40] [--scrollback]
  <target> may be an exact task id, a legacy fm-<id> task label resolved
  through this home's state/<id>.meta, or an explicit backend target.
  --scrollback reaches above the viewport on herdr, where the read otherwise
  stops. It scrolls an idle fullscreen agent, so it is for one deliberate look,
  never for a loop, and it is refused for a remote pane.
A selector whose meta records remote_host= is a remote secondmate: its pane
lives on that host, so the capture routes over fm-on.sh to the host-local
capture (fm-remote-secondmate-control.sh), clamped to that command's
100-line cap. An unreachable host or unreadable endpoint fails loudly naming
the host; the local backend adapters are never asked to read a remote target.
EOF
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
shift
N=40
CAPTURE=fm_backend_capture
for arg in "$@"; do
  case "$arg" in
    --scrollback) CAPTURE=fm_backend_scrollback_capture ;;
    -*) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) N=$arg ;;
  esac
done

REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ] && [ -n "$(fm_meta_get "$REMOTE_META" remote_host)" ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$REMOTE_META" remote_host)
  if [ "$CAPTURE" = fm_backend_scrollback_capture ]; then
    echo "error: --scrollback cannot read the remote pane of $REMOTE_ID on $REMOTE_HOST; a remote read stops at the viewport on herdr" >&2
    exit 1
  fi
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" < /dev/null; then
    echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    exit 1
  fi
  exit 0
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

"$CAPTURE" "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
