# 0002: Prove Herdr Aqua birth through launchd attestation

Date: 2026-10-11.
Status: accepted.

## Context

A herdr server, and every pane and agent it later spawns, keeps the macOS audit session of whatever started it.
Only the Aqua login session (the gui/<uid> launchd domain) can read the login keychain without a UI prompt.
A server started over SSH runs in sshd's audit session, where `security find-generic-password -w` exits 36 (interaction not allowed) and every claude pane silently falls back to a stale plaintext credentials file and reports "Login expired".
Herdr's own remote attach starts such a server when it finds none, and it wins the socket at boot because sshd accepts connections before the login session exists.
docs/verification/runtime-backends.md ("fm-remote server birth and login-keychain access") holds the dated evidence for every marker read here.
macOS 26 no longer exposes one process's environment to another through ps -E, so the birth markers the owner library read from the socket owner's environment (SSH_* variables, XPC_SERVICE_NAME, FM_REMOTE_JOB_ACTIVE) are unreadable there.
The failure is silent: every owner classifies as unknown, the readiness check reports a healthy Aqua-born server as foreign, and the launch-agent guard retakes a session it should have left alone.

## Decision

Prove birth through launchd's own job-to-pid record instead of the owner's environment.
A socket owner is launchd-born when `launchctl print gui/<uid>/<aqua-agent-label>` names it as the job's main process.
A socket owner is worker-born when it carries FM_REMOTE_JOB_ACTIVE=1 or descends from the dev.firstmate.remote-job main process launchctl names, with that job loaded only in gui/<uid>.
SSH birth keeps its two existing signals: SSH_* environment markers where readable, and an sshd or remote-client-bridge ancestor everywhere.
Anything unproven stays unknown, and unknown stays not Aqua, so an unreadable environment refuses rather than guesses.

## Consequences

The environment-marker tiers stay as a first signal where the platform still exposes them, so older macOS and Linux classify exactly as before.
A merely loaded job proves nothing without naming the owner as its main process, so a foreign server can no longer hide behind a loaded agent.
The Darwin fixtures model launchd's pid attestation and SSH ancestry directly, since marker environments cannot be observed on macOS 26.
