---
name: grilling-supervision
description: >-
  Agent-only route for running a grilling interview with the captain for any registered project, with the installed `grilling` skill as the method.
  Load before dispatching an interview when the captain asks to grill or interview a project's goal or design, and whenever that interview's worker reports a round or recap ready.
user-invocable: false
metadata:
  internal: true
---

# Grilling supervision

The installed `grilling` skill is the method: it owns the decision tree, the numbered frontier rounds with a recommendation per question, the one Lavish page per round, the open answers, the recomputed frontier, the final recap, and the project record in `docs/interviews/<topic>.md` and `docs/goals.md`.
This skill wires that method into Firstmate: one worker prepares every round, the captain answers each round with one board submission, and that submission is recorded whole on the round's own captain-held task.
The captain owns every answer, the worker researches and proposes, and firstmate owns every exchange with the captain.

## Start an interview

1. Resolve the target project under `AGENTS.md` section 7; a target that is not yet a registered project goes through `project-management` first.
2. Ask the captain one question for the interview's destination and boundary when the ask leaves them unclear.
3. File one work item for the whole interview with `--repo <project>`, and resolve its delivery mode, merge posture, and branch prefix like any ship; the reviewed record lands through them.
4. Scaffold a ship brief, keep the captain's ask in `## Captain's intent`, put the worker rules below in `## Firstmate spec` with this home's absolute `FM_HOME` and code-root paths filled in, then spawn as usual.

## Worker rules for the brief

- Follow the installed `grilling` skill as the method, and leave the project work itself unbuilt.
- Report only to firstmate: every question reaches the captain on a round board firstmate approved, and a board reply only acknowledges.
- Keep one board page for the whole interview at an untracked path in the isolated copy, opened with `lavish-axi` before the first round, and draft each round or recap at a separate untracked path, so the live board changes only on firstmate's go.
- Key round N's card to the held task `<interview-id>-r<N>` and the recap's card to `<interview-id>-confirm`.
- Build each round as one form whose one submit calls `window.lavish.queuePrompt` once, tagged `choice`, with data `{schema: "fm-bearings-answer.v1", question: "<interview-id>-r<N>", selection: "", note: <round note>, answers: [{question, selection, note}, ...]}` covering every question of the round, a skipped question sent with an empty selection and note, and no option preselected.
  The header of `bin/fm-procevent-lavish.sh` owns that round format and its limits.
- Build the recap as a single card with data `{schema: "fm-bearings-answer.v1", question: "<interview-id>-confirm", selection: "confirmed" or "corrections", note}`.
- Report each draft with `needs-decision [key=grill-round-<N>]`, or `[key=grill-recap]`, naming the draft path, the board path, and the board URL, then wait for firstmate's go.
- On the go, copy the draft over the board page, arm the board with `FM_HOME=<home> <root>/bin/fm-procevent-lavish.sh arm <board> --for <interview-id>` before the first round, and declare `paused:` while the captain answers.
- When a round's result reaches the inbox, read the captain's answers with `<root>/bin/fm-procevent-lavish.sh answers <result>`, which prints the line the held task recorded, and any freeform message with `read`.
  When that prints no line for the round's key, the answers were not recorded: report `blocked` naming the result.
  Otherwise re-arm at once with a one-line acknowledgement through `--agent-reply-file`, put the actual answers in the Q&A draft, and recompute the frontier from them.
- Acknowledge every terminal result with `FM_HOME=<home> <root>/bin/fm-procevent.sh handled <source-id> <sequence>` and leave that board unarmed; one that arrives before a recorded `confirmed` goes to firstmate as a `needs-decision`, because only the captain reopens an ended board.
- A recorded `corrections` reopens the named decisions in a new round.
- A recorded `confirmed` ends the board: when the session is still open, re-arm with a closing reply, run `lavish-axi end <board>`, and acknowledge the terminal result.
  Then finish the Q&A and goals per the `grilling` skill and deliver them through the brief's definition of done.

## Each round

When the worker reports a round or recap draft:

1. Review the draft against the answers already recorded on earlier round tasks before the captain sees it.
   It asks the whole current frontier and nothing more: every question's prerequisites are settled, no question depends on another in the same round, every disputed, skipped, or ambiguous earlier answer is asked again, and nothing the worker could look up is asked.
   Each question carries a recommendation and its alternatives, the card is keyed to the expected task id, and its one submit carries every question id.
   A draft that follows a prewritten list instead of the recorded answers goes back to the worker.
   Steer fixes and leave the decision open until the draft passes.
2. Hold the round: `bin/fm-captain-hold.sh hold <interview-id>-r<N> --title <title> --repo <project> --origin <interview-id> --reason "<numbered questions, each with its recommendation>"`, or `<interview-id>-confirm` carrying the recap for the final confirmation.
   One held task and one card carry the whole round.
3. Run `bin/fm-captain-hold.sh complete <interview-id>` with every round and recap task held so far; it records the inventory and transfers the worker's open round decision to the held task.
4. Before the first round only, bind the board with `bin/fm-captain-hold.sh bind "$(bin/fm-procevent-lavish.sh source-id <board>)"`; every later round on the same board uses that binding.
5. Tell the worker to publish with a plain `bin/fm-send.sh` steer, and keep the round's task id out of `--resolve-key`, which would record the steer as the captain's answer.
6. Present the round to the captain as one decision with the board URL under `AGENTS.md` section 9.

The listener feeds the captain's one submission to the keyed-answer intake, which records every selection and note on the round's held task and closes it, then delivers the capture to the worker without waking firstmate.
At the worker's next report, confirm the previous round's held task carries that recorded answer before reviewing the next draft.
When a round's task is answered anywhere other than its round board, in chat or on the Bearings board, make sure the captain's exact words are on the task, through `bin/fm-captain-hold.sh answer` for chat, and relay them to the worker; questions those words leave unanswered stay open.
A recommendation is never recorded as the captain's answer.

## Confirmation and the record

The final recap is its own held task, and only a recorded `confirmed` ends the interview.
The worker then delivers the reviewed `docs/interviews/<topic>.md` and `docs/goals.md` through the project's delivery mode, and `AGENTS.md` section 7 owns its landing under the usual merge authority.
Board pages, drafts, and captures are exchange mechanics; the held tasks and the project's reviewed record are the durable record.
Building anything the interview settled is separate work with its own authorization.
