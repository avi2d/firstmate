# 0011: Claude Code cloud session worker relay

Date: 2026-10-25.
Status: accepted.

## Context

Claude Code cloud sessions run a task on Anthropic's hosts and bill a separate cloud credit, so a ship task can run without a local agent.
The command line creates a session only from an interactive terminal, sends follow-ups non-interactively, and has no verb that reads session state.
The only state reader is a beta HTTP API authenticated with the account's login token, which Firstmate would have to read from the system keychain.

## Decision

Run a relay process in the task pane instead of an agent.
The relay pushes the task branch, creates the session through `script(1)`, and records the session id.
It forwards the durable steering inbox with `claude -p --cloud`.
It treats GitHub as the source of truth.
A ready pull request from the task branch is the done signal, and the relay fast-forwards the local copy onto its head before reporting it.
A configured deadline is the only stuck or failed signal, and the session API and the keychain stay unread.
Restrict the adapter to direct-PR ships on GitHub, because no-mistakes runs on this machine and local-only never reaches GitHub.

## Consequences

A cloud task costs one idle local pane and one local copy, and existing supervision, steering, and cleanup apply without a second control plane.
A session that stalls, asks a question, or fails surfaces only at the deadline.
Interrupt, exit, and relaunch keys cannot reach the cloud agent, so the control plane refuses them.
Cloud commits bypass the per-task commit-message strip, so the task prompt carries the attribution rule instead.
