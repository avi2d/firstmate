# Primary turn-end supervision guard

Pi's `agent_settled` event runs `bin/fm-turnend-guard.sh` at the end of a logical agent run, not after each tool call.
The script takes no arguments and does not read stdin.
Exit 0 lets the turn end.
Exit 2 emits a repair message on stderr, and the extension queues one marked follow-up.

## Guard predicates

The guard checks the effective home's state only from a primary checkout.
A linked task worktree is not a primary.
`bin/fm-primary-scope-lib.sh` owns that check for both the guard and [session start](sessionstart-nudge.md).

A live task, registered process-event source, registered custom check, or pending wake can require supervision.
`bin/fm-supervision-lib.sh` owns that decision.
The guard checks the watcher against its home, live process identity, and beacon age.
A fresh beacon alone does not prove that its watcher still owns the cycle.

## Harness integrations

Pi and pi-signed use the same `.pi/extensions/fm-primary-turnend-guard.ts` extension.
The extension sends at most one follow-up per logical run.
If Pi rejects delivery, the extension releases that claim so the next eligible run can retry.
The guard is a backstop, not the normal way to re-arm.
See [watcher continuity](watcher-continuity.md) for ordinary wake handling.

## Regression coverage

`tests/fm-turnend-guard.test.sh` exercises the executable with an empty stdin and checks the Pi event handlers.
[Supervision verification](verification/supervision.md#turn-end-guard) records the live evidence.
