# 0020: Session start digest

Date: 2026-11-19.
Status: accepted.

## Context

A session used to start with six or more separate reads: bin/fm-bootstrap.sh, then data/projects.md, data/captain.md, and data/learnings.md, then bin/fm-lock.sh and bin/fm-wake-drain.sh, then data/backlog.md, every state/*.meta, and every state/*.status.
Every one of those reads ran at every session start, so they belong in one script rather than in several agent turns.

The digest is delivered through harnesses that cut an oversized payload from the tail.
A 70KB digest once arrived as lines 1 to 435 of 578 and lost the live task inventory.

The digest runs on a session-open hook, or before Pi's first provider preflight, that blocks the session until it ends.
Every external network call it used to make was unbounded, so one unreachable remote could use the whole budget and cut the work queue from the digest.

The older order ran bootstrap before the lock.
A second concurrent session could then run bootstrap's mutating sweeps, such as fleet sync and backlog reconciliation, before it learned that another session held the lock.

A measured lab home with twelve tasks under way printed a digest of about 12,000 tokens, and over a third of it was a full state/*.meta body and a five-line status tail for every task.

## Decision

bin/fm-session-start.sh composes bin/fm-lock.sh, bin/fm-bootstrap.sh, bin/fm-wake-drain.sh, and bin/fm-startup-network.sh as subprocesses and prints their own output.
It never reimplements their logic, and each of them still works on its own.
Bootstrap's one seam is the opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag, which runs its detect-only checks without its mutating sweeps.

The digest prints its stages in this order, and the same names are the stage list behind the truncation banner:

1. lock: take the per-home session lock before any mutating step.
2. role: the firstmate repository role line from bin/fm-role.sh report.
3. bootstrap: detect-only checks always run. Herdr projection cleanup and the mutating sweeps run only when this session holds the lock, and network sweeps run in the deferred stage.
4. wake-queue: the wake drain presents durable wakes, so it runs only with the lock. It first seeds the outcome store's tail copy when that is absent.
5. supervision-instructions: the one operating block for the detected primary harness. On a Pi primary it also reports when either tracked extension is not loaded.
6. read-once: the contract that stops the next turn from reading the digested sources again.
7. fleet-state: backlog counts and bounded listings, then one line per task under way with its endpoint liveness and latest status line.
8. network-checks: the deferred network stage, read without waiting for it.
9. context: data/projects.md, data/captain.md, and data/learnings.md, or the current decision memory view.
10. next-step: the closing reminder, which points back to the operating block and never arms the watcher itself.

The lock comes first, so only the session that wins it touches shared mutable state.
A refused session still runs bootstrap in detect-only mode and still prints the read-only digests, so it never goes dark.
It skips the GitHub authentication probe, because a read-only session has no dispatch, steer, or merge for that verdict to gate.

No step on the blocking path makes an external network call.
GitHub authentication, fleet sync, and the inactive terminal outcome scan run as one detached bounded worker started right after the lock and read at the network-checks stage.
On a slow network the digest prints IN PROGRESS and names the checks not yet confirmed, and never reports an unconfirmed check as passed.

Fleet state comes before context, because a truncated tail should lose the cheapest thing.
Curated memory is stable between sessions, governed by config/startup-memory-budget, and recoverable with one read, while live fleet identity changes every session and recovery depends on it.
The read-once contract comes before both, because a contract printed after its payload is the first thing a truncated digest loses.

The fleet state is a summary, not a dump:

- Done rows are never listed.
- Held rows are decisions waiting on the captain, so each is listed with its hold kind and reason and never bounded away.
- In-flight rows are not listed, because each task with a worker record has its own line. An in-flight row with no state/<id>.meta is listed, because nothing else would show it.
- Blocked and ready queued rows are each bounded by FM_SESSION_START_QUEUED_LIMIT, default 10, and each omission prints its count and the command that lists the rest.
- Each task under way gets one line: its id, kind, mode, endpoint liveness, and latest status line capped by bin/fm-line-cap-lib.sh. Older status lines stay in state/<id>.status, and the wake drain above folds open decisions from the whole log.
- Full task bodies stay out and are read with bin/fm-tasks-axi.sh show <id> --full when needed.

When compatible tasks-axi is available, the groups are its own filters, so the script never reimplements task state.
In manual mode, or when tasks-axi is unavailable, the script prints only section headings and item title lines, and keeps every title line that marks a hold or a blocker.

A context re-emit after a clear or a compaction prints the same one-line work under way with no endpoint read, counts instead of held and blocked rows, and a manifest of the context files instead of their bodies.

The whole digest runs as one child of the script under FM_SESSION_START_TIMEOUT, default 120 seconds.
Each per-task endpoint read runs in its own crash-isolated child under FM_SESSION_START_ENDPOINT_TIMEOUT, default 10 seconds, so one hung backend becomes that task's error verdict.
Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog.
The deferred network stage runs outside that bound in its own process group under its own deadline.
On any nonzero child exit the parent prints a STARTUP TRUNCATED banner that names the stage that did not finish and every section never printed, and still exits 0.

## Consequences

A session starts in one or two turns, and a fresh start no longer grows with the meta body and status history of every task.
A turn that needs a task's meta or older status lines reads state/<id>.meta or state/<id>.status for that one task.
With a wedged backend the fleet-state stage can take the number of tasks times the endpoint bound, which can itself reach the digest's bound.
