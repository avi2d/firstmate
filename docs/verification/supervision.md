# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, supervision-host, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

### Pi `/new` provider prerequisite

The real offline Pi regression ran on 2026-11-20 with Pi 1.5.1, an isolated home and session directory, a barrier-controlled native digest, and a deterministic local `streamSimple` provider.
The provider makes no HTTP request and requires no user credential.
Its missing-native branch deliberately requests `bin/fm-session-start.sh`, so an escaped first call reproduces the duplicate-producing manual path rather than passing vacuously.

```sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 \
  tests/fm-sessionstart-hook-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 1.5.1: immediate and completed-before-prompt /new paths each made one first provider call with exactly one native startup context and no manual execution
# fm-sessionstart-hook-live-e2e.test.sh: offline Pi /new race assertions passed
```

The immediate case submitted its first prompt only after the native `clear` child published `started`, held the child behind a release barrier, and proved the provider log remained absent for 500 milliseconds before release.
After release, the first payload reported one native context and no manual result, the session persisted one matching custom message, and the fixture recorded one native execution.
The control case let native generation complete before prompt submission and produced the same first-payload result.
The portable public-event regression in `tests/fm-sessionstart-nudge.test.sh` separately covers interruption, process-tree retirement, two rapid replacements, stale completion, empty output, spawn error, timeout output, truncation, ineligible stand-down, and compaction cancellation.
Pi and pi-signed load the same tracked extension bytes; pi-signed was not installed on this host for a separate 1.5.1 live rerun.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
### Per-task endpoint reads cannot truncate the digest

A per-task backend endpoint liveness read that dies mid-read inside the digest process takes every later stage with it, and a parent wrapper that banners only the runtime-bound exit stays silent about the missing sections.
The digest now runs each per-task endpoint read in its own bounded child (`FM_SESSION_START_ENDPOINT_TIMEOUT`, default 10s) whose death, hang, or nonzero surprise becomes that task's own `endpoint: error` line, and the parent wrapper banners ANY nonzero child exit, naming the stage and the abnormal exit status.
Verified on 2026-09-27 with the deterministic process-tree tests that reproduce both failure shapes with real processes and no harness:

```sh
tests/fm-session-start.test.sh
# ok - a killed per-task endpoint read becomes that task's error line and the digest completes
# ok - a hung per-task endpoint read hits its configured bound, reports the task, and leaves nothing stuck
# ok - a digest child killed mid-stage is bannered by the parent, which still exits 0
```

The kill test's fake `ps` walks real `/proc` ancestry to TERM the digest bash itself mid-lock-stage, so the parent-wrapper banner path is exercised end to end rather than asserted from output shape alone.
Both process-tree cases therefore need a readable `/proc` and print a skip line without it, and the companion case that pins a signal death to a nonzero status on the perl timeout mechanism skips when `perl` is absent.
These guarantees are process semantics, not vendor-emitted signals, so no live-harness guard is owed; the same suite is the refresh command.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-crew-state.test.sh
```

## No-mistakes run ledger and terminal run fields

The terminal-reading precedence rules in `bin/fm-crew-state.sh`, which bound both failed and done readings, read the run ledger's rows and a terminal run's `pr` field, so both were confirmed against the installed CLI on 2026-09-04 with no-mistakes v1.60.2 (eb4e379).

Column layout and newest-first ordering:

```sh
no-mistakes runs --limit 5
```

Observed result, abbreviated to two rows:

```
  cancelled    fm/fm-afk-inject-never-delivers eebd9498  2026-08-31 22:48  https://github.com/kunchenguid/firstmate/pull/3050
  completed    fm/fm-stooddown-worker-false-wedge-alarms b387086f  2026-08-30 10:03  https://github.com/kunchenguid/firstmate/pull/3281
```

The date column stamps a run's START, not its end:

```sh
ls -la ~/.no-mistakes/logs/01M186HDY76G4RJHW5Z7CFHQDB
```

Observed result: `intent.log`, the run's first step, has mtime `30 Aug 10:03`, matching that run's ledger date `2026-08-30 10:03`, while `ci.log`, its last step, has mtime `30 Aug 11:13`.
The column therefore cannot order a status-log record against the moment a run finished, which is why the reader orders the crew's own word against the run not at all and answers unknown where currency cannot be proven.

A terminal run that never reached its `pr` step emits no `pr` field at all:

```sh
no-mistakes axi status --run 01M14G3F9BEYBSYSZRVRQJ9XYT
```

Observed result: `status: failed`, `review,failed` with `test` through `ci` still pending, `outcome: failed`, and no `pr:` line at all.
The completed run above reports `pr: "https://github.com/kunchenguid/firstmate/pull/3281"` in the same field.
That absence is what lets a terminal outcome take its pull-request identity from the same record as its state instead of an older recorded one.

The ledger's first column is the RUN STATUS, not the axi outcome, established on 2026-09-19 against the installed no-mistakes v1.72.0 (9fcc865):

```sh
no-mistakes runs --limit 400 | awk 'NF{print $1}' | sort | uniq -c
```

Observed result: across the 313 stored runs the column holds only `running`, `completed`, `failed`, and `cancelled`.
`checks-passed` is an axi OUTCOME and never appears in that column; a run still at its ci step, which has no outcome yet, reads `running` there.

Every captured run record agrees with that column in its own `status:` field - `failed.toon` reports `status: failed`, `superseded.toon` `status: cancelled`, `completed.toon` `status: completed` - so the record already carries the ledger's vocabulary once.
The reader therefore derives the status it compares against from that field alone, normalising the live words (`ci`, `running`, `fixing`, `awaiting_approval`, `fix_review`) to `running`, rather than keeping a second mapping keyed on the outcome word.

That derivation change removes a second definition; it is not observable, and the shapes were traced rather than assumed:
a record carrying any outcome is terminal under the run-selection contract, so beside a still-live ledger row it is answered `unknown` by the liveness cross-check before the comparison is reached, on both the inventory and the ledger-fallback path.
Where the comparison IS reached, the overview row and the record report the same run from the same store and therefore the same status word, which is the word the derivation now uses.
The only input that separates the two derivations is a record whose `status:` disagrees with its own overview row, which the CLI does not produce - so no regression test can distinguish them, and none is claimed.

Deterministic entry points:

```sh
tests/fm-crew-state.test.sh
tests/fm-inactive-reconcile.test.sh
```

## Turn-end guard

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |

## Watcher continuity

Pi 0.86.1 passed the isolated watcher-only live check on 2026-09-22:

```sh
FM_PI_LIVE_E2E=1 FM_PI_LIVE_WATCH_ONLY=1 tests/fm-pi-primary-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.86.1 live E2E covered repeated successor handoffs and a genuine stopped-chain alarm
```

The test observed three consecutive actionable notifications, each with a ledger-linked successor before model handling, then replaced the isolated lab's arm command with an intentional failure, stopped that lab's live arm chain, and confirmed the guard still emitted `WATCHER DOWN - SUPERVISION IS OFF` after the bounded grace period.

Pi same-process session-transition ownership was verified on 2026-09-01 against the tracked extension with provider-free public lifecycle events, retained and fresh extension-module rebinds, and real arm children:

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, `/fork`, and reload, plus same-instance shutdown-plus-start, an owning `session_start` armed the replacement generation before any model turn and without the `watcher: not armed - Pi session is shutting down` refusal.
A fresh module rebind also received exactly once the actionable close whose first delivery was still in flight at shutdown, while retaining one live successor.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
The strict no-emit check used the installed Pi SDK declarations to hold the lifecycle event contract.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner.

On 2026-09-22 the deterministic transition suite additionally proved that replacement shutdown leaves the established predecessor running under a `handoff` generation marker until a distinct `active` successor generation commits, an actionable reason observed before process close cannot reuse its predecessor as the successor, and a handoff marker from an absent replacement extension cannot suppress session-start or turn-end outage diagnostics.

On 2026-09-02 the same suite, the strict typecheck, and the credential-free real-SDK guard were rerun against `@earendil-works/pi-coding-agent` 0.84.4 after the extension stopped waiting for `before_agent_start` before settling a main delivery; [`runtime-backends.md`](runtime-backends.md#2026-09-02-streaming-time-watcher-delivery) owns the exact commands and output.
Observed guarantee: a wake delivered while main was streaming was followed by a verified successor and by delivery of the next actionable close, a replacement replayed only the follow-up Pi had not consumed, an exhausted restoration delivered its typed failure without launching an arm past the retry bound, and a verified successor that failed while a branch settlement still held its wake took the ordinary bounded retry once that delivery settled.

The once-per-generation recovery bound and immediate handling-successor poll were verified on 2026-08-21 with the tracked Pi extension, real watcher processes, and an isolated home.
The regression forced handling confirmation to fail, observed one recovery follow-up across the former repeat window, confirmed the successor remained live, and then proved a separate handling successor durably queued a crew event within the bounded poll window.

```sh
bin/fm-test-run.sh tests/fm-watch-recovery-loop.test.sh
```

Observed output:

```text
ok - a resurfacing handling successor stays alive and supervises instead of going blind
ok - unacknowledged recovery is announced at most once per generation and the successor stays alive
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59357
```

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-wake-queue.test.sh
tests/fm-turnend-guard.test.sh
```
