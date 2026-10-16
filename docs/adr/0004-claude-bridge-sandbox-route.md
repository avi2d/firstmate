# 0004: Claude bridge workers use a dedicated token route

Accepted 2026-10-16.

A claude-bridge worker authenticates through a Claude Code child, not through pi key storage.
The child honors `ANTHROPIC_AUTH_TOKEN` from its environment, so the profile injects the dedicated setup token at the nono proxy and the worker receives only a phantom placeholder.
The profile grants `api.anthropic.com`, redirects `CLAUDE_CONFIG_DIR` to a task-owned directory, and unsets inherited `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY`, which would otherwise redirect the child.
The setup token file stays owner-only outside the sandbox and a supervisor-side capture reads it.
The dummy proof returned Anthropic 401 on an invented credential, and removing the credential file stopped all egress.
