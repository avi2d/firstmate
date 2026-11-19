#!/usr/bin/env bash
# Stable PreToolUse transport for the cd-guard command policy.
#
# A stray persistent top-level `cd projects/<clone>` in the PRIMARY firstmate
# shell silently relocates the shell, so a later firstmate-owned command (a
# backlog write, an fm-* lifecycle call, tasks-axi) runs inside a project clone
# instead of the home. This seatbelt denies such a command before it runs.
# bin/fm-cd-command-policy.mjs is the sole owner of the block/allow decision; it
# reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only scopes the guard to the real primary checkout, acquires the
# harness payload, invokes that policy, and renders the established harness
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/cd-guard.md for the complete contract and validation record.
#
# Usage:
#   bin/fm-cd-pretool-check.sh --command '<cmd>'
#
# The Pi primary's tool_call adapter passes the exact command string.
#
# Exit/output contract (identical shape to bin/fm-arm-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 and a deny object on stderr.
#   INERT - not the real primary checkout (a worker task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - missing Node or policy owner, or an invalid policy response.
set -u

CMD=""
CMD_SET=0

usage() {
  cat <<'EOF'
Usage: fm-cd-pretool-check.sh --command <cmd>

Fires only in the real primary firstmate checkout; it is a silent no-op in a
worker task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny a persistent top-level cwd change.
A cd whose single literal absolute target resolves to this checkout itself is
allowed, because it cannot move the shell out of the home.
The deny reason is written to stderr.
An unavailable classifier runtime fails open.
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
  usage >&2
  exit 2
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes that the classifier joins within a shell word
# before looking for cd/pushd/popd, so ordinary quoted or escaped fragments
# cannot hide a deniable cwd change from the policy owner. A quoting-decoder
# marker - a $ immediately followed by a
# single quote (ANSI-C $'...') or a double quote (bash locale $"...") - delegates
# too, because the classifier decodes those and can reconstruct cd from bytes
# this substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset. Deliberate deeper obfuscation is
# out of scope by the same agent-mistake threat model the policy uses.
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
      *cd*|*pushd*|*popd*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Scope to a plain, non-worktree firstmate checkout, where git-dir equals
# git-common-dir. A crewmate/scout task worktree - the shape bin/fm-spawn.sh
# always hands out - is a linked git worktree where the two differ. This guard
# does not inspect .fm-secondmate-home, so it applies in a git-cloned secondmate
# home but remains inert when the secondmate home is itself a treehouse-leased
# linked worktree. docs/cd-guard.md owns this scope; docs/turnend-guard.md owns
# the turn-end guard's separate marker-aware scope. Any failure to confirm the
# checkout is inert (exit 0), never a block, so a broken environment never
# denies a shell command.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

POLICY="$FM_ROOT/bin/fm-cd-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --home "$FM_ROOT" --command "$CMD" 2>/dev/null) || exit 0
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
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
