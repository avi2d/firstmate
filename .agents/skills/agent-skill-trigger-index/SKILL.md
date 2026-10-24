---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---
# Agent-only reference skills

These skills are not captain-invocable; load them only at their precise triggers.
Each entry repeats its skill's own description word for word; the description is the trigger.
After changing a skill description, run `bin/fm-skill-trigger-index.sh --write`.

- `ask-user-authority` - Single owner of ask-user finding policy.
  Load before deciding any ask-user finding.
- `away-quiet-supervision` - Load whenever /afk or /quiet is invoked, an away or quiet record exists, or a marked away-supervisor message arrives.
- `bootstrap-diagnostics` - Load when the session-start digest's bootstrap or network-checks section, or a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run, prints an actionable diagnostic line - MISSING, MISSING_MANUAL, OUTDATED, PRESENTATION_UNAVAILABLE, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
- `captain-hold-lifecycle` - Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints.
- `diagnostic-reasoning` - Load before scoping a reported bug and before acting on a diagnostic report.
- `firstmate-codexapp` - Load before creating, reading, steering, archiving, debugging, or reviewing a Codex App visible thread for Firstmate work, and before responding to requests to make Codex App native to Firstmate.
- `firstmate-coding-guidelines` - Load before editing firstmate's shared, tracked material as defined by AGENTS.md section 1, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
- `firstmate-orca` - Load when switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
- `firstmate-self-repo` - Load before dispatching, promoting, relaunching, or delivering any task whose project is the firstmate repository itself, when a firstmate bug or improvement idea surfaces in ordinary use, before granting or revoking upstream publication authority, and before deciding whether any push, pull request, issue, comment, or fork may reach firstmate's own upstream.
- `fmx-respond` - Relay playbook, loaded only when Relay is enabled.
  Load on an "x-mention <request_id>", "x-mode-error ...", or "public-followup ..." check wake, on milestone and terminal wakes for a Relay-linked task before posting completion follow-ups, and whenever a promised final public reply must be created, reconciled, or delivered.
- `fork-drift-sync` - Agent-only response to a fork drift check wake.
  Load on a `fork drift:` check wake naming a project behind its upstream.
  Dispatches the merge-commit sync ship in the project's registered delivery mode, merges the green PR, and runs that project's existing rollout.
- `grilling-supervision` - Agent-only route for running a grilling interview with the captain for any registered project, with the installed `grilling` skill as the method.
  Load before dispatching an interview when the captain asks to grill or interview a project's goal or design, and whenever that interview's worker reports a round or recap ready.
- `harness-adapters` - Load before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
- `operational-home-layout` - Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
- `process-event-sources` - Load before arming a long-polling source firstmate owns, before registering a deterministic condition->action watch, on any `procevent <adapter> <source-id> <sequence>` check wake, and on any `process-event source stranded` or `process-event source failed to start` check wake.
- `project-management` - Load before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
- `quota-array-dispatch` - Load when a crew-dispatch rule or default resolves to more than one profile candidate.
- `scout-completion` - Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
- `secondmate-provisioning` - Load when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
- `session-start-recovery` - Load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
- `ship-landing` - Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
- `stuck-crewmate-recovery` - Load when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer, after observing a defeated Claude or Codex bypass, and when a live crewmate reports its no-mistakes pipeline dead, unreachable, or timed out.
- `validation-supervision` - Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
