# 0003: Sandbox profile shape for pi workers

Date: 2026-10-16.
Status: accepted.

## Context

The scout trial pinned the model proxy at port 18999 in the worker models file.
A fixed port collides when two sandboxed workers run at once.
The trial also covered only the opencode-go provider.
Other providers need their own proxy routes before they can run sandboxed.

## Decision

Omit the fixed proxy port and the base URL from the per-task models file.
The worker keeps only the key reference there and takes the endpoint from the proxy environment of its own run.
Gate sandboxing on the opencode-go provider.
Other providers and Claude bridge models launch unsandboxed with a warning until their routes are proven.

## Consequences

Concurrent sandboxed workers no longer share a proxy port.
Each new provider needs a tested route before it joins the gate.
