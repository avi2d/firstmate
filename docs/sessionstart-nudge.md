# Pi session start

The [Pi extension](#pi-and-pi-signed) runs the digest before the first provider call of a new session.

## Source routing

The extension supplies the source through `bin/fm-sessionstart-run.sh --source <name>`.
The wrapper does not read stdin.

A re-emit (`--reemit`) reprints the digest for the lock owner after a context reset.

| Source | Action | Why |
| --- | --- | --- |
| `startup`, `new` | Full digest | This is a true session start that has not taken the helm; Pi CLI continuations are refined to `resume` by the adapter before reaching this boundary. |
| `clear`, `compact` | `--reemit` after a proven complete startup, otherwise full digest | This process normally has the helm and lost only its context, but an earlier hook may have been truncated after acquiring the lock. |
| `resume`, `reload`, `fork` | Delegate to the nudge wrapper | Prior context is restored, so re-running is redundant when the lock is still ours and an instruction is enough when a new process resumed an old session. |
| unreadable or unrecognized | Full digest | Taking the helm redundantly is cheap and idempotent; not taking it is the bug this tier exists to fix. |

### Lock and completion interlock

Two records together are the idempotency interlock for the whole scheme:

- Current harness ownership of the lock.
- Its matching `state/.session-start-complete` record.

The full digest updates the completion record in this order:

1. It acquires the lock.
2. It clears the completion record.
3. It republishes the lock owner's pid only after every stage completes.

So `clear` or `compact` cannot skip startup sweeps after a truncated run.

### Re-emit mechanics

`bin/fm-session-start.sh --reemit` owns these re-emit details:

- Which work a re-emit skips.
- Its true-start AGENTS.md baseline.
- Its supported stale-instruction refresh pairs.

The `bin/fm-session-start.sh` header is the single owner of those mechanics.

## Runtime bound

### Network work stays off the blocking path

The digest makes no external-network call at all.
Every network call it owes runs off the blocking path, in the separately bounded deferred stage owned by `bin/fm-startup-network.sh`.
So an unreachable host can no longer consume this budget.

### Digest timeout

Some digest work remains local but unbounded:

- Tool version probes.
- The backlog listing.

So the whole digest still runs as one bounded child, default 120s via `FM_SESSION_START_TIMEOUT`.

Each per-task endpoint liveness read runs serially in its own crash-isolated child, bounded by `FM_SESSION_START_ENDPOINT_TIMEOUT` (default 10s; a non-numeric or zero value falls back to the default).
So a read that hangs or dies becomes that task's own `endpoint: error` line and the digest continues.
With a wedged backend the stage's ceiling is tasks times that per-read bound and can itself reach the digest bound.

The per-item backlog row reads inside bootstrap's reconcile and close-replay sweeps are the exception.
Each of those reads is bounded by `FM_BACKLOG_ROW_TIMEOUT_SECS` (default 10s) through `bin/fm-backlog-transition-lib.sh`.
The first bound hit latches the sweep.
Later reads in that sweep then return immediately while still naming their own item.

When timeout, gtimeout, and perl are unavailable, the shared timeout owner falls back to a pure-Bash process-group watchdog.
So no supported host runs the digest unbounded.

### When the child stops early

The child streams into the native transport as it runs.
So everything emitted before the child stopped is retained for delivery.
The parent then prints a `STARTUP TRUNCATED` banner on any nonzero child exit, not only the bound, that names:

- The stage that did not finish.
- The stages that were therefore never emitted.
- Whether the child hit its bound or died unexpectedly with its exit status.

The parent still exits 0.
The regression evidence for both shapes is in [`docs/verification/supervision.md`](verification/supervision.md#per-task-endpoint-reads-cannot-truncate-the-digest).

## Pi and pi-signed

The tracked transport is `.pi/extensions/fm-primary-turnend-guard.ts`.
The extension maps Pi events onto wrapper sources:

- It maps `session_start` reasons `startup`, `new`, `resume`, and `fork` onto wrapper sources.
- It refines a Pi-reported `startup` to `resume` only when a continuation, resume-selection, or explicit-session flag accompanies a session header older than the current process.
- It maps a fork flag to `fork`.
- It handles `session_compact` as the compaction equivalent.
- Pi's `reload` reason does not start the wrapper.

Setup-created entries such as `--name` are not restoration evidence.

Each mapped session generation starts one native prerequisite.
`before_agent_start` awaits its matching result and returns one persistent context message before the first provider call.

### Pi message delivery

The extension marks the digest as operational input so Pi can distinguish it from a user message.

For `session_start`, the extension does the following:

1. It activates a session-id and monotonic-generation owner synchronously.
2. It starts the wrapper once.
3. It makes `before_agent_start` await that same promise before returning Pi's persistent `message` result.

Replacement or shutdown stops the matching process group.
Stale generations cannot deliver into the active session.

Pi compaction keeps its most recent entries, so the digest delivered after an earlier compaction can survive beside the newest one.
The extension's `context` handler therefore sends the model only the newest session-start message, while the session file keeps every delivery.

An eligible native failure or empty result settles before the extension returns the existing exact manual instruction.
So native and manual startup never run concurrently.

An intentional gate or non-primary stand-down returns no message.
Context-preserving sources retain their existing silent result when the current process already holds the lock.

Manual and automatic compaction retain the existing persistent delivery path, because an automatic retry may have no new `before_agent_start`.
That path still shares the same generation cancellation and exactly-once claim.

The extension encodes an unencoded digest or fallback as `session-start` operational input and leaves an already-encoded nudge alone.

### Pi delivery size limit

The extension streams the hook to completion and retains at most 512 KiB for message delivery.
Whenever the digest is incomplete, this approved containment keeps the prefix and appends a loud `PI SESSION-START DELIVERY TRUNCATED` marker with direct-inspection guidance.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` exercises source routing and the Pi extension.
`tests/fm-sessionstart-hook-live-e2e.test.sh` verifies real Pi session-open events.

[Supervision verification](verification/supervision.md#native-session-start-delivery) records the commands and observed results.
