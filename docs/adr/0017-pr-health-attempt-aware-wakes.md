# 0017: Attempt aware failing check wakes in the PR health monitor

Date: 2026-11-08.
Status: accepted.

## Context

The PR health monitor wakes once per owned pull request for a new merge conflict or a new failing check.
A failing check woke once per latest commit and check name.
A rerun that failed again at an already reported commit stayed silent when the name was already recorded.
One task waited out a forge outage behind a fixed recheck while new attempts failed on typecheck, and the monitor never woke because the failing name was already recorded.

## Decision

A failing check now wakes once per latest commit, check name, and run start.
A rerun that fails again at the same commit wakes once more because the new run is new evidence.
The same attempt never wakes again.
Each newly failing check names the failing step read from its newest failed Actions job, with the attempt number and the failed step names.
A step read that fails for any reason keeps the check only wake instead of losing it.
Checks recorded before run start tracking carry no start and are adopted silently, so the upgrade itself wakes nothing.

## Consequences

A real failure that follows an outage reads as itself instead of as the outage still standing.
A check that reruns in a loop wakes once per attempt, so a rerun storm can wake repeatedly until the failure is fixed or the pull request moves.
The step read costs extra forge reads only on passes that already wake, bounded by the pass deadline.

## Why the kept rules hold

These reasons sit behind the monitor header rules.
The REST single pull request read starts the mergeability computation.
A null mergeable reads as neither clean nor conflicting and never clears a reported condition.
The rollup judges each check name by its newest run because the forge keeps a cancelled run beside the passing rerun that replaced it.
Ownership outlives the worker through enrollment, so the open pull request on a live task copy current branch stays owned.
Retirement ends ownership even while the copy stays on that branch.
A secondmate copy is never looked up because its pull request belongs to the secondmate home.
Another home pull request is dropped without a forge read or a wake.
When no reported check is required, any failing reported check counts, matching the unprotected stacked base rule.
Branch discovery and owned pull request reads fan out in one concurrent wave with no rotating backlog.
The line prints before its fingerprint saves, so a pass killed between the two repeats one wake rather than losing it.
An unreadable fingerprint file is reported once and replaced, so a corrupt record cannot wedge the monitor silent.
