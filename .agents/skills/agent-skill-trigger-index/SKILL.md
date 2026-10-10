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

- `ask-user-authority` - Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
- `away-quiet-supervision` - Load whenever /afk or /quiet is invoked, an away or quiet record exists, or a marked away-supervisor message arrives.
- `bootstrap-diagnostics` - Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, PRESENTATION_UNAVAILABLE, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
- `captain-hold-lifecycle` - Agent-only policy for completing investigations and visual reviews without losing unresolved captain calls, and for closing what the captain owns with his actual words.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints.
- `decision-hold-lifecycle` - Renamed pointer kept for in-flight briefs: the decisions concept collapsed into "a task held for the captain".
  Load captain-hold-lifecycle instead; this stub only redirects and will be removed one release after the collapse.
- `diagnostic-reasoning` - Agent-only procedure for diagnosing reported bugs.
  Use before scoping a reported bug and before acting on a diagnostic report.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, and disconfirming evidence.
- `firstmate-codexapp` - Agent-only playbook for coordinating visible Codex Desktop threads alongside Firstmate without pretending they are a selectable shell backend.
  Use before creating, reading, steering, archiving, debugging, or reviewing a Codex App visible thread for Firstmate work, and before responding to requests to make Codex App native to Firstmate.
- `firstmate-coding-guidelines` - Agent-only reference for changing firstmate's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, trigger hygiene for new skills, and repo style rules (one sentence per line, plain dash, no agent co-author, shellcheck-clean bin scripts, colocated tests, and maintainer-verification evidence).
- `firstmate-orca` - Agent-only operator checklist for Firstmate's Orca runtime backend.
  Use when switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
- `fmx-respond` - Agent-only playbook for handling Relay mentions and follow-ups.
  Use on an "x-mention <request_id>" check wake to read the stashed mention, classify it, act autonomously on eligible requests, reply or dismiss, and link spawned work.
  Also use on an "x-mode-error ..." check wake to report the Relay configuration blocker instead of answering a mention.
  Also use on milestone and terminal wakes for a Relay-linked task before posting completion follow-ups, using typed promised-final reconciliation when registered and --final otherwise.
  Also use on a "public-followup ..." check wake, and whenever a promised final public reply must be created, reconciled, or delivered.
  Loaded only when Relay is enabled.
- `fork-drift-sync` - Agent-only response to a fork drift check wake.
  Load on a `fork drift:` check wake naming a project behind its upstream.
  Dispatches the merge-commit sync ship in the project's registered delivery mode, merges the green PR, and runs that project's existing rollout.
- `grilling-supervision` - Agent-only route for running a grilling interview with the captain for any registered project, with the installed `grilling` skill as the method.
  Load before dispatching an interview when the captain asks to grill or interview a project's goal or design, and whenever that interview's worker reports a round or recap ready.
- `harness-adapters` - Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, gemini, muse, rovo, omp, agy, and devin.
- `operational-home-layout` - Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
- `process-event-sources` - Agent-only procedure for registered process-to-event sources and their wakes.
  Use before arming a long-polling source firstmate owns, before registering a deterministic condition->action watch, on any `procevent <adapter> <source-id> <sequence>` check wake, and on any `process-event source stranded` or `process-event source failed to start` check wake.
  Owns the arming commands, the condition->action eligibility boundary, the durable result read, which wakes must be routed to their adapter instead of acknowledged generically, the handled acknowledgement contract, the one-owner rule, and the precise durability boundary.
- `project-management` - Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
- `quota-array-dispatch` - Agent-only decision procedure for resolving a matched crew-dispatch profile array from quota-axi's default TOON, ranking by spendPriority after three orthogonal gates, or taking the first candidate that passes them when the dispatch file declares array_order preference.
  Load when a dispatch rule or default resolves to more than one profile candidate.
- `scout-completion` - Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
- `secondmate-provisioning` - Agent-only reference for persistent secondmate setup and retirement.
  Use when creating, seeding, validating, launching, recovering, handing backlog to, pushing inherited local material into, or retiring a secondmate home, or when editing data/secondmates.md.
  Covers local leases, whole-home remote routes, transactional seeding, record intake for an existing or inherited domain, project clone restrictions, secondmate harness pins, inherited local-material push, idle charter, handoff helper, and teardown safety.
- `session-start-recovery` - Load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
- `ship-landing` - Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
- `stuck-crewmate-recovery` - Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Also use on the inverse case: a live crewmate reporting the no-mistakes pipeline dead, unreachable, or timed out.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
- `validation-supervision` - Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
