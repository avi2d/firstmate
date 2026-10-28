# Claude Code cloud sessions

`cloud-claude` runs a ship task in a Claude Code cloud session on Anthropic's hosts, billed to the Claude account the home names in `config/cloud-claude-account`.
It takes GitHub-hosted direct-PR ship tasks only; scouts, secondmates, primaries, no-mistakes ships, and local-only ships stay on a local adapter.
[Configuration](../../../../../docs/configuration.md#cloud-claude-worker) owns the settings, [verification evidence](../../../../../docs/verification/cloud-claude.md) owns the live facts, and [the design record](../../../../../docs/adr/0011-cloud-claude-relay.md) owns the rationale.

## Operating facts

| Fact | Value |
|---|---|
| Pane | Runs `../../../../../bin/fm-cloud-claude-relay.sh`, never an agent. The relay pushes the task branch, starts the session with `claude --cloud "<task>" --on-branch <branch>` under `script(1)` because creation needs a terminal, records the session id in `state/<id>.cloud-session`, and then polls. A relaunch reuses the recorded session. |
| Account | `CLAUDE_CONFIG_DIR` is the `config/claude-accounts` login for `config/cloud-claude-account`, or for `--claude-account` on that spawn. Without either the spawn refuses; it never falls back to the default login. |
| Busy state | Relay-written `cloud-relay` events: `awaiting-pr` busy after the start and after each forwarded steer; `pr-ready` and `deadline` idle with a turn end. |
| Declared wait | While a run is out, the relay appends a `paused:` line whose `until` is the run's deadline, so a long cloud run reads as a declared wait rather than a wedge. |
| Done | The relay asks GitHub's REST API for an open pull request whose head is the task branch. A ready (non-draft) one fast-forwards the local copy onto its head and appends `done: PR <url>`. A draft is never done. |
| Stuck or failed | Detected by deadline only: no ready pull request within `config/cloud-claude-deadline` minutes (default 90) appends `blocked [key=cloud-deadline]` with the session's claude.ai link. Firstmate never reads Anthropic's session API or the account's login token. |
| Steering | `fm-send` text, including a leading `/`, rides the durable inbox; the relay forwards each record with `claude -p --cloud <session> <text>` and restarts the deadline. An archived or missing session appends `blocked [key=cloud-session-closed]` and leaves the steer in the inbox. |
| Interrupt, exit, relaunch | `fm-control` refuses: no key in the pane reaches the cloud agent. |
| Model and effort | Refused at spawn; the session runs its own. |
| Trust | The spawn pre-registers workspace trust for the task copy in the cloud account's config, as for a local Claude worker. |
| Machine load | Skips the Mac and Linux load gates, the heavy-worker cap, and the core budget, since the session runs on Anthropic's hosts; it holds no heavy place, so local starts do not count it. Project capacity still applies. |
| Cleanup | `fm-teardown` removes the relay pane, the local copy, and `state/<id>.cloud-session`. The cloud session stays in the account's session list. |
| Commit attribution | The task prompt forbids agent trailers, but cloud commits never pass through the local commit-msg strip. |

## Preconditions

The Claude GitHub App must reach the repository, and the account must be signed in to Claude Code with cloud sessions enabled.
Inside the session GitHub GraphQL is blocked, so the task prompt directs the pull request through `gh api repos/<owner>/<repo>/pulls`.
