# Remote workers

A remote worker is an individual ship or scout worker that runs on another host while this home keeps supervising it.
Operators who place projects on an execution home use this reference, and so does anyone checking the remote worker lifecycle.

An execution home is an agentless Firstmate home on an SSH-reachable host.
It holds project clones, worker worktrees, and the Herdr panes the workers run in.
This home keeps the backlog, the task records, the status stream, and every captain-facing decision.
A remote second mate is a different arrangement, where a whole supervising home lives on the other host, and [Remote second mates](remote-secondmates.md) covers it.

## Set up an execution home

1. Prepare the host exactly as [Remote second mates](remote-secondmates.md#prerequisites) describes, including the SSH alias and the fixed remote entrypoint.
2. Seed the route with `fm-remote-home-seed.sh --exec`.
   [Execution home routes](configuration.md#execution-home-routes) owns the `data/remote-homes.md` record and the seeded markers.
3. Annotate each placed project with `host=<route>` in `data/projects.md`.
   `fm-project-mode.sh --placement <project>` reads that annotation.

## Lifecycle

| Step | Command | What happens on the host |
| --- | --- | --- |
| Launch | `fm-spawn.sh` for a placed project | The host admits the task, creates its worktree, and opens one pane in the execution home's Herdr session |
| Status | Automatic | One feed per execution home mirrors every task's status lines into this home's `state/<task>.status` |
| Steer | `fm-send.sh <task> ...`, with `--resolve-key` when it answers a decision | The steer lands in the task's durable inbox on the host and rings the pane |
| Lifecycle | `fm-control.sh <task> interrupt\|exit\|relaunch` | The host acts on its own pane and reports the endpoint back |
| Current state | `fm-crew-state.sh <task>` | The host classifies its own pane |
| PR ready | The worker's `done:` line | The host runs the done gate against its own worktree |
| Cleanup | `fm-teardown.sh <task>` | The host runs the landed-work test, returns the worktree slot, and closes only that pane |
| Post-merge sync | `fm-fleet-sync.sh --remote <route> <project>` | The host fast-forwards its own clone of the project |

A host at capacity answers a launch with exit 75.
The item then stays queued and is dispatched again at the next queue review.

## Cleanup

`fm-teardown.sh <task>` on a remote worker first asks the execution home to clean up its side.
That host-side teardown applies the ordinary landed-work test, so unlanded work is refused there exactly as it is for a local worker.
Only after the host confirms does this home archive the status stream, clear its task records, retire the task's feed cursor, and move the backlog item to Done with its PR link or scout report.
A scout's report must already have reached this home through the status feed.

An SSH exit 255 or a budget timeout means the host's completion is unknown.
Every local record then stays as it was, and running the same teardown again reconciles it.
A host whose record is already gone answers `teardown=absent`, so the rerun finishes the local side.
A host refusal is relayed with its reason, and nothing local changes.

## Backlog reclaim

`fm-backlog-reclaim.sh <secondmate-id> [--dry-run] --all|<item-key>...` moves Queued items from a remote second mate's backlog into this home's backlog.
Use it when retiring a remote second mate whose projects now run on an execution home.

- In-flight and Done items are refused, and so is a blocker that the selected set would strand.
- `--dry-run` reads the second mate's backlog, rehearses the move on scratch copies of both backlogs, and changes nothing.
- Notes, holds, `--until` dates, and blocked-by links travel with each item.

The move has two legs.
The second mate stages the selected items into a confined outbox and removes them from its own backlog in one step.
This home fetches that outbox, inserts the items into its backlog, and then asks the second mate to release the outbox, naming its exact length and SHA-256.
The outbox is the only copy between those legs, so a lost reply on either leg leaves it in place, and a rerun finishes the same staged set without duplicating an item.
While a staged set exists, a reclaim that names a different set is refused.

## Exit codes across the transport

| Exit | Meaning | What to do |
| --- | --- | --- |
| 0 | The host finished the command | Nothing |
| 75 | The host deferred the launch because it is at capacity, and nothing was published on either side | Leave the item queued |
| 124 | The local budget expired, so the host's completion is unknown | Rerun the same command to reconcile |
| 255 | The transport was unavailable, so the host's completion is unknown | Rerun the same command to reconcile, never a different one |

## Verification

The local-transport end-to-end test drives the whole lifecycle through the real entrypoint without a second host:

```sh
bin/fm-test-run.sh tests/fm-remote-worker-local-e2e.test.sh
```

The cleanup, post-merge sync, and reclaim paths have their own tests:

```sh
bin/fm-test-run.sh tests/fm-remote-worker-teardown.test.sh tests/fm-backlog-reclaim.test.sh
```

A real-host proof runs its panes in a named `fm-lab-` Herdr session that only the host's own `bin/fm-herdr-lab.sh` creates and removes, so the execution home's fleet session is never touched.
