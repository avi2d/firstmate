# 0001: Daily supervisor session reset

Date: 2026-10-10.
Status: accepted.

## Context

A quota review found supervisor sessions growing past 400k tokens with no reset path.
Second mates already restart through a persist-gated flow, and the main session runs on Pi.

## Decision

Reset every supervisor conversation once daily at one configurable time in config, defaulting to the captain's night.
Reuse the persist-gated restart for second mates instead of building a second replacement mechanism.
Schedule and gate the pass in a new watcher check, and keep validation-run judgment with the main supervisor through explicit mate ids.

## Consequences

The main session cannot replace itself by tool call: Pi grants session replacement to user-initiated commands only, and model-invoked tools receive a context without it.
So the daily pass restarts the second mates and prints the main-session half as instructions for the captain's next fresh session.
The check stays silent while an away or quiet record exists, because a parked supervisor cannot act on the wake and the day's pass would be lost.
A mate proven mid-turn is skipped and retried the next day, so the reset never interrupts a turn in flight.
