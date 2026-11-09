# 0018: Per-home status feed for remote workers

Date: 2026-11-09.
Status: accepted.

## Context

Remote workers append status host-side, while wake classification, the open-decision fold, and Bearings read this home's state/<id>.status.
One remote job lane serializes every job for a home, so one long poll per task would queue behind itself and starve the feed.
Spawn already publishes the remote route record, and the reply channel already proved the mirror, dedup, normalization, document fetch, and self-announcing contract for one fixed log.

## Decision

Each execution home gets one multiplexed feed instead of one poll per task.
The host-side reader polls every listed state/<task>.status through the single-log delta reader with a zero wait, so per-task snapshot, continuity, whole-line, and bound behavior stay unchanged.
The feed frames whole per-task delta blocks behind a small envelope and returns as soon as any task has news.
An empty window exits with the same status the single-log reader uses, and the feed command is preemptible like that reader.
The main-side adapter is generalized from the reply adapter: per-task cursor vectors assembled from this home's own task records, per-task dedup and normalization, structured report pointer fetch into this home's own data/<task>/ tree, and the self-announcing contract.
A pointer outside the source task's own tree never transfers.
Spawn arms the route feed after publishing the remote route record.

## Consequences

One remote status line produces exactly one wake through the ordinary signal scan, and a replayed window stays silent.
A task that spawns later joins the next window with an empty cursor and needs no registration change.
A single task's continuity break is escalated into that task's own stream and the proven new prefix is adopted, so the shared feed stays live instead of dropping its one registration over one rewritten log.
An unreachable host still reads as unknown transport, never as failure, and the feed resumes at the committed cursor vector.
Teardown and backlog reclaim for remote workers stay with the later cleanup change, which retires the route feed it no longer needs.
