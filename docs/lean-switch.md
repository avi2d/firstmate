# Switch to a lean home

This runbook moves the fleet from an old Firstmate home to a lean home on the `lean` branch.
The lean home gets a second folder on the Mac and a second execution home on the Windows host, called winbox here.
The groomed Backlog.md draft board becomes the lean home's task list, and the old `data/backlog.md` stays behind.
The old home and its backlog files stay untouched for a week as the way back.

[`bin/fm-lean-switch.sh`](../bin/fm-lean-switch.sh) does the copying, and `--help` lists its commands.
It only reads the old side and only writes under the lean side.

## Names used below

| Name | Meaning |
| --- | --- |
| `OLD` | The old home on the Mac |
| `LEAN` | The lean home on the Mac, a clone of the `lean` branch, such as `~/Projects/firstmate-lean` |
| `BOARD` | The groomed board, `$OLD/data/backlog-groom-audit/backlog-md/backlog` |
| `OLD_EXEC` | The old execution home on winbox, `~/fm-exec` |
| `LEAN_EXEC` | The lean execution home on winbox, such as `~/fm-exec-lean` |

## Before the switch

Switch right after the old home's daily session reset, when every open record is already written to disk.
Hold every merge and every dispatch in the old home from then on.

Rehearse the whole runbook on scratch copies first, as [Rehearse on copies](#rehearse-on-copies) describes.
Its counts must equal the board's counts printed by step 3.

## 1. Stop the old workers and keep their work

Work in `OLD`.

1. Land or tear down every task whose PR has merged, with `bin/fm-teardown.sh <task>`.
2. For every other live task, tell its worker to commit and push its branch with `bin/fm-send.sh <task> "<text>"`.
   Wait for its status line.
3. Stop each of those workers with `bin/fm-control.sh <task> exit`.
4. Stop each second mate the same way, because a lean home has no second mates.
   Its projects move to the lean home, and its own home stays as it is.

Never run `bin/fm-teardown.sh` on unlanded work.
A stopped worker keeps its worktree, its branch and its task record in the old home.

## 2. Create the Mac home

```sh
git clone --branch lean https://github.com/avi2d/firstmate.git "$LEAN"
npm ci --prefix "$LEAN/bin/fm-backlog-md"
"$LEAN/bin/fm-lean-switch.sh" seed-home "$OLD" "$LEAN" "$BOARD"
```

`seed-home` refuses a lean home whose `data/`, `config/` or `projects/` already has content.
It prints one line for each file it copies, leaves behind or cannot find.

### What the lean home gets

| File | Treatment |
| --- | --- |
| `data/captain.md`, `data/captain-shared.md`, `data/learnings.md`, `data/projects.md` | Copied |
| The groomed board | Copied whole as `data/backlog`, keeping ids, labels, priorities, drafts and the archive |
| `data/<task>/` folders | Copied when a ticket names `data/<task>` or carries the label `old:<task>` |
| `data/backlog.md`, `data/done-archive.md` | Left behind as the way back |
| Other `data/` entries | Left behind |
| `config/crew-dispatch.json`, `config/project-capacity` and the other non-secret settings the script lists as `copy` | Copied, a symlink as the same symlink |
| `config/claude-accounts` and every other credential file | Left behind unopened |
| `config/firstmate-role` | Left behind, because a home never grants itself a role |
| `config/herdr-session` | Left behind, because the lean home names its own session |
| `config/daily-session-reset` | Left behind, because lean has no daily reset |
| `config/backlog-backend` | Written as `backlog-md` |
| Any config file the script does not know | Left behind and printed as `unclassified` |
| `projects/` symlinks | Recreated with the same target |
| `projects/` clones | Left behind and printed, to be added again with the `project-management` skill |

Write the credential files and `config/firstmate-role` into `$LEAN/config/` by hand.
Only the user chooses the account pins in `config/claude-accounts`.

## 3. Check the board

```sh
"$LEAN/bin/fm-lean-switch.sh" counts "$BOARD"
"$LEAN/bin/fm-lean-switch.sh" counts "$LEAN/data/backlog"
```

Both commands print the same three lines, and `seed-home` already refused on any difference.
The board groomed on 2026-11-19 prints these counts:

```text
tasks: queued=14 waiting=6 in_flight=2 done=23 other=0
drafts: 86 queued=51 waiting=35 in_flight=0 done=0 other=0
archive: tasks=2096 drafts=0
```

## 4. Hand over the live tasks

```sh
"$LEAN/bin/fm-lean-switch.sh" handover "$OLD" "$LEAN"
```

`handover` matches each old task record in `$OLD/state/` to the In Flight ticket that carries its `old:<task>` label.
It refuses and changes nothing while an old record has no such ticket.
It lists second mates and leaves their records alone.
Then land or tear down that task in the old home, or give its ticket the label, and run `handover` again.

Each In Flight ticket becomes a queued ticket on hold of kind `parked`.
The hold reason names the old worker's branch, its worktree and its execution route.
A second run changes nothing.

For the board above, the two In Flight tickets move to Waiting:

```text
tasks: queued=14 waiting=8 in_flight=0 done=23 other=0
```

To resume a handed-over task, run `bin/fm-tasks-axi.sh unhold <id>` in `LEAN`.
Write its brief to continue from the kept branch named in the hold reason, and dispatch it as usual.

## 5. Create the winbox execution home

On winbox, clone the `lean` branch as `LEAN_EXEC`:

```sh
git clone --branch lean https://github.com/avi2d/firstmate.git ~/fm-exec-lean
```

The SSH entrypoint on winbox stays as it is, because it takes the code root as an argument.

From `LEAN` on the Mac, seed the route with the same route name the projects use in `data/projects.md`, such as `winexec`.
Pick a Herdr session name that differs from the old execution home's `config/herdr-session`, so the two homes never share panes.

```sh
bin/fm-remote-home-seed.sh --exec --session <lean-session> winexec <ssh-alias> <remote-root> ~/fm-exec-lean <project>...
```

`data/remote-homes.md` is not copied, because this seed writes the lean home's own record.
Then, on winbox, copy the execution home's kept settings:

```sh
~/fm-exec-lean/bin/fm-lean-switch.sh seed-exec ~/fm-exec ~/fm-exec-lean
```

| Execution home file | Treatment |
| --- | --- |
| `.fm-exec-home`, `config/backlog-backend`, `config/herdr-session` | Written by the seed |
| `config/project-capacity` | Copied |
| `config/claude-accounts` and its backups | Left behind unopened |
| `config/firstmate-role` | Left behind, written by hand when needed |
| `data/`, `state/`, worktrees | Left in `~/fm-exec`, where the stopped workers keep their work |

Workers on winbox are still started and supervised from the Mac.

## 6. Start the lean home

Start the supervisor session in `LEAN`, and never start it in `OLD` again during the week.

## The way back

For one week nothing in `OLD` or `~/fm-exec` changes, and nothing removes them.
To go back, stop each lean worker with `bin/fm-control.sh <task> exit` in `LEAN`, then start the supervisor session in `OLD`.
The old `data/backlog.md` is as it was at the switch, so re-enter by hand any task the lean board gained since then.
Removing the old home after the week is a separate decision for the user.

## Rehearse on copies

Run every step against copies in a scratch folder, never against the running home or the real `~/fm-exec`:

1. Copy the old home's memory files, its config file names with dummy contents, and the board into a scratch old home.
2. Copy a `lean` checkout into a scratch lean home and run `npm ci --prefix bin/fm-backlog-md` there.
3. Run steps 2 to 4 against the scratch homes, and `seed-exec` against a scratch execution home.
4. Compare the printed counts with step 3, and compare a checksum of the scratch old home before and after.
