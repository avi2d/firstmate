# 0008: Live Pi TUI keystroke-echo guard for supervision delivery

Date: 2026-10-22.
Status: accepted.

## Context

The captain reported the TUI freezing on every supervision outcome arrival.
Subprocess work in the delivery path stopped Pi's single thread, blocking repaint and key echo.
The portable regression pins the mechanism with real processes and no harness.
This guard measures the symptom against the installed Pi by typing into the pane and timing keystroke echo.

## Decision

Type markers into a live Pi TUI in three arms in one run and compare worst keystroke-echo delay.
The floor arm runs Pi without the supervision extension.
The idle arm runs Pi with the extension loaded and nothing to deliver.
The delivery arm runs Pi with the extension loaded and two captain-facing outcomes arriving.
The floor is what Pi itself costs on that machine, and the loaded arms must stay in its class.
The margin is wide on purpose, since the guarded regression was an order of magnitude.

## Consequences

The guard needs Pi, tmux, and node, and runs as a default-on live gate.
It touches nothing global: a scratch home, a scratch project holding a copy of the tracked extension, a private tmux socket, a scratch session directory, trust for that run only, and offline mode.
Pi reads the operator's own agent directory so it renders a usable TUI, and nothing there is written.
