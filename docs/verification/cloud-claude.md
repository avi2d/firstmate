# Claude Code cloud session worker verification

Audience: maintainer verification.

The [adapter reference](../../.agents/skills/harness-adapters/references/harness/cloud-claude.md) owns operating facts.
`bin/fm-cloud-claude-lib.sh` and `bin/fm-cloud-claude-relay.sh` own the mechanics.
The evidence below comes from Claude Code 2.1.287 on macOS arm64, on 2026-10-25.

## Refresh commands

```sh
claude --version
claude --help | grep -E -- '--cloud|--on-branch|--ref|--teleport'
bash bin/fm-test-run.sh tests/fm-cloud-claude.test.sh
```

The suite uses stub `claude`, `gh`, and `script` binaries and a local bare origin.
It never creates a cloud session.

## Command-line surface

| Probe | Result |
|---|---|
| `claude --cloud "<task>"` with stdin or stdout not a terminal | `--cloud requires an interactive terminal` |
| `claude -p "<task>" --cloud "<task>"` | `Error: --cloud cannot be combined with --print.` |
| `claude --cloud "<task>"` under a pseudo-terminal in an untrusted folder | Stops at the workspace-trust dialog |
| `claude -p --cloud session_<id> "<text>"` | Sends and exits. With `--output-format json` it prints `{"ok":true,"session_id":...,"url":...}` |
| `claude -p --cloud session_<unknown> "<text>"` | `Session not found: <id>` |
| `--on-branch` without `--cloud` or `--environment` | `Error: --on-branch resumes work on a branch in a cloud session; pass --cloud or --environment` |
| `--ref` with `--cloud <session>` | `Error: --ref sets the base for a new cloud session; it cannot be combined with --cloud <session_id\|url>` |

The session clones the GitHub remote's branch, not local commits, and prints `local branch '<b>' is not pushed to origin; remote agents will run against the repository's default branch` when the branch is unpushed.
No command-line verb reads a cloud session's state.
`claude agents --json --all` lists local sessions only.
Inside a session, `gh pr` and `gh issue` answer 403 through the cloud proxy, while `gh api repos/<owner>/<repo>/...` works.

## Live creation, pull request, and follow-up

One approved run used the credit-backed account against a scratch clone of this repository at its default branch.
After the trust dialog, `claude --cloud "<task>"` printed and exited without leaving a viewer attached:

```text
Created cloud session: README cloud worker proof
View: https://claude.ai/code/session_<id>?from=cli&m=0
Resume with: claude --teleport session_<id>
```

About thirty seconds later the session had pushed a branch and opened a ready, non-draft, one-line pull request whose body linked the session.
A follow-up through `claude -p --cloud` returned `ok`, and the session answered without changing the branch.
The run cost 0.52 USD of the account's cloud credit.
The pull request was closed unmerged and its branch deleted.

## Limits of this evidence

The live run created its session without `--on-branch`.
The relay's `--on-branch <task branch>` creation and its `script(1)` capture of the printed session id are proven only against the stub.
The Claude GitHub App check reported `installation_not_found` for the repository immediately before the run, which still succeeded, so that check is not a reliable precondition probe.
