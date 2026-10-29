# Share guard

A PreToolUse seatbelt refuses unapproved board publishes.
It covers the agent running `lavish-axi share` and any equivalent publish to the outside host.
A captain confirmed share still passes.

## Approve one exact share

Ask the captain to confirm the exact share in the moment.
After an explicit yes, record the approval in `$FM_HOME/state/lavish-share-approvals`.
Each line holds an epoch timestamp, a space, and an absolute file path or a `site:<id>` value.
File approvals cover the exact bytes for 30 minutes.
A file edited after its approval needs a new approval.
The `FM_LAVISH_SHARE_APPROVED` session value approves one path or site for the running session.

## How the two parts divide the work

`bin/fm-share-guard/policy.ts` owns classification and approval matching.
`bin/fm-share-guard-pretool-check.sh` owns payload extraction and harness rendering.
The transport never executes the submitted command.
The transport installs the policy runtime into `$FM_HOME/state/.fm-share-guard` on first use.
A missing runtime fails open and the test suite skips instead of passing silently.

## What the policy refuses

A `lavish-axi share` invocation with no matching approval is refused.
The check sees through `sudo`, `npx` style runners, `bash -c`, `eval`, groups, and command substitution.
A `--token`, `--password`, `--private`, `--site`, or `--update-key` flag never changes the verdict.
A `curl` or `wget` upload to the outside host is refused the same way.
A plain view of a shared board stays allowed.
Unpublish needs the matching `site:<id>` approval.

## What the policy cannot see

A publish hidden behind an unreadable value stays allowed and is listed here.
A `VAR=value lavish-axi share file` prefix does not count as an approval.
A runner the policy does not name passes its payload through untouched.
A script file passed to `sh`, `bash`, `node`, or `python` is read and scanned.
A script the scan cannot classify is judged by its text, so naming lavish passes and a `lavish-axi share` or upload to the outside host is refused.
A module loaded with `python -m` is not resolved.
An `ssh` remote command is not scanned.
A value built only at runtime with no share marker is not classified.
A typed command value that mentions a share marker but resists classification is refused.

## Prefilter coupling

The transport prefilter stays a strict superset of the classifier decoders.
Adding a quote or expansion form to the classifier requires extending the marker set in the same change.

## Harness wiring

Claude reads the `--claude` rendering through `.claude/settings.json`.
Codex reads the plain rendering through `.codex/hooks.json`.
Cursor reads its own object through `.cursor/hooks.json` with `--cursor`.
Grok reads the plain rendering through `.grok/hooks/fm-primary-share-guard.json`.
OpenCode throws through `.opencode/plugins/fm-primary-pretool-check.js`.
Pi and OMP block through their `fm-primary-turnend-guard.ts` extensions.

## Validation record

`tests/fm-share-guard-pretool-check.test.sh` drives the shell transport through every entry form.
It pins refusal of each publish shape and passage of views and unrelated commands.
It pins approval expiry, post approval edits, wrong path approvals, and the unpublish path.
It pins passage of scripts that only name lavish or shared words, and refusal of the same scripts once they publish.
The suite ran green against the real `bun` runtime with a scratch home.
