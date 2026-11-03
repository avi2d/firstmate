# 0016: Agent control plane and fresh relaunch

Date: 2026-11-03.
Status: accepted.

## Context

bin/fm-send.sh is the data plane: conversational text for the agent to read, always routing-marked for a secondmate target so the reply returns through the status path.
That marking is right for a message and wrong for a lifecycle command, because a marked `/quit` arrives as chat the agent reasons about instead of executing.

`resume` is not deterministic across the verified adapters, and docs/agent-control.md owns the per-adapter resume facts.

A relaunch once resumed the Herdr pane's recorded Pi session with `--session`, so the status authority Herdr had bound to that session kept applying to the replacement.
That also handed the replacement its predecessor's whole conversation, so a relaunched worker continued at turn 434 of an old session instead of starting from its instructions.

Herdr keeps a Pi pane's registration after the agent quits when the pane's shell outlives it, and it then drops every report carrying any other session.
A fresh Pi in that pane reports a new session, so without intervention the pane stays frozen at the previous agent's last state.
A report from the same source with no session clears that binding, after which the fresh agent's session report binds and its state reports apply.
Reproduced on herdr 0.9.5 with Pi integration version 9: with no clearing report a working fresh agent read idle for 30 seconds, and with one it read working within three seconds on its new session file.

## Decision

bin/fm-control.sh is the control plane: allowlisted lifecycle verbs addressed to an exact task id, with per-harness mechanics in bin/fm-control-lib.sh.
That library holds three capability tables and their artifact-path tables: the verb allowlist, the per-harness control mechanics, and the per-backend key and agent-state capability.
They have no side effects, run no backend command, and read no state, so a test reads them as a pure contract.
The one exception is fm_control_endpoint_absence_verdict, the single owner of the per-backend endpoint-absence proof, which runs backend reads.
A verb whose postcondition cannot be proven on the recorded backend is refused rather than performed blind.

`resume` is not a verb.
`relaunch` treats the instructions on disk as the durable input and always starts a fresh agent session on every harness.
The replacement inherits only the task's local copy and the relaunch note.

Before typing the launch into an adopted Herdr pane, bin/fm-spawn.sh clears a stale session binding through bin/backends/herdr.sh's fm_backend_herdr_pane_session_binding_clear.
The clear acts only on a stale registration over a shell-only pane, sends one sessionless idle report from the registration's own source with a microsecond sequence newer than the exited agent's reports and not newer than the replacement's, and then confirms the binding is gone.

## Consequences

A relaunch never carries a prior conversation forward, at the cost of the context that conversation held.
When the clear cannot be confirmed the relaunch still proceeds fresh and warns that the pane's status may not follow the replacement.
A live registration is never cleared, so a pane whose previous agent still runs keeps its binding and the existing launch refusal applies.
