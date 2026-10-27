#!/usr/bin/env bash
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-share-guard-pretool-check.sh [--command <cmd>] [--background true|false] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unavailable policy runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || exit 0

PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *lavish*|*share*|*ht-ml*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
GUARD_DIR="$ROOT/bin/fm-share-guard"
POLICY="$GUARD_DIR/policy.ts"

command -v bun >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
[ -f "$GUARD_DIR/package.json" ] || exit 0
[ -f "$GUARD_DIR/bun.lock" ] || exit 0

CACHE_DIR="$ACTIVE_HOME/state/.fm-share-guard"
MODULES_DIR="$CACHE_DIR/node_modules"
if [ ! -f "$MODULES_DIR/effect/package.json" ] || ! cmp -s "$GUARD_DIR/bun.lock" "$CACHE_DIR/bun.lock"; then
  mkdir -p "$CACHE_DIR" || exit 0
  cp -f "$GUARD_DIR/package.json" "$GUARD_DIR/bun.lock" "$CACHE_DIR/" || exit 0
  (CDPATH='' cd -- "$CACHE_DIR" && bun install --frozen-lockfile >/dev/null 2>&1) || exit 0
  [ -f "$MODULES_DIR/effect/package.json" ] || exit 0
fi

POLICY_OUTPUT=$(NODE_PATH="$MODULES_DIR" bun "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
