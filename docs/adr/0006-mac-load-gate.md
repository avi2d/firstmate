# 0006: Mac load gate and single simulator boot path

Date: 2026-10-17.
Status: accepted.

## Context

A rebooted Mac showed a one minute load average under 10 while the five and fifteen minute averages stayed above 20 after a Spotlight reindex.
Three simulators booted at once drove the load near 390, and validation booted three more at once for a load near 850.
The standing limits allow at most four heavy workers while the five minute average stays under 10, with one simulator at a time.

## Decision

Judge a heavy start on the five minute average, and refuse it at or above 10 with exit 75 so the backlog item stays queued.
Count heavy workers machine wide across every local home, excluding secondmates and handed off records, and refuse a fifth with exit 75.
Boot simulators only through bin/fm-sim-boot.sh, which holds one machine wide lock, refuses while another device is booted or the average is high, and prefers a warm iPhone on the newest runtime.
Declare the limits in config/project-capacity as `@heavy-limit` and `@load-limit` lines with standing defaults 4 and 10.

## Consequences

A relaunch obeys the same gate as a fresh spawn, and an unreadable state refuses rather than undercounts.
The simulator helper works under the nono sandbox profile because it only shells to sysctl, xcrun, and a cache directory.
Every ship and scout brief on this machine carries the helper path through config/brief-include.md.
