#!/usr/bin/env bash
# fm-agent-sandbox Mac-only integration proof against the real nono.
# Opt-in: FM_LIVE_AGENT_SANDBOX=1 runs it, anything else honestly skips.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_LIVE_AGENT_SANDBOX nono git pi claude

TMP_ROOT=$(fm_test_tmproot sandbox-live)
SB="$ROOT/bin/fm-agent-sandbox.sh"
PI_BIN=$(command -v pi)

[ -S "$HOME/.no-mistakes/socket" ] || fail "live proof needs the running no-mistakes daemon socket"
[ -f "$HOME/.pi/agent/auth.json" ] || fail "live proof needs the captain pi auth store present to prove it blocked"
[ -f "$HOME/.claude/.credentials.json" ] || fail "live proof needs the captain claude store present to prove it blocked"

cfg="$TMP_ROOT/on"
mkdir -p "$cfg"
printf '0.80.0\n' >"$cfg/agent-sandbox"
"$SB" check "$cfg" || fail "real nono passes the pinned check"
pass "real nono passes the pinned check"

live="$TMP_ROOT/home"
wt="$live/wt"
state="$live/state"
tmp="$live/tmp"
data_id="$live/data/t1"
mkdir -p "$state" "$tmp" "$data_id"
fm_git_init_commit "$wt"
touch "$state/t1.pi-ext.ts" "$state/t1.status"
render_out=$("$SB" render "$state" t1 "$wt" "$tmp" "$data_id" "$live/hooks" "$ROOT" scout "") || fail "render scout profile"
profile=$(printf '%s\n' "$render_out" | sed -n 's/^profile=//p')
nono profile validate "$profile" >/dev/null || fail "real nono validates the rendered scout profile"
pass "real nono validates the rendered scout profile"
[ "$(nono why --profile "$profile" --path "$HOME/.pi/agent/auth.json" --op read 2>/dev/null | head -n 1)" = DENIED ] || fail "rendered profile blocks the pi auth store"
pass "rendered profile denies the existing pi auth store"
[ "$(nono why --profile "$profile" --path "$state/t1.status" --op write 2>/dev/null | head -n 1)" = ALLOWED ] || fail "rendered profile grants the task status file"
pass "rendered profile grants the task status file"

render_ship=$("$SB" render "$state" t1 "$wt" "$tmp" "$data_id" "$live/hooks" "$ROOT" ship no-mistakes) || fail "render ship profile"
profile_ship=$(printf '%s\n' "$render_ship" | sed -n 's/^profile=//p')
nono profile validate "$profile_ship" >/dev/null || fail "real nono validates the rendered ship profile"
pass "real nono validates the rendered ship profile"

printf 'dummy-claude-token-value\n' >"$cfg/agent-sandbox-claude-token"
chmod 600 "$cfg/agent-sandbox-claude-token"
"$SB" claude-token-check "$cfg" || fail "fixture owner-only token passes"
touch "$state/t2.pi-ext.ts" "$state/t2.status"
render_claude=$("$SB" render "$state" t2 "$wt" "$live/tmp-t2" "$data_id" "$live/hooks" "$ROOT" scout "" claude) || fail "render claude profile"
profile_claude=$(printf '%s\n' "$render_claude" | sed -n 's/^profile=//p')
nono profile validate "$profile_claude" >/dev/null || fail "real nono validates the rendered claude profile"
pass "real nono validates the rendered claude profile"
[ "$(nono why --profile "$profile_claude" --path "$HOME/.claude/.credentials.json" --op read 2>/dev/null | head -n 1)" = DENIED ] || fail "claude profile blocks the captain claude store"
pass "claude profile denies the existing captain claude store"
claude_tmp="$live/tmp-t2"
env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY \
  FM_AGENT_SANDBOX_CLAUDE_TOKEN_FILE="$cfg/agent-sandbox-claude-token" \
  CLAUDE_CONFIG_DIR="$claude_tmp/claude" TMPDIR="$claude_tmp" DISABLE_AUTOUPDATER=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  nono run -s --profile "$profile_claude" --allow-cwd --no-rollback-prompt -- sh -c '
test -r "$HOME/.claude/.credentials.json" && exit 10
[ -n "$ANTHROPIC_AUTH_TOKEN" ] || exit 11
' 2>/dev/null </dev/null || fail "sandboxed shell blocks the captain store and receives the phantom placeholder"
pass "sandboxed shell blocks the captain store and receives the phantom placeholder"
claude_out=$(env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY \
  FM_AGENT_SANDBOX_CLAUDE_TOKEN_FILE="$cfg/agent-sandbox-claude-token" \
  CLAUDE_CONFIG_DIR="$claude_tmp/claude-cli" TMPDIR="$claude_tmp" DISABLE_AUTOUPDATER=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  nono run -s --profile "$profile_claude" --allow-cwd --no-rollback-prompt -- claude -p "say the word ok" --output-format text 2>&1 </dev/null) || true
printf '%s\n' "$claude_out" | grep -q "401" || fail "sandboxed claude egress reaches Anthropic"
pass "sandboxed claude egress reaches Anthropic with the injected dummy rejected"
pi_out=$(env -u SSH_AUTH_SOCK -u HERDR_SOCKET_PATH -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY \
  FM_AGENT_SANDBOX_CLAUDE_TOKEN_FILE="$cfg/agent-sandbox-claude-token" \
  CLAUDE_CONFIG_DIR="$claude_tmp/claude-pi" PI_CODING_AGENT_DIR="$claude_tmp/pi-agent" TMPDIR="$claude_tmp" DISABLE_AUTOUPDATER=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  nono run -s --profile "$profile_claude" --allow-cwd --no-rollback-prompt -- "$PI_BIN" --approve --model claude-bridge/claude-haiku-4-5 --thinking low -p "say the word ok" 2>&1 </dev/null) || true
printf '%s\n' "$pi_out" | grep -q "401" || fail "pi on claude-bridge reaches Anthropic"
pass "pi on claude-bridge reaches Anthropic with the injected dummy rejected"
