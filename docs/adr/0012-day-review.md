# 0012: Day review on the watcher check

Date: 2026-10-26.
Status: accepted.

## Context

The captain wants an evening board at 21:00 Moscow time with where time and API price went, quality signals, and advice that the next evening checks.
The fleet already runs one daily job, the session reset, as a registered watcher check.

## Decision

Schedule the review as a second registered watcher check with its own time and zone, separate from the session reset.
The check compares the current instant in the configured IANA zone, so a host clock in another zone still fires at the configured local time.
The main home collects every second mate, remote ones through the tracked remote command path, and renders one board.

## Consequences

No daemon or scheduler is added.
The watcher already polls registered checks on its normal cadence, which is precise enough for a once a day board.
A parked supervisor is not woken.
The next review covers the whole time since the last one, capped at a week, so no day is lost.
Advice is judged per finished task, because raw totals rise and fall with how much work finished that day.
Figures with no source stay named gaps rather than estimates, so a missing list price or log shows up on the board.
