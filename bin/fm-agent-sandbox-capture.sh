#!/usr/bin/env bash
# Usage: fm-agent-sandbox-capture.sh <provider>
set -u
provider=${1:-}
[ -n "$provider" ] || { echo "fm-agent-sandbox-capture: needs a provider" >&2; exit 2; }
if [ "$provider" = claude-bridge ]; then
  token_file=${FM_AGENT_SANDBOX_CLAUDE_TOKEN_FILE:-}
  [ -n "$token_file" ] && [ -f "$token_file" ] || { echo "fm-agent-sandbox-capture: no claude token file" >&2; exit 1; }
  cat "$token_file"
  exit 0
fi
if [ -n "${FM_AGENT_SANDBOX_CAPTURE_LOG:-}" ]; then
  { printf '%s provider=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$provider"; } >>"$FM_AGENT_SANDBOX_CAPTURE_LOG" 2>/dev/null || true
fi
unset PI_CODING_AGENT_DIR
pi_bin=${FM_AGENT_SANDBOX_PI_BIN:-}
[ -n "$pi_bin" ] || pi_bin=$(command -v pi) || { echo "fm-agent-sandbox-capture: pi not found" >&2; exit 1; }
exec "$pi_bin" auth print-api-key --provider "$provider"
