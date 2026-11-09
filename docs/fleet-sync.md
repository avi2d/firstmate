# Fleet sync

`bin/fm-fleet-sync.sh` refreshes project clones.
It fast-forwards the checked-out local default branch to `origin/<default>` when that is safe.
It prunes a local branch whose upstream tracking branch no longer exists on the remote, as after a merged PR, when no worktree still needs it.

## Self-heal and STUCK reports

The one unambiguously safe drift heals itself.
A clean, detached HEAD that holds no unique commits, because it is an ancestor of `origin/<default>`, and whose default branch is free to check out is re-attached and then fast-forwarded.
The output line says `recovered:`.

Every other off-default state may hold real work.
That covers a non-default named branch, a detached HEAD with unique commits, a dirty tree, and a diverged default.
Those are left untouched and reported as a quantified `STUCK: ... N commits behind ... - needs attention` warning rather than a quiet drift.
Nothing is ever forced, stashed, or discarded.

## Skips

Local-only and no-origin projects, missing remotes or branches, and fetch failures are skipped.
A project whose registry entry `bin/fm-project-mode.sh` refuses is skipped too, naming that command so its refusal is readable, rather than synced under a guessed posture.
A candidate under `projects/` must be the root of its own work tree.
Git discovery walks up, so a plain nested directory would otherwise resolve to the enclosing repository and be synced under that directory's label.
Anything else is reported as `skipped: not a clone root`, naming the repository that would have been touched.

## Pruning

Pruning never deletes the checked-out branch or a branch that still has a worktree, so it cannot discard unlanded work.
Set `FM_FLEET_PRUNE=0` to disable it.

## Orphaned packed-refs lock

A git ref rewrite killed mid-write leaves `.git/packed-refs.lock` behind.
A timed-out bootstrap sync or a teardown process kill can do that.
The next fetch then fails on that lock.
The fetch is retried with a bounded wait, and the lock is removed only when provably stale.
`FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES`, `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS`, and `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` bound that recovery.

## Usage

`fm-fleet-sync.sh` with no argument syncs every clone under this home's `projects/`.
`fm-fleet-sync.sh <project-dir-or-name>` syncs one clone.
It accepts a path, absolute or relative to the caller's working directory, or a bare `<name>` or `projects/<name>` form resolved against `$FM_HOME/projects` or `$FM_PROJECTS_OVERRIDE`.
Bare names and `projects/<name>` forms prefer this home's projects directory before falling back to an explicit path.

`fm-fleet-sync.sh --remote <route> <project-name>` runs the same single-project sync in a registered execution home's own clone over `bin/fm-on.sh`.
Each output line is prefixed with the route.
An execution home that does not answer is reported as skipped, because its clone refreshes at its own next sync.
Use it after a remote worker's PR merges so the execution home's clone of that project catches up.
