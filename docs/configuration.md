# Configuration

Configure where Firstmate keeps its files, which tools launch workers, and how supervision runs.
Start with the directory layout, then use the setting reference for the behavior you want to change.

## Find a setting

| What you want to configure | Start here |
| --- | --- |
| Firstmate's code, private files, or project location | [FM_HOME](#fm_home) and [operational home layout](#operational-home-layout-and-state) |
| Task windows and worker tools | [Runtime backend](#runtime-backend-configbackend--fm_backend) and [harness support](#harness-support) |
| Worker permissions, accounts, or environment | [Codex approval review](#codex-automatic-approval-review), [Claude permission mode](#claude-permission-mode-configclaude-permission-mode), [Codex permission mode](#codex-permission-mode-configcodex-permission-mode), [persistent managed-policy failover](#persistent-managed-policy-failover), [worker account pin](#worker-account-pin-configclaude-account-configpi-account), [cloud Claude worker](#cloud-claude-worker), [worker tool exclusions](#worker-tool-exclusions-configcrew-exclude-tools), [worker launch environment](#worker-launch-environment-configlaunch-env-allowlist) |
| Backlog, preferences, and memory | [Backlog backend](#backlog-backend-taskstoml--configbacklog-backend), [external memory tiers](#external-memory-tiers-memory-layering-section), [record export](#record-export-configrecord-export-root), and [startup memory budget](#startup-memory-budget-configstartup-memory-budget) |
| Supervision and presentation | [Pi supervision branch](#pi-supervision-branch), [supervision host](#supervision-host-configsupervision-host), [Codex native Stop park](#codex-native-stop-park-configcodex-stop-park), [warm-cache compaction](#warm-cache-compaction-configwarm-compact), and [Calm preference](#calm-preference-configcalm) |
| Merging green yolo pull requests without a turn | [Merge on green](#merge-on-green) |
| Per-run overrides and tuning | [Environment variables](#environment-variables) |

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.

| Location | What it contains | Default relationship |
| --- | --- | --- |
| Firstmate repo root | Shared code, including the scripts in this repo's `bin/` | Most scripts also use this as the operational home when `FM_HOME` is unset. |
| Operational home | Private `state/`, `data/`, `config/`, and `projects/` | Selected by `FM_HOME`. |
| Projects directory | Local project clones | Under the operational home; `FM_PROJECTS_OVERRIDE` can select a different directory for tests and specialized harness setup. |

When `FM_HOME` is unset, most scripts use the repo root as the home.
When it is set, scripts still run from this repo's `bin/`, while `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.

### Root and directory overrides

`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.

Normal `bin/fm-send.sh` sends require `FM_HOME` to be set before resolving a
target, but
`bin/fm-send.sh --help` prints its usage without resolving a target or requiring
`FM_HOME`.
Normal sends do not use the general fallback, because a steer must not silently
resolve against the wrong home.
These variables override individual operational directories for tests and specialized harness setup:

| Variable | Directory selected |
| --- | --- |
| `FM_STATE_OVERRIDE` | Runtime state |
| `FM_DATA_OVERRIDE` | Durable private records |
| `FM_PROJECTS_OVERRIDE` | Local project clones |
| `FM_CONFIG_OVERRIDE` | Local configuration |

### Relative paths and lifecycle safety

Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` saves a path or passes it to another process, it handles each applicable `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory as follows:

- Resolve relative directories against the caller's working directory.
- Preserve accepted absolute spellings unchanged.
- Reject an unresolvable relative directory and name the offending variable.

`fm-spawn.sh` additionally rejects control bytes in those raw directory inputs before shell or filesystem normalization can change which path the backlog gate checks.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured data or state root, and a final-component symlink is refused even when its target remains within that root.

Other transient consumers retain their existing shell-relative behavior.

### Backend labels and containers

| Backend | Effect of the operational home |
| --- | --- |
| herdr | `FM_HOME` determines the adapter's workspace label. |

## Operational home layout and state

This section is the single owner of the top-level operational-home layout.
Producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains shared instructions, skills, documentation, workflows, and `bin/`.
Each effective `FM_HOME` contains private operational directories.

`data/` holds durable private fleet records:

- Project and secondmate registries.
- Captain preferences and optional shared captain preferences.
- Learnings, backlog, briefs, scout reports, optional task status archives, and the optional per-task no-mistakes pipeline-spend ledger.
- Explicitly installed content-addressed extension packages under `data/extensions/packages/`.

`state/` holds runtime records:

- Task metadata, append-only status events, and endpoint signals.
- Watcher and wake-queue coordination and away-mode state.
- Inactive terminal-outcome receipts under `state/terminal-outcomes/`.
- Enabled extension working namespaces under `state/extensions/`.
- Parent-side remote ledger copies under `state/secondmate-summary-cache/`.
- One-shot Bearings reconcile requests under `state/reconcile-notify/`.
- Private secondmate config-reread generations with their retry and quarantine state.
- Per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`).

`config/` holds local gitignored operating choices, including explicit extension bindings under `config/extensions.d/`.

`projects/` holds local project clones.
Firstmate reads these clones, but changes them only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based secondmate sync guards treat a home as dirty.

### Format and lifecycle references

- `bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.

- The producing PR helpers own the fields they append, [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns status-event vocabulary, optional emission-time syntax, and legacy unknown-time handling, and `bin/fm-crew-state.sh` owns current-state reconciliation.

- The [`bin/fm-fleet-snapshot.sh` header](../bin/fm-fleet-snapshot.sh) owns the snapshot's event-time and age fields, including secondmate parent-event projections.

- Wake, watcher, and away-mode state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

### Session-start references

- `bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.

- `bin/fm-startup-network.sh`'s header owns the deferred startup stage that keeps every external-network call and the potentially slow inactive-outcome scan off that digest's blocking path, including its state files and the safety argument for running them later.

- `docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.

- `AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.


## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md).
Edit it like any prompt when the fleet is empty.
While tasks are in flight, dispatch shared-repo edits to a crewmate.

## Calm preference (config/calm)

The Pi Calm extension and the Claude Code Calm mod share the local, gitignored `config/calm` preference under the effective Firstmate home.
One `/calm` choice therefore applies on either harness.
Both resolve the home in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from their own path under it.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.

### Values and default

| Value or file state | Result |
| --- | --- |
| `on` | Calm on. |
| `off` | Calm off. |
| Absent, unreadable, or unrecognized | Defaults to off. |

Both written values end with one newline.
`max` is a legacy value from a removed third presentation level.
Its behavior is now ordinary Calm, so it is still read as `on`.
A home upgraded from `max` keeps Calm on rather than dropping to off.

### Saving and reloading the preference

Each `/calm` command saves the new choice before changing live presentation.
A failed write leaves the current choice unchanged and is not reported as a saved preference.
Pi replaces the file atomically; the Claude Code mod uses the plugin API's plain file write.
The Pi extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.

The Claude Code mod reloads it on every `session.start`, including same-process session replacement.
It also loads the preference lazily before any row that can draw ahead of that event, including during `claude --continue` restoration.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Pi repeated-read containment

The tracked `.pi/extensions/fm-primary-read-repetition.ts` extension provides an optional read-loop safeguard for a Linux Pi primary.
It is off by default, including when configuration is absent or omits `enabled`.
When enabled, it stops the owning primary after three identical recognized reads return the same successful result within fifteen minutes.
It blocks the next call before execution and requires fresh interactive or RPC user input to resume.
Extension input and marked operational follow-ups cannot reset that stop, including the turn-end guard's recovery message.
The stopped owner also cancels compaction so the aborted turn cannot start a separate compaction request.
Changing results, errors and nonzero exit codes break the repetition sequence.
An identical call already in flight is temporarily blocked without being counted as a completed success.

Optional `config/read-repetition.json` configures the guard at extension load:

```json
{"enabled": true, "repeatLimit": 3, "windowMs": 900000}
```

`repeatLimit` must be an integer from 2 through 32, and `windowMs` an integer from 1000 through 86400000.
An absent file uses `enabled: false`, `repeatLimit: 3` and `windowMs: 900000`; malformed JSON, unknown keys or invalid values report an extension-load error instead of silently substituting limits.
`enabled: false` registers no guard handlers.
Configuration changes require the next extension load.

Ownership requires the effective home, current directory, session directory and primary PID marker to match this primary, with the session lock naming its process or a verified ancestor.
Workers, supervision branches, foreign owners and nested capability probes remain outside the guard.
Linux ancestry uses bounded `ps` queries, including when a wrapper holds the lock.
Enabled configuration on macOS or Windows reports an unsupported-platform load error; those platforms have no protection claim.
Missing ownership evidence leaves the guard inactive without writing session history or aborting another session.
A proven owner records `fm-read-repetition-activation-v1` in its Pi session journal with the effective limits and restored latch state; extension discovery alone is not evidence of activation.

The recognizer counts Pi's native `read`, `grep`, `find` and `ls` tools plus a conservative subset of ordinary shell reads.
It recognizes a narrow SSH read shape without executing or interpreting its command.
Supported shell forms include simple `cat`, bounded `head`/`tail`, `sed -n N,Mp`, pipeline `cut -cN-M`, selected `grep` options, `nl -ba` with optional `-vN` line numbering, `wc -l`/`-c` and `od -An -tx1c`/`od -An -c`.
One outer parenthesized group may contain a sequence of recognized reads separated by semicolons or newlines, including `cd /project`, read pipelines and unquoted backslash-newline continuations.
Every stage must be recognized; nesting, brace groups, shell substitutions, redirections other than `2>&1`, additional shell interpreters and unknown programs or options are uncounted.
Ungrouped multiline shell commands and polling tools are also uncounted.
An unrecognized stage makes the entire shell command uncounted, even if its output repeats hundreds of times.
This is a repetition detector, not command authorization or comprehensive loop detection.
History contains bounded hashes, labels and timestamps rather than read arguments or output; the stopped latch survives reload and compaction.
SDK-generated temporary paths in truncated Bash footers are normalized only when matching truncation metadata identifies them.

The extension uses the existing tracked-file distribution and trusted Pi project auto-discovery described in the [setup guide](../README.md).
The supported interception surface is Pi's own session event pipeline, including RPC sessions; its tool-call, result, input, session and compaction-veto hooks must all execute.
Other primary harnesses, worker interruption and tool execution in a separate native adapter are outside this extension's protection.
An adapter's `firstmate:native-tools` registration does not forward this interception or abort contract.
The stop is stored as a displayed custom message, but a native app may filter that message; an abort alone does not prove that its detailed notice was shown.
Current SDK and installed-harness evidence is recorded in [runtime backend verification](verification/runtime-backends.md#pi-repeated-read-containment).

### Migrating an ignored local guard

The managed entrypoint and `lib/fm-primary-read-repetition-policy.ts` intentionally differ from the local workaround's `fm-read-repetition-guard.ts` and `lib/fm-read-repetition.ts`.
An update therefore preserves those old ignored files and `config/read-repetition.json`, including with an updater from before this feature.
If the legacy entrypoint is present, enabling the managed guard refuses to register its handlers and reports the migration needed; a broken symlink at that path also refuses activation.
The legacy extension may still run under its own rules until it is migrated.
Before enabling the managed guard, preserve both legacy files and any existing configuration in a private backup outside Pi's extension discovery directories, then move the legacy entrypoint outside `.pi/extensions`.
Retain the backup and deliberately review the existing configuration before setting `enabled: true` and reloading extensions normally.
No automatic migration, removal, overwrite, reload or live-process change occurs.
For a locally installed file at either new managed path, preflight the update and use Git's `--no-overwrite-ignore` fast-forward option; an older updater does not protect arbitrary ignored-path collisions.

## Pi supervision branch

On a Pi primary, an in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews.
Main-only rows stay on the captain-facing path.
[docs/pi-supervision-branch.md](pi-supervision-branch.md) defines its conversation lifecycle, row eligibility, mixed-queue dispatch, heartbeat routing, and pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.

Bash absorbs a genuinely no-op heartbeat before it reaches Pi.
Every watcher-failure alarm stays on the captain-facing main path.
If the branch breaks, wakes fall back to main.
The branch cannot merge, land local work, start a task, or answer a decision.

### Outcome delivery and acknowledgement

While attended, a captain-facing branch outcome (verdict `captain`) is saved as one exact visible transcript entry keyed by sequence.
It then opens one processing turn on main for that sequence.
The turn stays open until main acknowledges the sequence through its `fm_branch_processed` tool.
The branch prompt's "Verdict: routine or captain" section owns the distinction between captain-facing, unsolicited routine, and unchanged-review outcomes.

The generated [Pi supervision protocol](supervision-protocols/pi.md) owns main's event ownership, acknowledgement duty, and conversational treatment for merged outcomes, while the persisted entry itself owns captain visibility.
A task-level routine no-change outcome or a no-change heartbeat explicitly reported with `silent=true` is delivered without a rendered note; the branch prompt owns task-level eligibility, and every other routine outcome still appends a rendered, sailboat-prefixed note.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

The branch can run on a cheaper model than main because supervision is an easier job than the captain's own conversation.
It can also use a lower reasoning effort because supervision needs less reasoning than that conversation.

### Choose a model and effort

The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.

The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.

Both picks change the supervision branch alone and never the captain's own conversation model or effort.

### Saved settings and available models

The command saves the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`.
Both live under the effective Firstmate home, resolved in this order: `FM_HOME`, `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path.
When `FM_CONFIG_OVERRIDE` is present for tests or specialized setup, it selects the config directory directly.
Firstmate keeps no model catalog of its own.
The list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.

A provider that exists only because an extension registered it inside the captain's session, such as pi-devin-auth's `devin`, is offered and can be pinned or followed like any other; [pi-supervision-branch.md](pi-supervision-branch.md#cost-model-and-the-byte-stable-prefix) owns how that registration reaches the isolated branch runtime.
Stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.

### Model file format and default

The model file holds one `<provider>/<model-id>` line followed by one newline.
Parsing splits at the first `/`, so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin.
The branch then follows main's current model, applied explicitly and live whenever main changes models mid-session.

### Following a native Codex model

When main uses `codex-native`, following main explicitly selects the same model through ordinary Pi's `openai-codex` provider, so the background branch owns an independent Pi conversation.
If that ordinary Pi model is unavailable, the branch refuses to build and returns the notification to main; it never inherits the main native thread or silently selects a different model.

Picking "Follow main" under a `codex-native` main reports that same `openai-codex` model, or that same refusal, because the command and the branch build share one follow rule.
A `codex-native` branch pin is refused and excluded from the picker.

### Applying and changing a model pin

A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.

The file decides the branch model on every build: the new conversation opened at each main session start, and a reopen after a model or effort change within a session.
It overrides the model Pi would otherwise restore from the reopened branch session, so the choice survives both cases.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.

### Unavailable models

For ordinary Pi providers, an unpinned build passes no model override only when main's model is unknown or this home's stored credentials cannot run it in the isolated branch runtime.
This preserves the behavior from before the file existed.
Model choice never loses the wake.
If main's model could not be applied, the command reports that failure instead of reporting a change that did not take effect.
If a pin names a model Pi cannot return because it is unknown or has no configured credentials, the branch refuses to build.
It sends the accepted wake back to the watcher's captain-facing main path, as any other unreachable branch does.
It never silently falls back to main's model.

Picking also releases the live branch so the next wake reopens this session's own branch conversation under the new model without waiting for a session replacement.

### Effort file format and available levels

The effort file holds one Pi thinking level followed by one newline.
Model and effort pins are independent: a captain may pin either, both, or neither.
The effort step follows the model step because the effective branch model determines which levels exist.
The menu uses Pi's own supported-level list.
Models without extended levels do not offer them; a non-reasoning model offers only `off`.

The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the most recent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.

### Applying and changing an effort pin

An absent, unreadable, or unrecognized file means no effort pin.
The branch then follows main's current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.

Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.

Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.

### Unsupported effort levels

Pi maps an unsupported pinned level to the branch model's nearest supported level.
Effort never causes the branch to refuse a build.
The captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will actually use.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

### Cancellation and inheritance

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick from the same run.
The command's closing message reports both choices as they will take effect.


## Supervision host (config/supervision-host)

Two optional local, gitignored files control the supervision host for this home: `config/supervision-host-off` opts the home out, and `config/supervision-host` opts a home in and selects its engine.
The host runs the supervision branch's contract on a headless engine session beside a non-Pi primary.
[docs/supervision-host.md](supervision-host.md) defines its design, current scope, and verified engines.
A Claude, Cursor, OpenCode, omp, Grok, or Codex primary can run the host.

A present `config/supervision-host-off`, whatever it holds, opts the home out on every primary.
Otherwise a Claude primary runs the host by default: with no `config/supervision-host` it runs exactly as with an empty one, at the Claude engine's default model.
A Cursor, OpenCode, omp, Grok, or Codex primary runs the host only while `config/supervision-host` exists and the home is not opted out.
A home that does not run the host behaves exactly as it does without it, and a Pi primary keeps its in-process supervision branch whatever either file says.
`fm_supervision_host_enabled` in `bin/fm-supervision-engine-lib.sh` implements this gate for every reader.

While the home runs the host, the primary's arm owner runs it in place of the watcher arm.
The host handles wakes on the engine under the [posture rules](supervision-host.md#postures), including an away record and attended operation on a Claude or Cursor primary with a verified dialog mirror.
The same gate governs the primary's dialog-mirror hooks (`bin/fm-host-mirror.sh`), which record on a Claude or Cursor primary ([supervision-host.md](supervision-host.md#the-dialog-mirror)).
Grok's arm command is rendered at session start, so a change to its host mode takes effect at its next session start; the other arm owners check the gate at every arm.

### Engine selection

`config/supervision-host` may be empty or hold one line `<engine> [<model>]`:

- empty or `default` selects the primary harness's own engine at that engine's default model (`sonnet` for the Claude engine);
- `<engine> [<model>]` names a verified engine, currently only `claude`, and optionally the engine's own model name or alias; `default <model>` selects the primary harness's engine with that model.

Only Claude has a verified engine of its own, so a Cursor, OpenCode, omp, Grok, or Codex home names `claude` in the file.

### Failures, when changes apply, and inheritance

An unverified engine, a primary without a verified engine, or a malformed line leaves the host without an engine.
It takes no wake, so every wake reaches main as it would without the host.
Each away-posture wake includes a line naming the problem.
The running host reads both files at every wake, so an engine change or an opt-out takes effect at the next wake without a restart.

`config/supervision-host` is local to each home and not inherited, because each home's engine and model are its own choice.
While the home runs the host, main's lease-checked commands also take the per-task lease lock, so a claim by the host's engine cannot race a mutation main already started (`bin/fm-lease-lib.sh`).

### Acknowledged hand-back (config/supervision-handoff-ack)

Create the empty, home-local `config/supervision-handoff-ack` file to enable acknowledged hand-backs on a Claude primary that runs the supervision host.
The flag is off when absent, is not inherited, and has no effect on other primaries or the host-off Stop path.
The host reads its presence at each hand-back, so enabling it needs no session restart.
Removing it stops further retries and leaves the current watcher for the ordinary next park.
[Supervision host](supervision-host.md#acknowledged-hand-back) owns the acknowledgement, retry transport, and limits.

## Codex native Stop park (config/codex-stop-park)

Create the empty, home-local `config/codex-stop-park` file to let a Codex primary wait for watcher wakes outside the model between turns.
The feature is off when the file is absent, and every Codex session then keeps the bounded foreground checkpoint protocol.
With the file present, only an interactive native Codex session on the verified CLI version that holds this home's session lock parks; every other session keeps the foreground checkpoint.
The supervision protocol is chosen when the session starts, so create or remove the file before starting the Codex session.
The file is local to each home.
[The Codex protocol](supervision-protocols/codex.md) owns the parked operating protocol, and `bin/fm-codex-stop-park.sh` owns version selection, registration, and failure fallback.

## Warm-cache compaction (config/warm-compact)

Create the home-local `config/warm-compact` file to compact an idle Claude primary and the supervision host's engine conversation before their prompt cache expires.
A session that sits idle past the cache lifetime re-writes its whole context at the cache-write price on its next turn.
Compacting while the cache is still warm reads the old context at the read price, so the next turn writes only the summary.

The feature is off when the file is absent.
The file is local to each home and is not inherited.
The host reads it at every check, so creating or removing it needs no restart.
It acts only on a home that runs the [supervision host](#supervision-host-configsupervision-host) beside a Claude primary, because the host's park is the primary's idle episode.

The file may be empty or hold these lines, each optional:

- `idle-seconds=<n>` is the idle time before a session is due (default 2700).
- `min-context-tokens=<n>` is the context size below which a session is never due (default 80000).

Blank lines and lines that start with `#` are ignored, and an unusable value keeps its default.
Context size is the last request's `input + cache_read + cache_creation` usage in the session's transcript.

A session is compacted when all of these hold:

- The home opted in.
- The session has been idle for `idle-seconds`: the primary since its turn ended, the engine conversation since its last handled turn.
- Its context is at least `min-context-tokens`.
- It was not already compacted in this idle episode.
  The host remembers a primary compaction for one park.
  It records an engine compaction in the engine record, so a later host does not repeat it.
- For the engine conversation, the next turn would resume it: the same engine, model, and prompt key, and below the rotation limit.
  An abandoned compaction is not recorded, so a later check retries it.
- For the primary, the agent reads idle and the composer reads provably empty.
  A busy agent, a non-empty composer, or an unproven state defers the compaction; nothing is typed.

The engine conversation receives `/compact` as one resumed, bounded headless turn.
A compaction is housekeeping: it adds no wake, outcome, or close line, and it is recorded only in the host's log.
A compacted primary still picks up pending wakes and decisions from disk, because a wake is a record the next drain reads, not conversation state.

This feature does not set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` or any other autocompact setting.
`bin/fm-warm-compact-lib.sh` owns the guards, with coverage in [`tests/fm-warm-compact.test.sh`](../tests/fm-warm-compact.test.sh) and the opt-in live guard [`tests/fm-warm-compact-herdr-live-e2e.test.sh`](../tests/fm-warm-compact-herdr-live-e2e.test.sh).

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
A home may instead select another tasks-axi adapter such as Beads through its own `.tasks.toml` or `TASKS_AXI_BACKEND`; firstmate still uses only tasks-axi verbs for routine backlog reads and mutations, and the adapter maps `start` and evidence-bearing `done` transitions to its native statuses and evidence fields.

### Backlog.md lab backend

Set `config/backlog-backend` to `backlog-md` only in a disposable home.
This option changes `bin/fm-tasks-axi.sh` but does not move the dispatch or completion transitions.
It does not import or replace either source file when you select it.

Install the pinned Backlog.md package with `npm ci --prefix bin/fm-backlog-md`.
From the lab home's `data` directory, run the installed `backlog init Firstmate --defaults --no-git --integration-mode none`.
In `data/backlog/config.yml`, replace `statuses` with `[Queued, Waiting, In Flight, Done]` and set `default_status` to `Queued`.
List the project's task types, priorities `p0` through `p4`, and project names in `task_types`, `priorities`, and `projects` for the board's filters.

The wrapper supports `show`, `add`, `list`, `ready`, `update`, `done`, `block`, `hold`, `unhold`, `unblock`, and `edit`.
Use `update --body` to replace a task body.
The wrapper rejects `note`, as does tasks-axi.
Each task name stays in the ticket's `id` field.
A held ticket uses the `Waiting` column and a `waiting-on:<kind>` label, with an optional `hold_until` date.
On or after that date, `ready` no longer excludes the ticket for the hold.

Run the installed `backlog browser` from the lab home's `data` directory to view the board.
Write through `bin/fm-tasks-axi.sh` so all writes take the same lock.
The native board and CLI do not take that lock.

Use [`bin/fm-backlog-md-convert.sh`](../bin/fm-backlog-md-convert.sh) with copies of the tasks-axi backlog and its Done archive.
Run `--help` for the dry-run and apply commands.
The converter counts queued and in-flight tasks as open, and counts every open task with a recorded hold as waiting, even if the hold date has passed.
It keeps archived tasks in the archive and retains non-blocking relations and blocker reasons in the ticket's implementation notes.
The converter rejects duplicate ticket IDs and public follow-up obligations rather than dropping records.
Keep both source copies if an import stops partway through, and retry in a fresh lab board.

### Decision memory in Backlog.md

The JSON topic map assigns a topic key to each source entry by its filename without the extension and its line number, such as `captain-7`.
Entries omitted from the map get distinct topic keys, so review the map for related entries before relying on the check.
The summaries JSON maps every source entry to an authored, single-line summary of at most 120 characters.
The converter reports each entry with an unknown date and retains the source text without claiming that it is a direct quotation.
The source records remain unchanged.

Run `node bin/fm-backlog-md/decisions.cjs check DECISIONS_DIR` to find invalid summaries, duplicate active topics, missing or inconsistent replacement links, and cycles.
For a replacement, set the older record's status to `superseded` and its `superseded_by` to the new record ID.
Add the older ID to the new record's `supersedes` list.
Preserve unrelated text from an older entry in separate records when only part of it is superseded.
Run the check again before activating the memory.

Place the checked records in the lab home's `data/backlog/decisions` directory.
Run `node bin/fm-backlog-md/decisions.cjs activate DECISIONS_DIR` once to select decision memory at startup.
Startup regenerates `data/decision-current.md` from the active global records and loads it instead of the four prose files.
A read-only startup renders the same view without writing it.
A failed check reports the error rather than loading the old prose.
Run `node bin/fm-backlog-md/decisions.cjs render DECISIONS_DIR PROJECT` to include summaries scoped to a project.
Use `render-full` in place of `render` to include the source text for global and matching project records.
A missing date or provenance is recorded as `unknown`.

### Captain holds on Beads

Captain-hold row creation is owned by [`bin/fm-captain-hold.sh`](../bin/fm-captain-hold.sh) `hold`: when no work item exists, it creates an ordinary backlog row (`--kind captain` metadata; Beads native type `task`) and then applies the captain hold.
Captain rows have no Beads due semantics, so that create path waives a Beads `due.required` setting rather than passing a synthetic `--due`; `--until` remains the optional hold deferral.

Do not register a Beads `types.custom` `captain` type for this: captain is a hold kind, and the fleet Beads `due.required` policy for ordinary work stays in the federated beads config.

### Automatic dispatch and completion

When the automatic transition gate applies, dispatch and completion each move the work item in the same run that creates or removes its task record.
The ordinary successful path therefore keeps the backlog and live task set in sync ([`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh)).
Under that gate, dispatch accepts only an unheld, unblocked Queued or In flight item in this home; a missing, Done, held, or dependency-blocked item is refused before any endpoint or local copy is created.

[`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh) refuses `add --start` and its `create --start` alias.
Either would place a row In flight without a task record, status file, or inbox, counting it as live work that nobody is doing.
The wrapper still passes through the documented direct transition `tasks-axi start <id>`.
Completion refuses to report success until the item is closed, and session start reconciles this home's own books after an interrupted run.

When a spawn is interrupted after launch delivery began, its exit path re-reads the paired task record and the backlog row under the same per-task lock as the commit, repairs a row the commit believed it had moved, and reports only what was verified or honestly attempted, never intent phrased as outcome ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh); [`tests/fm-backlog-atomicity.test.sh`](../tests/fm-backlog-atomicity.test.sh)).

### Which backlog receives a transition

Automatic transitions run from the configured data directory's parent, letting that home's effective tasks-axi configuration address its selected adapter while keeping relative scout-report links rooted there.
A markdown backlog is additionally addressed by an explicit `--file` at `<data>/backlog.md`, so the change lands in the home that owns the task regardless of the caller's working directory.

Any other configured adapter is addressed by that root alone, because `--file` would override the adapter's own workspace path.

### Exemptions and refusal conditions

The gate does not apply to persistent secondmates, manual-backend homes, or markdown homes without a backlog file.
Those retain their existing persistent-agent, manual, or ad-hoc lifecycle behavior.
Configured non-markdown adapters remain active without that file.
Migrated-hold resolution on a beads home reads its graph path, binary, and prefix from the root `.tasks.toml` `[beads]` section only, and refuses (rc=2) when the beads backend is selected elsewhere (a `TASKS_AXI_BACKEND` override or user-level config) with no root-level `[beads]` section.

On an automatic-backend home, missing or incompatible `tasks-axi`, an unresolvable configured data directory, or one containing a control byte fails lifecycle work before mutation.
An unreadable backend configuration can refuse lifecycle work before the no-backlog exemption applies; repair the configuration named in the diagnostic ([backend resolution contract](../bin/fm-tasks-axi-lib.sh)).

### Required tools and manual mode

Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh).
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for required-tool diagnostics and silent default-backend behavior.

Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not required-tool diagnostics.
A `manual` home owns its backlog file outright: the lifecycle transitions above are skipped there, dispatch and completion never fail over the file's contents, and a completed teardown prints the hand edit that is owed instead.

Absent or `tasks-axi` selects the tasks-axi path.
On the default markdown adapter, tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

### Using a separate operational home

The tracked `.tasks.toml` paths resolve against the directory tasks-axi runs in, not `FM_HOME`, so a bare `tasks-axi` run from the code root addresses the code root's `data/` whenever the home lives elsewhere.
tasks-axi replaces its target by renaming a temporary file over it.
If the target is a symlink, the write replaces it with a regular file.
Linking the code-root copy into the home therefore forks the queue on the first write instead of keeping the copies in sync.

Run every routine Firstmate backlog command through [`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh).
Like lifecycle transitions, it addresses this home's backlog and archive from any working directory.
Bootstrap reports a code-root `data/backlog.md` or `data/done-archive.md` that is not this home's own file as a `BACKLOG_RECONCILE: code-root ...` line, even in a read-only session.

## Runtime backend (config/backend / FM_BACKEND)

The runtime session-provider backend controls where task endpoints are created, captured, sent to, watched, and killed.
Herdr is the only runtime backend, and Treehouse provides each task's worktree.
[`docs/herdr-backend.md`](herdr-backend.md) owns its behavior.

### Backend selection order

New spawns choose the backend in this order:

1. An explicit `--backend` flag authorized for that exact task by a present user instruction or the task's own accepted brief.
   A later task cannot inherit that authority by analogy.
2. `FM_BACKEND`.
3. The first non-empty line of local, gitignored `config/backend`.
4. Default `herdr`.

Any value other than `herdr` is rejected.

### Liveness classification

The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.

The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.

### Dependency and socket checks

A herdr spawn version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A backend spawn refusal from a missing dependency or version gate is terminal; firstmate surfaces it as a blocker instead of retrying.

### Task metadata

Task meta records `backend=herdr`.

- Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
- A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.

### Task selectors

Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.

Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded `window=` target, and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.

These rules are the single owner of the task-selector vocabulary.
Backend guides and other documents refer here instead of restating the resolution order.

### Teardown identity checks

`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
When the worktree identity is missing, empty, or ambiguous, the refusal also explains how to identify the held copy and restore exactly one `worktree=` line without changing the record automatically.

### Herdr homes and presentation

[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.

The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The local `config/herdr-project-groups` file opts a home in to display-only Herdr project groups; [Project groups](herdr-backend.md#project-groups) owns its values, rules, tags, inheritance, and limits.

For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.

### Precedence and session boundary

`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.

See [`fleet-ledger.md`](fleet-ledger.md) for the opt-in setup, record contract, and limits.

## Merge on green

`bin/fm-merge-on-green.sh` decides and acts, and `bin/fm-procevent-merge-on-green.sh` runs it every 20 seconds as this home's process-event source, so it keeps running between supervision turns and stops when the home goes still.
`bin/fm-pr-check.sh` arms that source when it records a pull request for a yolo task, a yolo ship arms it at spawn, and an existing home arms it once with `bin/fm-procevent-merge-on-green.sh arm`.
Each home sweeps only the tasks in its own `state/`, and the source id carries a hash of that state directory because process-event claims are machine-wide.

A pull request merges only when every one of these holds, each read by the program rather than judged by an agent:

- The task is a ship task recording `yolo=on`, and the project's registry entry still carries `+yolo`.
- The pull request is on GitHub, open, and not a draft.
- No check is still running, and every one that reported passed.
- Every check the base expects has reported on this head.
  The expected checks are the names carried by each of the base's last five merged pull requests that carried any check, so a head whose workflow runs GitHub has not created yet waits instead of reading as green.
  A head with no check at all merges only when none of those five carried one, and waits when the base has no merged pull request or they cannot be read.
- The task is not held for the captain and has no open `needs-decision` or `blocked` key.
- The pull request carries no merge hold for the captain, recorded with `bin/fm-merge-hold.sh` against the pull request itself so it survives a task hold answer or release.
- The pull request is the newest one the task's `done:` or `ready:` reports name.
  When the record still holds an earlier pull request that has already landed, the newest report wins.
  A recorded pull request that has not landed keeps its claim.
- When no `pr=` was recorded, the GitHub pull request the newest report names is adopted once the forge shows its head branch is the task's ship branch.
  A report may name the pull request with its URL or with its bare number, and a bare number resolves through the task copy.
- A URL the task does not own is never adopted.
- The worker's latest `done:` or `ready:` report names this pull request, and no `working`, `paused`, or `failed` report follows it.
- The worker's latest `done:` line does not flag a credential, token, secret, auth, permission, sandbox, or isolation change.
  A mention counts as a flag unless its clause negates it.
- The diff touches no path naming a credential, auth, token, secret, sandbox, runner isolation, key, or `.env` file, and changes no `permissions:` line or scope inside a workflow.
- The pull request head was not already refused for changing security-sensitive paths.
- The branch does not conflict with its base.
- The green is settled, so a check that registers late cannot be raced.
  It is settled when the last check finished at least `FM_MERGE_ON_GREEN_SETTLE_SECS` ago, or when the same head read green on two sweeps that far apart.
  The default is 10 seconds.

Every merge goes through `bin/fm-pr-merge.sh`, which re-verifies the live head, the captain hold, the per-pull-request merge hold, the away record, and every check before the forge call.
It is given the head that read green, so a head pushed since then is refused instead of merged on the earlier head's checks.
A head that is behind its base is first brought up to date with `gh pr update-branch`, which merges the base into the branch and never rebases, and merges once its new head is green.
A refused merge or a failed update is retried at the same head only after `FM_MERGE_ON_GREEN_RETRY_SECS`, 300 seconds by default.
A merge refused for security-sensitive paths instead holds the task for the captain once, and that head is never retried.
A pull request skipped for what the forge reported, such as a red check, is read again only every `FM_MERGE_ON_GREEN_SKIP_RECHECK_SECS`, 60 seconds by default, so a standing red pull request does not spend a forge read on every sweep.
A task its own record rules out, because it is not a ship task, its yolo is off, or its project lacks `+yolo`, is skipped before any report is resolved through the forge.
Reports are read newest first, so a waiting task with a long history costs no forge read per sweep.
Every other pull request, including a red, pending, draft, conflicting, held, or boundary-touching one, stays open on the supervised path.

Each task's latest verdict is kept in `state/<task-id>.merge-on-green`, and every verdict change, merge, refusal, and update is appended to `state/merge-on-green.log`.
`bin/fm-merge-on-green.sh assess <task-id>` prints one task's verdict without acting.
GitLab, Forgejo, and Gerrit pull requests are not merged on green.

## Firstmate role (config/firstmate-role)

The optional local, gitignored `config/firstmate-role` declares this home's relationship to the firstmate repository itself.
Every home defaults to **user/operator** with no firstmate-upstream publication authority: ordinary project work and `/updatefirstmate` pulls are unaffected, but without an explicit grant no ship task on the firstmate repository may carry a publishing contract.
For the agent's local diagnosis, workaround, and draft-only response to a firstmate bug, see [`firstmate-self-repo`](../.agents/skills/firstmate-self-repo/SKILL.md#when-a-firstmate-bug-surfaces-in-ordinary-use).

The file holds exactly one directive line, with blank lines and `#` comment lines ignored:

| Directive | Effect |
| --- | --- |
| `user` | The default; identical to an absent file. |
| `maintainer <host>/<owner>/<repo>` | This home may dispatch publishing work that targets the one named firstmate upstream. |

A scope names the publication target repository (where a pull request lands), normalized to lowercase for comparison, not a push destination.
A fork maintainer contributing to the parent repository uses per-task consent rather than a second standing scope.
Write the primary home's file by hand; firstmate never grants itself a role, and the file never travels through git.
Supported secondmate propagation writes or removes the inherited copy as described below.
A malformed, unreadable, or symlinked file - including one with a second directive anywhere - resolves to user/operator; the role fails closed rather than guessing.

Authority is also available for one task at a time: `--upstream-consent <host>/<owner>/<repo>` on `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh` records the captain's explicit approval in the task's delivery contract and metadata without changing the home's role.
Role is never inferred from GitHub identity, forge permissions, remotes, repository ownership, authentication state, environment, or CI.
`bin/fm-role.sh report` prints the resolved role with no network call, and the session-start digest shows it in the HOME ROLE subsection.

`bin/fm-role-lib.sh` owns the fail-closed parser, self-repository detection, and the gate that `bin/fm-brief.sh`, `bin/fm-spawn.sh`, and `bin/fm-promote.sh` apply.
The publication target is selected from the first configured remote whose `remote.<name>.gh-resolved` value is exactly `base`, else one whose value names an explicit owner/repo on its own host, otherwise from the first configured remote in the order `upstream`, `github`, `origin`.
Selection is offline.
`bin/fm-role-lib.sh` owns URL and local-path normalization.
An unreadable or URL-less marked remote is not replaced by a fallback remote, and an undeterminable target never authorizes a task, even under task consent.
A task's project counts as the firstmate repository when it shares the code root's lineage - the same git common dir, or a root commit of the code root's history, which every fork, the parent, and any clone of either share - computed offline; undeterminable lineage (for example a shallow clone sharing no root commit) is refused, even under task consent.
Secondmate homes inherit the primary's resolved role, never its raw file: a primary file that resolves to user for any reason propagates as revocation.
The receipt prevents accidental publication through supported paths; it proves consistency, not provenance, and is not a security boundary against a process that deliberately forges local records.

## Waiting worker spends no turns (config/wait-no-turns)

The optional local, gitignored `config/wait-no-turns` presence flag opts this home into keeping a waiting worker from spending turns until it is answered.
With it present, ship and scout briefs gain the `# Waiting` section and the foreground no-mistakes drive text, every brief's inbox section keeps the natural-checkpoint check and adds that a waiting worker does not poll or list its inbox because a waiting instruction rings, a pending-reply recovery waits while that mate has its own open decision or blocker, and a fire-and-forget steer whose doorbell did not land gets one later ring.
With the file absent, generated briefs omit the waiting section and the no-poll inbox line, the drive text backgrounds the call, recovery sends during an open decision, and a fire-and-forget steer is not owed a retry ring.
The flag is a home-local preference.

## No local tests

The optional local, gitignored `config/no-local-tests` presence flag makes CI on the pull request the only test run for this home's workers.
With it present, every ship and scout brief gains a `# Local tests` section saying that the repository's own tests never run on the worker machine, in any repository, including any `package.json` test script and any test runner.
The section allows a throwaway check: a small script written in the worker's temporary folder outside the repository, run once to see one behavior, never committed, and finishing in about a minute without a browser, simulator, or App.
Build, lint, and typecheck commands may still run.
That section outranks a `config/brief-include.md` instruction about local tests, because the include defers to every other brief section.
Every no-mistakes drive instruction also adds `test` to its skip list: `--skip test` on an ordinary run, `--skip test,pr,ci` under `pr=manual`, and `--skip test,push,pr,ci` on Gerrit.
With the file absent, generated briefs carry no such section and the pipeline's test step runs.
The flag is read when a brief or a scout promotion is rendered, so a worker already under way keeps its brief.
`bin/fm-dod-lib.sh` owns the section and the drive text.
The flag is a home-local preference.

## PR registration scan (config/pr-register-scan)

The optional local, gitignored `config/pr-register-scan` presence flag opts this home into recording, without the supervisor, each PR a task reports.
With the flag present, the watcher's check sweep runs `bin/fm-pr-check.sh scan` before the merge polls.
The scan reads each ship task's newest `done:` line that names a `PR <url>`, and records that PR through the ordinary registration path when the task has no `pr=`, or has that same `pr=` but no published merge poll.
It skips persistent secondmate and scout records, a `pr=` that names another PR, and a PR whose merge was already reported or whose poll was retired.
A refused registration, such as a draft, prints one `check: pr-register:` wake for each task and PR, and later sweeps retry without a new wake, so a PR marked ready later is recorded.
With the file absent, the check sweep does not run the scan, and `pr=` and the merge poll come only from a manual `bin/fm-pr-check.sh <id> <PR url>` run.

## No-mistakes pipeline spend (config/pipeline-spend)

The optional local, gitignored `config/pipeline-spend` presence flag opts this home into recording per-task no-mistakes pipeline spend in `data/pipeline-spend.jsonl` during teardown.
When the flag is absent, teardown skips recording and the recorder exits before reading task metadata, no-mistakes state, or the spend ledger.
An existing ledger is left untouched while recording is disabled.

## No-mistakes home resolver (config/nm-home-resolver)

The optional local, gitignored `config/nm-home-resolver` file opts this home into finding each task's no-mistakes home through a site-provided resolver, for sites that run one no-mistakes daemon per isolated workspace, each against its own `NM_HOME`.
The home cannot be derived from a task copy's `no-mistakes` remote, because every workspace of a project shares one gate URL.
The file's first line is the absolute path of an executable the site provides; Firstmate calls it with the task copy's path as its only argument and never interprets the layout itself.
When the resolver exits successfully within 5 seconds and prints exactly one line naming an existing directory by absolute path, that directory is exported as `NM_HOME` for that one call.

Only host-side reads use it: current-state reads, pipeline-spend recording, the custody check, and teardown's parked-run lookup and `axi abort --run`, which read `axi status`, the `axi` overview, `axi logs`, `runs`, `daemon status`, and the state database.
It never starts a daemon and never changes how runs are launched or driven, account routing, or no-mistakes' own `config.yaml`.
An explicit non-empty `NM_HOME` always wins and the resolver is not called.
With the file absent, a first line that is not an absolute executable path, or a resolver that fails, times out, or prints anything else, every read uses the ambient home exactly as without the file.
The file is a home-local site choice; `bin/fm-nm-run-lib.sh` owns the exact resolution.

## Lane capacity (config/lane-capacity)

The optional local, gitignored `config/lane-capacity` file says how many ship and scout lanes this home should run at once, and when it should stop taking more.
`bin/fm-capacity.sh` reads it to report how many lanes are open for queued work, alongside running lanes, 1-minute load against logical cores, free memory, free disk, and, where orc is installed, the heavy queue's running and queued calls.
With the file absent nothing changes: the report prints counts and host figures only, never invents a target, never advises holding dispatch, and nothing is published; a malformed value is reported as invalid rather than guessed.
Persistent secondmates hold no lane.
The file is a per-machine choice, so each home owns its own numbers.

The first non-comment line is the cap, one non-negative integer, so a file holding only that integer keeps its earlier meaning.
Optional lines follow, one key and its value per line, with `#` starting a comment:

```text
12                     # the cap: lanes this home runs at once
min-avail-gb 5         # keep this much memory available; a 1 GB lane must fit above it
min-disk-gb 60         # every disk row must stay above this many GB
pressure-file ~/.cache/lookout-beat/beat.json      # repeatable; a lookout.beat 1.x document
reserve-flag /var/run/fm-reserved.flag host reserved by the captain   # repeatable; admit nothing while the file exists
captain-idle 300       # opt-in, macOS: the captain counts as present when input was idle under 300 s
quota-provider claude  # opt-in: publish that provider's quota runway
max-load1 20           # keep a raw 1-minute load rule while beats replace it
```

`pressure-file` and `reserve-flag` may repeat and take an absolute or `~/` path; a `reserve-flag` path may be followed by the label it is reported by.
Every other key may appear at most once.
An unknown key, a repeated single key, or a malformed value makes the whole file invalid: the report exits 1 naming the line, and the published facts carry the cap as invalid, because the captain's limits are never guessed.

A pressure file is any producer of the `lookout.beat` 1.x shape, read by its own file age on this machine; a missing, stale, or unreadable one is skipped with its reason and the host's own probes stand in, so a broken beat never blocks anything.
`captain-idle` reads input idle time locally and publishes only `present`, `idle`, or `away` (an away record), never the idle time itself.
`quota-provider` is the only key that makes the script reach the network, through `quota-axi`, bounded to five seconds.

While the file exists, the watcher runs `bin/fm-capacity.sh --publish` detached at most every 30 seconds, writing this home's lane facts to `state/lane-capacity.json`: its lanes, its cap and limits, its machine's pressure and boots, its watcher's freshness, and its own admission verdict.
Publishing is best-effort and never changes what the watcher does; no spawn reads the verdict.
`bin/fm-capacity.sh --admit` is an advisory check of the same verdict: it exits 0 when the verdict admits or the file is absent, and reports the reasons on stderr with exit 75 when it does not.
No Firstmate script calls it.
The script's header owns the report line, the published document's fields, the verdict, the beat freshness rules, the host-constraint thresholds, and the probe fallbacks.

The child's own `done` line still reaches the parent through `bin/fm-inactive-reconcile.sh`.
The flag is a home-local preference; [`bin/fm-pr-check.sh`](../bin/fm-pr-check.sh) owns the mechanics.

## Task status archive (config/status-archive)

The optional local, gitignored `config/status-archive` presence flag opts this home into retaining task status history during teardown.
Create it with `touch "$FM_HOME/config/status-archive"`; remove it to disable future archival and pruning.
It is off by default: without the flag, teardown deletes status logs as before and leaves existing archives untouched.
The flag applies to teardown run by this home, including forced retirement of its secondmate children; it is not inherited by other homes.
Each opted-in archival prunes owned logs older than 30 completed days by mtime; housekeeping failures warn and never abort teardown.
Age-based retention works independently of the selected backlog backend and keeps histories available for a predictable audit period.
[`architecture.md`](architecture.md#task-status-archives) describes archive locations and isolation from live state; [`bin/fm-teardown.sh`](../bin/fm-teardown.sh) owns the mechanics.

## Record export (config/record-export-root)

The optional local, gitignored `config/record-export-root` file contains exactly one absolute directory path and opts this home into a private copy of a fixed record allowlist.
The setting is off by default.
When the file is absent, sync exits without export work, teardown follows its existing path, and spawn, watcher, presentation, classification, and snapshot readers remain unaware of exports.
When the file is present, `python3` is required and an unreadable config directory or file is a hard failure rather than an opt-out.

The configured path must name a dedicated root outside and disjoint from the effective home, config, data, and state trees.
Its parent must already exist, while the final root may be absent so the exporter can create it.
An existing root is accepted only when its strict versioned ownership marker names this canonical home, so one root cannot serve multiple homes.
The exporter refuses an unmarked pre-existing directory, an owner mismatch, unknown managed artifacts, or unsafe object types instead of changing a broad or shared directory.
Exporter-owned directories use mode `0750`, and exported files use mode `0640`.

Run `bin/fm-record-export.sh sync` to publish the currently present allowlisted files through `<export-root>/live/`:

```text
data/{projects.md,backlog.md,done-archive.md}
data/<task>/{brief.md,report.md,status*.log}
state/fleet-ledger.jsonl
state/<task>.{meta,status}
state/<task>.inbox/{,handled/}NNN.msg
```

Sync skips hidden names in `state/`, such as `.startup-network.status`, because they are Firstmate records rather than task records.
The command is one-shot and starts no network transfer, daemon, timer, or watcher.
It does not recursively copy `data/` or `state/`, accept arbitrary sources, discover secrets, or redact content.
The exporter opens source and destination components relative to verified directory descriptors with no-follow semantics, then rechecks source identity and content before publication.
Sync builds a complete immutable generation, flushes its files and directories, and atomically replaces `live` with a relative symlink to that generation.
Consumers that need one consistent snapshot resolve `live` once and read that immutable generation rather than resolving the pointer separately for each file.
Superseded live generations remain selectable for 30 completed days before a later sync removes them.
The published generation is exact, so a later sync retracts allowlisted files that are no longer live and represents a pending-to-handled message move only at its current path.

Enabled teardown commits metadata, the live status when present, and pending and handled inbox messages under `<export-root>/archive/<task>/<spawn_gen>/` before those source records are retired.
Direct archive calls acquire the task metadata lock, while teardown calls under the same lock it already holds, so the exact source set is re-enumerated immediately before commit.
Each attempt builds a fresh sibling staging directory, flushes every copied file, directory, and manifest, and publishes the complete generation with one descriptor-relative rename.
`manifest.v1.json` carries the version, capture time, completeness, source-relative names, byte counts, and SHA-256 values.
Retries parse that JSON with duplicate-key rejection, require the exact v1 fields and types, and verify a one-to-one mapping between manifest entries and archived regular files.
A reused task ID writes its distinct `spawn_gen` rather than overwriting an earlier generation.
Only strictly valid committed generations older than 30 completed days are pruned by manifest mtime, matching task status archive retention, and scan failures warn without undoing a successful capture.
If the archive cannot commit, teardown reports the reason and stops before deleting metadata, status, or inbox sources.
Removing `config/record-export-root` is the explicit escape hatch back to ordinary teardown behavior.

Briefs and handled inbox messages carry captain text, and every exported record can contain other sensitive operational data.
Keep the export root private and never serve it directly.
The schema is versioned for compatible readers, but it is not a Firstmate command API and no Firstmate reader consumes it.
[`architecture.md`](architecture.md#read-only-record-exports) describes the mechanism boundary; [`bin/fm-record-export.sh`](../bin/fm-record-export.sh) owns the exact allowlist, schema, path checks, publication, and retention mechanics.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional local, gitignored `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it present, every referenced task must independently show positive work evidence, and an eligible bare turn-ended task that lacks authoritative proof may satisfy that requirement when its pane content changed since the previous poll.

### Evidence and time limit

It stays opt-in because the other two proofs read a verdict the harness itself vouches for while this one infers execution from rendered bytes; with the flag absent triage behaves exactly as it did before.
`FM_TURNEND_CHURN_ABSORB_SECS` is a positive integer number of seconds, defaults to `900`, and bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway.

An invalid value fails closed and surfaces the wake.
The bound is required rather than cosmetic because churn and pane staleness read the same pane.

The flag is a home-local supervision-noise preference, which run their own crew mix.
[`architecture.md`](architecture.md) owns the triage contract and `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed boundaries.

## Parked-gate wait deferral (config/wedge-defer-parked-gate)

The optional local, gitignored `config/wedge-defer-parked-gate` presence flag opts this home into a default-off further form of wait evidence in the watcher's wedge timer.

### When a waiting gate defers an alarm

With it present, a provably-working pane about to escalate is also deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's own current state is a validation gate whose answer is owed to the supervisor and whose decision for that run is still open, and the recheck names the supervisor and the action that clears the lane instead of reporting a suspected wedge.
It stays opt-in because the other evidence is a written record of the lane's silence - the worker's own declaration or firstmate's backlog captain hold - while this is derived from a pipeline's gate state, so which lanes give up the escalation ladder for it is a home's choice.

With the flag absent the wedge timer spends no fold or current-state read for it, writes no record, and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference, which supervise their own crew and own that trade separately.

[`architecture.md`](architecture.md) owns the wait-evidence contract and which records may take the ladder away; `bin/fm-watch.sh`'s `wedge_wait_evidence` owns the exact derivation and its fail-closed boundaries.

## Wedge evidence guards (config/wedge-evidence-guards)

The optional local, gitignored `config/wedge-evidence-guards` file opts this home into consulting operator-owned [Jev guards](jev-guards.md) before the watcher wedge-escalates a quiet live pane.
It lists one absolute guard executable path per line, and blank lines and `#` comments are skipped.
The file and every listed executable must be regular files owned by the watcher's user and not group or world writable, or they are never run.

### When a guard defers an alarm

Only at the wedge threshold, after the declared-wait, worktree-write, dead-endpoint, and opt-in validating-run checks have all let the escalation through, the watcher runs each guard as `<guard> --json` with `FM_GUARD_TASK` and `FM_GUARD_ENDPOINT` set, bounded by `FM_WEDGE_GUARD_TIMEOUT_SECS`.
The first guard that prints one JSON object with `status` `CRITICAL` and a non-empty `recommendation` defers that escalation by one window, without advancing the escalation count.
After `FM_WEDGE_GUARD_DEFER_MAX` consecutive deferrals the escalation fires anyway, and its reason names the guard and the first line of its recommendation.
A timeout, non-zero exit, malformed output, `OK`, `WARNING`, or `UNKNOWN` changes nothing, and a dead or missing endpoint is reported before any guard is asked.
A guard's answer is evidence only and never authorizes a decision, merge, cleanup, or any other action.

With the file absent the watcher runs no guard, writes no record, and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.

### Example operator family

Firstmate ships no default guard for this; host-specific families belong to the operator's own layer.
For example, an operator whose workers hold numbered tickets in a local queue directory could list a guard like this:

```sh
#!/bin/sh
# CRITICAL while this task holds a queue ticket whose recorded job is alive.
ticket="$HOME/queue/$FM_GUARD_TASK.ticket"
if [ -f "$ticket" ] && kill -0 "$(head -n 1 "$ticket")" 2>/dev/null; then
  echo '{"name":"ticket-dir","status":"CRITICAL","recommendation":"queue ticket held by a live job"}'
else
  echo '{"name":"ticket-dir","status":"OK","recommendation":"no live queue ticket"}'
fi
```

`bin/fm-watch.sh`'s `wedge_guard_evidence` and `wedge_defer_guard` own the exact invocation, deferral record, and fail-open boundaries.

## Worker-declared wait deferral (config/wedge-defer-worker-wait)

The optional local, gitignored `config/wedge-defer-worker-wait` presence flag opts this home into a default-off form of wait evidence in the watcher's wedge timer.
With it present, a provably-working pane about to escalate is deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its newest status line is the worker's own still-open `blocked:` or `needs-decision:` line, and the recheck names firstmate and that verb's clearing action instead of reporting a suspected wedge.
Lines under supervisor-reserved keys do not count, the escalation count does not rise, and any newer status line or a newer acknowledged steering-inbox record ends the deferral, so an answered lane that never resumes returns to the ladder.

With the flag absent the wedge timer spends no read for it and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference.
[`architecture.md`](architecture.md) owns the wait-evidence contract and `bin/fm-classify-lib.sh`'s `status_worker_wait_verb` owns which lines count.

## Open-decision reminders (config/open-decision-reminders)

The optional local, gitignored `config/open-decision-reminders` presence flag enables a default-off watcher backstop for unanswered keyed `needs-decision` and `blocked` records.
On each poll, the watcher queues at most one `check: open decision overdue: <task> key=<key> age=<seconds>s` wake for the oldest eligible overdue key, independently of pane state or supervision-branch classification.
Declared `paused:` waits and tasks already held for the captain are exempt.
Resolving a key stops its reminders, and a later opening starts a new reminder episode.
Only explicit keys with valid source `[at=<epoch>]` timestamps can be aged.

`FM_OPEN_DECISION_OVERDUE_SECS` defaults to `1800` seconds.
Repeats start at that interval, double after each repeat, and cap at `FM_OPEN_DECISION_BACKOFF_MAX_SECS`, which defaults to `14400` seconds.
Both settings must be canonical positive integers of at most nine digits, with the cap at least the threshold.
Invalid settings stop the watcher with an error when the flag is present.
Pass them in the watcher's environment, or export them in `config/watch.env` for watchers started through `bin/fm-watch-arm.sh`.
The flag is home-local.
`bin/fm-watch.sh`'s `open_decision_reminder_tick` owns the per-key schedule, which persists across watcher restarts.

## Validating-run deferral (config/wedge-defer-validating)

The optional local, gitignored `config/wedge-defer-validating` presence flag opts this home into a default-off deferral in the watcher's wedge timer.
With it present, a provably-working pane about to escalate is deferred to the `FM_PAUSE_RESURFACE_SECS` recheck cadence when its crew's attributed no-mistakes run step is `validating (running)` or `validating (fixing)`, because the worker is correctly idle behind its own drive call while the pipeline executes the round.
The recheck names that run instead of reporting a suspected wedge, the escalation count does not rise, and a run that is parked, terminal, ci-monitoring, absent or unreadable keeps the ladder.

With the flag absent the wedge timer spends no current-state read for it and keeps the unchanged escalation schedule, reasons, and `demand-deep-inspection` wording.
The flag is a home-local supervision-noise preference.
[`architecture.md`](architecture.md) owns the deferral contract and `bin/fm-classify-lib.sh`'s `crew_run_is_validating` owns which verdicts count.

## Spawn base from the primary checkout (config/spawn-base-primary-checkout)

The optional local, gitignored `config/spawn-base-primary-checkout` presence flag opts this home into a default-off base for fresh task worktrees on projects that land work locally.
Without it, every fresh ship or scout worktree on a project with an origin remote resets to `origin/<default>`, or to `origin/<base>` for a named base branch.

### Which tasks it changes

With it present, a fresh local-only ship, or a scout spawned without `--base-branch`, starts from the primary checkout's `<default>` when that branch strictly contains origin's tip.
A local-only project lands work there through `bin/fm-merge-local.sh` and never pushes, so `origin/<default>` stays at the last push, and a fresh task would otherwise start behind work already landed and load the project's instruction files from that stale tree.
A no-mistakes or direct-PR ship and any task with a named base branch still start from origin's tip, because that work is delivered against origin.
When the primary checkout's `<default>` and origin's have diverged, the spawn prints a note and starts from origin's tip.
A project without an origin remote is unaffected, and a relaunch never changes the base a task already has.

`bin/fm-review-diff.sh` reads the same flag, so a local-only ship or a scout is reviewed against the branch it delivers to and its diff shows only its own work, while a no-mistakes or direct-PR ship stays anchored on `origin/<default>`.
`bin/fm-promote.sh` reads it too, telling a scout promoted to no-mistakes or direct-PR on a project with an origin remote to return to origin's default branch rather than the primary checkout's.

The flag is per home, which keep their own project clones and opt in separately.
Only its presence is read, at each fresh spawn, review, and promotion.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the exact base rule, and the [`fm-review-diff.sh` header](../bin/fm-review-diff.sh) owns the review anchor.

## Gate defaults (.no-mistakes.yaml)

The tracked [`.no-mistakes.yaml`](../.no-mistakes.yaml) sets `test.evidence.store_in_repo: true` and runs the canonical [shell/workflow lint](../bin/fm-lint.sh) followed by the [Pi production-consumer typecheck](../tests/fm-pi-primary-types.test.sh) in the compiler-owning lint phase.
Storing evidence in the repo publishes each run's test artifacts to the orphan `no-mistakes/evidence` branch and links them from the PR body, instead of keeping them on local disk under the no-mistakes home.

That branch shares no history with code branches, so evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
The [`firstmate-coding-guidelines` skill](../.agents/skills/firstmate-coding-guidelines/SKILL.md#no-mistakes-test-configuration) owns why `commands.test` stays absent and targeted validation belongs to the evidence path.

`commands.test` executes code, so no-mistakes honors it only from the default-branch copy of `.no-mistakes.yaml`; a pushed branch cannot change what the gate runs.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.

Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## User preferences (data/captain.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.

When the home holds a decisions clone at `projects/decisions`, the context digest closes with an Unfiled rulings subsection listing dated `data/captain.md` bullets no record there cites yet.
`bin/fm-decisions-unfiled.sh --help` owns the cite rule.
The subsection stays silent when the clone is absent or every ruling is cited.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.

There is no shared learnings file by captain decision.

## External memory tiers (Memory layering section)

A home may declare memory stores outside firstmate, such as MCP-served knowledge stores, as authoritative for named classes of knowledge.
No declaration means firstmate's local files under `data/` are the only memory owners, which is the default.

Each declared tier states, in plain prose or a table:

- its destination, named precisely enough for an agent to reach it, such as a connector's tool-name prefix;
- the knowledge classes it is authoritative for, such as decisions and corrections, or people and references;
- its correction rule, such as append-only supersession instead of edit or delete;
- any capture etiquette, such as capture first and report what was captured.

For example, one home declares a Palimpsest MCP store authoritative for reasoning continuity (decisions, hypotheses, corrections), an OpenBrain MCP store authoritative for retrievable facts (people, projects, references), and its own `data/` as a disposable per-machine cache; those stores are that home's choice, not a template default.

The declaration is per-home untracked state under `data/`, like every other captain preference, so no clone or update carries it.
A fresh primary home has no declaration until the captain re-declares the `Memory layering` section there from their own records.
Until then local files are the only memory owners.

[`AGENTS.md`](../AGENTS.md) section 6 owns what a declaration changes about knowledge routing, and the internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns how curation reads the declaration and protects tier-owned entries from pruning.
The section counts toward the startup memory budget like the rest of its file, so keep it to the mapping rather than restating these rules.

## Startup memory budget (config/startup-memory-budget)

The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.

### Set and validate the budget

To select another allowance, replace the home's file with one valid positive value in the exact format below.

The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.

### Accounting and curation

Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.

The internal [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.

The helper's header owns exact parsing, publication, and report output mechanics.

### Daily startup growth check

A home can arm a lightweight daily growth monitor with `bin/fm-startup-growth-check.sh arm`.
It writes `state/startup-growth.check.sh` and binds it through the existing authenticated watcher-check mechanism, so no extra daemon or scheduler is installed.
Registering it is a reason to watch on the same terms as the [watched-tool check](#watched-tool-updates-configwatched-toolsjson), so an armed home keeps needing a watcher after its last task is torn down.
Use `bin/fm-startup-growth-check.sh disarm` to remove the check and its local report record.

The check evaluates at most once per day and stays silent when nothing meaningful changed.
Those tracked bytes are code and instruction-surface size, not prompt-memory cost.
The check does not run session-start, bootstrap, network checks, model calls, repository refreshes, `/stow`, or full preference/learnings rereads.

Growth is measured against a per-file baseline retained in the check's own state record, so accumulation that stays under one day's threshold is still caught once it adds up; reporting a file rebases its baseline to the reported size, so accepted growth then stays silent.
A surface observed for the first time is baselined silently, including the first content of an optional file that did not exist yet when the check was armed, and an established baseline survives that file disappearing and coming back.
The fixed growth thresholds are inspectable in the script header: 2048 bytes for tracked startup/instruction files and 250 estimated tokens for the printed startup-memory files.
Budget overrun, unsafe or unreadable inputs, missing required tracked owner files, or material growth are reported once and deduplicated until the finding changes or clears; the report line is delivered before the check advances its own record, so a state-publication failure can repeat a finding but never swallow one.
That one line goes out through the shared per-line digest cut, so an over-long finding set carries the repo's `[truncated]` marker instead of ending mid-finding, while deduplication keeps comparing the full uncapped set.
Older bulk learning files remain reference-only; this monitor neither loads nor merges them.
A reported review need is only a recommendation, not cleanup authority.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.

With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.

The flag is per home, because stow cadence is a property of the home doing the stowing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.

The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Self-update source (config/self-update-source)

The optional local, gitignored `config/self-update-source` changes where `/updatefirstmate` takes the running firstmate from, and nothing else.
It suits a home that runs its own fixes before upstream merges them, by following a branch that holds upstream's default branch plus those fixes, for example a `carry` branch on a fork.
It holds one line, `<remote> <branch>`, for example `fork carry`, naming a remote that already exists in this repository and a branch on that remote.
When the file is absent, `/updatefirstmate` fast-forwards from `origin` exactly as before.

When it is present, [`bin/fm-update.sh`](../bin/fm-update.sh) fetches only that branch and fast-forwards the primary to it under the same guards as the origin path: a dirty, off-default, or diverged primary is skipped and left untouched, so the named branch must only ever move forward.
A remote secondmate's host runs its own update against its own code root, so a remote home follows the named branch only when that code root has the same file; otherwise it keeps following its own origin.
Worker spawns, review diffs, the cleanup landed-work test, lint, and default-branch detection keep using `origin`, so work started in this home still branches from, and is judged against, upstream.
An unreadable or malformed file, an unknown remote, or an invalid branch name stops the whole update before anything moves and names the file; it never falls back to `origin`.
The file is per home.
To stop following the branch, remove the file; a primary already ahead of `origin` is then reported as diverged until it is brought back by hand.
The script's header owns the exact parsing and the per-home outcome lines.

## Execution home routes

Execution home routes live in `data/remote-homes.md`.
Each route names an SSH alias, the remote code root and home, the Herdr session, and the projects to clone.
Omit the session to use `fm-remote`.

Seed a route with `bin/fm-remote-home-seed.sh --exec`.
The command checks the host with the remote doctor, clones the requested projects, and records the Herdr session in `config/herdr-session`.
It writes `.fm-exec-home` and sets `config/backlog-backend` to `manual`.

`bin/fm-on.sh` reads the route registry.
Add `host=<route>` to a project record to run its workers there.
[Remote workers](remote-workers.md) covers setup, steering, and cleanup.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and omp are empirically verified for crewmate and secondmate launches; gemini is verified for crewmate and scout launches only, and [README requirements](../README.md#requirements) own the set supported for the primary session.

### Harness restrictions and credentials

`fm-spawn.sh` refuses kimi on cmux and Orca at preflight, because answering Kimi's folder-trust dialog needs a verified viewport-only capture those backends lack; [its adapter reference](../.agents/skills/harness-adapters/references/harness/kimi.md#readiness-gated-start) owns the trust-dialog handling.
It also never answers a Kimi folder prompt that announces project MCP servers, pages what trusting would activate, or is collapsed for a short terminal, so no project MCP server starts without a consent decision that covers it; the launch fails with that reason, and the same adapter reference owns the exact rules.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](supervision-protocols/cursor.md) owns its supervision protocol.

Cursor typed-submit confirmation is verified on tmux and Herdr only.
On Zellij, cmux, Orca, Paseo, and tern a typed-plane Cursor send (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.

muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.

gemini is likewise refused for secondmates because it has no primary supervision protocol; [its adapter reference](../.agents/skills/harness-adapters/references/harness/gemini.md) owns the credential precondition, canonical-launch wiring, and raw-launch limitations.
rovo is likewise verified for crewmate and scout launches ONLY, refused for a secondmate for the same reason - no turn-end hook and no primary supervision protocol; [`docs/verification/rovo.md`](verification/rovo.md) owns that evidence, including the OAuth token's silent background refresh from a stored refresh token and both tmux and herdr pane liveness (herdr placement is verified live, with a Herdr-side agent-detection gap left open for recovery classification).

kiro (Kiro CLI, V2 engine only) is likewise verified for crewmate and scout launches ONLY, refused for a secondmate because it has no primary supervision protocol; it is claude-shaped, so its per-task turn-end and busy hooks live in a firstmate-owned agent config the spawn writes under `state/<id>.kiro-home` and reaches by relocating `KIRO_HOME` (never the worktree's own `.kiro/`), with the `--trust-all-tools` modal suppressed by a seeded `chat.disableTrustAllConfirmation` setting; [`docs/verification/kiro.md`](verification/kiro.md) owns that evidence, and the v3/KAS engine is out of scope and unsupported on Amazon Linux 2.
A kiro hook command must be one unquoted token, so a kiro spawn refuses before launch when that per-task home path contains whitespace or a shell-special character (such as a quote or `$`) and asks for an `FM_HOME` or `FM_STATE_OVERRIDE` free of them.

devin is verified for crewmate and scout launches only; a secondmate is refused because Devin has no verified primary supervision protocol.

Its private worker config disables Claude Code imports (including the captain's hooks) and, unless the home sets `config/keep-ai-trailers` (see "Commit attribution"), Devin commit attribution without editing user or project config; [`fm-devin-config.sh`](../bin/fm-devin-config.sh) owns these enforced settings and [Devin verification](verification/devin.md) owns the live evidence and observed model availability.

cortex (Snowflake's Cortex Code) is likewise verified for crewmate and scout launches only; a secondmate is refused because Cortex has no verified primary supervision protocol.
It runs only on the tmux and Herdr backends; a zellij, cmux, orca, paseo, rex, or t3code launch is refused because those backends supply no Cortex pane identity to prove its titled composer empty.
Its busy-state and turn-end hooks reach the worker through a private per-task plugin directory passed with `--plugin-dir`, so no user or project Cortex or Claude config is edited; [`fm-cortex-plugin.sh`](../bin/fm-cortex-plugin.sh) owns it and teardown removes it.
The launch clears `CLAUDECODE` so Herdr's Claude integration hook cannot claim the pane, and it uses `--dangerously-allow-all-tool-calls`, which also skips the project trust dialog without recording the project in Cortex's trust file.
Cortex loads Claude-compatible hook files with no switch to disable the import, so a worker in a project with Claude hooks runs them.
[Cortex verification](verification/cortex.md) owns the live evidence, the Herdr pane-claim behavior, and the unverified items.
commandcode (Command Code) is verified for crewmate and scout launches only; a secondmate is refused because Command Code has no verified primary supervision protocol.
It runs only on the tmux and Herdr backends; a zellij, cmux, orca, paseo, or tern launch is refused because those backends supply no Command Code pane identity, without which its idle composer placeholder never reads empty and steering stalls, and a rex launch is refused until Command Code is live-verified there.
Its busy-state wiring is a tracked mod loaded per process with `--mod`, so no user or project Command Code settings are edited; [its adapter reference](../.agents/skills/harness-adapters/references/harness/commandcode.md) owns the launch facts and [Command Code verification](verification/commandcode.md) owns the live evidence.

Hermes Agent is verified for crewmate and scout TUI launches on tmux only; primary and secondmate use and other backends are refused.
Its native profile selects the model and reasoning, and the profile's own gateway may run only if it is idle at dispatch.
The [Hermes adapter reference](../.agents/skills/harness-adapters/references/harness/hermes.md) owns operating limits, [`fm-spawn.sh`](../bin/fm-spawn.sh)'s header owns the per-spawn profile flag, and [Hermes verification](verification/hermes.md) owns live evidence.

Polytoken is verified for crewmate and scout launches only; [its adapter reference](../.agents/skills/harness-adapters/references/harness/polytoken.md) owns the operating contract and [verification record](verification/polytoken.md) owns the live evidence.
It has no primary or secondmate supervision protocol.
The launch generates a private per-task config directory that mirrors the operator's provider/model configuration and enforces unattended permissions without modifying global configuration.
The first-start license dialog requires an operator decision and is never accepted automatically.

cloud-claude runs a direct-PR ship task on a GitHub-hosted project in a Claude Code cloud session, and is refused for every other task kind and delivery mode.
[Cloud Claude worker](#cloud-claude-worker) owns its settings, and [its adapter reference](../.agents/skills/harness-adapters/references/harness/cloud-claude.md) owns the operating contract.

### Verification and primary supervision

New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in the skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).

The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
A Claude worker's launch brief is published as an operational record in the receiving home's state and delivered as a printable doorbell; if publication fails, the spawn reports the failure and launches nothing rather than sending a marker that Claude Code would strip.
Other harnesses retain the typed operational-marker launch path.

Pi-family launches run Pi's default fullscreen TUI and add optional flags only where the installed CLI advertises them.
[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).

Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).

Claude uses [hook-owned tokenless re-arm cycles](watcher-continuity.md#claude-stop-hook), Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints unless the home opts in to its [native Stop park](#codex-native-stop-park-configcodex-stop-park), Pi and pi-signed use the same two tracked primary extensions, omp uses its own two tracked `.omp/extensions/` files with a blocking `session_stop` turn-end hook, and OpenCode uses its TUI plugin.

### Choose the worker harness

`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.

Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.

### Per-launch overrides and inherited defaults

An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit harness also bypasses reading the pin file during spawn or control-plane relaunch, so malformed unused pin configuration cannot block that override. A relaunch supplying explicit `--harness`, `--model`, and `--effort` therefore does not read this configuration.

Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
Such a spawn also refuses until `bin/fm-dispatch-resolve.sh data/<id>/brief.md` has written that task's record, `data/<id>/dispatch-resolution.json`.
Both paths are under `FM_DATA_OVERRIDE` instead of `data/` when it is set.
When the record is `clear`, the spawn must match its harness, and its model and effort where the record sets them, with no raw launch command, unless `--dispatch-override <reason>` records a task override in `state/<id>.meta` as `dispatch_override=<reason>`.
A model or effort the record leaves empty is not bound, so the documented effort fallback still applies.
When the record is `ambiguous`, `escalate`, `error`, or `off`, the explicit flags from the manual intake are enough.
An `fm-spawn.sh --relaunch` skips this check.

Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.


### Installed hooks and launch details

For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.

Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.

Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
Pi-family secondmates can start unattended in Firstmate-seeded homes without accepting project trust manually.
[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the capability requirement, session-only approval scope, and older-version fallback, with [regression evidence](verification/runtime-backends.md#pi-project-trust).

For omp secondmate launches, `fm-spawn.sh` names only the parent home's `state/<id>.omp-ext.ts` busy extension with `-e`: omp auto-discovers the home's tracked `.omp/extensions/` with no trust gate, and naming a discovered file with `-e` as well loads it twice; every omp launch also carries the tracked `.omp/fm-worker-overlay.yml` posture overlay through `--config`, which [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns.

For a Claude secondmate, `fm-spawn.sh` writes the busy hooks into the parent home's `state/<id>.claude-settings.json` and passes that file as Claude Code's one `--settings` value.
The same file carries `feedbackDrafts` and, unless `config/keep-ai-trailers` is present, the attribution policy every other Claude launch puts in its inline `--settings` JSON.
Claude Code applies `--settings` for that session and does not write the file into the mate home.
A key the file sets overrides the same key in user, project, and local settings.
A key it omits keeps the file-based value, so a `.claude/settings.local.json` already in the home is left untouched.
Hook entries merge across settings files rather than replacing each other, so the home's tracked Stop guard still runs beside these hooks.
The CLI reference documents the one file-or-JSON flag, the settings page documents session precedence, and the hooks page documents the hooks merge: <https://code.claude.com/docs/en/cli-reference>, <https://code.claude.com/docs/en/settings>, <https://code.claude.com/docs/en/hooks>.
[`fm-spawn.sh`](../bin/fm-spawn.sh) owns the file and the flag.

### Codex automatic approval review

Codex crewmate, scout, and secondmate launches default to `--dangerously-bypass-approvals-and-sandbox`.
The local, gitignored `config/codex-approval-mode` accepts one whitespace-trimmed token.
Absent or `bypass` retains that default.
`approve-for-me` selects `--approve-for-me`.
The fallback uses a model reviewer in the workspace-write sandbox, which starts with network access disabled and reviews writes outside the working directory.
It remedies a managed policy that leaves bypass launches with user-reviewed approvals even when its sandbox bypass applies.
Firstmate targets current CLIs rather than detecting versions or emulating older approval flags.
Crew and scout launches still request hook disablement and retain their notification wiring, while secondmates retain their primary-session hooks.
A managed policy can override the requested hook disablement, so it may still require an operator's hook review.
See the [current verification and limits](verification/runtime-backends.md#codex-automatic-approval-review) for observed task-channel and network access.

## Worker sandbox

The optional local, gitignored `config/agent-sandbox` file runs pi scouts and pi no-mistakes ships inside a nono program sandbox on the Mac.
An absent file leaves every launch exactly as it was, so homes that never opt in are unaffected.
The file holds one line with the pinned nono version, such as `0.80.0`.
A home with the file set refuses the spawn when nono is missing or its version differs from the pin, instead of launching unsandboxed.
`fm-spawn.sh` renders a per-task profile at `state/<id>.nono.json` and launches the worker through it with its own pi directory, its own temp directory, a domain allow list, and the model key held outside the sandbox.
A no-mistakes ship additionally receives the daemon data directory and read-write git directories, so its pipeline client can reach the gate.
That grant reaches state the daemon mediates for other tasks, so a ship is isolated from secrets and captain files but not from all other task state.
A claude-bridge worker receives a dedicated token route instead of the proxy key: the setup token stays outside the sandbox, a supervisor-side capture hands it to the nono proxy, and the worker sees only a phantom placeholder in `ANTHROPIC_AUTH_TOKEN` with its config redirected to a task-owned directory.
The opencode-go and claude-bridge providers are routed through the sandbox today.
A claude-bridge worker without a passing setup token, and a worker on any other provider, launches unsandboxed with a warning.
The setup token for sandboxed Claude workers lives at `config/agent-sandbox-claude-token` with owner-only permissions once the captain creates it with `claude setup-token`.
Secondmates, direct-PR workers, and local-only workers stay unsandboxed.
After a sandboxed launch lands, `fm-spawn.sh` stops nono per-session debug system-log stream through `bin/fm-sandbox-quiet.sh` on tmux and herdr panes.
Enforcement stays in the kernel profile, but the post-run denial footer can no longer attribute denials and falls back to its no-denials text.
Mechanics live in `bin/fm-agent-sandbox.sh` and its `--help` output.

## Claude permission mode (config/claude-permission-mode)

The optional local, gitignored `config/claude-permission-mode` selects the permission flag for Firstmate-built Claude command lines: crewmates, scouts, Claude secondmates, and control-plane relaunches.

### Accepted values and refusals

The token is the file's whitespace-trimmed content.

| Token | Launch permission flag |
| --- | --- |
| `auto` | `--permission-mode auto` |
| `bypass` | `claude --dangerously-skip-permissions` |

An absent file defaults to bypass, preserving `--dangerously-skip-permissions` for unconfigured homes.
Auto uses a model reviewer and avoids managed policies that block bypass-permission sessions.
It is selected by an explicit setting or the firstmate-invoked failover below.
Only the permission flag changes between the two modes.
The environment prefix, session settings, model, effort flags, and the task-channel `--add-dir` grant below stay the same in both.

Every Firstmate-built Claude command line, in both modes, also passes `--add-dir` for exactly this task's Firstmate channel directories, resolved to real paths: a secondmate gets the parent home's `state/<id>.inbox` it reads its steers from; a ship or scout worker gets this home's `state/operational-inbox` (its launch record), `state/<id>.inbox` (its steers), `data/<id>` (its brief and report), and the code root's `.agents/skills`.
The grant exists because Claude Code path-checks the Read/Glob/Grep file tools against cwd plus `--add-dir`, and since 2.1.257 the first outside read in `auto` mode parks the pane on a one-time interactive question, while a "Block" answer there writes `permissions.blockReadsOutsideWorkingDirectories` into user settings and then refuses the same reads under bypass too.
It never covers the whole `state/` or anything wider.

Any other value or an unreadable file refuses every spawn from that home, whichever harness it would launch.
This happens before any endpoint, worktree, or task record exists.
The diagnostic names the accepted values; Firstmate never falls back to a permission posture the captain did not choose.

### When changes apply and inheritance

`bin/fm-spawn.sh` reads the file on every spawn and relaunch, so a change takes effect at the next launch without a restart.

The [Claude adapter reference](../.agents/skills/harness-adapters/references/harness/claude.md) records the permission-mode observations and the distinct startup dialogs.

## Codex permission mode (config/codex-permission-mode)

The optional local, gitignored `config/codex-permission-mode` selects the permission flags for Codex crewmates, scouts, secondmates, and relaunches started by this home.

| File content | Launch permission flags |
| --- | --- |
| Absent or `bypass` | The [Codex approval mode](#codex-automatic-approval-review) flag, `--dangerously-bypass-approvals-and-sandbox` by default |
| `restricted` | `--sandbox workspace-write --ask-for-approval on-request` |

Create the file containing exactly one of the two tokens, optionally followed by a newline.
An absent file preserves the existing launch command.
Restricted mode changes only the permission flags; model, effort, and hook wiring stay the same.
It replaces whichever flag `config/codex-approval-mode` selects, and the task record reports `restricted`, so managed approval failover never treats the launch as bypass.
It grants no additional writable directories, including the shared Firstmate state directory.
Writes outside the worker's worktree, including status reports and steering-inbox acknowledgements, remain subject to operator approval.
Codex `--sandbox workspace-write` also disables network access and does not permit writes to shared Git metadata by default, so `git commit`, `git push`, `gh`, and no-mistakes pipeline steps from a restricted worker likewise stop at an approval prompt.
Choose restricted mode only when that approval workflow is available.

`bin/fm-spawn.sh` reads and validates the setting before any spawn or relaunch mutation, regardless of the selected harness.
Any other content, an unreadable or non-regular file, or a dangling symlink refuses the launch instead of falling back to bypass.
Changes take effect at the next launch without a restart.

## Persistent managed-policy failover

After firstmate observes a Codex command-approval prompt under its bypass flag or a Claude managed-policy refusal of a bypass session, it asks the captain for explicit approval to save a lasting worker permission setting and relaunch the worker.
Only after that approval does firstmate invoke `bin/fm-approval-failover.sh`; the script's header and help own the command and recovery mechanics.
There is no automatic detection, polling, startup window, or approval-prompt answering.
The command saves Codex's `approve-for-me` or Claude's `auto` in the owning home's absent mode file, so later launches use the model-reviewed remedy without retrying bypass.
Existing explicit settings are never overwritten, including invalid or empty files, directories and dangling symlinks; a concurrent setting wins too.
Recovery uses the existing [lifecycle control plane](agent-control.md), respecting its leases and supported-runtime limits; incomplete recovery is reported with the saved setting and work preserved.
Generic login failures do not establish a defeated bypass, and managed hook review remains a separate operator decision.
Neither fallback is unrestricted execution, and Firstmate does not change vendor or security-agent settings.

## Worker tool exclusions (config/crew-exclude-tools)

The optional local, gitignored `config/crew-exclude-tools` hides named tools from this home's ship and scout workers, for example to keep an MCP server's write tools out of reach while its read tools stay available.
The contract is runtime-neutral: a runtime must support hiding the listed tool names or refuse the launch, and a non-empty list is never silently ignored.
With no file, or a file with no entries, every launch on every runtime is unchanged.

Create the file with one tool name per line, such as `mcp__<server>__<tool>` for an MCP tool.
Blank lines and lines beginning with `#` are allowed, and surrounding whitespace on a line is trimmed; a trailing comment on an entry line is not allowed.
The file is read from this home's own configuration directory on every launch, so a change reaches the next worker or relaunch without a restart.

### Runtime support

| Runtime | With a non-empty list |
| --- | --- |
| `pi`, `pi-signed` | Hides listed tool names, MCP tools included, on every ship and scout spawn and relaunch. |
| Every other runtime, and a raw launch command | The launch refuses with an error naming `config/crew-exclude-tools`, because that runtime has no verified way to hide tools. |

A relaunch validates the list and the replacement runtime's support before stopping the running worker, so an exclusion-list refusal preserves the running agent.

### Validation

An entry may use only `A-Z`, `a-z`, `0-9`, `_`, `.`, and `-`.
An entry with any other character, including internal whitespace, a comma, or a `*`, refuses the launch and names the offending entry.
An unreadable or nonregular file, or a path inspection error, also refuses and names the configuration file.
For a new worker, these checks run before its endpoint, local copy, or task record is created; Firstmate never launches with a partial list.
Only exact tool names are accepted, not wildcard patterns.
Firstmate checks syntax and runtime support before launch but never runs `pi mcp list` or otherwise connects to servers to validate names.
When its first agent run starts, after Pi's startup tool-loading boundary, the worker extension compares the launch's exclusion list with its own loaded-tool registry and appends a timestamped warning note to `state/<task-id>.status` naming the configuration file and every unmatched entry for the supervisor.
The check runs before worker actions so it cannot supersede a terminal status emitted during the turn.
An unmatched entry is reported as **unverified**, not valid: Pi versions that omit excluded tools from the registry cannot distinguish a correct exclusion from a typo, and a server that has not connected cannot verify its tools either.
Names present in the registry produce no report; unknown or unverified names do not refuse the launch.
Each relaunch installs a fresh worker extension with the home's current list, so the replacement performs the same check.

[`bin/fm-exclude-tools-lib.sh`](../bin/fm-exclude-tools-lib.sh) implements parsing and pre-launch validation for this contract; [`bin/fm-spawn.sh`](../bin/fm-spawn.sh)'s header owns the launch-flag mechanics.

## Worker account pin (config/claude-account, config/pi-account)

A home that mixes accounts for one runner, such as a work login and a personal one, can pin the account its own Claude and Pi workers launch on.
The pin is opt-in: without a home-wide or per-secondmate pin, pane-backed Claude launches keep receiving firstmate's own `CLAUDE_CONFIG_DIR` when it is set.
Unpinned Pi launches use the destination pane's ambient account.

Both files are local and gitignored.

| Runner | File | Variable the launch receives | `ordinary` means |
| --- | --- | --- | --- |
| `claude` | `config/claude-account` | `CLAUDE_CONFIG_DIR` | the variable unset, so Claude uses its default login |
| `pi`, `pi-signed` | `config/pi-account` | `PI_CODING_AGENT_DIR` | `~/.pi/agent` |

### File format and provider selection

`config/claude-account` holds one line: `ordinary`, or the absolute path of an existing Claude config directory.
`config/pi-account` holds that same root on line 1 and, on line 2, the providers this home may spend, separated by spaces, for example `openai-codex anthropic`.

A final newline is optional; any other line, a relative path, or a control character such as a CR refuses.
For Claude, `ordinary` unsets `CLAUDE_CONFIG_DIR` rather than pointing it at `~/.claude`, because Claude reads `$CLAUDE_CONFIG_DIR/.claude.json` and keys its macOS Keychain entry to any directory that is set ([authentication, "Credential management"](https://code.claude.com/docs/en/authentication#credential-management)).

A Pi root can hold several provider logins at once, so the root alone does not say which account a launch spends.
A pinned Pi launch therefore needs `--model <provider>/<id>` naming a declared provider, and Firstmate also passes `--provider <that provider>` so Pi cannot resolve the model under another signed-in provider.

An unqualified model, an undeclared provider, or a raw Pi launch command, which cannot receive that flag, refuses; Firstmate never guesses a provider.

### Launch scope and sign-in checks

A raw Claude launch command refuses if its leading assignments set `CLAUDE_CONFIG_DIR` or a credential that a pinned launch unsets, such as `ANTHROPIC_API_KEY`.
The assignment would override the pin.
The refusal names the variable; remove that assignment from the raw command, or change or remove `config/claude-account`.

Before any worker endpoint, local copy, or task record exists, and before a relaunch stops the running worker, Firstmate asks the runner itself whether the pinned account is signed in: `claude auth status` for Claude, and `pi auth check --provider <provider> --json --no-refresh` for Pi, falling back to `pi --list-models <provider>` for a provider an extension registers.
The check runs with only `HOME`, `PATH`, `TMPDIR`, `USER`, `LOGNAME`, and the pinned root in its environment, so a credential variable in firstmate's own environment cannot answer for an empty root.

A pinned Claude launch also unsets the environment credentials Claude ranks above a stored login, such as `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, and the Bedrock and Vertex switches ([authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence)).
Pi ranks a root's stored logins above environment variables, so a pinned Pi launch unsets nothing.

A home that authenticates Claude through environment credentials on purpose should leave the pin absent.

### Failures, reporting, and inheritance

A malformed file, a root that is not a readable directory, or a signed-out account refuses the launch and names the file to fix; Firstmate never falls back to the ambient account and never changes a global login or copies a credential.
The spawn prints the pin as `account=` (plus `account_provider=` for Pi) and records the same fields in the task record, so the session-start digest shows which account each worker launched on.

[`bin/fm-worker-account-lib.sh`](../bin/fm-worker-account-lib.sh) owns parsing, the sign-in check, and the full list of credentials a Claude launch unsets; [runtime backend verification](verification/runtime-backends.md#worker-account-pin-sign-in-check) records the check against the real runners.

## Claude accounts (config/claude-accounts)

A home with several Claude subscriptions managed by the `clauth` account manager can list each account as its own candidate in a dispatch profile array, so the array spends one account before another.
A profile names its account with `claude_account`, the clauth profile name, such as `main` for a Max plan and `second` for a Pro plan.
A profile without `claude_account` resolves and launches on the worker's ambient Claude login, except on a Pi `claude-bridge/` model, which needs an account once the map below declares one, as [launch checks](#launch-checks-records-and-inheritance) describe.

### Map each account to a login

`config/claude-accounts` is local and gitignored, and maps each account to the login its workers launch on, one account per line:

```text
# clauth profile  login
main    ordinary
second  /Users/me/.claude-accounts/second
```

- `ordinary` is the machine's default Claude login, launched with `CLAUDE_CONFIG_DIR` unset.
  It counts as that account only while `clauth status --json` reports the profile active, so a candidate or launch refuses when clauth reports another profile or cannot answer.
- An absolute path is a Claude config directory signed in to that account.
  Create it once with `CLAUDE_CONFIG_DIR=<path> claude`, then `/login` as that account.
- Blank lines and `#` comment lines are ignored.
  A duplicate account, a relative path, or a control character is a configuration error that names the line.

A mapped directory holds its own login rather than clauth's stored token.
Claude Code refreshes and rotates its token, and on macOS keys its Keychain entry to the config directory, so a worker sharing clauth's token would sign clauth and its sessions out.
Firstmate only reads clauth and never runs `clauth switch`, which would move the machine's login under every running session.

### Runners an account reaches

| Runner | What the launch receives |
| --- | --- |
| `claude` | `CLAUDE_CONFIG_DIR` set to the mapped directory, or unset for `ordinary`, replacing `config/claude-account` for that launch |
| `pi`, `pi-signed` with a `claude-bridge/<id>` model | The same `CLAUDE_CONFIG_DIR`, which the bridge passes to the Claude SDK; Pi's own root and any `config/pi-account` pin are unchanged |

Both shed the environment credentials Claude ranks above a stored login, as a [worker account pin](#worker-account-pin-configclaude-account-configpi-account) does.
Any other harness, a Pi model on another provider, or a raw launch command refuses `claude_account`.
A Claude worker on a mapped directory reads that directory's settings, memory, and skills instead of `~/.claude`.

### How resolution reads an account

[Typed dispatch resolution](#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model) takes one `clauth status --json` snapshot when any profile names an account, and reads the account's own windows instead of quota-axi's `claude` row, which measures only the active login.

- `all_models` remaining is 100 minus the larger of the 5-hour and 7-day utilization, and a per-model weekly window such as `7d fable` adds `model:fable`.
- A profile `floor`, such as `{ "scope": "all_models", "min_percent": 30 }`, makes the account ineligible below 30% remaining, and 0% remaining is exhausted.
  clauth reports no reset time, so an account floor never skips near a reset.
- An account is ineligible, with the reason on its candidate line, when clauth is missing or fails, has no such profile, reports its sign-in or usage reading as failed, or reports the reading stale; when `config/claude-accounts` does not map it; or when an `ordinary` account is not the active profile.
  An unverifiable account is never treated as available.
- clauth projects no `spendPriority`, so under `spendPriority` ranking an account candidate stays eligible but unranked; order accounts with `"array_order": "preference"`.
- A chosen account rides on the profile line as `--claude-account <name>`.

### Launch checks, records, and inheritance

`fm-spawn.sh --claude-account <name>` refuses before any worker endpoint, local copy, or task record exists unless the map declares the account, an `ordinary` account is the active clauth profile, and `claude auth status` says its login is signed in.
That check runs with the same cleared environment as the worker account pin check.
The spawn prints and records `claude_account=<name>`.
A ship or scout for a project placed on an [execution home](remote-workers.md) runs that check on the host, against the host's own `config/claude-accounts`, and refuses before this home records the task when the host does not map the account or runs code too old to apply it.
Once the map declares an account, a ship or scout spawn or relaunch on a Pi `claude-bridge/<id>` model that names no account refuses before any of those exist, or before the running worker stops, and names `--claude-account` and the declared accounts.
Without an account the bridge would run on the terminal's ambient Claude login, which clauth folder attach signs out, so the worker would stop at its first turn.
A relaunch that keeps the same harness and model, or lands on a Pi `claude-bridge/<id>` model, keeps the account under the same check before the running worker stops, and a relaunch onto another profile drops it.
`fm-control.sh <id> relaunch --claude-account <name>` sets or replaces the account for the replacement.

A secondmate whose inherited dispatch file names accounts treats them as ineligible until its own home maps them.

[`bin/fm-worker-account-lib.sh`](../bin/fm-worker-account-lib.sh) owns the map and the launch check, and [`bin/fm-clauth-lib.sh`](../bin/fm-clauth-lib.sh) owns how a clauth reading becomes a quota row.

## Lavish server address (config/lavish-axi-host)

The optional local, gitignored `config/lavish-axi-host` contains one non-empty address without whitespace for the per-machine Lavish server.

Once a board exists, the process-event adapter derives the polling address from that board's own saved Lavish session instead; its header owns the lookup contract.
When the file is absent, worker launches do not add a board address and retain the existing ambient-environment behavior.
Scout briefs carry the board address that reaches a board served on the worker's own machine: the configured server address, or loopback when no address is configured, on the ambient `LAVISH_AXI_PORT` or the server's own `4387` default.

Malformed or unreadable values refuse the launch before the worker starts.
The address selects the existing shared server; it does not authorize starting or stopping the server, and the Lavish startup crash remains a vendor-tool concern.

## Home brief include (config/brief-include.md)

The optional local, gitignored `config/brief-include.md` adds standing worker instructions to every ship and scout brief.
This keeps private brief content out of tracked files.
When the file exists, `bin/fm-brief.sh` appends its text verbatim as the scaffold's last section, `# Home brief additions`, which defers to every other section of the brief, including the ship contract a later scout promotion appends below it.

An absent or blank file changes nothing, while a present path that is not a readable regular file, or text carrying its own `Delivery contract: mode=` line, stops the scaffold before anything is written.
The text is static and never executed or expanded; secondmate charters never take it, and the file is local to each home rather than part of secondmate inherited configuration.

`bin/fm-brief.sh`'s header owns the placement rule and its safety argument.

## Home branch prompt include (config/branch-prompt-include.md)

The optional local, gitignored `config/branch-prompt-include.md` adds standing home rules to the supervision branch's system prompt, the way `config/brief-include.md` extends worker briefs.
The branch's headless engine loads none of the home's own hooks, `CLAUDE.md`, skills, or plugins, so this file is how a home gives the branch a home-specific rule.
When the file exists, `bin/fm-branch-prompt.sh` appends its text verbatim as the prompt's last section, `# Home prompt additions`, which defers to every other section of the prompt.

An absent or blank file leaves the prompt byte-identical, while a present path that is not a readable regular file stops the generator before it emits anything, so the branch does not start.
The text is static and never executed or expanded, and an edit takes effect when the branch next builds its prompt for a new conversation.

`bin/fm-branch-prompt.sh`'s header owns the placement rule and how it keeps the prompt cache stable.

## Herdr lifecycle spawn guard (config/herdr-lifecycle-spawn-guard)

The optional local, gitignored `config/herdr-lifecycle-spawn-guard` presence flag opts this home into refusing, at spawn, a ship or scout brief that drives Herdr lifecycle without the Herdr isolation contract.
Create it with `touch "$FM_HOME/config/herdr-lifecycle-spawn-guard"`; remove it to launch such briefs again.
It is off by default: without the flag, `bin/fm-spawn.sh` launches the brief as before, and only the unguarded scaffold's own `# Herdr lifecycle declaration - NOT ENABLED` gate text asks the author to regenerate it.
With the flag present, a brief that names `bin/fm-herdr-lab.sh`, or a `herdr session` or `herdr server` command with the verb `start`, `stop`, `delete`, `restart`, `reload-config`, or `live-handoff`, must carry the `# Herdr isolation - HARD SAFETY CONTRACT` section that `bin/fm-brief.sh --herdr-lab` emits.
The refusal names the first matching command, so the author can tell a brief that truly drives Herdr lifecycle from one that only quotes a verb incidentally, and points at `bin/fm-brief.sh --herdr-lab` as the remedy.
A refused spawn writes no task record, so the brief can be regenerated and the spawn repeated.
[`herdr-backend.md`](herdr-backend.md) owns the lab isolation contract itself; `bin/fm-spawn.sh`'s header owns the exact matching rule.

## Cloud Claude worker

`--harness cloud-claude` runs a ship task in a Claude Code cloud session billed to a chosen Claude account, while this machine keeps only a relay pane and the task's local copy.
The spawn refuses it unless the task is a ship with `--mode direct-PR`, the project's origin is on github.com, and no `--model` or `--effort` is passed.
It also needs `claude`, `gh`, and `script` on PATH, and the Claude GitHub App must reach the repository.

| File | Contents | When absent |
| --- | --- | --- |
| `config/cloud-claude-account` | One [Claude accounts](#claude-accounts-configclaude-accounts) profile name, the login whose cloud credit pays for the sessions | The spawn refuses unless it passes `--claude-account <profile>` |
| `config/cloud-claude-deadline` | Whole minutes a session may run before it is reported stuck | 90 minutes |

The account is never inferred, so a home that leaves the file absent cannot spend its default login's cloud usage by accident.
A spawn's `--claude-account` overrides the file for that task only.
A cloud-claude spawn skips the Mac and Linux load gates, the heavy-worker cap, the core budget, and the [browser-suite](#browser-suites) stagger, because its session runs on Anthropic's hosts, and it holds no heavy worker place, so local starts do not count it.
[Project capacity](#project-capacity-configproject-capacity) still applies to it.
The relay reports a ready pull request on the task branch as the task's result, and a missing one past the deadline as a blocker that links the session.
Each forwarded steer restarts the deadline.
Firstmate reads no Anthropic session API and no stored login token, so a session that waits on a question or fails is seen only at the deadline.
Interrupt, exit, and relaunch through `bin/fm-control.sh` are refused, and cleanup leaves the cloud session in the account's session list.
[The adapter reference](../.agents/skills/harness-adapters/references/harness/cloud-claude.md) owns the operating details and [the design record](adr/0011-cloud-claude-relay.md) owns the rationale.

## Worker launch environment (config/launch-env-allowlist)

The optional local, gitignored `config/launch-env-allowlist` limits the ambient environment passed to newly launched workers, scouts, and secondmates, including relaunches.
With no file, ambient inheritance remains unfiltered: selected harness markers are cleared, while the provider, long-lived terminal daemon, and shell initialization determine which other variables reach the worker.

Do not assume every worker inherits the invoking Firstmate process's current environment.

Changes apply to subsequent launches; existing processes keep their environment.

### Allowlist format

Create the file with one environment variable **name** per line, never credential values, assignments, wildcards, or shell commands.
Blank lines and lines beginning with `#` are allowed.

Invalid names, an unreadable or nonregular file, or a path inspection error (including an inaccessible configuration directory) stop the launch.
An empty file enables filtering with only Firstmate's operational floor.

For example, a provider using `OPENAI_API_KEY` and Git using an SSH agent could use:

```text
# Provider credential already available in the destination pane
OPENAI_API_KEY
# Git over SSH using an existing agent
SSH_AUTH_SOCK
```

### Variables retained and where values come from

Firstmate retains basic home, executable search, terminal, locale, temporary-directory, and backend routing variables, plus its explicit launch assignments, its ship and scout task marker, the compact-adviser kill switch described below, and enabled task trace.
[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact retained names and parsing mechanics.

Other ambient names must be listed explicitly, including custom credential-store locations, proxy settings, and certificate overrides when required by the selected tools.
The command shell and worker may still create their own variables.

Allowed values come from the destination pane at execution time; they are neither copied from the invoking Firstmate process nor written into the launch command.
Listing a name does not provision it in a daemon's environment or transfer credentials to another machine.

Project and harness sandbox settings still own filesystem access to personal credential stores.

### Authentication requirements

Choose the minimum additions for the authentication method actually in use:

| Provider or Git transport | Additional names needed |
| --- | --- |
| Provider login stored under the normal home directory | None for the environment contract; the same user still has access to that provider's stored login. |
| Provider configured through environment variables | The exact credential and endpoint names required by that provider, for example `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`; a multi-provider tool needs each provider it will actually use. |
| Custom provider store | Its configured location variables, such as `CODEX_HOME`, `GROK_HOME`, or `XDG_CONFIG_HOME`; Firstmate's existing explicit Claude and Muse store assignments still apply. |
| Muse environment authentication | `META_API_KEY`, already present in the target tmux session environment; Firstmate's preflight requires the stored-login path on other backends. |
| Git over SSH with an agent | `SSH_AUTH_SOCK`; add `GIT_SSH_COMMAND` only if the chosen transport requires that override. |
| Git over SSH with a key file | No credential variable when normal SSH configuration selects the key; file permissions and any passphrase handling still apply. |
| Git over HTTPS with a credential helper | Whatever the configured helper requires; a GitHub CLI helper using an environment token needs its selected `GH_TOKEN` or `GITHUB_TOKEN`. |

### Validation and security limits

Verify the selected provider login and Git transport after opting in; Firstmate does not infer credentials from model names or install a secret manager.
Raw launch commands run under noninteractive POSIX `sh` with this option and must use compatible syntax.

The filter runs at the worker command boundary, after the terminal daemon and pane shell have started; it does not scrub either of those processes.
This is not a sandbox: it cannot revoke same-user access to credential files, prevent tools or later shells from loading credentials again, or isolate processes from the same user's other processes.

Regression coverage executes emitted launch commands with synthetic nonsecret values in [`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh).

### Compact adviser setting

Every crewmate, scout, and secondmate Firstmate launches starts with `COMPACT_ADVISER_DISABLE=1` in its environment, on a fresh spawn and on a relaunch alike, so an unattended session never activates the compact adviser.
This guarantee also covers raw launch commands, remote secondmates, and launches filtered by `config/launch-env-allowlist`; it does not depend on the destination environment already containing the variable.

Firstmate provides no configuration or flag to change this value.
This applies only to agents Firstmate launches; the captain's own primary Firstmate session is never given the variable.

[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the delivery mechanics, with focused regression coverage in [`tests/fm-spawn-compact-adviser-disable.test.sh`](../tests/fm-spawn-compact-adviser-disable.test.sh) and [`tests/fm-spawn-compact-adviser-disable-remote.test.sh`](../tests/fm-spawn-compact-adviser-disable-remote.test.sh).

### Commit attribution

The optional local, gitignored `config/keep-ai-trailers` presence flag opts this home into keeping AI co-author trailers on its launched workers.
With the flag absent, every Claude command line Firstmate builds carries inline `--settings` JSON with `"attribution":{"commit":"","pr":"","sessionUrl":false}`, every Devin worker config sets `"attribution": false`, and every fleet launch appends a worker-scoped `GIT_CONFIG` `core.hooksPath` entry pointing at `state/<id>.git-hooks`, where a `pre-commit` guard refuses an author or committer that differs from the machine git config and git's `commit-msg` hook strips known AI trailers even when a runtime injects them after the typed message.
The entry follows any `GIT_CONFIG_*` entries the worker inherits, so an inherited scoped `credential.helper` still applies to the worker and to the repository's own hooks, such as a git-lfs `pre-push`.
An inherited `GIT_CONFIG_COUNT` that is not a decimal number, or that leaves no room for another entry within Git's signed int, stops the launch before the worker runs.
When the flag is present, Claude launches omit those attribution-off settings, Devin worker configs keep the user config's `attribution` setting (Devin's default is on), and fleet launches keep the identity guard and the project-hook chaining while the `commit-msg` hook leaves trailers alone.
Cortex Code has no attribution switch and its model writes a `Generated with Snowflake CoCo` line and a `Co-authored-by: Snowflake CoCo` trailer itself, so the strip hooks are the only mechanism that removes them from a Cortex worker's commits.
`bin/fm-git-strip-ai-trailers.sh` owns the trailer identities, the install, the identity reference, and chaining the hooks of whichever repository git is running in, including when `git -c core.hooksPath` supplies the pane's hook override, so a project hook such as husky still runs.
A repository whose config sets `core.hooksPath` to the empty string runs no project hook, as in plain git; if the wrapper otherwise cannot resolve that repository's hooks directory, the git operation fails rather than silently skipping a project hook such as a pre-push guard.
The hooks directory is read-only, so a hook manager run inside a fleet pane (lefthook's npm postinstall, `pre-commit install`) fails instead of displacing the hooks; install a project's hooks from outside the pane, where the wrappers chain them.
Per-machine Cursor `cli-config.json` attribution-off is not this contract: it does not travel with Firstmate, defaults back to on when unset, and only feeds the CLI's request to the server, so it suppresses the trailer rather than preventing it.

## Heavy queue on the worker PATH

When orc is installed, every ship and scout launch runs `orc heavy path` on the machine that hosts the worker and puts the folder it prints first on the worker's PATH, so the worker's test, build, and browser tools wait their turn in that machine's heavy queue.
A worker on an execution home gets that host's own folder, because the launch runs there.
When orc is missing, `orc heavy path` fails or runs past `FM_HEAVY_PATH_TIMEOUT` seconds, 20 by default, or the worker is sandboxed or in the cloud, the worker launches with its PATH unchanged and the spawn prints one note saying why.
Secondmates are not changed.
`bin/fm-capacity.sh` adds the machine's running and queued heavy calls to its report, read fresh from `orc heavy check --json` each time and never stored.

## Project capacity (config/project-capacity)

The optional local, gitignored `config/project-capacity` tells Firstmate how many workers a project can run at once on this machine, for a project whose machine-local resource - a heavy test suite, a local editor stack, a device - only serves a few workers at a time.
Without it, dispatch stays uncapped as `AGENTS.md` section 7 describes, and a surplus worker is launched only to spend full-context turns waiting for the resource.

```text
# heavy suite serves two workers
my-project 2
```

The name is the project's registered name, which is its clone directory name and may contain spaces, and the number, the last field on the line, is a positive integer.
A line that is only `#`, or that begins with `#` followed by whitespace, is a comment, as is a `#` line whose last field is not an integer.
A project name may begin with `#` when that `#` is written immediately against the rest of the name and the line ends with the project's capacity.
A name that is `#`, or that begins with `#` and a space, cannot be declared, because that line is a comment.
A line whose name starts with `@` is a machine-wide setting rather than a project: `@heavy-limit` caps heavy workers across every project with a standing 3 from 06:00 up to but not including 21:00 UTC and 4 at other hours, and `@load-limit` caps the five-minute load average a heavy start tolerates with a standing 10.
A worker that is only waiting on the captain or on a set time holds no heavy worker place, and counts again once its status shows it resumed.
A cloud-claude worker holds no heavy worker place, and it is exempt from these machine-wide settings, as the [Cloud Claude worker](#cloud-claude-worker) section describes.
On Linux the standing caps are 4 from 06:00 up to but not including 21:00 UTC and 6 at other hours with a load cap of 16.
`@core-budget` caps trailing-hour core hours on the Mac with a standing 6, so a heavy start waits while the hour already burned that budget and resumes on its own once use drops back under, while a light start never waits.
On a Linux host that two Firstmate homes share without a common local root, each home lists the other in `config/linux-load-siblings`, and the same two lines cap heavy starts across both homes with a standing 4 from 06:00 up to but not including 21:00 UTC and 6 at other hours, while the load average cap stays 16.
Where `config/linux-load-siblings` lists sibling homes, a place is also held by every ship or scout in those homes.
The declaration is matched by the spawning clone's directory name, so clones of the same origin share the cap only when they use that same directory name.
A clone of that origin under a different directory name finds no declaration and is not capped, though its workers are still counted as holders for a same-origin clone that is capped.
When every place is held, `bin/fm-spawn.sh` launches nothing, creates no record, leaves the backlog item queued, prints one `deferred:` line naming the holders, and exits 75, so Firstmate dispatches the item again once a place frees.
A malformed or unreadable file refuses every fresh ship or scout spawn until it is fixed, rather than guessing the intended limit, and so does a local home's state directory or task record that cannot be read while counting a capped project's holders.
Firstmate cannot see which part of a worker's life uses the resource, so the number bounds whole workers from launch to handoff, and the tightest resource every worker needs should decide it.
[`bin/fm-project-capacity-lib.sh`](../bin/fm-project-capacity-lib.sh) owns the file format, what holds a place, and why concurrent spawns cannot both take the last one.

## Browser suites

The optional local, gitignored `config/browser-suites` names the projects whose workers run a browser suite, and how far apart their starts must be, so several suites do not start together and spike the machine's load.
Without it, no worker is a browser-suite worker unless its brief marks one, and no start is staggered.

```text
# browser suites in these projects
@stagger-minutes 10
my-web-app
```

Each other line names one project by its registered name, which is its clone directory name and may contain spaces, while blank lines and lines that are `#` or begin with `#` and whitespace are comments.
`@stagger-minutes` is the minimum gap, in whole minutes, between two browser-suite starts on this machine, and it may appear at most once.
A brief also marks its own task as a browser-suite worker with a line that is exactly `Browser suite: yes`, for a browser suite in a project the file does not list.
A browser-suite worker always starts heavy: a `--weight light` spawn is raised to heavy with a note, so it waits on the core budget like any heavy start, and it holds a heavy worker place under the machine-wide settings of [project capacity](#project-capacity-configproject-capacity) as every ship or scout does.
A fresh browser-suite ship or scout that starts inside the gap after the previous browser-suite start launches nothing, prints one `deferred:` line naming how many minutes remain, leaves its backlog item queued, and exits 75, so Firstmate dispatches it again once the gap passes.
The start time is recorded only once a browser-suite start passes every other admission gate and brief check, and a start that fails after that point still holds the gap until it passes.
Every other worker, a relaunch, a secondmate, and a cloud-claude worker are never delayed by the stagger.
A malformed or unreadable file refuses every fresh ship or scout spawn until it is fixed, rather than guessing which projects or gap were meant.
[`bin/fm-browser-suite-lib.sh`](../bin/fm-browser-suite-lib.sh) owns the file format, the brief marker, and the machine-shared start record.

## Project tiers

The optional local, gitignored `config/project-tiers` ranks this home's projects so that, when several queued items are ready at once, Firstmate dispatches the higher tier's items first.
Without it, ready work keeps the backlog's own order.

```text
# fleet speed tiers
website P0
ru-compliance P1
career P3
```

The name is the project's registered name, which may contain spaces, and the tier, the last field on the line, is `P0`, `P1`, `P2`, or `P3`.
Blank lines and lines beginning with `#` are ignored.
The ready listings in the session-start digest and in `bin/fm-tasks-axi.sh ready` put P0 items first, then P1, P2, and P3, then items whose project has no tier or no project at all, keeping the backlog's order within each group.
The digest orders the listing before it bounds it, so a bound never cuts a higher-tier item in favor of a lower one.
Any other line shape, a tier outside `P0` to `P3`, a project named twice, or an unreadable file is an error.
`bin/fm-tasks-axi.sh ready` then refuses and names the line, while the digest prints the error under its ready heading and keeps the backlog's order.
A tier orders dispatch only, and dependencies, holds, time gates, and [project capacity](#project-capacity-configproject-capacity) still decide whether an item can be dispatched.
[`bin/fm-project-tiers-lib.sh`](../bin/fm-project-tiers-lib.sh) owns the parse and the order.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
Firstmate chooses the best matching rule with judgment; shell scripts do not match the natural-language rules.
Firstmate resolves the rule's profile object or array under `AGENTS.md` section 4 and `quota-array-dispatch`, then passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.

**Spawn requirements**

- When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
- An explicit harness alone is not proof the rules were read, so the same spawn also refuses when the task data directory holds neither the resolver output saved as `data/<id>/dispatch-resolve.out` with a clear status whose profile line matches the launch nor the selection record at `data/<id>/dispatch-selection.md`.
- The selection record names the matched rule by index such as `rule_1` or `default` for the default array, carries exactly one candidate line per entry of that rule's `use` array with each line naming its harness and model plus provider and remaining or spendPriority quota reading, and chooses a profile that is one of those candidates and equals the launch, so an unknown rule, a missing candidate, a candidate with no quota reading, or a chosen profile outside the candidates is refused.
- A resolver clear result satisfies the check on its own.
- An explicit per-task captain override stays possible with the stated reason recorded on an `override` line in that same selection record.
- A stated override keeps the full candidate accounting and waives only the requirement that the chosen profile is one of those candidates.
- The same spawn, and any relaunch, checks quota against every profile whose harness, model, and effort match the launch, and refuses one exhausted now or below a profile `floor` unless `--quota-override-reason` states why.
  A floor skipped near its window's reset under "Profile quota floors" below needs no override, prints the skip, and records it as `quota_gate=checked:<skip>`.
- A profile without `claude_account` also matches a launch that passes `--claude-account`, and is checked against that account's clauth reading.
- A launch that matches no profile prints a warning naming the launch and records `quota_gate=skipped:no matching dispatch profile` instead of refusing, because a stated captain override may choose a profile outside the rules.
  Firstmate reports that warning to the captain.
- Relaunches reuse the recorded task and its original proof.
- Batch spawns satisfy the harness requirement with a shared `--harness`, and each pair needs its own proof under its own task data directory.

**Contract owners**

This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "array_order": "preference",
  "preferred_provider": "<optional quota-axi provider family to spend first>",
  "shared_quota": false,
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "approval": "captain",
      "min_confidence": 0.85,
      "floor": { "scope": "<quota-axi scope>", "min_percent": 20, "provider": "<quota-axi provider>" },
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max|ultra, optional>", "provider": "<optional quota-axi provider>", "quota_scope": "<optional quota-axi scope>", "claude_account": "<optional clauth profile>", "floor": { "scope": "<quota-axi scope>", "min_percent": 50 } }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

**Required and optional fields**

| Field | Requirement |
| --- | --- |
| `rules` | May be absent or empty for a default-only configuration. |
| Top-level `array_order` | Optional, with `"preference"` as its only value. Absence keeps `spendPriority` ranking (see "Array order" below). |
| Rule `when` and `use` | Required for each rule. |
| `use` and optional top-level `default` | Accept one profile object or a non-empty array of profile objects; the single-object form remains fully backward-compatible. |
| Profile `harness` | Required in every profile. |
| Profile `model` and `effort`; rule `why` | Optional. |
| Profile `claude_account` | Optional clauth profile name that launches the profile on that Claude account, so one array can hold one account per candidate; see [Claude accounts](#claude-accounts-configclaude-accounts). |
| Top-level `preferred_provider` | Optional provider-family preference, applied after eligibility checks under `quota-array-dispatch`. |
| Top-level `shared_quota` | Optional; see "Shared-quota opt-out" below. |

**Array order**

Without `array_order`, every profile array is ranked by `spendPriority` after the gates `quota-array-dispatch` owns.
With `"array_order": "preference"`, every profile array, in rules and in `default`, is an ordered preference instead: the first candidate that passes those same gates against the current `quota-axi` output is chosen, and `spendPriority` does not rank the array.
`quota-axi` still decides usability, so an `exhausted_now` or otherwise failing candidate is skipped to the next one, while unknown quota keeps a candidate eligible with disclosed uncertainty.
Any other value is a configuration error, and so is a rule `select` in a file that declares `array_order`, because the two would disagree about how that rule's array is chosen.

**Preferred provider**

`preferred_provider` accepts a provider ID matching `^[a-z0-9]+(-[a-z0-9]+)*\z`, using the same vocabulary as profile `provider`.
For example, `"preferred_provider": "codex"` prefers the OpenAI subscription family across its eligible accounts, not one account or harness.
Both bootstrap and the enabled resolver reject malformed values, including null, empty strings, uppercase letters, and whitespace.
Bootstrap validates this field even without a resolver key because the agent-owned intake also honors it.
An absent field preserves the existing routing behavior.
The [profile-array procedure](../.agents/skills/quota-array-dispatch/SKILL.md#rank-by-spendpriority) owns family preference, uncertainty, and fallback after the existing gates.

**Shared-quota opt-out**

An optional top-level `"shared_quota": true` declares this home draws every provider's usage from one single shared budget, such as one workplace AI spend line, so per-provider quota rows do not describe what is left.
With it set, typed dispatch resolution makes no `quota-axi` call, applies no quota floor or runway gate, ranks nothing by `spendPriority`, and resolves the matched rule's `use` profiles in declared order; every candidate line still prints, stating quota ranking is off by home declaration.
`preferred_provider` is a separate home preference, not a quota signal, so it still applies: `preferred_provider` still narrows the pool; declared order then picks within it.
Firstmate's own `quota-array-dispatch` intake honors the same declaration.
Without the setting, or with `"shared_quota": false`, behavior is unchanged.
The declared value must be a boolean; anything else is an actionable configuration error reported like any other malformed rule.

**Fields applied only by typed resolution**

Rule `approval`, `min_confidence`, and `floor`, and profile `provider`, `quota_scope`, and `floor` are optional declarations that only [typed dispatch resolution](#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model) applies in code; without that opt-in they are inert, and firstmate's own intake reads them as ordinary hints.
The resolver supplies the fixed neutral Choice option `No listed rule applies to this task.` for work that matches no listed rule.

- `approval` accepts only `"captain"` and means a task the rule matches is never dispatched from the tool's answer alone.

`min_confidence` is a number from 0 through 1.
The rule's own probability in the answer must reach it, replacing the resolver's global 0.6 floor on the answer's confidence.
Set it high when a wrong pick is costly and low when the rule is a safe runner-up.

**Rule quota floors**

- A rule `floor` names the quota-axi `provider` and `scope` whose `effectivePercentRemaining` must be at least `min_percent` for the rule's profiles to apply.
- A provider-only rule floor on an expanded provider binds to its `default` account row.
- An absent or unknown row or unmeasured provider makes the floor unverifiable and escalates without authorizing default routing.
- A known percentage below the floor makes the tool resolve among `default` profiles instead.

**Provider identifiers and mappings**

A profile `provider` optionally names the quota-axi provider family whose rows apply to that profile; when present, profile and rule-floor provider IDs must match the strict whole-string pattern `^[a-z0-9]+(-[a-z0-9]+)*\z`.
Bootstrap's resolver-only validation gate is described under "Validation and diagnostics" below.

Typed resolution additively recognizes `gemini` because AGENTS.md section 4 verifies it for crewmate and scout dispatch.

| Harness | Provider declaration on the opted-in resolver path |
| --- | --- |
| `claude`, `codex`, `grok`, `kimi`, `cursor`, `agy`, `muse` | The resolver has an authoritative single-provider mapping. |
| Every other verified harness | Must declare `provider` explicitly; this includes multi-provider `pi`, `pi-signed`, `omp`, and `opencode`, and unmapped `gemini`, `rovo`, `devin`, `commandcode`, `cortex`, and `kiro`; omission is an actionable configuration error before any request. |

This single-provider table is separate from the frozen legacy mapping used by `fm-quota-choose.sh`, so additions cannot alter no-key routing.

**Profile quota scope**

- A profile `quota_scope` is a non-empty string naming one quota-axi row of that profile's provider and matched account, such as an Antigravity tier scope (`gemini` or `claude_gpt`) that no model-name rule can bind.
- The named row joins the candidate's applicable rows by exact scope match, so a known zero or `exhausted_now` row makes the candidate ineligible and a healthy row ranks it.
- A named row absent from the snapshot leaves the candidate eligible but unranked and is reported as disclosed uncertainty, never as a block.
- Firstmate never derives the scope from a model name and never falls back to a profile or rule `floor` scope; a profile without `quota_scope` resolves exactly as before.

**Profile quota floors**

- A profile `floor` contains only `scope` and `min_percent`, always uses that profile's provider and matched account, and makes that one candidate ineligible below `min_percent` on the named scope.
- An absent or unknown named row also makes the candidate unrankable and is reported as an unverifiable floor, not as a known shortfall.
- A known shortfall skips the floor instead when every window holding the scope below `min_percent` reports a reset time within the next 24 hours.
  A reserve kept for later work in a window that refills before the task ends serves no one.
  The candidate line then shows `floor=skipped` with the window and its reset time.
- A floor never skips itself for a window at 0% remaining, a window reporting `exhausted_now`, a reset time that is absent, unparseable, or already past, or a reset more than 24 hours away.
- Rule floors do not skip, so a rule floor below `min_percent` still falls through to `default`.

**Model, effort, and fallback behavior**

- `ultra` is native-only: the model-aware validation contract and launch mapping are owned by `bin/fm-harness.sh validate-native-effort` and `bin/fm-spawn.sh` respectively.
- Codex `max` is valid when the profile selects `gpt-5.6-luna`, whose installed catalog entry supports that reasoning level.
- An omitted model or effort means the selected harness uses its own default for that axis.
- OpenCode receives the effort as its default `build` agent's `variant`, keyed to the resolved model, inside the `OPENCODE_CONFIG_CONTENT` JSON its launch already writes (the per-model reasoning-effort field of the config schema, verified on opencode 1.18.32); with no model resolved, the effort is recorded in task metadata but omitted from the launch.
- Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`, in the order "Array order" above selects.
- If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
- Except for `ultra` under the native-effort contract above, an effort value the chosen harness does not accept is recorded as `effort=` in task meta for traceability but omitted from the launch flags.
- Bootstrap reports unsupported harness/model/effort combinations as a `CREW_DISPATCH` diagnostic when they are visible in the file.

See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`; its Pi default declares the `claude` provider required for typed resolution of that Anthropic model.

**Validation and diagnostics**

- When the file exists, bootstrap validates it with `jq`.
- Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
- Malformed JSON, malformed rules, an invalid `array_order`, an empty or malformed profile array, a malformed `preferred_provider`, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`.
- While typed resolution is active, malformed `approval`, `min_confidence`, `floor`, and present `provider` declarations receive the same diagnostic.
- Without the key those inert declarations preserve the pre-existing bootstrap behavior.
- Bootstrap enables resolver-only checks for `approval`, `min_confidence`, `floor`, and present `provider` declarations when `config/bws-typesafe-secret-id` exists, regardless of `FM_DISPATCH_PROVIDER`.
- An OpenRouter key or OpenRouter credential source declaration alone does not enable these bootstrap checks.
- The resolver validates those declarations itself before any request.
- Without a typesafe key, bootstrap retains its pre-existing verified-harness baseline.
- Missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
- While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.

**Inheritance**

A primary file held as a symlink is machine-local indirection and is not inherited.
Remote homes converge to absence for it and keep their own machine-local link, so a home on another machine never receives this machine's variant bytes.
Link that machine's own variant into a file-less home once to give it those rules.
Inheritance preserves the link thereafter.

## Typed dispatch resolution (.env FM_DISPATCH_PROVIDER, FM_DISPATCH_MODEL)

`bin/fm-dispatch-resolve.sh` resolves one concrete crewmate or scout profile from a written brief through typesafe.ai, OpenRouter, any System One-compatible host, or OpenAI, so the rule match that firstmate otherwise reasons out in its own context becomes one short tool turn.
`FM_DISPATCH_PROVIDER` selects `typesafe`, `openrouter`, `systemone`, or `openai`, and `FM_DISPATCH_MODEL` selects the model.
Each setting comes from the calling environment or the home's gitignored `.env` through `bin/fm-env-lib.sh`; a non-empty environment value wins.
The accessor reads dispatch keys without logging their values.
For each key, the last assignment wins, with an optional leading `export`, surrounding whitespace, and one layer of matching quotes.
A missing file or key returns an empty value without an error.
OpenRouter, `systemone`, and OpenAI each require their explicit `FM_DISPATCH_PROVIDER` value and a non-empty `FM_DISPATCH_MODEL`; an omitted model is an actionable configuration error, and the presence of a provider's key never selects that provider by itself.
`systemone` also requires `FM_DISPATCH_BASE_URL`, an `http://` or `https://` base such as a local llama.cpp server or a hosted System One-compatible service, and posts to `<base>/v1/systemone`; a missing or scheme-less base URL is an actionable configuration error.
With no provider setting and a valid base, the original typesafe.ai behavior is unchanged: `jev-latest` is used when the typesafe key is available from Bitwarden, `FM_DISPATCH_MODEL` is ignored, and the resolver is off when no secret id file exists.
Explicit `FM_DISPATCH_PROVIDER=typesafe` also uses `jev-latest` when no model is set.
The OpenRouter and OpenAI keys must be non-empty in the environment or `.env`, with the environment taking precedence; the OpenRouter key alone may instead come from the credential source the home declares for `openrouter`.
`systemone` is the exception: an absent `FM_DISPATCH_API_KEY` means the request carries no `Authorization` header.
The typesafe key is never read from the environment, `.env`, or a credential source declaration.
The gitignored `config/bws-typesafe-secret-id` file holds the Bitwarden Secrets Manager secret id, which identifies the secret and is not itself the credential.
The resolver fetches the value with `bws` at run time through `bin/fm-bws-lib.sh`, reading the access token from the macOS keychain item `bws-access-token` and falling back to `~/.config/bws/token`.
The token reaches `bws` only through `BWS_ACCESS_TOKEN`, never on argv.
An absent id file turns the typesafe gate off.
A configured id whose fetch fails refuses with exit 2 and a line that names what is missing, and sends nothing.
`TYPESAFE_BASE` optionally selects a different base for the TypeSafe request, from the environment or `.env` with the same non-empty-environment precedence.
If neither source supplies a non-empty value, the base defaults to `https://api.typesafe.ai`.
It must be an `http://` or `https://` URL with a host and no userinfo, query, fragment, whitespace, or backslash.
An explicit port must be between 1 and 65535, and a bracketed host must be a valid IPv6 address.
Its path must not contain literal `[` or `]` characters; IPv6 host brackets remain supported.
An invalid value exits 2 before credential lookup and sends nothing, even when no key is available.
Trailing slashes are removed before appending `/v1/systemone`, so `TYPESAFE_BASE=https://ai-gateway.vercel.sh/typesafe/` sends to `https://ai-gateway.vercel.sh/typesafe/v1/systemone`.
To select a gateway-specific model ID, set `FM_DISPATCH_PROVIDER=typesafe` and `FM_DISPATCH_MODEL` to that ID.

Off means one `dispatch-resolve: off` line on stderr, nothing on stdout, exit 0, and no network call, so firstmate dispatches exactly as it does without the tool.
A declared credential source that cannot supply its key is not off; see "Credential source declaration" below.
This section is the single owner of the tool's operator contract; the script header owns its exact flags and output lines, and "Crew dispatch profiles" above owns the declared top-level, rule, and profile fields it applies.

Rules come only from the effective home's `config/crew-dispatch.json`; `FM_CONFIG_OVERRIDE` selects the config directory for tests and specialized setup like the other scripts.

```sh
bin/fm-dispatch-resolve.sh data/<id>/brief.md --project <name>        # TOON block on stdout
```

**When firstmate invokes the resolver**

Firstmate invokes the resolve path directly after writing the brief, without a preflight; the absent-key off line is handled exactly like every other non-clear outcome.

**What the model receives**

When on and at least one rule exists, the tool sends the project name and the brief's task-specific text as state and asks one Choice question.
Scout briefs use rules whose `when` contains the word `scout`, case-insensitively.
Other briefs use the remaining rules.
Both include the fixed neutral option for no matching rule, and a scout with no scout rules uses the default without a model call.
The model never sees quota, catalogs, `why`, `use`, approvals, or confidence floors.
OpenRouter's Decisions API and a `systemone` host accept the same Choice request shape and return the same typed answer, including confidence and a probability per option.
For OpenAI's Decisions API the resolver rewrites that request into OpenAI's shape - the state as JSON text `input` and one `choice` question named `rule` whose `choices` are the same options - and maps the answer's per-option probability array back; a refusal, a missing or duplicated rule answer, or duplicated option values is rejected as malformed.
Every provider then uses the same response validation and post-model gates.
The task-specific text is the brief's `## Captain's intent` and `## Firstmate spec` sections under `# Task` that `bin/fm-brief.sh` scaffolds, read by the same parser that feeds `fm-spawn.sh` validation and the no-mistakes `--intent` contract; a brief with neither section is sent whole.

When the sections are sent from a scout brief, the line `Brief kind: scout (report only)` comes first, taken from the scaffold's scout contract line; ship briefs and briefs sent whole get no kind line.
A ship brief's delivery mode is deliberately not sent, because in live runs naming it pushed a routine ship brief toward the hardest tier (see [the verification record](verification/dispatch-resolve.md)).

The scaffold's standard setup, rules, and definition-of-done text is the same in every brief, so leaving it out keeps its safety language from reading as a signal about the task.

**Never-send list (config/dispatch-never-send)**

The optional local, gitignored `config/dispatch-never-send` keeps values you name from ever leaving the machine in a resolver request.
It has no default entries, and an absent file changes nothing.

Each non-blank line not beginning with `#` is one literal value, matched case-insensitively.
Every entry is trimmed of surrounding whitespace, and any run of whitespace, in the entry or in the checked text, counts as one space, so a value the brief wraps across lines still matches.

```text
# Client names
Example Client Ltd
```

Before the request is sent, the endpoint URL and every string in the final provider-specific request body are checked, including strings inside JSON text such as OpenAI's `input`: the selected model, the project name, the task text, each rule's `when`, and the fixed question text.
A match stops the request: the resolver behaves exactly as when it is off, printing one `dispatch-resolve: off (...; nothing sent)` line on stderr and nothing on stdout, making no network or quota call, and exiting 0, so firstmate dispatches through its existing intake.
A list that is present but not a readable regular file also stops the request the same way rather than sending unchecked text.
That one diagnostic names the list line number at most and never prints the listed value or the matching text.

**Missing or invalid rules**

An absent rules file, a default-only file, or `rules: []` returns the non-clear reason `no rules to match` without a model or quota request, leaving firstmate's existing routing in control; an existing but unreadable or malformed rules file, including a broken symlink, remains an actionable exit 2 configuration error.

**Checks performed after the answer**

After the answer, code applies all remaining checks and ranking:

- The confidence floor and the matched rule's `approval` and `floor`.
- Each candidate's `provider`, `quota_scope`, and `floor`.
- Every applicable account-wide and model/product row from one `quota-axi --json` snapshot.
- The optional `preferred_provider` restriction under the [profile-array procedure](../.agents/skills/quota-array-dispatch/SKILL.md#rank-by-spendpriority).
- The numeric `spendPriority` argmax within that candidate pool, using each candidate's limiting row, or, when the file declares `array_order` preference, the first eligible candidate of that pool in array order.
- With the home's `shared_quota: true` declaration ("Crew dispatch profiles"), the quota snapshot, floors, runway gates, and `spendPriority` argmax are skipped entirely; resolution is the matched rule's declared profile order (`preferred_provider` still narrows the pool; declared order then picks within it).

The resolver prints its preferred-family decision while retaining evidence for every candidate.
If preferred candidates remain eligible but none is rankable, it escalates instead of selecting another family.
It never introduces candidates outside the matched rule or its existing default fallback.

Before ranking, the resolver applies the Haiku-first promotion to the matched candidate array.
The promotion moves a Haiku candidate directly ahead of a Muse candidate when both are present and the quota snapshot shows a short Go allowance with a comfortable Claude allowance.
A short Go allowance means the Go monthly window runs ahead of pace with `reservePercentPoints` at or below -15, or the Go weekly or rolling window has under 10 percent left.
A comfortable Claude allowance means the seven-day window has at least 25 percent left and the five-hour window has at least 30 percent left.
Unknown or missing window readings leave the default order unchanged.
The per-window readings come from the snapshot `windows` entries, since the effective-availability scopes carry only the limiting percent.

The [shared quota library](../bin/fm-quota-axi-lib.sh) accepts schema 5 and schema 6 and implements the [account-matching contract](../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility).

- An expanded provider with no matching account row leaves the candidate eligible but unranked.
- Known applicable rows from a provider with partial quota semantics remain rankable; rows whose own status is not known remain unrankable.

**Confidence and fallback rules**

- A rule that declares `min_confidence` is checked against that rule's own probability, whether it is the picked option or a runner-up, so a runner-up never needs weaker support than it would as the pick.
- A picked rule without `min_confidence`, and the neutral option, keep the global 0.6 floor on the answer's confidence exactly as before, so a file with no declared floors behaves as it did.

When the picked rule declares its own floor but its probability falls below it, the tool checks the other options:

1. Find the most probable other option that clears its own floor: the rule's `min_confidence`, or 0.6 otherwise.
2. Print a `fallback:` line naming both floors and resolve that rule as though it had been picked.

No qualifying option, or two equally probable qualifying options, produces `ambiguous`.

**Candidate eligibility and evidence**

- Any applicable `exhausted_now` row or known zero bound makes that candidate ineligible, and a known profile-floor shortfall not skipped near its reset does the same before unrelated quota uncertainty is considered.
- Missing or nonnumeric `spendPriority` evidence is never ranked, and every candidate is printed beside its evidence or the reason it was not rankable, including on ambiguous and approval-gated outcomes that emit no profile.
- Under preference order, the first eligible candidate is chosen even when its quota is unknown, with that uncertainty printed as a note.
  An unverifiable profile floor on it escalates instead, because the floor can be proven neither met nor missed.
- On the opted-in path, duplicate concrete profiles with the same harness, model, and effort inside one rule or the default array are configuration errors rather than ties.

**Outcomes and exit status**

| Result | Meaning |
| --- | --- |
| `clear` | A `profile:` line ready for `fm-spawn.sh`. |
| `ambiguous` | Confidence below the floor with no runner-up taken. |
| `escalate` | An approval-gated rule, unverifiable rule floor, nothing rankable, or a genuine tie. Under preference order, no eligible candidate or an unverifiable profile floor on the first eligible one. |
| `error` | API, network, malformed response metadata, rendering, quota-axi failure, or a declared credential source that cannot supply its key. |

Every result above exits 0.

- Response probabilities must contain exactly every offered choice, use numeric values from 0 through 1, and sum to approximately 1 within 0.01.
- Only a usage or configuration error exits 2: an unreadable brief, an existing but unreadable or malformed canonical rules file, an unreadable or invalid credential source declaration, a missing `jq`, an unknown provider, a non-typesafe provider without a model, an invalid `TYPESAFE_BASE` for TypeSafe, or `systemone` without a valid base URL, each reported and never selected around.
- Missing `curl` is a normal structured `error` outcome with exit 0 so firstmate uses today's routing.

**Firstmate retains the dispatch decision**

The tool never replaces firstmate's judgment, `quota-array-dispatch`, the captain-approval gate, or `fm-spawn.sh` validation; `AGENTS.md` section 4 owns what firstmate does with each outcome.
By accepted design, a `clear` result does not enforce catalog/authentication, reasoning-class, or completion-runway gates.
Firstmate still applies those gates before dispatch, including when `preferred_provider` is present.
Explicit captain overrides retain precedence over the resolver's suggestion.

Firstmate passes its profile line unless it states a reason to override, such as the brief's reasoning class or an eligible-unranked-candidate note; every non-clear result returns to the full existing intake.

**Task record (data/<id>/dispatch-resolution.json)**

For a brief at `data/<id>/brief.md`, or `<FM_DATA_OVERRIDE>/<id>/brief.md` when that override is set, each run first removes that task's `dispatch-resolution.json`, so a decision never outlives a later run.
Every outcome that exits 0, including off, then writes one JSON object there: `task` (the `<id>`), `status` (`clear`, `ambiguous`, `escalate`, `error`, or `off`), and `profile`.
On `clear`, `profile` holds `harness`, `model`, and `effort`, each `null` when the chosen profile leaves it unset; otherwise `profile` is `null`.
A usage or configuration error (exit 2) writes no record.
`fm-spawn.sh` reads this record as the task's decision, as "Per-launch overrides and inherited defaults" describes.

**Credential source declaration (config/dispatch-credential-sources.json)**

The optional local, gitignored `config/dispatch-credential-sources.json` tells the resolver where a provider's key lives when neither the environment nor `.env` supplies one.
It names a source and never holds a key.
It is read from the effective config directory, which is `FM_CONFIG_OVERRIDE` when set and `$FM_HOME/config` otherwise, so each home reads only its own file.
A home without the file behaves exactly as it did before the file existed.
It covers the `openrouter` key only.
The typesafe key comes from Bitwarden as above, and the `systemone` and OpenAI keys still come from the environment or `.env`.

The file is one JSON object keyed by provider, `openrouter`, and each value says where that provider's key is:

```json
{
  "openrouter": { "source": "macos-keychain", "service": "openrouter-api-key", "account": "me" }
}
```

`source` is required and names the adapter, and `macos-keychain` is the first.
It requires `service`, accepts an optional `account`, and reads that generic-password item with `security find-generic-password -s <service> [-a <account>] -w`.
Store the item with `security add-generic-password -s <service> [-a <account>] -w`, which prompts for the key and lets `security` read it back without an access dialog.
Only the service and account reach `security`'s argument list, and the key comes back on a pipe.
No other field is accepted, so the file has nowhere to put a key.
`bin/fm-credential-source-lib.sh` owns the schema and the adapters, so a further source adds an adapter there rather than a special case in the resolver.

The resolver reads the file only after the environment and `.env` have supplied no key for the selected provider, and it uses only that provider's entry.
A declaration for one provider never feeds another provider and never selects a provider.
Three outcomes stay distinct:

- **Off.** No entry for the selected provider and no key keeps today's behavior: the `dispatch-resolve: off` line, nothing on stdout, and exit 0.
- **Configuration error.** An unreadable file, malformed JSON, an unknown provider such as `typesafe`, an unknown or missing field, or a value that is not a plain non-empty string exits 2 with one line that names the problem.
  The check covers the whole file, so an invalid entry for a provider that is not selected also exits 2.
  The line names providers and fields and never prints a declared value.
- **Unavailable source.** An entry whose source this host cannot run, or that yields no key, ends as the `error` outcome with exit 0 and a reason ending `nothing sent`, and makes no network or quota call.
  The reason says whether the host cannot run the source, the source holds no readable key, or it did not answer in time, and it never relays the tool's own output.
  A source that does not answer within 5 seconds ends the same way, so an unanswered Keychain access prompt cannot hold an intake.

A configuration installer can check a source before it writes anything:

```sh
bin/fm-dispatch-resolve.sh --supports-credential-source macos-keychain
```

The probe prints `supported` and exits 0, or prints `unsupported` and exits 1, for a source name on the host it runs on.
`unsupported` covers an unknown name, a host the adapter does not run on, and a missing tool.
The probe reads no declaration and no credential and runs no credential tool.
An installer should treat any status other than 0 as a refusal, because a resolver that predates the probe rejects the flag with exit 2.

**Key handling and provider settings**

- The resolver copies every environment-provided key into a non-exported private variable and unsets `TYPESAFE_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, and `FM_DISPATCH_API_KEY` before launching child processes; the typesafe value itself is fetched through `bws` at run time, and bootstrap also protects that key.
- A key read from a declared source is captured into the same private variable, so it is never exported either.
- The resolver sends only the selected key to `curl` as a header read from a file descriptor, never on argv, and never prints, logs, or writes any key.
- TypeSafe endpoint selection follows `TYPESAFE_BASE` above; the OpenRouter endpoint is `https://openrouter.ai/api/alpha/decisions`, the OpenAI endpoint is `https://api.openai.com/v1/decisions`, and the `systemone` endpoint is `<FM_DISPATCH_BASE_URL>/v1/systemone`.
- The default confidence floor remains 0.6; every provider times out after 10 seconds.
- A CPU-only local `systemone` host may not answer within its 10-second timeout; that is an ordinary `error` outcome, and firstmate keeps its existing intake.

The recommended OpenRouter model is `typesafe/jev-1.13` because it is built for fast typed choices and supplies native per-option probabilities without generated text.
The dated model catalog observation is recorded in [dispatch verification](verification/dispatch-resolve.md#the-api-the-tool-depends-on).
The resolver never chooses this model automatically; use these settings in the calling environment or the home's `.env`:

```dotenv
FM_DISPATCH_PROVIDER=openrouter
FM_DISPATCH_MODEL=typesafe/jev-1.13
```

A `systemone` or OpenAI setup names its model the same way; the resolver never picks one for them:

```dotenv
FM_DISPATCH_PROVIDER=systemone
FM_DISPATCH_MODEL=<model the host serves>
FM_DISPATCH_BASE_URL=http://127.0.0.1:8080
```

The live rule-match evidence is recorded in [`verification/dispatch-resolve.md`](verification/dispatch-resolve.md).

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with its exact install or upgrade command, or with manual instructions.
It installs missing automatically supported tools only after you say go; for an installed but outdated tool, run the printed upgrade command after consent, while manual-only tools remain for you to install from the printed instructions.

Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.

**Universal requirements**

Every home requires:

- node and git.
- gh, with GitHub authentication through `gh auth login`.
- no-mistakes v1.46.0 or newer.
- Compatible gh-axi.
- chrome-devtools-axi.
- Compatible tasks-axi, as specified in "Backlog backend" above.
- Compatible quota-axi.

[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.

In that list, no-mistakes runs the validation pipeline, gh-axi and chrome-devtools-axi cover GitHub and browser operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
Lavish is a presentation-only dependency for visual decisions and reports; nonvisual work can proceed with plain text when it is unavailable.

**Backend requirements**

The herdr backend adds `herdr`, `jq`, and `treehouse`; `fm_backend_required_tools` in `bin/fm-backend.sh` owns that list.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch.

**Feature-specific requirements**

- When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
- When `config/record-export-root` exists, record sync and teardown archival require `python3` for descriptor-relative filesystem transactions and strict manifest parsing.

**Missing and outdated tool diagnostics**

`tasks-axi` and `quota-axi` are essential bootstrap tools in every profile.
An absent required tool with an automated install path reports `MISSING:` with its install command, while a present required tool below its floor or missing a required capability reports `OUTDATED:` with its installed version (or `unparseable`), requirement, and upgrade command; manual-only and presentation-only dependencies retain their dedicated diagnostics, and [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh)'s header owns these exact line formats.

- An absent `treehouse` reports `MISSING:` with its install command, while an installed build without `treehouse get --lease` support reports `OUTDATED:` with the `treehouse update` upgrade.
- An absent `no-mistakes` reports `MISSING:` with its install command, while a version below 1.46.0 or an unparseable version reports `OUTDATED:` with the `no-mistakes update` upgrade.
- An absent `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)` and a below-floor or feature-incompatible one reports `OUTDATED:` with its required version and any missing feature-probe capability, while retaining that same `npm install -g tasks-axi` upgrade; when `config/backlog-backend` is not `manual`, a home with a configured non-markdown adapter or a markdown backlog refuses lifecycle mutation until compatible `tasks-axi` is on `PATH`, while a manual-backend home keeps its backlog hand-edited.
- An absent `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)` and an outdated one reports `OUTDATED:` with its `gh-axi update` upgrade.
- An absent or board-incompatible `lavish-axi` reports `PRESENTATION_UNAVAILABLE` with the 0.1.77 compatibility floor, install command, and explicit text fallback; compatible versions below 0.1.80 retain legacy board replies and report an upgrade recommendation for synchronous acceptance.
- An absent `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)` and an incompatible one reports `OUTDATED:` with its `quota-axi update` upgrade; firstmate cannot resolve a profile array without a compatible binary.

**Checkout diagnostics**

Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.

**Project refresh at startup**

The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.

- It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
- Normal completed runs keep local-only and no-origin skips silent.
- If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.

**Stale Git lock recovery**

A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.

It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.

## Forge selection (data/projects.md forge= token)

A project with no `forge=` token is served by the GitHub tooling, `gh` and `gh-axi`, exactly as before the token existed, and the token changes nothing for existing entries.
A remote-backed project on a Forgejo or Gitea server is registered with `forge=forgejo`, one value of the same closed `forge=` binding that Gerrit uses; `bin/fm-project-mode.sh`'s header owns its grammar, values, and refusals, and `bin/fm-project-mode.sh --forge <name>` reads it back.
Firstmate passes the binding to `bin/fm-brief.sh --forge` at intake the same way it passes `--mode`, and `bin/fm-spawn.sh` refuses a brief whose forge disagrees with the registry; on `forgejo` the generated ship brief names `tea` instead of `gh-axi`.
The URL-driven provider dispatch in [`bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh) recognizes a GitHub, GitLab, Gerrit, or Forgejo PR/MR/change URL once one exists, regardless of this token.

A Forgejo (or Gitea) project needs `tea` on `PATH` plus a `tea login` registered for that project's host (`tea login add`); the login is matched to a PR's host automatically, never configured per project.
A GitLab project needs no forge token, only `glab` on `PATH`, authenticated via `glab auth login`.
[`docs/gitlab-merge-watch.md`](gitlab-merge-watch.md) and [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md) hold the empirically verified CLI behavior each provider's watch and merge path depends on.

A project whose reviews are created by a review tool that uploads its own snapshot of the worker's commits is registered `[direct-PR forge=external]`; it is never detected, ships `direct-PR` only, carries no yolo, and needs the [external review tool](#external-review-tool-configexternal-reviewmd-configexternal-review-url-configexternal-review-backup) configuration below.
[`docs/external-review-forge.md`](external-review-forge.md) is the design.

## PR text selection (data/projects.md pr= token)

A project with no `pr=` token keeps today's behavior: the no-mistakes pipeline's `pr` step writes the pull request title and body and refreshes them on every validated push.
A project whose outside maintainer reviews and merges, and whose hand-written PR text the pipeline would overwrite, is registered `[no-mistakes pr=manual]`.
`pr=manual` is the one accepted value, off by default, read like `forge=`: `bin/fm-project-mode.sh --pr <name>` reads it back, and its header owns the grammar and refusals.
It applies to a `no-mistakes` ship on a project with no `forge=` binding only, so the registry refuses it on `direct-PR`, which already leaves the PR text to the worker, on `local-only`, which opens no PR, and beside a forge.
Firstmate passes it to `bin/fm-brief.sh --pr manual` at intake the same way it passes `--forge`, `bin/fm-spawn.sh` refuses a brief whose `pr=` disagrees with the registry, and `bin/fm-promote.sh` reads it from the registry.
The generated brief then has the worker pass `--skip pr,ci` on every `no-mistakes axi run`, write the PR title and body itself, open or update the PR with `gh-axi`, and wait for the PR's checks; `bin/fm-dod-lib.sh` owns that text.
The token is the thin registry form of no-mistakes' own keep-text option, [kunchenguid/no-mistakes#1648](https://github.com/kunchenguid/no-mistakes/issues/1648), and is meant to map onto it once that exists.

## GitHub Enterprise hosts (config/github-hosts)

`config/github-hosts` is an optional local, gitignored file naming the GitHub Enterprise hosts whose pull request URLs this home accepts, one lowercase hostname per line, such as `leadsonline.ghe.com`.
The PR library reads `github-hosts` from `FM_CONFIG_OVERRIDE` when nonempty, otherwise from `$FM_HOME/config`, falling back when `FM_HOME` is unset or empty to `config/` under the library's own code root, captured when the library is sourced.
`github.com` needs no line and is always accepted.
Blank lines, `#` comments, and any other line authorize nothing: only a line equal to the host is a match, so the file cannot be made to allow more than it spells out.
An absent, unreadable, or symlinked file authorizes no Enterprise hosts.

GitHub pull request URLs are otherwise identical on every GitHub host, so a hostname's shape cannot show whether it is a GitHub host or a look-alike such as `github.com.evil`, and [`bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh)'s `fm_github_host_allowed` accepts an Enterprise host only when this file names it.
That covers registration through `bin/fm-pr-check.sh`, the merge poll, `bin/fm-pr-merge.sh`, and the merge-outcome and teardown reads, which all carry the parsed host through `gh` and `gh-axi` via `GH_HOST`.
A host named here still needs its own `gh` authentication (`gh auth login --hostname <host>`), exactly as `gh` itself requires.

The host is part of each recorded PR identity, so removing a host while a task's pull request is still open stops that task's merge monitoring rather than pointing it at another host.

## Security-sensitive paths: config/security-paths

`bin/fm-security-paths.default` is the tracked list of security-sensitive paths.
It holds one extended regular expression per line, matched against every path a pull request changes.
Both names of a rename count.
`config/security-paths` in the home, when present, replaces that default list entirely.
Blank lines and `#` lines are ignored.
An autonomous merge, one run without `--attended-override`, is refused when a changed path matches a line.
Those paths need the captain's explicit word.
A missing or empty list, an unreadable changed-file list, or a pattern that does not compile refuses the merge.
It never passes.

Workflow files are the one exception.
When every matched path matches only the list lines `^\.(github|forgejo)/(workflows|actions)/` or `^\.gitlab-ci\.yml$`, the merge reads the diff of those files instead.
It merges on its own unless an added or removed line touches a `permissions:` key or its block, references secrets, a `GITHUB_TOKEN`, a `token:` input or an `id-token` setting, or an added line has a `uses:` whose owner is not on the workflow owner list.
A local `./` action is never outside the list.
A renamed workflow file, a diff the forge did not send, or a path matched by any other line keeps the refusal, and the refusal names each line or file that caused it.

### Workflow owners: config/workflow-owners

`config/workflow-owners` is an optional local, gitignored file listing the owners whose actions a workflow change may add without the captain's word.
It holds one GitHub account or organisation name per line, compared without regard to case.
Blank lines and `#` lines are ignored.
Without the file, the list is the pull request's own repository owner.
A file that is present but unreadable or has no names refuses every workflow merge.

## External review tool (config/external-review.md, config/external-review-url, config/external-review-backup)

These optional local, gitignored files configure a home's `forge=external` projects; a home with no such project needs none of them.

| File | Required | Meaning |
| --- | --- | --- |
| `config/external-review.md` | yes, for any `forge=external` scaffold or spawn | Worker instructions for the home's review tool: how to validate, upload, and read review state, and which state is the stopping point. `bin/fm-dod-lib.sh` appends it verbatim to the Definition of done under `## Review tool instructions (home configuration)`. |
| `config/external-review-url` | no | One extended regular expression a ready review URL must match in full. Without it, any `https://` URL with no whitespace, control characters, query, or fragment that is not a forge pull request URL is accepted. |
| `config/external-review-backup` | no | Line 1 names a git remote in the project clone that is the captain's personal backup remote; an optional line 2, `prefix=<ref-prefix>`, sets the backup ref prefix, default `backup/`. |

A missing, unreadable, or empty adapter stops the scaffold or spawn, as does an adapter carrying its own `Delivery contract: mode=` line, because a worker with no upload instructions would otherwise improvise a push.
A backup remote named `origin`, absent from the project clone, or pointing at one of origin's URLs stops the spawn, as does a backup prefix that is empty, invalid, or equal to or starting with the task branch prefix.
The files are static, never executed, and local to each home rather than part of secondmate inherited configuration.
`bin/fm-external-review-lib.sh`'s header owns the readers, and [`docs/external-review-forge.md`](external-review-forge.md) owns the backup rule and its teardown consequence.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.

The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs or updates tools, fetches into a watched git repository, or changes `PATH` or a version manager.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "published": {
        "source": "npm",
        "package": "<npm package name, including an optional @scope/>"
      },
      "version_url": "<optional https URL whose body carries the newest published version>",
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

**Entry fields and probe behavior**

- Each entry needs a unique non-empty `name` and at least one of `command` or `git`; an entry may carry both.
- A `published` probe also requires `command` to supply the installed version; it can accompany `git` and an announcement on the same entry, but not `version_url`, so an entry has at most one published-version source.
- A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reads the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
- The announcement counts as `update available` only when the version it names is newer than the newest installed copy found; a version already installed is reported only as `update not in effect`, so one completed install does not report both in the same sweep. An announcement naming no readable version is reported as an available update as before.
- A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
- `announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
- A tool whose CLI never announces its own updates (Claude Code is one) can add `version_url` to its `command` entry: one HTTPS URL without whitespace or control characters whose response body carries the newest published version.
- It is fetched read-only with curl inside the same probe bound; the first dotted numeric version in the body is compared with the newest installed copy found.
- `update available` is reported only when the published version is newer than every installed copy found; a failed request, a body without a readable version, or a missing curl is reported as that tool's own check failure.
- An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
- A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
- An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.

**Published release sources**

A `published` object selects one public release source:

- `{"source":"npm","package":"tasks-axi"}` reads the public npm registry version selected by the package's `latest` dist-tag; scoped names such as `@scope/tool` are supported.
- `{"source":"github","repo":"herdrdev/herdr"}` reads the `tag_name` of GitHub's latest published release for that public repository; draft releases, prereleases, and tags without a release are not selected.

`published` accepts only the fields shown for its source, and requires a package name or `owner/repo`, without a URL, query, or credentials.
It compares that source with the newest installed copy found, and reports an update only when the published version is numerically newer; a published version already installed is reported only as `update not in effect`.
For this comparison, the installed version is the first dotted number in the output of a version command that exits successfully, so `0.1.49`, `v0.8.2`, and `herdr 0.8.2` work; a version command that fails is reported as a check failure.
The published version must be a dotted numeric version with an optional leading `v`; other formats, including prerelease suffixes, produce a check failure.
Components are compared numerically, with leading zeroes and missing trailing zero components ignored.
These queries use `curl` and the existing `jq` parser, without an npm installation or a GitHub login; `curl` is required only for a `published` or `version_url` probe.
The `published` HTTP reads ignore curl configuration and send no credentials, follow no redirects, and fail within the probe bound on an unavailable source, HTTP error, or unreadable version.

All probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
Malformed configuration stops `arm` with a diagnostic.
During a sweep, malformed configuration is reported as a registry failure and no tools are checked.
See [`docs/examples/watched-tools.json`](examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

**Arm, edit, and disarm**

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.

- That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
- Registering the check is itself a reason to watch, so the home keeps a watcher for it after the last task is torn down, and `disarm` is what ends that need.
- `bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.

**Repeat reporting and inheritance**

- The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
- A changed or returning condition is reported again.
- Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.

**Probe timing and limits**

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_TOOL_UPDATE_INTERVAL` | 900 seconds | Time between probes; `0` probes on every run. |
| `FM_TOOL_UPDATE_PROBE_SECS` | 5 | Bounds one probe. |
| `FM_TOOL_UPDATE_BUDGET_SECS` | 20 | Bounds a whole sweep. |

- If the budget runs out before the next tool, the sweep records its partial findings and says which check it did not reach rather than reporting the remaining tools as current.
- It waits until the next configured interval before probing again, while a final probe that finishes after the deadline still completes the sweep.
- The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills records nothing and would then surface as a `timed out` check wake on every poll.
- So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
- A budget that is not a whole number from 1 to 120 is still refused outright.

## Local Claude usage warner (config/usage-warner)

`config/usage-warner` is an optional local, gitignored set of Claude usage-window thresholds.
It is opt-in and load-bearing: an unconfigured home sees no behaviour change, and [`bin/fm-usage-warner.sh`](../bin/fm-usage-warner.sh) refuses to arm without at least one valid threshold.
This is a threshold warner, not a usage viewer - it runs the existing `quota-axi` read (`--no-credential-refresh`, never a credential-refreshing flag) and speaks only once when a configured window crosses a configured percentage, batching several crossings from the same read into one notification and re-arming once a window reads back below its threshold.
Warnings post through macOS Notification Center, the same OS-level path the away-mode wedge alarm resolves to on this platform, without sourcing or coupling to that daemon's away-mode-specific config or rate limiting.

This section is the single owner of the canonical schema.
`bin/fm-usage-warner.sh` owns read, notification, and de-dupe mechanics.

```
<window-id>:<percent>
```

One directive per non-empty, non-comment line, split on the last colon so a per-model window id such as `model:fable` still parses.
`<window-id>` is exactly the `id` field `quota-axi`'s own `--json` output already uses.
`<percent>` is how much of that window has been CONSUMED, a whole number from 1 to 100, compared against the window's own `percentUsed`: `seven_day:90` warns once the weekly window is 90% used, with 10% of it left.
See [`usage-warner.md`](usage-warner.md) for the full behaviour reference and [`docs/examples/usage-warner`](examples/usage-warner) for a starting point to copy into local `config/usage-warner`.

Arm the check once per home with `bin/fm-usage-warner.sh arm`.
That writes `state/usage-warner.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns a crossing into a `check:` wake; no separate schedule is involved.
`arm` refuses on any platform other than macOS.
`bin/fm-usage-warner.sh disarm` removes the shim, its trust binding, and the de-dupe record (`state/.usage-warner`).

## Watched fork drift

The watched fork list lives in `config/fork-upstream.json`, an optional local gitignored file.
When it is absent, the drift check does nothing.
When it is present and the check is armed, [`bin/fm-fork-drift-check.sh`](../bin/fm-fork-drift-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<project> is <behind> behind / <ahead> ahead of <upstream> at <head>` means the upstream branch moved past the fork branch.
- `<project> upstream published <tag>` means the upstream published a newer release.

Each entry names the registered project, the fork, the upstream, and the trigger.
A fork or upstream is an `owner/repo` slug or a git URL the local git can read.
The branch defaults to each side's default branch and can be pinned per entry.
See [`docs/examples/fork-upstream.json`](examples/fork-upstream.json) for a starting point to copy into local `config/fork-upstream.json`.

**Arm, edit, and disarm**

Arm the check once per home with `bin/fm-fork-drift-check.sh arm`.

- That writes `state/fork-drift.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake.
  No separate schedule is involved.
- `bin/fm-fork-drift-check.sh disarm` removes the shim, its trust binding, and the report record.

**Repeat reporting and inheritance**

- The check prints nothing when every upstream is current.
  `state/.fork-drift` records the last reported head, tag, or failure per fork, so each new upstream state is reported exactly once, even a change that lands on a day the sweep missed.
- A changed or returning condition is reported again.
- A probe that cannot answer is reported as that fork's own check failure rather than read as current.
  A repeating failure stays silent until the outcome changes.
- Adding, removing, or changing a watched fork is an edit to this file and needs no code change or re-arming.
- Secondmate homes do not inherit this file, so each home watches the forks it actually tracks.

**Probe timing and limits**

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_FORK_DRIFT_INTERVAL` | 86400 seconds | Time between sweeps. `0` sweeps on every run. |
| `FM_FORK_DRIFT_PROBE_SECS` | 10 | Bounds one probe. |
| `FM_FORK_DRIFT_BUDGET_SECS` | 25 | Bounds a whole sweep. |

- A sweep that runs out of budget defers the forks it did not reach to the next sweep rather than reporting them as current.
- The sweep must finish inside `FM_CHECK_TIMEOUT`, which defaults to 30.
  A run the watcher kills prints nothing and records nothing, and would then repeat that silence on every poll.
- So a budget larger than that timeout allows is cut down to what fits instead of being refused.
  The cut is reported in the report line.
- A budget that is not a whole number from 1 to 120 is still refused outright.
- Counting behind and ahead fetches both histories into a temporary directory, so a home watching several large forks may need a larger budget and timeout.
  The fetches are read-only and no project clone is touched.
- A `fork drift:` wake names the project, the counts, and the upstream head or tag.
  Load the `fork-drift-sync` skill to dispatch the merge-commit sync ship, merge the green pull request, and run that project's existing rollout.

**Upstream sync merges**

`bin/fm-pr-merge.sh` reads this file to keep an upstream sync from being squashed.

- A GitHub pull request is an upstream sync when its repository is a fork listed here and its head carries commits of that fork's upstream branch that the pull request's base branch lacks.
  For a `release` trigger, the upstream's tags count as upstream history too.
- The branch name and title play no part, because sync pull requests have used several of each.
- The script reads both histories from a commits-only fetch at merge time.
- An upstream sync merges as a merge commit when no method is named, and an explicit squash or rebase is refused before anything is recorded.
- A pull request into a listed fork whose histories cannot be read is refused unless `--merge` is passed.
- A GitHub pull request into a repository not listed here, merged with no method named, is refused when it looks like a sync: its title or head branch says sync, or a commit headline merges another remote, an upstream, or another repository's URL.
  The refusal names this file and `--merge`, and a pull request with an explicit method merges as named.
- Every other pull request keeps the script's default merge method.

## Local copy drift

[`bin/fm-copy-drift-check.sh`](../bin/fm-copy-drift-check.sh) checks, once a day, the local copies this machine runs: the firstmate code root and every clone directly under this home's `projects/`.
It needs no configuration file, and each home checks only its own copies.

It reports two conditions per copy in one `copy drift:` line:

- `<copy> is <n> commits behind origin/<default>` means origin's default branch has commits the local default branch lacks.
  A copy that is only ahead of origin is not reported.
- `<copy> has an uncommitted change <n> days old: <file>` means the copy holds uncommitted tracked or untracked work whose oldest modified file is more than a day old.
  Ignored files do not count, and a younger change is not reported.

A copy that cannot be compared, for example because its fetch failed or it has no local default branch, is reported as such rather than read as current.
A copy without an `origin` remote is checked only for stale uncommitted work.
A current, clean copy raises nothing.

The check fetches each origin and changes nothing else in the copy: it never pulls, resets, stashes, or checks out.
Acting on a report is a separate decision.
A clone can be brought current through `bin/fm-fleet-sync.sh`, and uncommitted work belongs to whoever made it, so it is never discarded to quiet the report.

**Arm and disarm**

Arm the check once per home with `bin/fm-copy-drift-check.sh arm`.

- That writes `state/copy-drift.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake.
- `bin/fm-copy-drift-check.sh disarm` removes the shim, its trust binding, and the record.

**Timing**

`state/.copy-drift` records when the last sweep ran, and a sweep runs once its interval has passed.
Every sweep that finds drift reports it again, so a copy left behind or dirty is raised each day until it is resolved.

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_COPY_DRIFT_INTERVAL` | 86400 seconds | Time between sweeps. `0` sweeps on every run. |
| `FM_COPY_DRIFT_FETCH_SECS` | 15 | Bounds the fetches, which run in parallel, one per repository. |

The whole sweep must finish inside `FM_CHECK_TIMEOUT`, which defaults to 30, so a fetch bound that leaves less than five seconds for the local comparisons is cut down to fit.
A sweep that runs out of time reports the copy it did not reach.

## Practice drift

[`bin/fm-practice-drift-check.sh`](../bin/fm-practice-drift-check.sh) sweeps, once a day, every clone directly under this home's `projects/` whose origin is on GitHub, and reports where a repository has drifted from the checks kit's practices.
The kit lives in `config/practice-drift.json`, an optional local gitignored file that names its npm package and its GitHub repository.
See [`docs/examples/practice-drift.json`](examples/practice-drift.json) for a starting point to copy into local `config/practice-drift.json`.
Without that file, a sweep reports the missing configuration on one line.

The kit applies to a clone whose `package.json` depends on the kit package or is the kit itself.
Every repository is read for its open issues filed by `github-actions[bot]` carrying label `night-run`, `daily-tests`, or `daily-ci`, and a repository the kit applies to is also cloned shallowly at its default branch into a temporary directory and read for these practices:

| Key | Reported when |
| --- | --- |
| `kit-pin` | The kit pin is older than the kit's newest GitHub release. |
| `retired-workflow` | A workflow under `.github/workflows` is the retired scheduled whole-tree workflow or runs the retired whole-tree lint flag, so it is still waiting to be removed. |
| `author` | `package.json` names no author and no contributors. |
| `ci-wiring` | `checks-ci-wiring` from the newest kit release fails, and the report carries its failing headings. |
| `merge-methods` | The repository allows merge commits or rebase merges. |
| `runs-on` | The repository is private and sets no `CI_RUNS_ON` repository or organization variable. |
| `schedule-<name>` | The last completed scheduled run of workflow `<name>` on the default branch did not succeed, and the report counts the runs in a row. |
| `release-pr-<n>` | A pull request titled `chore: release` by `github-actions[bot]` open 7 days or longer. |
| `issue-<n>` | An issue by `github-actions[bot]` carrying label `night-run`, `daily-tests`, or `daily-ci` is open. |

A sweep prints one `practice drift: <repository>: ...` line for each repository with a new, changed, cleared, or unreadable finding, and nothing when no finding changed.
A cleared practice reads `<key> cleared`, and a closed issue or release pull request reads `<key> closed`.
An open issue prints once when first seen, and once more when it is 7 days old and no row in this home's backlog names its URL.
An open release pull request prints once it is 7 days old.
The backlog is read through `bin/fm-tasks-axi.sh`, and an unreadable backlog is printed as unreadable rather than taken as no row.

A read that fails, a clone that cannot be made, an unknown newest kit release, or a kit clone whose origin is not on GitHub is printed as unreadable on every sweep, never as clean.
Its recorded findings are kept, so a repository that becomes readable again with the same drift stays quiet.

The check only reads GitHub: it never posts, runs no project tests, and never touches a clone under `projects/`.
It installs the newest kit release with `bun` into its temporary directory to run `checks-ci-wiring`.
Acting on a report is a separate decision.

**Arm and disarm**

Arm the check once per home with `bin/fm-practice-drift-check.sh arm`.

- That writes `state/practice-drift.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake.
- `bin/fm-practice-drift-check.sh disarm` removes the shim, its trust binding, and the record.

**Timing**

`state/.practice-drift` records when the last sweep ran and what it found.
A sweep runs at the first check after the daily sweep hour, and the first check after arming sweeps at once.

| Setting | Default | Purpose |
| --- | --- | --- |
| `FM_PRACTICE_DRIFT_HOUR` | 15 | UTC hour of the daily sweep. |
| `FM_PRACTICE_DRIFT_BUDGET_SECS` | 25 | Bounds one sweep, whose reads run in parallel. |

The whole sweep must finish inside `FM_CHECK_TIMEOUT`, which defaults to 30, so a budget that leaves less than three seconds for judging the reads is cut down to fit.
A read that runs out of time is printed as unreadable.

## Day review

The day review is a short evening board for the captain: where the time and the API price went per finished task, the quality signals, three recommendations, lessons from repeated mistakes, and whether the last advice helped.
`config/day-review` is an optional local gitignored file holding `HH:MM` with an optional IANA time zone, such as `21:00 Europe/Moscow`.
When it is absent the review is due daily after 21:00 Europe/Moscow, whatever the host clock's zone.
A bare `HH:MM` uses Europe/Moscow.
The word `off` disables it, and a malformed file is reported once until edited.

Arm the check in the main home only with `bin/fm-day-review.sh arm`.
Second mates need no check of their own, because the main home's run reads them.
That writes `state/day-review.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it and turns its one line into a `check:` wake.
`bin/fm-day-review.sh disarm` removes the shim, its trust binding, and the due record.
The check stays silent while `state/.afk` exists.
The next review then covers the whole time since the previous one, up to a week.

Handle the wake by running `bin/fm-day-review.sh run`, then deliver the board path it prints with `lavish-axi`.
The run reads this home and every home in `data/secondmates.md`, local ones directly and remote ones through `bin/fm-on.sh <id> fm-day-review.sh collect`.
A home that cannot be read becomes a stated gap on the board rather than a failed run.
Durations come from the status records and `state/merge-on-green.log`, tokens from the Pi session logs, prices from list prices in `bin/fm-day-review.py`, and quality from the no-mistakes database.
A figure with no source, such as a model with no list price, is named on the board instead of estimated.
Output lands in `data/day-review/<day>/`: `board.html` links `full.html`, and `numbers.json` holds every figure.
`data/day-review/notes.json` keeps each day's advice so the next review can judge it per finished task, and `data/day-review/lessons.md` keeps the lessons with the days they were seen.
`run --force` builds a board before the scheduled time without marking the day done or recording advice.

## Review round monitor

A live no-mistakes run on a task of this home that reaches its third review fix round gives firstmate one `check:` wake naming the task, project, branch, and run.
[`bin/fm-review-round-monitor.sh`](../bin/fm-review-round-monitor.sh) counts the review step's auto-fix rounds read-only from the no-mistakes state database, resolved by `fm_nm_state_db`.

- `bin/fm-review-round-monitor.sh arm` writes `state/review-rounds.check.sh` and binds it with `bin/fm-check-register.sh`, so the existing watcher turns its one line into a `check:` wake.
- `bin/fm-review-round-monitor.sh status` lists this home's live runs with their round counts, read-only.
- `bin/fm-review-round-monitor.sh disarm` removes the shim, its trust binding, and the de-dupe record.

A run is live until it is `completed`, `failed`, or `cancelled`, so a run in a fixing or gate state still counts.
Each run wakes once, and its de-dupe entry is dropped when the run ends.
A database that cannot be read is reported once until it reads again.

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.

[`extension-bindings.md`](extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own exact command mechanics.

**Discovery and disabled behavior**

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, environment payloads, and Pi packages are never searched for extensions.

When the directory is absent, ordinary process-event commands perform only a bounded absence check, create no package or extension state, and preserve every built-in adapter path.

**Bind a trusted package**

Binding separates the package's own manifest from this home's explicit enablement.
`bind` performs these steps:

1. Validate the source package and compute every digest.
2. Copy the complete tree into the read-only content-addressed `data/extensions/packages/` store.
3. Perform the live handshake.
4. Atomically publish the enabled adapter-name subset.

The operator supplies trust and required consent facts, not hashes.

**Working state and cleanup**

`state/extensions/<extension-id>/` is created when binding performs its initial handshake and is that package's home-local working namespace for later verification and invocation.
`state/extension-invocations/` contains private host-owned invocation cleanup records, including residue retained after interruption; [extension cleanup safety](extension-bindings.md#executable-protocol) owns their recovery rules.

This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

Use an absent destination for the copy so the source identity remains inspectable and reproducible.

**Bind on a remote secondmate**

For a configured remote secondmate, keep the package at the controller and transfer it through the authenticated `fm-on` route:

```sh
bin/fm-extension.sh remote-bind <secondmate-id> \
  /absolute/controller/path/to/file-signal \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
```

The command serializes only the validated extension package, stages it below the addressed remote home's fixed extension staging root, binds it there, and prints transfer and binding digests.
Registration uses `bin/fm-on.sh <secondmate-id> fm-procevent.sh ...`.

**Retire a binding**

After retiring every registration with its printed owner token and handling every captured result, retire the enabled remote binding and its exact staged transfer together with `bin/fm-on.sh <secondmate-id> fm-extension.sh retire-transfer <extension-id> --if-transfer-digest <transfer-digest> --if-binding-digest <binding-digest>`.
For a direct local binding, use `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>` after the same process-event retirement and handling steps.

Both commands retain the retired identity reversibly and leave unrelated bindings and content-addressed installed packages unchanged.

**Register a completion source**

Register one file completion source with a path-safe source id and an explicit non-secret source configuration reference.
Credential values never belong in that reference, command argv, or a process-event result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the new registration's owner token and exact owner-matched retirement command.

**Classify and acknowledge results**

The source waits outside the conversational turn, and its completed result arrives through the existing process-event `check` path.
Classify the captured result through its immutable package identity with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with the existing `handled` command only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.
The [host-error capture and retry contract](extension-bindings.md#compatibility-and-failure-semantics) defines how repeated external host failures retain inspectable evidence while polling continues.

**Keep blocking sources out of the turn**

Never run the registered blocking source command directly in a conversational turn.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; built-in adapters retain their tracked `bin/fm-procevent-<adapter>.sh` commands, while an explicitly bound external adapter routes through the trusted host contract above.

`bin/fm-procevent-lavish.sh` is the first built-in adapter and wraps the published `lavish-axi poll` interface plus `lavish-axi reply` when the installed version supports synchronous reply acceptance.

**Open the Lavish artifact first**

Before arming any Lavish source, open its artifact with `lavish-axi` so the saved session identifies the board's server; reply and poll attempts derive their host and port from that session and refuse missing or invalid session evidence before posting or consuming a staged worker reply.
`arm` looks for that open session before registering and refuses with the missing `lavish-axi <artifact>` step, so a board that was never opened never prints `registered`.
`arm` records the board's Lavish state directory in the registration, so a listener restart or a later re-arm reaches the board's own server whatever the restarting environment sets.
The recorded directory is `LAVISH_AXI_STATE_DIR` when set, otherwise the directory the board's existing registration recorded, otherwise `~/.lavish-axi`.
A registration with no recorded directory keeps using `LAVISH_AXI_STATE_DIR` or `~/.lavish-axi`, so its owner arms a board served from another state directory once with `LAVISH_AXI_STATE_DIR` set to record it.

**Retry interrupted Lavish polls**

That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times with poll starts at least 5 seconds apart, so an internal retry never reaches the runner as a captured result.
This start-to-start governor is a no-op after a normally blocking poll but caps an immediately returning poll under the shipped defaults independently of the owner lease and registration launch pacing.

Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 1 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so retire the source, then arm it again to adopt this retry policy.

### Crew-hosted Lavish review boards

**Arm and confirm a listener**

A live task that hosts a Lavish board owns its listener, so firstmate must never arm that board.
A board a sandboxed worker declared with `needs-decision [key=board-handoff]` but never opened has no listener yet, so firstmate opens and arms it with `bin/fm-lavish-board-handoff.sh <board> --for <task-id>` instead of widening the sandbox.
After opening the artifact as required above, the worker arms it with `bin/fm-procevent-lavish.sh arm <artifact.html> --for <task-id>` and never runs `lavish-axi poll` itself.

`arm` prints `armed` only after the process-event owner confirms this registration generation's listener is running, and otherwise returns nonzero without that line.

- The confirmation is a live claim, or a launch stamp that advanced without its run ending with no result, judged when the window bounded by `FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` closes, and a failed confirmation retires a source that never started unless `retire` refuses because something may still own it, in which case the registration stays for `reconcile` or a human.
- An earlier registration's listener that releases the board inside the confirm window lets the new registration start, and `arm` then reports `armed` as usual.
- When a live listener from an earlier registration of the same board still holds it when the window ends, `arm` exits zero with `still-listening` instead of `armed`, because that earlier listener keeps serving the board and the new registration takes effect only after the source is retired and armed again.
- The arm is refused unless that task id has valid, identity-matching endpoint metadata, because a board whose owner has no endpoint would collect feedback nobody can be told about.

**Acknowledge a round by re-arming**

The registration persists as one task-owned source record, while each captured nonterminal round remains open until the worker re-arms and the existing handled marker acknowledges that round.
Re-arm acknowledges that round and registers the next listener: the board is armed once while no record exists, and a further arm by the same owner is refused unless an unacknowledged nonterminal round is waiting, so an open round is never replaced before its owner acknowledges it.

**Post an agent reply**

Re-arm never acquires, releases, or hands off the source claim.
It may carry `--agent-reply-file <path>`.
With lavish-axi 0.1.80 or newer, the reply is posted through `lavish-axi reply` under the source lock only after the arm passes its endpoint, ownership, and pending-round checks, and the server's acceptance is awaited before the listener is registered or armed.
An arm refused for endpoint, ownership, or pending-round eligibility never posts the reply, and a failed or timed-out reply stops the arm before it registers a listener or acknowledges the round, so the worker cannot hand the board back as ready and can retry the same arm.
If Lavish accepts the reply but the local registration then fails, retrying the arm posts that reply again; this rare duplicate is a known, benign limitation.

Older compatible Lavish versions keep the prior behavior: the reply is staged into the listener and sent through `poll --agent-reply`, which cannot confirm acceptance before its long-poll returns.
That compatibility path does not provide the synchronous handoff guarantee: a crash after the listener consumes its staged reply but before its poll posts it can lose that round's reply.
Only a version probe that confirms an older compatible release selects that path.
When `lavish-axi` is missing, its version cannot be read, or it is below the board floor, a reply-carrying arm fails without posting or registering a new listener; the worker's original reply file remains available for retry.
The Lavish version floors and feature probe are owned by `bin/fm-bootstrap.sh`.

**Deliver feedback to the worker**

- The captured result is stored with immutable task-owner routing evidence and delivered directly to that task's steering inbox, without a firstmate `check` wake for the captain's words while the owner's agent is running.
- When the doorbell finds the owner's agent exited or its endpoint missing, the same capture is also published as the ordinary `check` wake and the note is marked as already surfaced, so firstmate acts when the board is answered instead of when the steering inbox later escalates the unread note.
- The doorbell rings only when that idempotent write creates a fresh inbox record; filing the note into `handled/` is the worker's own acknowledgement of the delivery, so a later reconcile never moves an already-filed note back into the active inbox or re-rings its owner, and re-delivery of a note still open in the inbox is left to the steering inbox's own re-ring ladder.
- A task-owned source with an unhandled capture is not relaunched, so delivery failure cannot consume a round and start another poll.
- That record is the only ownership evidence there is, so while any captured round of it is unacknowledged every retirement path refuses - the runner's own terminal retirement and an explicit `retire` alike - and the refusal names the acknowledgement that releases it.

**Conclude a terminal round**

- A terminal result, including `session_ended`, an empty End, or missing, is delivered to the owner with an explicit stop-and-conclude instruction and is never auto-rearmed.
- That round keeps the board with its owner: the source record is not retired while the terminal capture is unacknowledged, so no second armer can take the board, and acknowledging it with `bin/fm-procevent.sh handled <source-id> <sequence>` is what concludes and retires it.
- That conclude retains the registration it is retiring, removes it, then records the acknowledgement and restores the registration if that record cannot be written, so a failed conclude never leaves the round open with its owner gone.
- An interruption between those two durable steps leaves the board unregistered with its terminal round still open, which nothing relaunches and the same `handled` call finishes.
- It concludes only a round that is still open, so a repeated acknowledgement of an already-closed round reports `already-handled` and never touches whatever registration holds the board by then.

**Ownership and recovery**

- A second armer is refused with the current owner named, and the source list derives `listening`, `round-open`, or `dead` from the claim and handled captures without a second ownership record.
- If the hosting worker cannot be recovered, relaunch a worker to re-host first; guarded firstmate adoption is an explicit last resort only after the old claim is proved dead.
- The cross-home gap between worker rounds remains an accepted residual until lavish-axi's exclusive listener lands.
- The interim crew instruction emitted by `bin/fm-brief.sh` points workers at this arm-and-acknowledge contract.

**Register deterministic condition and action watches**

The `when` adapter (`bin/fm-procevent-when.sh`) registers a deterministic condition and action once.
Its blocking child polls the condition without waking firstmate.
A stable true fires the action at most once.
One terminal outcome is then durably captured and published as a wake, which remains eligible for re-announcement until handled.

The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs, and that binding is reloaded from disk immediately before each fire rather than trusted from when polling started.
A repo update that fast-forwards an in-repo action's bytes in place would otherwise desync every already-armed watch's trust binding with no tampering involved; `bin/fm-procevent-when.sh rebind-all` re-hashes and republishes the binding for every registered watch whose action lives under `FM_ROOT`, including one already polling, so it keeps firing across such an update instead of being refused on its next fire.

Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

**Wake on orc-dash alert events**

The `orc-dash` adapter, `bin/fm-procevent-orc-dash.sh`, turns each line `orc-dash alerts --json` prints into its own durable `check` wake, whose captured result is that alert event unchanged, unless the adapter's `silent` command judges the alert deterministically routine and records it with no wake.
A home arms it once with the configured orc-dash command, which defaults to `orc-dash` and is stored in the registration.
The stream runs in a detached tap that outlives each runner, so orc-dash keeps its episodes and quiet clocks between alerts instead of refiring them.
The tap stops when no runner has polled it for `FM_ORC_DASH_TAP_IDLE_SECONDS`, 1800 by default, or when its registration is gone.
A poll window that sees no alert lasts `FM_ORC_DASH_POLL_WINDOW_SECONDS`, 300 by default, and the runner then polls again under the same claim.
Alert events never end the source.
A stream command that exits by itself produces one terminal stopped result carrying its exit code and stderr tail.
Firstmate records its judgment of an alert with the adapter's `verdict` command, which appends to the orc-dash verdict record the dashboard panel reads and then acknowledges the result.
That record and every alert rule belong to orc-dash, which knows nothing of firstmate, and the adapter's `--help` owns the record's path and line shape.
A runner killed after an event left the spool and before its durable capture loses that one event, and a tap restarted after it stopped starts every orc-dash rule fresh.

**Capture and publish results**

This section is the single owner of the runner's operating contract.

- Process-event commands resolve the state root to its physical directory before validating it and deriving paths, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target directory remains refused.
- Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
- By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
- The self-announcing adapter exception and its fail-safe ordering are defined below.
- The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
- A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
- A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.
- By default, a runner releases its claim after one poll; an adapter that opts into `relisten` keeps that runner and claim across empty waits and captured results, adopting a replacement registration only when the registered command is unchanged and the claim still belongs to it.
  A failed relisten check releases the claim; the runner never refreshes its own home lease.

**Reconcile sources**

Discovery is never a timer.
Each registered source has its own child process blocking on that source.
On every cycle, the watcher's `reconcile`:

- Republishes every captured result without a durable handled acknowledgement, regardless of earlier publication.
- Restarts a source whose owner is gone.
- Stops this home's runner if its registration disappeared unexpectedly.

In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

**Suppress only adapter-confirmed no-op results**

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.

- Before publishing, the runner asks the immutable captured owner through the built-in `silent` command or external `result.silent` operation and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
- The task-owned terminal exception is evaluated first, so an empty terminal board round goes to its owner's steering inbox for the required conclusion instead of entering this generic silence path.
- A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
- For built-ins, silence remains independent of the keyed-answer feed below: suppressing an announcement never suppresses the captain's own answer.

**Lavish silence rules**

- For Lavish that verdict covers two shapes - a session the adapter classifies `ended` that carries no queued content block at all, which is a review surface closed with nothing said, and `browser_disconnected` (classified `disconnected`), which carries no answer while the session remains open.
- Any recognized top-level `prompts` or `feedback` block counts as content regardless of its declared count, and a malformed header makes the result indeterminate rather than empty.
- A `Send & End` close carrying the captain's answer arrives as `status: feedback` with `session_ended`, so it classifies `feedback` and is announced unchanged, as is any `ended` result that still carries content, and every `waiting`, `missing`, `unknown`, or unreadable result.

**Retire terminal sources**

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture, the runner asks the immutable captured owner whether the result is terminal.
It uses the built-in `terminal` command or external `result.terminal` operation.
Under the default ordering, this happens after the initial `check` publication.

- Exit 0 retires the registration.
  The exception is a task-owned board, whose owner must first acknowledge the round as defined above.
- Retirement drops only the exact registration generation captured by the claim.
  Under one source boundary, it releases that claim only after removal succeeds.
- A missing command, an error, or any other exit keeps the source armed.
  An adapter with no notion of ending needs no change.

- A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
- Any registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending; replacement becomes eligible only after that generation is proved gone or its terminal retirement completes.
- A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work.
- For ordinary sources, explicit `retire` stays the supported and idempotent path afterwards; a task-owned board instead refuses `retire` until its owner concludes the open terminal round with `handled`.
- For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

**Apply built-in results automatically**

Applying a captured result through code is a built-in adapter seam, and some built-in results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the built-in adapter apply and acknowledge its own result.

That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.

**Adapter-controlled announcement order**

The built-in `bin/fm-procevent-<adapter>.sh self-announcing` command declares announcement order:

| Response | Runner behavior |
| --- | --- |
| Exit 0 | The adapter declares that every result its autohandle fully applies is announced through its own durable downstream channel; the runner applies first, then publishes a `check` wake only for results still unhandled. |
| Any other response | Keep strict publish-before-apply ordering; autohandle runs only after this capture's own wake was successfully appended to the durable queue. |

The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.

**Feed keyed captain answers**

Keyed captain answers from built-in adapters use one more seam of the same kind, and the runner still decides nothing about them.
Some built-in sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.

- A built-in source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
- A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
- The built-in adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future built-in answer source needs nothing here beyond an `answers` command and a binding.

**Reconcile selections and handling boundaries**

- The reserved Reconcile selection uses the parallel optional `reconciles` adapter command and binding-verified `reconcile-requests` intake rather than entering keyed answers; [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md#reconcile-re-check-reality-never-a-blind-close) owns those semantics.
- Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer or request is transcription while acting on it is firstmate's judgement.
- An unbound built-in source, a built-in adapter without the corresponding command, and a failure on either side all leave the capture untouched and still announced.
- External binding responses never enter either authority-bearing intake.

**Machine-wide source ownership**

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.

- Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
- Each claim binds its caller-reported home and runner PID to a process identity, unique claim generation, exact registration-file generation, and resolved state-root identity.
- Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
- A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.

**Prove ownership before stopping a runner**

- Every stop proves ownership before its first signal: the live runner's recorded process identity must match and it must still lead its process group.
- Once that stop has proved ownership and sent TERM, its own escalation to KILL checks only whether the proved group still has members; it does not re-read the leader's identity or group membership, which can change or become unreadable as TERM ends the leader.
- This proof belongs only to that stop's own escalation and cannot authorize another caller that encounters an unproved group.

**Recover orphaned claims**

A stale claim whose process group still has members is one `reconcile` never displaces, and the two shapes it comes in recover differently.
`reconcile` preserves such a claim without signalling the ambiguous group or starting a replacement: the group check probes the runner's own process group, which contains its polling source child, so surviving members can mean that child is still attached to the session the source collects from, and a replacement would put a second destructive poller on it.

`list` reports both shapes as `orphaned`.

**Reused PID with surviving group members**

When the recorded pid is alive under a different identity but the group still has members, the claim boundary itself does not consult the process group.
In this case, `bin/fm-procevent.sh start <source-id>` reclaims the claim only if it can tidy the dead generation's reservation records.
Otherwise it refuses with `cannot claim source`.

Tidy-up is waived only for a generation proved gone.
This generation does not meet that condition.
That hand-run command is the recovery path, taken by someone who has checked that nothing is still polling the source.

That asymmetry between the automatic path and the deliberate one is the design rather than an inconsistency, and it is not a claim-level invariant: nothing below `reconcile` enforces it.

**Dead leader with surviving group members**

If the leader died from anything other than the stop's own signal and its group still has members, `start` does not reclaim the claim.
It reports `already owned` and changes nothing.

`retire`, `reconcile`, `sweep-home`, and the guard all refuse the surviving group permanently, so the source stops listening.
Recovery there is a human verifying whether the dead runner's polling child is still attached to the source; once that process group is empty the generation reads as gone and the next `reconcile` reclaims the source on its own.

Nothing automatic signals that group, and whether it may ever be signalled remains an open decision; the repaired guard does not close this gap.

**Report stranded claims**

The first `reconcile` that strands either kind of claim generation publishes a durable `check` wake.
It names the source and the recovery step:

- For a reused pid, the `start` command.
- For a leaderless group, the check to make.

Later cycles stay silent for the same generation.
A genuinely new stranded claim announces again.

**Reclaim a generation proved gone**

Reclaiming a generation that IS gone is not gated on tidying anything that generation left behind: its capture-reservation records, its staging file, or the registry directory a claim recorded for them.
Every one of those is keyed by claim token and every replacement claims a fresh one, so a leftover that can no longer be located or removed - a state-root identity a claim recorded before its home was re-created, or a recorded registry directory that no longer resolves to a directory - is stale bytes rather than an ownership hazard.

Making any of them a precondition is what leaves a provably dead runner owning its source permanently, because none of those conditions clears on its own.

- Ordinary release and reclamation still attempt reservation cleanup and require it unless both owner staleness and whole-group absence prove the generation gone.
- The narrow live-owner terminal-self-retirement path also attempts cleanup but tolerates its own still-in-flight reservation, which the runner removes on the normal end-of-capture path; exact home, PID, and claim-token ownership remains mandatory before the claim is released.

**Stop refusals and residual races**

- If identity cannot be established before the first signal, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
- A live PID whose identity no longer matches is refused before the first signal.
- Identity and process-group verification cannot be made atomic with signalling in portable shell: the reaper signals only a target it has verified as the recorded generation, but PID and group reuse remain possible in the narrow interval between verification and the signal.
- Launch pacing is the primary host-wedge protection; watchdog cleanup is a backstop.


- Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
- If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
- If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
- The sweep retires local registrations and machine-wide claims whose recorded state-root identity matches that home's resolved state root through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
- Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.

**Recover from unsupported manual deletion**

Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

The owning-home lease below bounds how long such an orphan can run, but it is a backstop, not a substitute for the supported path.

**Home lease and its limits**

A runner is bound to the HOME that owns it, not to the one session that armed it.
That granularity is deliberate: a persistent source is meant to outlive the turn and the session that armed it, so binding a runner to its arming session would stop exactly the sources this mechanism exists to keep running.

Any activity in the same home refreshes the lease, so a replacement session, another watcher, or an ordinary inspection command keeps a runner of that home alive; a runner whose SOURCE is no longer wanted in a live home is stopped by reconcile when that source is retired, independently of the lease.
The lease is therefore the backstop for a home that is GONE - the torn-down test sandbox this change exists to bound - and not a per-session ownership check.

KNOWN LIMIT: while any activity continues in a home whose original owning session has ended, that activity refreshes the lease and a runner of that home keeps running until its source is retired or the home goes away.

**Keep and guard the lease**

Detaching a runner into its own process group is what lets a persistent source outlive the turn that armed it, and on its own it is also what lets a runner outlive its whole home: reparented to init, it keeps its blocking child - and every process that child spawns - running with nothing left to reap it.

- So a home's process-event state carries a lease that registration, attached start, reconciliation, acknowledgement, listing, and detached launch by a non-runner caller through `reconcile` or `ensure-listening` refresh, and the watcher's reconcile cycle is what keeps it fresh in a live home.
- An attached public `start` continues refreshing the lease while its caller remains attached.
- Each runner fails closed unless a small guard starts successfully beside it in a separate process group.
- That guard accepts the lease only while the state root retains the device/inode identity recorded by the runner's claim, and initiates the verified stop after two consecutive reads cannot prove that identity and lease freshness, so one unreadable read cannot kill a live runner.
- Those two reads are spaced half a check interval apart, so the pair the debounce requires completes inside one check interval instead of costing two of them.

**Detection and stop timing**

For a runner whose ownership can still be proved, the nominal detection bound is the lease plus one check interval.
The verified stop then runs within its own grace period.
The lease age is compared in whole seconds, so the configured lease is honoured until that age reads one second past it.

Scheduling delays or failed inspection and signalling can extend the whole bound.
That grace is a ceiling rather than a delay every stop pays: two seconds for the ordinary signal and two more for the forced one, spent only by a group that outlives the signal it was sent, which is why a healthy runner's stop completes in a fraction of a second.

The group signal reaches the blocking child and everything under it exactly as retirement does.

**Prevent accidental self-refresh**

- A runner exports the inherited `FM_PROCEVENT_IN_RUNNER` marker and every lease refresh is skipped under it, so a runner and its ordinary children do not certify their own owner, and the next reconcile in a live home simply starts a replacement runner.
- That no-self-refresh rule is CONFUSED-AGENT-GRADE, the same deliberate captain-decided grade `bin/fm-lease-lib.sh` documents: it stops the accidental case this boundary exists for, an orphaned or test-scaffolding source tree that would otherwise keep its own owner alive.
- A source that DELIBERATELY strips the marker from its environment can still refresh the lease, so adversarial-grade unforgeability is explicitly out of scope here and tracked as separate follow-up design work.
- Scope is the owning state root and one runner generation, never a script or process name, so a live source in another home is untouched: that home refreshes its own lease.

**Lease and launch pacing settings**

| Setting | Default | Range | Purpose |
| --- | --- | --- | --- |
| `FM_PROCEVENT_OWNER_LEASE_SECONDS` | 600 | 1..86400 | How long a runner continues without activity in its owning home. |
| `FM_PROCEVENT_OWNER_CHECK_SECONDS` | 15 | 1..3600 | Guard detection interval; it reads the lease and recorded state-root identity twice per interval, half an interval apart, so both debounce reads fit inside one interval. |
| `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` | 1 | 1..3600 | Minimum time between consecutive launches of one registration generation's stored command; bounds immediately returning sources during the lease window. |

The generation's first launch is immediate, later launches share its monotonic pacing timestamp, a timestamp from before a reboot is treated as expired, and replacing the registration starts a fresh pacing generation.

**Confirm detached launches**

`FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` (default 3, range 1..600) bounds how long `reconcile` waits for the runners it just started to prove they are running: never less than the configured value, and at most one second more, because the wait is measured on a whole-second clock.

- Starting a runner is detached and its errors are not visible to the caller, so `reconcile` reports a start only after the source is observed owned or its launch-pacing stamp has advanced or appeared, and reports every unconfirmed launch as `failed=` and a non-zero exit instead.
- Both signals are durable evidence a runner claimed: ownership is the only evidence a runner still blocked on its source ever shows, and the stamp - written after the claim and before the source command runs, and removed only by registration replacement - covers a runner that claimed, ran and exited between two polls.
- A healthy launch therefore confirms on the first poll and the window only bounds a launch that has not yet proved itself - one that died before claiming, or one merely too slow to claim inside the window; confirmation cannot tell those apart, and a launch that proves itself on a later cycle closes its failure episode without a retraction wake.
- Confirmation takes the source lock only once a claim exists, because a runner needs that lock to claim and polling it earlier would starve the launch being confirmed.
- All of a cycle's launches share one window, so a home full of sources that cannot start costs the same bounded wait as one.

**Keep confirmation below the watcher interval**

Keep this window well below `FM_POLL`.
`bin/fm-watch.sh` runs `reconcile` once per supervision cycle, so a source that cannot start makes every cycle wait up to the confirm window before the rest of that cycle runs.

Raising the confirm window lengthens every supervision cycle and delays wake delivery by up to that much.

**Report launch failures**

A detached launch that never confirms is reported as `failed=` with a non-zero exit on every `reconcile`, rather than counted as `started` and retried silently as though it were healthy, so a wedged source stays visible instead of presenting as armed.
The `failed=` count reaches only the command's caller because `bin/fm-watch.sh` discards `reconcile` output and exit status.
For that reason, `reconcile` also publishes a durable `check` wake once per failure episode, with key `procevent:<id>:launch-failed:<registration-identity>-<episode-nonce>`.
Later cycles stay silent for that episode until a launch confirms.
A later fresh failure gets a fresh key, because the watcher never re-surfaces a key it has already surfaced.

- The announcement changes nothing about the launch: `reconcile` keeps relaunching the source every cycle exactly as before, and nothing is retried differently, throttled, or recovered from that signal.
- The wake reports only the observed failure: the launch did not prove that it took the claim within the window.
- If the failure persists, inspect the source command and adapter binary named in the registration.
  The wake names both, along with the attached `bin/fm-procevent.sh start <source-id>` command that reproduces the refusal on stderr.
  The detached launch discards that output.
- A later cycle that finds the source owned ends the episode automatically.
  A runner that was merely slow to claim needs no operator action.
- A source stranded on a claim nothing may automatically displace is announced the same way, once per stranded claim generation, as described above.
- `bin/fm-watch.sh` surfaces both under their own headlines - `process-event source stranded` and `process-event source failed to start` - rather than as a captured result.

An extension invocation cleanup refusal prevents a replacement launch and increments `uncertain=` instead of `failed=`.
It also publishes one durable wake per source failure episode using the `launch-failed` key family and `process-event source failed to start` headline.
The payload points to the extension host's cleanup diagnostic in the source's home and effective state root, without copying package diagnostics into the wake.
Reconciliation preserves the registration and retries cleanup on later cycles.
Successful reconciliation cleanup, an attached start that acquires the claim, or reconciliation observing a live owner clears the cleanup announcement marker, so another refusal on the same registration receives a fresh wake key.
Retirement removes the marker as well.

**Reject unusable settings**

A value this command cannot use is refused by name before anything is launched, the same way `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` and `FM_PROCEVENT_MAX_OUTPUT_BYTES` are refused, so a mistyped window can never present as a fleet of sources that cannot start.
`bin/fm-watch.sh` validates the same value when it arms and refuses to arm on an unusable one, naming the variable and the range: under a running watcher that refusal would otherwise repeat on every cycle into a discarded stdout and leave the whole home disarmed while presenting as supervised, whereas a watcher that will not arm is loud through the liveness guard.

**Limit captured output**

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

**Durability guarantees and limits**

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.

- `bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
- Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
- The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
- The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
- Never describe this path as at-least-once, no-loss, or lossless.

`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Inbox configuration

The model-backed `ask` subcommand reaches a paid API, so no region, model ID, or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, and the matching environment variable overrides it for a single run.
A missing required value refuses with the path to write.
See [the inbox contract](inbox.md) for command behavior and privacy.

| File | Environment | Holds |
| --- | --- | --- |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh ask`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model ID, required by `ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile, optional. |

Each file is read as its first line that is not blank and not a `#` comment.

## Environment variables

Runtime tuning via environment variables (defaults shown):

Pi worker model-stream observation is optional.
Set `FM_STREAM_SILENT_MAX_SECS=300` before launching workers and their watcher to inspect a foreground request that stops producing substantive content for five minutes.
It must be present in the environment that launches both the worker and its watcher: a value only the watcher sees, such as one added only to `config/watch.env`, instruments no worker, so a worker spawned without it records no stream evidence and keeps the general busy bound.
The interval includes foreground request preparation; the existing wedge delay and declared-wait deferrals still apply before an inspection notification, and no worker is interrupted or restarted.
Background provider/cache warming is excluded, and observation closes at assistant message completion, tool execution start, or settled idle state.
Changed nonempty text, thinking, or tool-call content refreshes stream evidence at most once per second and supplies a separate progress anchor for the general busy bound; empty or unchanged snapshots do not.
New instrumentation is version-gated to Pi 1.2.0 and takes effect on launch or relaunch; stream observation stays off on every unverified version until verified, with a warning and the general busy bound retained.
Observation writes have a five-second subprocess deadline and one-second termination grace; a failed write reports an instrumentation warning while Pi continues.
Unset, empty, zero, negative, malformed, and values longer than nine decimal digits disable the option, including its separate normal-model progress anchor.
`bin/fm-busy-lib.sh` owns stream evidence and ordering; the [real-Pi verification guard](verification/runtime-backends.md#pi-worker-model-stream-observation) refreshes the vendor evidence.

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity readers, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; only herdr is accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
FM_TASK_ID=             # internal task-worker marker fm-spawn.sh delivers to ship and scout environments, never set by hand; bin/fm-test-run.sh refuses to execute in the repository primary checkout while it is set
FM_TASK_INBOX=          # internal: absolute path of the task's steering inbox (state/<id>.inbox) that fm-spawn.sh exports into every ship, scout, and secondmate launch, never set by hand; the steering doorbell names "$FM_TASK_INBOX"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_SESSION_START_QUEUED_LIMIT=10   # blocked and ready queued backlog rows each listed in the session-start digest; held rows are never bounded, done rows and in-flight rows with a state/<id>.meta are never listed, and each omission prints its count and the command that lists the rest
FM_SESSION_START_ENDPOINT_TIMEOUT=10   # seconds bounding each per-task endpoint liveness read in the session-start digest (bin/fm-session-start.sh); nonpositive or invalid values fall back to 10; a read that hits the bound or dies becomes that task's own `endpoint: error` line and the digest continues
FM_BACKLOG_ROW_TIMEOUT_SECS=10   # seconds bounding each backlog row read (bin/fm-backlog-transition-lib.sh) and the tasks-axi replay of each captain-hold Done-archive row (bin/fm-captain-hold.sh, which stops with 124 on a replay timeout); the archive scan itself is not bounded; nonpositive or invalid values fall back to 10; the first backlog read bound hit latches the sweep so later reads return immediately, each still naming its own item
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the deferred inactive-outcome scan plus network checks, including the lock waits the worker makes before them; hitting it prints an actionable NETWORK_CHECKS line, and a lock a live process still holds at the deadline ends the worker with a failed-rerun record (publication and delivery are bounded by FM_SESSION_START_TIMEOUT the same way)
FM_SECONDMATE_CONVERGENCE_TIMEOUT=75   # shared per-mate deadline in seconds for remote startup tracked-file sync and inheritance push; bin/fm-bootstrap.sh owns its scope and timeout handling
FM_REMOTE_INHERIT_PUSH_JOBS=4   # inherited items one remote inheritance push sends at a time, 1 for strictly one after another; capped at 16 (bin/fm-remote-inherit-push.sh)
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_TASKS_AXI_CHECK_REASON=   # internal one-hop handoff of the reason behind that verdict (compatible, version, or the capability probes the build fails); consumed when bin/fm-tasks-axi-lib.sh is sourced, and it keeps the OUTDATED requirement text from repeating the probes
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HOME_SUMMARY_INTERVAL=300   # seconds before a live watcher refreshes this home's state/home-summary.json even without a status signal; invalid or zero values use 300
FM_HOME_SUMMARY_TIMEOUT=60     # seconds bounding the complete best-effort home-summary refresh, including lock acquisition, validation, atomic publication, and worker-side failure logging; invalid or zero values use 60
FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES=65536   # approximate size cap for state/.home-summary-refresh.log before it is trimmed to the newest 200 lines; invalid or zero values use 65536
FM_HOME_SUMMARY_FAILURE_REPORT=2   # recorded publication failures since the ledger's own last publication before session start reports a HOME_SUMMARY line; invalid or zero values use 2
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10   # seconds bounding each local per-task current-state read inside bin/fm-fleet-snapshot.sh; remote endpoint liveness is not probed on the snapshot path
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # maximum local tasks whose current-state and endpoint observations are collected concurrently during snapshot composition
FM_SNAPSHOT_BUDGET=5                # one total seconds budget for all concurrent remote home-ledger reads
FM_SNAPSHOT_CACHE_DIR=$FM_HOME/state/secondmate-summary-cache   # private parent-side cache of successfully fetched remote home ledgers
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=14  # floored elapsed-day threshold at which an undated captain hold (no hold-until; age from its UTC hold-set timestamp, falling back to since for legacy unstamped holds) is projected as a Charted Next gate instead of a live Captain's Call; 0 applies once the computed age is non-negative
FM_RECONCILE_REQUEST_MAX_BYTES=1048576   # maximum captured Bearings or fleet snapshot accepted for durable reconcile-notify request publication
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also requests an immediate scan in the deferred worker
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle endpoint; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_TASK_INBOX_BUSY_MAX=2      # consecutive busy-deferred due polls before a stuck-busy stale wake; 1..999999999, at most 9 decimal digits, otherwise 2; policy: bin/fm-task-inbox-lib.sh
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script; a cut check wakes with its output so far plus `timed out after <seconds>s`
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_PROCEVENT_OWNER_LEASE_SECONDS=600    # how long a source runner keeps going with no activity in its owning home; 1..86400
FM_PROCEVENT_OWNER_CHECK_SECONDS=15     # a runner guard's detection interval, read twice per interval; 1..3600
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1     # minimum interval between launches of one registration generation's source command; 1..3600
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=3   # how long reconcile waits for the runners it started to prove they are running; 1..600, keep well below FM_POLL
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CODEX_WATCH_CHECKPOINT_AWAY=3600  # requested away checkpoint bound on a home that runs the supervision host; longer of this and attended bound, capped at 27000
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh, and per state-database run-inventory read behind a capped AXI overview
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # plain runs-ledger rows scanned for fallback attribution; does not change the CLI's AXI overview window (selection owner: bin/fm-nm-run-lib.sh)
FM_TEARDOWN_NM_RUNS_LIMIT=200  # recent no-mistakes run rows scanned to prove an unresolved-head parked run belongs to teardown's task
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by watcher triage: the working/paused classification, the wedge timer's parked-gate wait evidence, and its opt-in validating-run deferral
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FM_DISPATCH_PROVIDER=   # typesafe, openrouter, systemone, or openai; absent preserves the original typesafe key gate ("Typed dispatch resolution")
FM_DISPATCH_MODEL=      # explicit model for the selected provider; required for openrouter, systemone, and openai
FM_DISPATCH_BASE_URL=   # http(s) base of a System One-compatible host; required for systemone
FM_DISPATCH_API_KEY=    # optional systemone key; absent sends no Authorization header
# typesafe key is not a .env entry; config/bws-typesafe-secret-id names its Bitwarden secret
TYPESAFE_BASE=          # optional TypeSafe base; see "Typed dispatch resolution"
OPENROUTER_API_KEY=     # OpenRouter dispatch key, from the environment, .env, or the declared credential source
OPENAI_API_KEY=         # OpenAI dispatch key, from the environment or .env
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # grace seconds for missing or nonnumeric lock-owner PIDs (minimum 2s); dead numeric PIDs, and live ones whose start time (or, for the watch lock, process identity) no longer matches the holder's recorded value, have no age grace
FM_GUARD_GRACE=300      # beacon freshness threshold for guard verdicts, arm health checks, and the primary turn-end guard; see docs/turnend-guard.md for model-aware exceptions
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded hook-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_STOPFAILURE_REWAKE_COOLDOWN=300   # minimum seconds between StopFailure-driven exit-2 continuations; nonnegative integers accepted, invalid or empty values use 300; pacing mechanics: bin/fm-claude-stop-autoarm.sh header
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, an open Stop auto-arm generation claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=300   # fresh-child confirmation backstop in seconds; default max(FM_GUARD_GRACE, 10), or max(FM_GUARD_GRACE, 30) on Git Bash/MSYS; positive overrides may be shorter; expiry still waits for safe interruption (docs/watcher-continuity.md "Startup interruption window")
FM_ARM_SUCCESSOR_CONFIRM_TIMEOUT=10   # successor confirmation seconds; fm-watch-arm defaults to 10, or 30 on Git Bash/MSYS; Claude Stop auto-arm's outer successor-status wait defaults to 30 on all platforms, plus slack
FM_WATCHER_STARTUP_LOCK_BOUND=60   # per-lock startup wait in seconds for downtime publication during singleton steal and startup recovery transitions; later poll-time recovery checks remain blocking; independent of the arm backstop
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm follows an attached watcher cycle (bin/fm-watch-arm.sh header)
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows; independent of the fresh-child arm backstop
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows; independent of the fresh-child arm backstop
FM_PI_BRANCH_SETTLEMENT_TIMEOUT_MS=60000   # milliseconds the Pi watcher extension waits for a branch-accepted wake to settle before delivering that wake to main; the late branch outcome still settles on its own
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCH_EXTENSION_LOG_KEEP_LINES=0   # opt-in Pi extension diagnostic log (state/.watch-extension.log); unset, empty, non-numeric, zero, or negative disables logging, a positive value keeps that many newest rows; logging never changes supervision behavior
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE if set, else the poll-derived grace (docs/turnend-guard.md "Guard grace and the poll cadence"); seconds before a fresh arm refuses a live holder's stale beacon (attached arms: FM_WATCHER_STALL_BOUND)
FM_WATCHER_STALL_BOUND=       # live-holder stall bound; default and arm/re-arm behavior: docs/turnend-guard.md "Guard grace and the poll cadence"
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_WATCHER_CLEANUP_LOCK_BOUND=   # optional watcher EXIT marker-lock wait; default and validation: docs/watcher-continuity.md
FM_TURNEND_CHURN_ABSORB_SECS=900   # longest one endpoint's bare turn-ends may be deferred on pane-churn evidence alone; only consulted when config/turnend-churn-absorb is present
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading declared-wait status verb; bin/fm-classify-lib.sh owns its meaning and legacy external-wait label; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates, unless that pane's own worker declared a wait that has not elapsed, its task is held for the captain in the backlog, or, where config/wedge-defer-worker-wait arms it, its worker's own newest line is a still-open `blocked:` or `needs-decision:` line, or, where config/wedge-defer-parked-gate arms it, that pane's crew is parked at a validation gate awaiting the supervisor's decision on it that the crew raised under that run's key and nobody has answered yet, or, where config/wedge-defer-validating arms it, that pane's crew has an attributed no-mistakes run whose step is running or fixing, any of which takes the FM_PAUSE_RESURFACE_SECS recheck below instead; stale panes whose crew is not provably working surface immediately unless admitted directly to the declared-wait cadence, while a live idle declared wait still surfaces once before that cadence bounds repeats; at that same escalation moment a recovery-grade agent-state probe (docs/architecture.md owns that dead-record contract) reports a pane whose endpoint is proven `dead` or `missing` once and stops re-escalating it while it stays that way
FM_BUSY_TURN_MAX_SECS=3600         # maximum age without a completed turn, explicit native-harness progress, or opted-in model progress (see the stream option above; bin/fm-watch.sh owns marker selection), before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait, an attended verified captain-held transfer, an attended backlog captain hold on the crew's task, or - where config/wedge-defer-worker-wait or config/wedge-defer-parked-gate arms it - the worker's own still-open newest `blocked:` or `needs-decision:` line or a validation gate of the crew's own awaiting the supervisor's still-unanswered decision, or - where config/wedge-defer-validating arms it - an attributed validation run that is running or fixing, takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_STREAM_SILENT_MAX_SECS=         # opt-in Pi worker foreground model-stream silence threshold; off by default; see the option above and bin/fm-busy-lib.sh
FM_SECONDMATE_WAKE_STALL_SECS=180  # minimum interval with no change of the oldest actionable foreign wake-queue row (it advances as the mate drains, and a queue reprovisioned under the same task id starts a fresh interval at whatever sequence it restarts) before an endpoint-recorded local secondmate produces one durable parent wake-loop-stall notification for that no-progress episode; a mate that is provably inside an active turn (an exact busy verdict) does not escalate until that same no-progress interval reaches FM_BUSY_TURN_MAX_SECS above; a mate whose busy class is exactly idle, whose agent is alive, and whose composer is not pending is rung once so its own home can drain, and the parent notification is withheld until that same row stays frozen for another stall interval; unknown or ring-unsafe panes keep the parent alarm; declared external-wait pause rows are excluded, and zero or invalid values use 180
FM_SECONDMATE_LIVENESS_SECS=60   # seconds between watcher probes of each registered secondmate's recorded endpoint; bin/fm-secondmate-liveness-lib.sh owns recovery actions and refusal rules; zero or invalid values use 60
FM_SECONDMATE_LIVENESS_TIMEOUT=120   # seconds allowed separately for a watcher-driven relaunch's per-home lock wait and its spawn execution; a lock-wait timeout skips recovery without touching the endpoint or recording an attempt; zero or invalid values use 120
FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS=3   # automatic relaunch attempts allowed per mate inside the window before the watcher parks auto-relaunch behind state/.secondmate-relaunch-bound-<id> and escalates once; a later live probe clears the marker and restores the full attempt budget (the ledger keeps its history behind a `rearmed` row); zero or invalid values use 3
FM_SECONDMATE_LIVENESS_WINDOW_SECS=3600   # window the relaunch bound counts state/.secondmate-relaunch-<id> attempt lines over; the file is also the durable per-mate relaunch record; zero or invalid values use 3600
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WEDGE_GUARD_TIMEOUT_SECS=5      # seconds one guard from config/wedge-evidence-guards may run before it counts as no answer; zero or invalid values use 5
FM_WEDGE_GUARD_DEFER_MAX=3         # consecutive windows a CRITICAL guard answer may defer one pane's wedge escalation before it fires anyway; invalid values use 3
FM_WEDGE_MAX_ESCALATIONS=0    # optional ceiling on consecutive wedge escalations for one worker window; 0 (the default) leaves the cap off and every escalation produces a wake, and any value from 1 up to 999999999999999999 publishes one terminal PERMANENTLY-WEDGED wake at that count - carrying the same evidence the escalation it replaces carried: the guard verdict, and the `demand-deep-inspection` marker once the count has reached `FM_WEDGE_DEMAND_INSPECT_COUNT` - and then writes the window-scoped state/.wedge-permanent-<key> to silence further wedge escalations for that window whatever hash its pane renders; the wedge path publishes no second terminal wake while the row that episode queued is still unacknowledged, which scopes the suppression to the episode rather than the window so an earlier episode's unconsumed wake cannot silence a later episode's (the away-posture first sight, which releases the markers without ending the episode, can re-open the row within one episode - an over-notify in the safe direction: the queue check bounds duplicate terminal wakes only while the episode marker stands, and the release removed exactly the marker that would have gated the re-fire, so after it a second wake can stand behind an unacknowledged first), the cap marker and the escalation count the cap was counting drop through the one episode-ending reset whose release routes are owned by the cap discussion below, and a fresh wedge escalates normally again; a cap fire also resets the consecutive-deferral budget of a config/wedge-evidence-guards guard, because the guard is not consulted at all while the cap is silencing that window, so its budget must not carry across as if it had been spent, and preserving it would leave a CRITICAL guard that reached its deferral ceiling before the cap fired already at that ceiling on the first escalation after the cap lifts, unable to defer at all; an invalid or out-of-range value uses 0
FM_CAP_HORIZON_SECS=86400    # seconds a fired cap's window-scoped marker keeps silencing the wedge path for that window, after which a new wedge escalates again; an invalid, out-of-range, or zero value uses 86400
FM_ROLLBACK_SENTINEL_TTL_SECS=3600   # seconds a cap-state write failure that could not be rolled back keeps the wedge path silenced through state/.wedge-rollback-failed-<key> - a failed cap-marker write whose own rollback also failed, an escalation count the state dir would not take, whose failed write leaves the ceiling unenforceable, or the cap-fire counter reset whose failed reset leaves the saturated counter standing - so a persistent write failure is observed once per wedge event instead of on every poll; an invalid, out-of-range, or zero value uses 3600
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_MAXDEPTH=6       # depth that same probe walks below the recorded worktree; it runs only at the moment a wedge escalation would otherwise fire, never on every poll; no probe knob applies to a secondmate, whose recorded worktree is a provisioned home the probe skips entirely
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_LEFTBAR_FOOTER_RE=   # optional fleet-wide override of the opencode left-bar mode/model footer's regex (bin/fm-composer-lib.sh's FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT, matched against both the ghost-stripped and the ANSI-stripped form of a run's LAST row); an override that cannot match the de-emphasised 1.19.0 footer puts the false `pending` back on an idle pane, so keep the default's required space after the separator and its exact `Build`/`Plan` mode words rather than widening it - widening it is the one path that turns typed text into the `empty` verdict which authorizes typing into a live session; see [runtime backend verification](verification/runtime-backends.md#2026-10-14-opencode-1190-de-emphasised-modefooter-row-in-the-left-bar-composer)
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; it no longer bounds the herdr adapter composer state/content reads, which supply the visible pane instead; it still bounds the shared inbox composer read (bin/fm-task-inbox-lib.sh) on pane backends, and on herdr it also floors how many Ctrl+U presses a refused leftover may take
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless, and a screen whose backend identity is Command Code is read at a fixed 160 instead. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled adapter reads). The default sits between the two populations it separates: harnesses draw their own de-emphasised composer furniture below it (opencode 1.19.0's mode footer at luminance 119.8 and its cwd row) and typed text above it. While it sits above the furniture the mode cells are stripped as ghost, so the footer's own identifying cells are gone from the ghost-stripped row and only the row's ANSI-stripped form still proves the footer - which is why the left-bar footer rule reads both forms and an idle opencode pane reads `empty` instead of the false `pending` that position produced - while dropping it under the furniture's luminance leaves those cells in the row and the footer then matches the left-bar footer rule in its stripped form too (still `empty`), and raising it over real typed text deletes typed text and reads as the false `empty` that authorizes typing into a live session; the measured luminances and the left-bar footer proof this threshold decides are in [runtime backend verification](verification/runtime-backends.md#2026-10-14-opencode-1190-de-emphasised-modefooter-row-in-the-left-bar-composer), so move it only against a fresh live capture
FM_COMPOSER_GHOST_GRAY_LUMA_MAX=180   # kiro panes only (a composer read whose caller names the recorded harness kiro; every other harness and a harness-less read ignore it): the higher luminance ceiling a NEAR-ACHROMATIC foreground gets instead of FM_COMPOSER_GHOST_LUMA_MAX, because kiro draws its idle placeholder in grey at 158 while chromatic real glyphs stay out of reach. Applies to a near-achromatic truecolor run and to a 256-colour index in the standard xterm 232-255 greyscale ramp, which is how kiro draws the same grey on a pane with no truecolor; the 6x6x6 cube's r==g==b diagonal is grey arithmetically but is deliberately NOT tested, so this ceiling never reaches it. It only ever RAISES the applicable ceiling - a near-gray run takes the higher of the two, so raising FM_COMPOSER_GHOST_LUMA_MAX past this still widens the strip on gray text
FM_COMPOSER_GHOST_GRAY_SPREAD_MAX=12   # kiro panes only: max channel spread (max channel minus min channel, 0-255) for a TRUECOLOR foreground to count as near-achromatic and take the gray ceiling above; anything more saturated keeps FM_COMPOSER_GHOST_LUMA_MAX. A gray palette index has zero spread by definition, so this knob does not gate it
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once; agy typed targets use a longer per-harness default owned by bin/fm-send.sh
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after the request turn completes without a correlated parent report before its one recovery repost is eligible, and after the recovery turn completes before the missed-report escalation is eligible; never counted from delivery
FM_SUPERVISOR_BACKEND=             # optional supervisor endpoint backend override; see "Away-mode supervisor backend" for supported backends and detection
FM_SUPERVISOR_TARGET=              # optional supervisor endpoint target override; herdr uses <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor endpoint is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# supervision host (bin/fm-supervision-host.sh); read only in a home that runs it
FM_SUPERVISION_HOST_PARK_SECONDS=27000   # the host ends its park with a cycle-boundary wake after this long, under the Stop hook's 28800 s timeout
FM_SUPERVISION_HOST_TURN_TIMEOUT=1200    # bound on one engine turn; a turn that hits it hands its wake to main
FM_SUPERVISION_HOST_ROTATE_TURNS=20      # the engine conversation starts fresh after this many turns (and at every main session start)
FM_SUPERVISION_ENGINE_GRACE=30           # seconds between TERM and KILL when an engine turn is stopped
FM_SUPERVISION_HANDOFF_RETRY_SECONDS=300 # with config/supervision-handoff-ack, seconds between the detached owner's delivery retries of an unacknowledged hand-back
# inbox; see "Inbox configuration" above
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh ask
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

`FM_WEDGE_MAX_ESCALATIONS` bounds wedge escalations, not detection, so while its markers stand the dead-endpoint report is still consulted ahead of the short-circuit and reports a proven-gone endpoint exactly once per incarnation.
The cap covers the wedge timer, which is where a BUSY pane whose agent is still generating output is escalated once its busy age crosses `FM_BUSY_TURN_MAX_SECS`, including the early crossing an opted-in model-stream silence causes.
It does not cover the first-sight stale surfaces, so a pane that renders a new hash on every poll is re-classified rather than escalated and still emits one stale wake per hash.
That re-classification is itself an episode end, so it also releases the markers: a hash-churning pane is not capped across its own churn either, because every first sight after the cap fired re-opens that window. The away-posture first sight releases the markers without ending the episode, because the away daemon owns the one-shot per stale hash and the episode it was already in resumes on that same hash once the away-posture record goes.
The consecutive-escalation count the ceiling is computed from is written before the escalation it counts is published, except for an opted-in foreground model-stream observation, which writes its count only after that guarded publication attempt resolves, so a close, progress, or replacement during the publication lock wait is never counted; where a configured state dir refuses that write, the wedge path rolls back and silences itself through `FM_ROLLBACK_SENTINEL_TTL_SECS` instead of leaving an unenforceable ceiling that restarts at 1 on every poll; with the cap off the count is only what the wake reason reports, so the failure is logged and the unconfigured schedule is unchanged.
The three cap settings are all bounded above at 999999999999999999, the largest value the watcher's own comparisons can carry, so a value that is not a whole number in range takes that setting's documented default instead: an out-of-range ceiling reads as unset and leaves the ladder uncapped rather than gaining a ceiling the watcher cannot enforce, while an out-of-range horizon or sentinel TTL falls back to its own default.
Apart from a first-sight classification, only a pane that leaves the stale path, an opted-in model-stream episode whose evidence changes, a declared wait (`paused:` or a verified captain-held transfer) as it starts or is lifted, and the turn-end churn absorb clear the markers, and all of them clear them through the one episode-ending reset, which drops the wedge timer and, wherever a cap is configured, the escalation count the cap was counting in the same call.
That shared reset is what makes the release structural rather than a list of sites to keep in step.
At the first-sight routes the reset is also opt-in per site: under a configured cap the count restarts with the released episode, while with the cap at its default 0 the count survives those routes exactly as the pre-cap watcher's did - the timer dropped and re-armed (or dropped alone), the escalation count standing - so a home that has not set anything keeps today's ladder, including the `demand-deep-inspection` prompt for a stuck pane.
An operator can re-engage a capped window at once by deleting its `state/.wedge-permanent-<key>` marker, and a window silenced by a failed cap-state write by deleting its `state/.wedge-rollback-failed-<key>` sentinel; both files are safe to delete, and the window then escalates on the ordinary schedule again.
[`bin/fm-watch-key-lib.sh`'s header](../bin/fm-watch-key-lib.sh) owns `<key>` derivation and the optional cleanup procedure for obsolete per-endpoint markers.
Turning the cap back off takes effect at once: every cap marker is read only while the cap is configured, so a leftover from an earlier configured run cannot keep a window silent in a home that has turned the cap off.

Upgrading a live home to the bounded `v3.` watcher keys intentionally resets its per-endpoint observation caches once, including stale timers, escalation counts, cap markers, and pause/wait notification throttles.
A previously capped window can start a fresh escalation ladder under the configured cap, and stale or declared-wait notifications can repeat before their new throttles are established.
This reset is harmless to running tasks and durable recovery state: task status, metadata, and wake queues are preserved, and a wedge notification never automatically interrupts, signals, or restarts a worker.
Declared pauses and waits are classified again from their existing evidence.
Their old notification throttles are not carried forward.
Legacy keys can conflate different endpoints, so importing their history could suppress a current endpoint using another endpoint's evidence.

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.

`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.

An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).

A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.

The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
