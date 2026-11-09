# 0019: Remote worker cleanup and backlog reclaim

Date: 2026-11-09.
Status: accepted.

## Context

A remote worker's worktree, pane, and treehouse slot live on the execution home, while its task record, status stream, and backlog item live in this home.
Only the host can run the landed-work test against the worktree, and only this home can close the backlog item.
The transport answers 255 or times out without saying whether the host finished, so any cleanup that removes local records first can strand a live pane with nothing left naming it.

Retiring a remote second mate needs its Queued items back in this home first.
The second mate's backlog is the only copy of those items, so a move that deletes before the insert lands can lose work, and one that inserts before the delete lands can duplicate it.

## Decision

Cleanup runs the ordinary host-side teardown inside the execution home first, through one control verb.
This home changes nothing until that verb confirms.
A host record that is already gone answers absent, so a rerun after a lost reply converges instead of refusing.
After confirmation this home archives the status stream, removes the task records, retires the task's feed cursor, and closes the backlog item through the same atomic transition a local teardown uses.

Reclaim is a two-leg move with a confined outbox as the hand-off copy.
The second mate stages the selected Queued items into its outbox and removes them from its own backlog in one locked step.
This home fetches the outbox through the confined file transfer, inserts the items into its own backlog, and releases the outbox only by naming its exact length and SHA-256.
A staged outbox pins the selected set, so a rerun finishes that set and a reclaim naming another set is refused.

The post-merge refresh of the execution home's clone is a single-project fleet sync run on the host, reported under the route.

## Consequences

Unlanded work on the host refuses cleanup there, with the host's reason relayed, and every local record stays.
An unanswered transport during cleanup or reclaim never removes or duplicates anything, and the same command reconciles it later.
A scout's report has to reach this home through the status feed before its cleanup can close the item with that report.
An unanswered post-merge sync is a skip, because the host's own next sync catches the clone up.
