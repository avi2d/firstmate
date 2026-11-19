#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, and transition this home's backlog item for ship and
# scout tasks before reporting success (a secondmate teardown transitions none,
# since secondmates are not backlog items), then refresh/prune the project's
# clone for PR-based ship tasks.
# An endpoint whose close could not do its job REFUSES before any record naming
# it is removed: those records are the only thing that names what survived, so
# reporting such a close as a completed cleanup strands the endpoint instead of
# merely leaving it behind. endpoint_close_refusal below owns that refusal and
# the one site where --force overrides it, and bin/fm-backend.sh's
# fm_backend_kill owns what each backend can prove about its own close - an
# already-exited endpoint is not a failure and stays silent.
# Removing state/<id>.meta and landing the backlog transition are one step, not
# two: bin/fm-backlog-transition-lib.sh owns that invariant, and both halves run
# under the task's own meta lock before this script reports success. Because the
# completion links (the PR, the report path, a local-main or discarded note) live
# only in the record being removed, the intended transition is recorded in
# state/<id>.backlog-close first, so a process killed between the halves leaves
# the next session start enough to finish it; a landed close removes that record.
# A close that fails is fatal and loud, preserves its pending-close record, and
# is retried by the next session start. The transition is skipped on a
# config/backlog-backend=manual home and in a markdown home that keeps no
# data/backlog.md; those cases print the manual follow-up. A configured
# non-markdown adapter remains active without a markdown file; any active
# automatic backend without compatible tasks-axi refuses before cleanup.
# None of this loosens the landed-work gates below: the transition runs only on
# the paths that already proceed to remove the record.
# The close - and only the close - is replaced by `tasks-axi reopen` with the
# deliverable recorded while the backlog item is still an open captain call
# (bin/fm-captain-hold.sh `open` owns that predicate), because the policy holds
# the very work item a question gates and cleanup must never retire the
# captain's own question.
# NOTE: this uses `open`'s silent default and depends only on its unchanged
# 0/1/2 exit-code contract. The optional `--identity` output that bin/fm-watch.sh
# asks for prints only on an exit 0 and changes nothing read here.
# The same pending-close record carries that intent as
# `mode=retain`, so an interrupted cleanup replays the retention rather than a
# close. "Cannot tell" refuses before any destructive step, --force does not
# lift the deferral (it authorizes discarding unlanded WORK, never the
# captain's question), and bin/fm-captain-hold.sh answer stays the only act
# that closes the call.
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch other than the local no-mistakes
# mirror (a fork counts as a remote, so upstream-contribution PRs pushed to a
# fork satisfy this in any mode; the mirror is not a forge), after
# refresh_remote_refs has updated those refs from each remote when the local ones
# do not show the work, OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main. A task whose meta records
# base_branch= (bin/fm-spawn.sh) runs that content check against origin's copy of
# its base branch instead of the default branch.
# Squash merges collapse the branch's commits, so per-commit patch ids against main
# no longer match, and a pipeline rebase can leave the local worktree diverged from
# the PR head. A diverged copy is not treated as landed: path-set coverage, git
# cherry, and merge-tree containment each fail to prove content landed without also
# accepting unlanded edits to the same paths. Teardown still accepts a merged PR
# whose head contains the current local work (ancestor or whitespace-exact patch ids),
# or a clean content-in-default tree match. Anything else refuses.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# A merge-tree option or execution error reports the content-landed proof as
# unavailable. The merge-tree --write-tree proof requires Git 2.38 or newer.
# Uncommitted changes are never landed. Before return, the dirty check explicitly
# requests all untracked files, even when status.showUntrackedFiles hides them.
# Dirty refusals distinguish untracked-only leftovers from tracked edits and list
# at most ten non-exempt untracked paths. tests/fm-teardown.test.sh covers hidden
# untracked work and the clean return control.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge after configured approval) as a fallback
# for the common case where there is no remote at all.
# Safety is proved again after task processes are reaped, before backlog-close
# publication, branch deletion, or worktree return.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# A scratch copy (kind=scout) and a --force run discard untracked content.
# Treehouse's return resets with `git clean -fd`, which never deletes a nested
# git repository, so the pool slot stays dirty and later checkouts skip it.
# Before that return, teardown runs `git clean -ffdq` in the copy, and a forced
# secondmate teardown does the same in each child copy it returns.
# The second -f removes nested repositories, and -x stays off so ignored files remain.
# A ship teardown without --force does not run that clean: it refuses untracked
# entries, except those under the .claude/ allowance, so a nested repository
# there can still survive the return.
# After a return that succeeds, teardown reads `git status --porcelain --untracked-files=all`.
# Any remaining output, a status read that fails, or a copy that is missing or
# no longer a readable worktree is reported at once with the lost pool slot and
# what remains. Teardown then finishes every cleanup step, reports the lost slot
# instead of a clean return, and exits 4. Exit 4 means only "cleaned up, but a
# returned pool slot was lost"; refusals and errors exit 1, and an invalid
# request exits 2. A local retirement of a remote secondmate whose remote run
# exits 4 still completes locally, forwards only the remote lost-slot warning
# to stderr, and then exits 4.
# Before destructive cleanup, teardown validates task check artifacts as
# ordinary single-link files on the state device. It refuses and preserves
# task state when that proof fails; otherwise it removes the task's check,
# trust record, PR sidecar, and publication record with the rest of the
# volatile state.
# That volatile state includes the watcher's per-task .seen-* signature for
# the task's turn-ended file, minted by bin/fm-wake-lib.sh (the .seen-*
# signature for its status file and its .hb-surfaced- heartbeat marker are
# already retired by status_retire_presentation_task) - and, once the
# recorded pane is proven gone, an orphaned Herdr presentation journal: a
# binding of exactly that pane, or a version 1 attempt whose
# token-bearing projected workspace is itself confirmed gone, names nothing the
# session-start sweep could still close, while a journal bound to any other pane
# - or a version 1 attempt whose workspace is still present or unreadable - may
# name a live quarantined space and is retained for that sweep.
# data/<id>/ is deliberately left in place: a successor spawn reads brief.md
# from it.
# Worktree-slot ownership (teardown-slot-collision): a treehouse pool slot is
# reused across tasks, so a stale, duplicated, or drifted worktree= record can
# name a slot a DIFFERENT live task now holds. Cleanup kills every process under
# that path and hard-resets it before returning it, so releasing a slot that is
# not genuinely this task's destroys another worker's live work. Before the first
# cleanup step, teardown verifies record exclusivity: no OTHER task record in
# this home or any locally registered Firstmate home may name the same live path
# in its worktree= or home=. One live path with two task records is the reuse
# collision itself, whichever record is stale. The one exception is a slot whose
# owner claim (below) names another task: this teardown is then records-only and
# touches nothing under the slot, so the scan is skipped rather than stranding
# the stale record and, with it, the claimant's own teardown.
# That scan alone cannot prove THIS record is the current owner, because the task
# that took the slot next may leave no record it can reach - its own worker may
# have exited and its record been cleaned up, or it may live in a home this
# machine does not register - which is how a released-then-reassigned slot was
# returned out from under a live worker (observed 2026-09-07). So teardown also
# reads the slot's own owner claim, written by bin/fm-spawn.sh at the moment the
# slot is taken and dropped here once it is genuinely returned; bin/fm-wake-lib.sh
# owns the claim, its location, and its states. A claim naming another task is
# proof of reassignment: the slot is no longer this task's, so teardown warns,
# names the claimant, and then finishes only this task's own cleanup - endpoint,
# status, records, checks, backlog - while every step that would read or touch
# that slot is skipped: no process kill under it, no dirty or landed-work
# inspection of it, no branch or hook removal in it, no Treehouse return, and
# never the other task's claim. Skipping the inspection discards nothing of this
# task's: whatever unlanded work it had in that slot was already destroyed when
# the pool handed the slot on. Refusing instead would strand the record, because
# bin/fm-backend.sh's endpoint validation refuses an empty or missing worktree=
# unconditionally, so there is no line an operator could clear to get past it.
# A claim that cannot be read proves nothing either way and refuses; inspect or
# repair the claim file at the printed path and re-run - never remove it, since
# an absent claim proceeds and would return a slot that may be another task's. An
# absent claim - a slot taken before claims existed, or already returned - keeps
# exactly the record-scan protection it had before, because refusing it would
# strand every task in flight across that change on no evidence at all.
# Why Treehouse's own state cannot answer this for crewmate slots, and why the
# claim file sits on top of it, is owned by bin/fm-wake-lib.sh's slot-owner
# claim comment.
# The recorded endpoint's exact task identity and the record's spawn incarnation
# are validated separately
# before cleanup. Its current working directory is only incidental process
# state: the same worker remains the owner after changing directory, so cwd can
# never veto teardown of that exact recorded endpoint.
# The scan and destructive return hold a project-identity lock in the local root
# Firstmate home's state directory, as resolved by bin/fm-wake-lib.sh's
# fm_firstmate_root_home; a home seeded from another machine is its own local
# root, since a lock on this filesystem cannot be held or observed across that
# boundary. Fresh Treehouse spawns for that project in
# every local Firstmate home hold the same lock from before slot allocation
# through metadata publication, closing the publication
# gap; forced secondmate teardown takes it and runs the same checks for every
# descendant Treehouse slot before touching any child.
# These refusals are not relaxed by --force: --force authorizes discarding THIS
# task's unlanded work, never another task's live work. Nothing of this task's
# own is removed by a refusal; reconcile whichever record is wrong and re-run.
# Orca is not a pool slot and proves its path through
# require_orca_worktree_path_match instead.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, locks each
# descendant home's task set before enumeration, and holds those locks through
# child cleanup. Contention refuses the complete forced teardown before child
# mutation. Local and remote retirement serialize their destructive phase with
# that mate's backlog-handoff lock under the registry lock. Pending handoff wake
# state is retired with the home, and local removal failure restores that state
# before preserving the route for retry. After a successful local or remote
# secondmate retirement, every parent pending-reply record for that id (resolved
# leftovers included) and its delivery confirmation is removed so retired mates
# cannot leave durable reply expectations behind. Non-forced retirement refuses
# while any of those records is still unresolved. Teardown then discards child
# work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force] [--legacy-record]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks and closes the scout as discarded with no report recorded, and
#   discards secondmate child work for kind=secondmate. Only use it when the
#   captain has explicitly said to discard the work.
#   --legacy-record accepts a task record that predates the spawn_gen field:
#   teardown then proceeds only when the recorded endpoint is confirmed dead or
#   agent-less (bin/fm-backend.sh's recovery-grade classifier), and without
#   --force the worktree still passes the ordinary landed-work checks. The
#   accepted legacy incarnation is stamped into the record before its close is
#   recorded and named in the teardown line; the flag never relaxes the
#   unlanded-work refusal, which --force alone can authorize. A legacy- stamp
#   an abandoned attempt left behind never counts as a published incarnation:
#   the record still reads as a legacy record, so a recorded endpoint runs the
#   endpoint gate again and the retry still needs --legacy-record. The safe
#   windowless exception below retries its retained stamp without the flag.
#   A tmux record with no window names no live endpoint, so there is nothing
#   for that classifier to inspect and nothing to kill. Combined with a
#   missing spawn_gen, that leftover would otherwise deadlock: automatic
#   teardown refuses for want of spawn_gen, and --legacy-record then refuses
#   for want of a window. When backlog incarnation validation applies, such a
#   leftover (no window, no spawn_gen or only a retained legacy stamp, no
#   backend other than tmux, no Orca terminal= or other backend's <backend>_*
#   endpoint identity, and every other identity field passing the shared
#   endpoint validator as if it named the task's own window) is accepted as a
#   missing-endpoint legacy record with or without --legacy-record; the shared
#   endpoint validator is skipped so it cannot be read as the current window,
#   kill is skipped, and a still-present worktree still faces the ordinary
#   landed-work checks. Every other windowless record, including one with a
#   spawn_gen, a non-tmux backend, or an ambiguous field, still faces the
#   validator and refuses.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
#
# Pre-teardown cleanup sequence (starts after the initial landed/discard-work
# safety checks pass, and BEFORE any worktree return or branch
# deletion below - a still-active run or a leaked process may
# own live work in that worktree):
#   Fix 1 - conclude the task's own no-mistakes run. A ship task's worktree can
#     be torn down while its no-mistakes pipeline run is still PARKED at a gate
#     (awaiting_approval/fix_review/any awaiting_agent field), with no worker
#     left to ever answer it - the run then sits there holding a fleet slot
#     indefinitely (observed 2026-08-03: runs parked 7h39m and parked at a
#     post-CI approval gate after the worker was already cleaned up). A run
#     with an autonomous step still under way (running/fixing/ci) is left
#     alone: no-mistakes drives those against its own gate-repo clone, not the
#     crew's worktree, so they are not orphaned by removing the worktree.
#     conclude_task_no_mistakes_run attributes the active-or-most-recent run to
#     THIS task only when its branch AND code identity (bin/fm-nm-run-lib.sh's
#     strict fm_nm_head_matches_worktree rule) both match this worktree, then
#     runs `no-mistakes axi abort --run <id>` for that verified run instance.
#     When the run head is absent from this copy's object store - the pipeline
#     committed its fix round in its own repo and the task copy never fetched
#     it - attribution falls to the same lib's shared
#     fm_nm_runs_status_for_worktree ledger rule, whose anchored continuation
#     recognition is the only remaining path, which refuses every row shape
#     it cannot prove, and which authorizes the abort only for an explicitly
#     active (`running`) proved continuation - a terminal newest word is
#     finished history, never an abort authorization (observed 2026-09-03: a
#     run parked at a post-CI gate after fix rounds advanced its head past
#     the submitted head stayed parked forever once the task was cleaned up).
#     A run already terminal
#     (an outcome is set) or not parked at a gate is left untouched. Idempotent:
#     an already-aborted run reads back terminal and is skipped on retry.
#   Fix 2 - reap leaked descendant processes. A backgrounded/disowned process
#     started under the worktree (or its per-task tasktmp) does not receive the
#     SIGHUP/SIGTERM that closing the backend pane sends to its own foreground
#     process group, so it survives reparented to init (observed 2026-08-03:
#     two `go test` binaries, deadlines blown past by ~100x, pinning CPU for
#     hours with no live task meta to attribute them to once teardown had
#     already removed it). reap_task_worktree_processes finds every process
#     whose CURRENT WORKING DIRECTORY is this task's own worktree or tasktmp
#     root via `lsof -a -d cwd` (cheap: bounded by process count, not by
#     walking the worktree's file tree) and sends TERM, then KILL after a short
#     grace period to any survivor whose process identity still matches. Both
#     roots are unique per task and never
#     shared, so this can never reach another task's or the primary's
#     processes. Idempotent: nothing left to find is a silent no-op.
#   Fix 3 - sweep abandoned remote job workers. A remote job worker started
#     from a worktree's own bin/ outlives that worktree's removal without
#     being reachable by Fix 2, because its working directory is wherever it
#     was launched rather than the task worktree (observed 2026-08-07: 29
#     workers at ppid 1, 1-2 days old, each still polling and appending to a
#     log in a pruned no-mistakes gate worktree). bin/fm-remote-job-reap-orphans.sh
#     owns that sweep and its safety rule; it never touches a worker whose code
#     root still exists, so the account's healthy LaunchAgent worker and every
#     live remote secondmate worker are out of scope. Best effort: a sweep
#     failure never blocks this teardown.
# After Fix 1 and Fix 2, when config/pipeline-spend opts this home in, a ship
# task whose local copy this teardown owns has its no-mistakes pipeline spend
# recorded by bin/fm-pipeline-spend.sh, which owns the attribution and the
# ledger. It runs before the task branch it attributes runs by is deleted and
# before state/<id>.meta is removed, and is best effort: a failure warns and
# never blocks cleanup.
# Opt-in config/status-archive preserves retired status logs in
# data/<id>/status.log, then status.<N>.log for reused IDs. The presentation
# lock covers archive publication, cursor retirement, then the existing live
# status and bookkeeping removal. A failed publication leaves live state intact.
# Forced child retirement uses data/<id>/children/<child-id>/ (recursively),
# outside the home being removed. Remote-home retirement with no status is a
# no-op. Symlinked/non-regular sources and symlinked archive directories refuse
# cleanup rather than following them; the configured data root may be a symlink.
# Existing archive filenames are never overwritten. Each archival prunes owned
# logs and orphaned staging files older than 30 completed days by mtime.
# Pruning failures warn, never abort teardown, and leave other task data and
# symlinks alone.
# Opt-in config/record-export-root delegates the record archive transaction to
# bin/fm-record-export.sh immediately before status, metadata, or inbox records
# for the retiring task are removed. A failed commit retains those sources.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# A missing `.` target is not a teardown result. Stock Bash 3.2 can abort it
# into an EXIT trap whose status is 0, and a newer Bash can print the
# diagnostic and continue into cleanup. Refuse by name before sourcing.
teardown_require_source() {  # <path>
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "error: teardown refused: required source $(basename "$1") is missing or unreadable; nothing was changed" >&2
    exit 1
  fi
}

teardown_require_backend_prerequisites() {  # <backend> <task-id>
  local backend=$1 task_id=$2
  if ! fm_backend_source "$backend"; then
    echo "error: teardown refused: required $backend source is missing or unreadable for $task_id; nothing was changed" >&2
    return 1
  fi
}

for _teardown_source in \
  fm-tasks-axi-lib.sh \
  fm-backlog-transition-lib.sh \
  fm-timeout-lib.sh \
  fm-backend.sh \
  fm-control-lib.sh \
  fm-lock-lib.sh \
  fm-classify-lib.sh \
  fm-gate-refuse-lib.sh \
  fm-pr-lib.sh \
  fm-env-lib.sh \
  fm-remote-registry-lib.sh \
  fm-operational-input.sh \
  fm-marker-lib.sh \
  fm-tmux-lib.sh \
  fm-composer-lib.sh \
  fm-cursor-lib.sh \
  fm-nm-run-lib.sh \
  fm-wake-lib.sh \
  fm-path-lib.sh \
  fm-lease-lib.sh
do
  teardown_require_source "$SCRIPT_DIR/$_teardown_source"
done
unset _teardown_source
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-remote-registry-lib.sh
. "$SCRIPT_DIR/fm-remote-registry-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# Archive paths live only in teardown; presentation/wake readers stay unaware.
teardown_archive_directory() {  # <directory>
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
    echo "error: unsafe status archive directory: $1" >&2
    return 1
  fi
  mkdir -p -- "$1"
}

teardown_prune_status_archives() {  # <task-directory>
  local dir=$1 child file suffix
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  while IFS= read -r -d '' file; do
    suffix=${file##*/}
    case "$suffix" in
      status.log|.status-archive.*) ;;
      *) suffix=${suffix#status.}; suffix=${suffix%.log}
         case "$suffix" in ''|*[!0-9]*) continue ;; esac ;;
    esac
    rm -f -- "$file" || echo "warning: could not prune status archive: $file" >&2
  done < <(find "$dir" -maxdepth 1 -type f \
    \( -name status.log -o -name 'status.[0-9]*.log' -o -name '.status-archive.*' \) \
    -mtime +30 -print0 || echo "warning: could not scan status archives: $dir" >&2)
  [ ! -L "$dir/children" ] || return 0
  for child in "$dir/children"/*; do
    teardown_prune_status_archives "$child"
  done
  return 0
}

teardown_task_result() {
  local kind=$1 mode=$2 pr_url=$3 observed_result=${4:-} line verb last_terminal='' ready=0
  if [ "$kind" = scout ] && [ -f "$DATA/$ID/report.md" ]; then
    printf 'accepted\n'
    return
  fi
  if [ "$kind" = ship ] && [ "$mode" != local-only ] && fm_pr_url_parse "$pr_url" \
    && fm_pr_poll_merge_already_notified "$STATE" "$ID" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    printf 'accepted\n'
    return
  fi
  case "$observed_result" in accepted|dropped) printf '%s\n' "$observed_result"; return ;; esac

  if [ "$kind" = ship ] && [ "$mode" = local-only ] && local_delivery_landed; then
    printf 'accepted\n'
    return
  fi
  if [ -f "$STATE/$ID.status" ] && [ ! -L "$STATE/$ID.status" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *:*) ;; *) continue ;; esac
      status_line_verb "$line" verb
      case "$verb" in
        working) last_terminal='' ;;
        done) ready=1; last_terminal=$verb ;;
        failed|dropped|cancelled|stopped) last_terminal=$verb ;;
      esac
    done < "$STATE/$ID.status"
  fi
  case "$last_terminal" in dropped|cancelled|stopped) printf 'dropped\n'; return ;; esac
  if { [ "$last_terminal" = failed ] || [ "$observed_result" = failed ]; } \
    && [ "$ready" = 0 ] && [ -z "$pr_url" ]; then
    printf 'failed\n'
  elif [ "$FORCE" = --force ]; then
    printf 'dropped\n'
  else
    printf 'missing\n'
  fi
}

teardown_archive_result() {
  local kind=$1 mode=$2 result=$3 generation endpoint
  local archive="$STATE/status-archive" dir file tmp
  case "$kind" in ship) ;; scout) mode='' ;; *) return 0 ;; esac
  fm_task_id_path_safe "$ID" || return 1
  generation=$(fm_meta_get "$META" spawn_gen)
  endpoint=$(fm_meta_get "$META" window)
  dir="$archive/$ID"
  file="$dir/result"
  teardown_archive_directory "$archive" && teardown_archive_directory "$dir" || return 1
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    return 1
  fi
  if [ -n "$generation" ] && [ -f "$file" ] && [ "$(fm_meta_get "$file" spawn_gen)" = "$generation" ]; then
    return 0
  fi
  tmp=$(mktemp "$dir/.result.XXXXXX") || return 1
  if ! printf 'spawn_gen=%s\nkind=%s\nmode=%s\nendpoint=%s\nresult=%s\n' \
    "$generation" "$kind" "$mode" "$endpoint" "$result" > "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

teardown_retire_status() {  # <state> <task-id> [<archive-relative-directory>]
  local state=$1 task=$2 relative=${3:-$2} dir part archive n=0 entry
  if [ ! -e "$CONFIG/status-archive" ]; then
    status_retire_presentation_task "$state" "$task"
    return $?
  fi
  # Preserve the remote-home no-op, including its lock-free fast path.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ]; then
    status_retire_presentation_task "$state" "$task"
    return $?
  fi
  if [ -L "$state/$task.status" ] || [ ! -f "$state/$task.status" ]; then
    echo "error: unsafe status archive source: $state/$task.status" >&2
    return 1
  fi
  # The configured root may itself be relocated through a symlink; only
  # archive components below that trusted root must refuse symlinks.
  mkdir -p -- "$DATA" || return 1
  dir=$(CDPATH='' cd -- "$DATA" && pwd -P) || return 1
  while [ -n "$relative" ]; do
    part=${relative%%/*}
    fm_task_id_path_safe "$part" || {
      echo "error: unsafe status archive path component: $part" >&2
      return 1
    }
    dir="$dir/$part"
    teardown_archive_directory "$dir" || return 1
    case "$relative" in */*) relative=${relative#*/} ;; *) relative= ;; esac
  done
  archive="$dir/status.log"
  while [ -e "$archive" ] || [ -L "$archive" ]; do
    n=$((n + 1))
    archive="$dir/status.$n.log"
  done
  status_retire_presentation_task "$state" "$task" "$archive" || {
    echo "error: status archival failed for $task; retaining live status for retry" >&2
    return 1
  }
  for entry in "$DATA"/*; do
    teardown_prune_status_archives "$entry"
  done
}

teardown_export_records() {  # <state> <task-id>
  local state=$1 task=$2
  if [ ! -e "$CONFIG/record-export-root" ] && [ ! -L "$CONFIG/record-export-root" ]; then
    return 0
  fi
  if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    if [ ! -d "$CONFIG" ] || [ -L "$CONFIG" ] || [ ! -r "$CONFIG" ] || [ ! -x "$CONFIG" ]; then
      echo "error: record export config directory is inaccessible or unsafe: $CONFIG" >&2
      echo "error: record export archive failed for $task; retaining task records for retry" >&2
      return 1
    fi
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_RECORD_EXPORT_META_LOCK_HELD=1 \
    "$SCRIPT_DIR/fm-record-export.sh" archive-task "$task" || {
      echo "error: record export archive failed for $task; retaining task records for retry" >&2
      return 1
    }
}

if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
TEARDOWN_LOST_SLOT_EXIT=4
FORCE=
LEGACY_RECORD_GIVEN=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=--force ;;
    --legacy-record) LEGACY_RECORD_GIVEN=1 ;;
    *)
      echo "error: invalid teardown request" >&2
      exit 2
      ;;
  esac
  shift
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Supervision lease guard: post-landing cleanup is overlap territory between
# the two Pi supervision actors; refuse while the OTHER actor holds this
# task's live lease (contract: bin/fm-lease-lib.sh; no-op in homes without
# leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# Role partition: forced teardown discards work, and the supervision branch
# never discards anything - only an ordinary landed-work teardown is branch
# territory (contract: bin/fm-lease-lib.sh).
if [ "$FORCE" = --force ] && [ "$(fm_lease_actor)" = branch ]; then
  echo "error: forced teardown refused - the supervision branch cannot discard work" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
fi
fm_lease_guard "$ID" "teardown (fm-teardown)"

META="$STATE/$ID.meta"
TREEHOUSE_PROJECT_LOCK=
TREEHOUSE_PROJECT_LOCK_HELD=0
TREEHOUSE_SLOT_LOCK_REQUIRED=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  TEARDOWN_LOCK_BACKEND=$(fm_meta_get "$META" backend)
  [ -n "$TEARDOWN_LOCK_BACKEND" ] || TEARDOWN_LOCK_BACKEND=tmux
  TEARDOWN_LOCK_WT=$(fm_meta_get "$META" worktree)
  TEARDOWN_LOCK_PROJECT=$(fm_meta_get "$META" project)
  if [ "$TEARDOWN_LOCK_BACKEND" != orca ] \
     && fm_treehouse_pool_slot "$TEARDOWN_LOCK_PROJECT" "$TEARDOWN_LOCK_WT"; then
    TREEHOUSE_SLOT_LOCK_REQUIRED=1
    TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$TEARDOWN_LOCK_PROJECT") || {
      echo "REFUSED: cannot resolve the shared Treehouse project lock for ${TEARDOWN_LOCK_PROJECT:-<missing>}; nothing was changed" >&2
      exit 1
    }
    fm_lock_try_acquire "$TREEHOUSE_PROJECT_LOCK" || {
      echo "REFUSED: another Treehouse slot allocation or return is in progress for $TEARDOWN_LOCK_PROJECT; nothing was changed" >&2
      exit 1
    }
    TREEHOUSE_PROJECT_LOCK_HELD=1
  fi
fi
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TEARDOWN_HERDR_LOCK_RECORDS=
teardown_release_locks() {
  local status=$?
  if declare -F teardown_release_herdr_locks >/dev/null 2>&1; then
    teardown_release_herdr_locks || true
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TREEHOUSE_PROJECT_LOCK" || true
    TREEHOUSE_PROJECT_LOCK_HELD=0
  fi
  fm_lease_guard_release || true
  return "$status"
}
trap teardown_release_locks EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown

fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
TEARDOWN_META_KIND=$(fm_meta_get "$META" kind)
[ -n "$TEARDOWN_META_KIND" ] || TEARDOWN_META_KIND=ship
case "$TEARDOWN_META_KIND" in
  ship|scout) ;;
  *) echo "REFUSED: task $ID has an unsupported recorded kind; nothing was changed" >&2; exit 1 ;;
esac
TEARDOWN_CLEANUP_RECOVERY=$(fm_meta_get "$META" cleanup_recovery)
TEARDOWN_META_SPAWN_GEN=
TEARDOWN_LEGACY_PENDING=0
TEARDOWN_LEGACY_ACCEPTED=0
TEARDOWN_LEGACY_ENDPOINT=
TEARDOWN_LEGACY_RETAINED_STAMP=
TEARDOWN_LEGACY_PRESTAMP_SIZE=0
TEARDOWN_BACKLOG_APPLIES=0
TEARDOWN_BACKLOG_SKIP_REASON=
TEARDOWN_WINDOWLESS=0
TEARDOWN_WINDOWLESS_SHAPE=0
TEARDOWN_WINDOW_COUNT=$(LC_ALL=C grep -c '^window=' "$META" 2>/dev/null || true)
TEARDOWN_BACKEND_COUNT=$(LC_ALL=C grep -c '^backend=' "$META" 2>/dev/null || true)
case "$TEARDOWN_WINDOW_COUNT:$(fm_meta_get "$META" window)" in
  0:|1:)
    case "$TEARDOWN_BACKEND_COUNT:$(fm_meta_get "$META" backend)" in
      0:|1:tmux)
        TEARDOWN_FOREIGN_ENDPOINT_KEYS='^terminal='
        for TEARDOWN_FOREIGN_BACKEND in $FM_BACKEND_KNOWN; do
          [ "$TEARDOWN_FOREIGN_BACKEND" = tmux ] \
            || TEARDOWN_FOREIGN_ENDPOINT_KEYS="$TEARDOWN_FOREIGN_ENDPOINT_KEYS|^${TEARDOWN_FOREIGN_BACKEND}_"
        done
        if ! LC_ALL=C grep -Eq "$TEARDOWN_FOREIGN_ENDPOINT_KEYS" "$META" 2>/dev/null; then
          TEARDOWN_SHAPE_META=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-teardown-shape.XXXXXX") || exit 1
          { LC_ALL=C grep -v '^window=' "$META" || true; printf 'window=leftover:fm-%s\n' "$ID"; } \
            > "$TEARDOWN_SHAPE_META"
          if fm_backend_validate_task_endpoint "$TEARDOWN_SHAPE_META" "$ID" 2>/dev/null; then
            TEARDOWN_WINDOWLESS_SHAPE=1
          fi
          rm -f "$TEARDOWN_SHAPE_META"
        fi
        ;;
    esac
    ;;
esac
if [ "$TEARDOWN_CLEANUP_RECOVERY" != orca ]; then
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$TEARDOWN_META_KIND"; then
    TEARDOWN_BACKLOG_APPLIES=1
  else
    TEARDOWN_BACKLOG_GATE_STATUS=$?
    if [ "$TEARDOWN_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: task $ID cannot be torn down because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    TEARDOWN_BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
  fi
fi
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  if ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
    TEARDOWN_LEGACY_GEN_COUNT=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$META" 2>/dev/null || printf '0\n')
    if [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ] && [ "$TEARDOWN_WINDOWLESS_SHAPE" = 1 ]; then
      # A tmux record with no window names no live endpoint, so there is no
      # incarnation for spawn_gen to identify and nothing for --legacy-record
      # to classify. Accept it as a missing-endpoint leftover, with or without
      # the flag; a still-present worktree still faces the ordinary landed-work
      # checks below.
      TEARDOWN_WINDOWLESS=1
      TEARDOWN_LEGACY_PENDING=1
    elif [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ] && [ "$LEGACY_RECORD_GIVEN" = 1 ]; then
      # A record that predates the incarnation field: acceptance is gated later,
      # once the recorded endpoint is known, so its state can be confirmed dead
      # or agent-less before any cleanup decision is made.
      TEARDOWN_LEGACY_PENDING=1
    elif [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ]; then
      echo "error: task $ID's record has no spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
      exit 1
    else
      echo "error: task $ID's record has an unreadable spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - fix the record, then retry teardown" >&2
      exit 1
    fi
  else
    case "$FM_BACKLOG_META_SPAWN_GEN" in
      legacy-*)
        # Only this teardown path mints a legacy- token; a launch publishes
        # s<epoch>.<pid>.<random>. So one still on a retained record is the
        # stamp an abandoned --legacy-record attempt could not roll back, not
        # an incarnation any spawn ever published. The record is still the
        # legacy record it was, and is treated as one: the dead-or-agent-less
        # endpoint gate runs again on the retry instead of being skipped by
        # the abandoned attempt's own stamp.
        if [ "$TEARDOWN_WINDOWLESS_SHAPE" = 1 ]; then
          TEARDOWN_WINDOWLESS=1
        elif [ "$LEGACY_RECORD_GIVEN" != 1 ]; then
          echo "error: task $ID's record carries the legacy incarnation stamp $FM_BACKLOG_META_SPAWN_GEN left by an abandoned --legacy-record teardown, not an incarnation published by a spawn; refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
          exit 1
        fi
        TEARDOWN_LEGACY_PENDING=1
        TEARDOWN_LEGACY_RETAINED_STAMP=$FM_BACKLOG_META_SPAWN_GEN
        ;;
    esac
  fi
  [ "$TEARDOWN_LEGACY_PENDING" = 1 ] || TEARDOWN_META_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
fi
# Cleanup never closes a captain call (see the header). Asked here, before any
# destructive step, so "cannot tell" can refuse while everything is intact.
TEARDOWN_BACKLOG_TRANSITION=close
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  TEARDOWN_CAPTAIN_OPEN_STATUS=0
  TEARDOWN_CAPTAIN_OPEN_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" 2>&1) || TEARDOWN_CAPTAIN_OPEN_STATUS=$?
  case "$TEARDOWN_CAPTAIN_OPEN_STATUS" in
    0) TEARDOWN_BACKLOG_TRANSITION=retain ;;
    1) ;;
    *)
      echo "error: task $ID cannot be torn down because whether its backlog item is still held for the captain could not be read; fix that read and retry rather than risk closing a captain call with no recorded answer" >&2
      [ -z "$TEARDOWN_CAPTAIN_OPEN_OUT" ] || printf '%s\n' "$TEARDOWN_CAPTAIN_OPEN_OUT" >&2
      exit 1
      ;;
  esac
fi

retire_busy_state() {
  local state_dir=$1 id=$2 gen=${3:-}
  # A remote host's route state lives inside the secondmate home this removed.
  [ -d "$state_dir" ] || return 0
  if [ -n "$gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ] \
      || { [ "$artifact" = "$state_dir/$id.merge-authority" ] \
        && [ "$(fm_pr_file_mode "$artifact")" != 600 ]; }; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust" || return 1
}

scout_captain_gate_verify() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null && return 0
  echo "REFUSED: scout task $ID has not passed the captain-call completion gate." >&2
  echo "Inventory its report and any visual review through bin/fm-captain-hold.sh before teardown." >&2
  return 1
}

# An execution home holds no backlog and no captain-call inventory: the
# supervising home verifies the gate before it asks this home to clean up.
home_is_execution_home() {
  [ -f "$FM_HOME/.fm-exec-home" ] && [ ! -L "$FM_HOME/.fm-exec-home" ]
}

# The host-side teardown owns the landed-work test, the slot return, and the
# pane close. A 255 or 124 leaves its completion unknown, so nothing local changes.
remote_worker_teardown() {
  local route host kind mode project_name pr_url window busy_gen out rc=0 marker data_relative result
  local remote_target remote_result='' candidate
  local -a done_args flags hop_args
  route=$(fm_meta_get "$META" remote_route)
  host=$(fm_meta_get "$META" remote_host)
  kind=$TEARDOWN_META_KIND
  [ -n "$route" ] && [ -n "$host" ] || { echo "REFUSED: remote worker metadata is incomplete" >&2; return 1; }
  [ "$(fm_remote_registry_field "$DATA/remote-homes.md" "$route" host 2>/dev/null || true)" = "$host" ] \
    || { echo "REFUSED: remote worker $ID's execution home $route is not registered for host $host" >&2; return 1; }
  [ "$TEARDOWN_LEGACY_PENDING" != 1 ] \
    || { echo "REFUSED: remote worker $ID's record has no spawn_gen; relaunch it to publish an incarnation, then retry" >&2; return 1; }
  mode=$(fm_meta_get "$META" mode)
  project_name=$(fm_meta_get "$META" project)
  project_name=${project_name##*/}
  [ -n "$mode" ] || mode=no-mistakes
  pr_url=$(fm_meta_get "$META" pr)
  done_args=()
  if [ "$kind" = scout ]; then
    if [ -f "$DATA/$ID/report.md" ]; then
      data_relative=$(fm_backlog_data_relative "$DATA") || return 1
      done_args=(--report "$data_relative/$ID/report.md")
    elif [ "$FORCE" = --force ]; then
      [ "$TEARDOWN_BACKLOG_TRANSITION" = retain ] || done_args=(--note discarded)
    else
      echo "REFUSED: scout task $ID's report has not reached this home at $DATA/$ID/report.md; wait for its status feed, or use --force after explicit discard approval" >&2
      return 1
    fi
    [ "$FORCE" = --force ] || scout_captain_gate_verify || return 1
  elif [ "$mode" = local-only ]; then
    done_args=(--note "local main")
  elif [ -n "$pr_url" ]; then
    done_args=(--pr "$pr_url")
  fi
  validate_pr_poll_cleanup "$STATE" "$ID" || return 1
  hop_args=(fm-remote-worker-control.sh teardown "$ID")
  [ "$FORCE" != --force ] || hop_args+=(--force)
  out=$(fm_run_timed "${FM_TEARDOWN_REMOTE_BUDGET:-900}" "$SCRIPT_DIR/fm-on.sh" "$route" "${hop_args[@]}" < /dev/null 2>&1) || rc=$?
  case "$rc" in
    0|"$TEARDOWN_LOST_SLOT_EXIT") ;;
    124|255)
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      echo "error: remote cleanup of $ID on $route did not confirm completion; every local record is preserved, rerun teardown to reconcile" >&2
      return 1
      ;;
    *)
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      echo "REFUSED: remote cleanup of $ID on $route refused (exit $rc); every local record is preserved" >&2
      return 1
      ;;
  esac
  [ "$rc" -eq 0 ] || printf '%s\n' "$out" | grep -E '^(warning: treehouse return left pool slot |  )' >&2 || true
  teardown_export_records "$STATE" "$ID" || return 1
  remote_target=$(fm_meta_get "$META" remote_target)
  if [ -n "$remote_target" ]; then
    for candidate in accepted dropped failed; do
      if grep -Fxq -- "task-result $remote_target $candidate" <<< "$out"; then
        if [ -n "$remote_result" ]; then remote_result=''; break; fi
        remote_result=$candidate
      fi
    done
  fi
  result=$(teardown_task_result "$kind" "$mode" "$pr_url" "$remote_result")
  teardown_archive_result "$kind" "$mode" "$result" || {
    echo "error: could not archive the result for $ID; retaining task records for retry" >&2
    return 1
  }
  remove_pr_poll_artifacts "$STATE" "$ID" || return 1
  busy_gen=$(fm_meta_get "$META" busy_gen)
  retire_busy_state "$STATE" "$ID" "$busy_gen" || return 1
  [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" cleaned_up "$ID" || true
  teardown_retire_status "$STATE" "$ID" || return 1
  window=$(fm_meta_get "$META" window)
  fm_wake_queue_prune_task "$STATE" "$ID" "$window" 2>/dev/null || true
  rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress" \
    "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
    "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
    "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note" \
    "$STATE/$ID.reconcile-nudged" "$STATE/$ID.pr-register-refused" "$STATE/.$ID.branch-outcome-index"
  rm -rf "$STATE/$ID.inbox"
  if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
    flags=()
    [ "$TEARDOWN_BACKLOG_TRANSITION" = close ] || flags=(--retain)
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$TEARDOWN_META_SPAWN_GEN" \
      ${flags[@]+"${flags[@]}"} ${done_args[@]+"${done_args[@]}"} || {
      echo "error: $ID's remote copy is cleaned up, but its pending backlog $TEARDOWN_BACKLOG_TRANSITION could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); rerun teardown" >&2
      return 1
    }
    marker=$(fm_backlog_close_marker_path "$STATE" "$ID") || return 1
    fm_backlog_atomic_transition "$TEARDOWN_BACKLOG_TRANSITION" "$STATE/$ID.meta" "$marker" \
      "$DATA" "$ID" "$STATE" ${done_args[@]+"${done_args[@]}"} || {
      echo "error: $ID's remote copy is cleaned up, but its backlog item could not be updated atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending change is recorded and the next session start retries it" >&2
      return 1
    }
  else
    fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE" || {
      echo "error: $ID's remote copy is cleaned up, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 1
    }
  fi
  rm -f "$STATE/.remote-agent-$ID" "$STATE/.remote-ring-$ID" "$STATE/.remote-ring-escalated-$ID" \
    || return 1
  "$SCRIPT_DIR/fm-procevent-remote-feed.sh" retire-task "$route" "$ID" \
    || echo "warning: $ID's status-feed cursor for $route was not retired; it is ignored once no record names the task" >&2
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
  if [ "$kind" != scout ] && [ "$mode" != local-only ]; then
    [ -z "$project_name" ] || [ ! -d "$FM_HOME/projects/$project_name" ] \
      || "$FM_ROOT/bin/fm-fleet-sync.sh" "$project_name" || true
  fi
  printf 'teardown %s complete (remote %s on %s)\n' "$ID" "$route" "$host"
  return "$rc"
}

if [ -n "$(fm_meta_get "$META" remote_route)" ]; then
  if remote_worker_teardown; then remote_teardown_rc=0; else remote_teardown_rc=$?; fi
  exit "$remote_teardown_rc"
fi

# This is the first cleanup authorization check. It is metadata-only and must
# complete before fm-guard, a backend command, file removal, branch deletion,
# worktree return, registry change, or process termination can run.
# A windowless record names no endpoint: the shared validator would refuse it
# (and must keep refusing it for control/kill callers), so teardown skips the
# validator rather than probing or closing an ambient current window.
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
T_ORCA=
if [ "$TEARDOWN_WINDOWLESS" = 1 ]; then
  BACKEND=tmux
  T=
else
  fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  T=$FM_BACKEND_VALIDATED_TARGET
  [ "$BACKEND" != orca ] || T_ORCA=$T
fi
# The recorded backend, including every sibling its adapter sources, has to
# be readable before the first destructive step. --force does not override
# this. A forced descendant is proved in validate_firstmate_home_children_removal.
teardown_require_backend_prerequisites "$BACKEND" "$ID" || exit 1
# The T3 capability and identity gate must pass before local teardown mutation,
# even under --force.
if [ "$BACKEND" = t3code ]; then
  fm_backend_runtime_check t3code || exit 1
fi
if [ "${FM_TEARDOWN_GUARD_DONE:-0}" != 1 ]; then
  "$FM_ROOT/bin/fm-guard.sh" || true
fi
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
if [ -z "$BUSY_GEN" ]; then
  BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fi
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0
CLEANUP_RECOVERY=$TEARDOWN_CLEANUP_RECOVERY

KIND=$TEARDOWN_META_KIND
TEARDOWN_POOL_SLOT_LOST=0
EXPECTED_TREEHOUSE_PROJECT_LOCK=
if [ "$BACKEND" != orca ] \
   && fm_treehouse_pool_slot "$PROJ" "$WT"; then
  EXPECTED_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ") || {
    echo "REFUSED: cannot resolve the shared Treehouse project lock for ${PROJ:-<missing>}; nothing was changed" >&2
    exit 1
  }
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" != 1 ] \
     || [ "$TREEHOUSE_PROJECT_LOCK" != "$EXPECTED_TREEHOUSE_PROJECT_LOCK" ]; then
    echo "REFUSED: task $ID's Treehouse project identity changed while teardown acquired its locks; nothing was changed" >&2
    exit 1
  fi
elif [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ]; then
  echo "REFUSED: task $ID stopped naming a live Treehouse slot while teardown acquired its locks; nothing was changed" >&2
  exit 1
fi
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
BASE_BRANCH=$(grep '^base_branch=' "$META" | cut -d= -f2- || true)

# A record accepted as a legacy incarnation (no spawn_gen, and either
# --legacy-record given or the record is windowless) may be torn down only
# when its recorded endpoint is confidently gone or agent-less. Windowless
# leftovers name no endpoint and are treated as missing. For a recorded
# window, only the recovery-grade classifier's dead and missing license
# that, and every ambiguous, unreadable, or unverified endpoint state refuses
# while the record is still intact. Acceptance resolves the incarnation token
# here; the record itself is stamped only once every landed-work refusal has
# passed, immediately before the close marker binds to it, so any refusal
# leaves the record byte-identical.
if [ "$TEARDOWN_LEGACY_PENDING" = 1 ]; then
  if [ "$TEARDOWN_WINDOWLESS" = 1 ]; then
    TEARDOWN_LEGACY_ENDPOINT=missing
  else
    TEARDOWN_LEGACY_ENDPOINT=$(fm_backend_agent_state "$BACKEND" "$T")
    case "$TEARDOWN_LEGACY_ENDPOINT" in
      dead|missing) ;;
      *)
        echo "REFUSED: task $ID's record predates spawn_gen and its recorded endpoint reads '$TEARDOWN_LEGACY_ENDPOINT', not confidently dead or agent-less; --legacy-record teardown is refused while an agent may still be bound to it. Nothing was changed." >&2
        echo "Reconcile the endpoint first (bin/fm-crew-state.sh $ID), or relaunch the task to publish an unambiguous incarnation, then retry teardown." >&2
        exit 1
        ;;
    esac
  fi
  if [ -n "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_META_SPAWN_GEN=$TEARDOWN_LEGACY_RETAINED_STAMP
  else
    TEARDOWN_META_SPAWN_GEN="legacy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  TEARDOWN_LEGACY_ACCEPTED=1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

# Remove only Polytoken's firstmate-generated worktree wiring, as named by
# fm_control_harness_wiring_paths. Its tracked hook and facet layers belong to
# the project. Other harnesses retain their existing worktree-return cleanup.
remove_harness_worktree_wiring() {  # <worktree>
  local wt=$1 path
  [ "$(meta_value "$META" harness)" = polytoken ] || return 0
  while IFS= read -r path; do
    case "$path" in "$wt"/*) ;; *) continue ;; esac
    git -C "$wt" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 && continue
    rm -f "$path"
  done <<EOF
$(fm_control_harness_wiring_paths "$(meta_value "$META" harness)" "$wt" "$STATE" "$ID")
EOF
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so teardown and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.
remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path grok "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path grok "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path kimi "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path kimi "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    *"/pulls/"*)  # Forgejo addresses pulls as /pulls/<n> and serves refs/pull/<n>/head.
      n=${target##*/pulls/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  # Indentation can change semantics. Unsupported --verbatim yields no id,
  # so callers fall back to the content check or refuse, never ignore whitespace.
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --verbatim 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --exclude='no-mistakes/*' --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

local_delivery_landed() {
  local head target
  head=$(fm_meta_get "$META" local_done_head)
  fm_pr_head_valid "$head" || return 1
  target=$(default_branch) || return 1
  git -C "$PROJ" merge-base --is-ancestor "$head" "refs/heads/$target" 2>/dev/null
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks the
# forge for both the PR state and head: a recorded Forgejo URL is read through
# tea (fm_pr_forgejo_read_record), and everything else through GitHub. Returns
# non-zero when the PR is not merged, the current work is not contained in the
# PR head, no PR is found, or any forge read error occurs - the caller then
# falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state remainder head resolved_url current landed=0
  PR_MERGE_LOOKUP=error
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(fm_pr_number_from_branch "$WT" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  if fm_pr_url_parse "$target" && [ "$FM_PR_PROVIDER" = forgejo ]; then
    fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || return 1
    if [ "$FM_PR_RECORD_MERGED" != true ]; then
      [ "$FM_PR_RECORD_STATE" != CLOSED ] || TEARDOWN_PR_RESULT=dropped
      PR_MERGE_LOOKUP=open
      return 1
    fi
    head=$FM_PR_RECORD_HEAD
    fm_pr_head_valid "$head" || return 1
    resolved_url=$FM_PR_URL
  else
    view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
    state=${view%%$'\t'*}
    remainder=${view#*$'\t'}
    [ "$state" != "$view" ] || return 1
    head=${remainder%%$'\t'*}
    resolved_url=${remainder#*$'\t'}
    [ "$head" != "$remainder" ] || return 1
    case "$state" in
      MERGED|merged) ;;
      CLOSED|closed) TEARDOWN_PR_RESULT=dropped; PR_MERGE_LOOKUP=open; return 1 ;;
      *) PR_MERGE_LOOKUP=open; return 1 ;;
    esac
  fi
  TEARDOWN_PR_RESULT=accepted
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif unpushed_patches_are_in_pr_head "$head"; then
    landed=1
  elif head_in_default; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$PR_URL" ]; then
    [ -n "$resolved_url" ] || return 1
    PR_URL=$resolved_url
  fi
  PR_MERGE_LOOKUP=merged
  return 0
}

# Prints the URL of the still-open PR whose head is <branch>. Returns non-zero
# when no PR is found, it is merged or closed, or the forge cannot be read.
open_pr_for_branch() {
  local branch=$1 number view state url
  number=$(fm_pr_number_from_branch "$WT" "$branch") || return 1
  view=$(cd "$WT" && gh pr view "$number" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  url=${view##*$'\t'}
  case "$state" in
    OPEN|open) ;;
    CLOSED|closed) TEARDOWN_PR_RESULT=dropped; return 1 ;;
    MERGED|merged) TEARDOWN_PR_RESULT=accepted; return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$url" ] && [ "$url" != "$view" ] || return 1
  OPEN_PR_URL=$url
}

up_to_date_default_ref() {
  local name=${BASE_BRANCH:-}
  [ -n "$name" ] || name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    printf '%s\n' "refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/$name"
  else
    return 1
  fi
}

head_in_default() {
  local ref
  ref=$(up_to_date_default_ref) || return 1
  git -C "$WT" merge-base --is-ancestor HEAD "$ref" 2>/dev/null
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, a merge conflict,
# or a Git error), so the caller refuses rather than guesses.
# CONTENT_LANDED_PROOF_ERROR names a merge-tree option or execution failure
# separately from a conflict or differing tree.
content_in_default() {
  local ref default_tree merged_tree merge_status
  CONTENT_LANDED_PROOF_ERROR=
  ref=$(up_to_date_default_ref) || return 1
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || {
    merge_status=$?
    case "$merge_status" in
      1) ;; # Git completed the merge and found conflicts.
      129) CONTENT_LANDED_PROOF_ERROR='git merge-tree --write-tree was rejected (Git 2.38 or newer required)' ;;
      *) CONTENT_LANDED_PROOF_ERROR="git merge-tree --write-tree failed (Git exit $merge_status)" ;;
    esac
    return 1
  }
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# when neither proof establishes that the work landed.
work_is_landed() {
  local branch=$1
  case "$PR_URL" in
    https://github.com/*/pull/[0-9]*)
      pr_is_merged "$branch"
      return $?
      ;;
  esac
  pr_is_merged "$branch" && return 0
  content_in_default
}

# The completion links this teardown already holds locally. A retained scout
# keeps its report as the held deliverable, while a force-closed scout is
# recorded as discarded with no report. A local-only ship lands on local main,
# and every other ship carries the PR recorded on its own record.
BACKLOG_DONE_ARGS=()
backlog_done_args() {
  local data_relative
  BACKLOG_DONE_ARGS=()
  case "$KIND" in
    scout)
      if [ "$BACKLOG_TRANSITION" = retain ]; then
        if [ -f "$DATA/$ID/report.md" ]; then
          data_relative=$(fm_backlog_data_relative "$DATA") || return 1
          BACKLOG_DONE_ARGS=(--report "$data_relative/$ID/report.md")
        fi
      elif [ "$FORCE" = "--force" ]; then
        BACKLOG_DONE_ARGS=(--note "discarded")
      else
        data_relative=$(fm_backlog_data_relative "$DATA") || return 1
        BACKLOG_DONE_ARGS=(--report "$data_relative/$ID/report.md")
      fi
      ;;
    *)
      if [ "$MODE" = local-only ]; then
        BACKLOG_DONE_ARGS=(--note "local main")
      elif [ -n "$PR_URL" ]; then
        BACKLOG_DONE_ARGS=(--pr "$PR_URL")
      fi
      ;;
  esac
}

# Closing the backlog item is this script's own last act on the record, not a
# printed instruction for a later turn (bin/fm-backlog-transition-lib.sh owns the
# invariant). This prints what already happened, so the follow-up wording stays
# only where a human still owes the edit.
backlog_refresh_reminder() {
  local backlog_display root backend=markdown
  [ "$CLEANUP_RECOVERY" = orca ] && return 0
  if root=$(fm_backlog_root "$DATA"); then
    backend=$(fm_tasks_axi_backend "$root") || return 2
  fi
  if [ "$backend" != markdown ]; then
    backlog_display="this home's configured tasks-axi backend (data directory $DATA)"
  elif backlog_display=$(fm_backlog_file "$DATA"); then
    :
  else
    backlog_display="${DATA%/}/backlog.md"
  fi
  if [ "$BACKLOG_CLOSED" = 1 ] && [ "$BACKLOG_TRANSITION" = retain ]; then
    printf '%s\n' "Backlog: $ID stays open in $backlog_display, still held for the captain with its deliverable recorded. Relay the question and close it only with bin/fm-captain-hold.sh answer."
  elif [ "$BACKLOG_CLOSED" = 1 ]; then
    printf '%s\n' "Backlog: $ID is closed in $backlog_display. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished ($BACKLOG_SKIP_REASON). Update $backlog_display - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

report_worktree_dirt() {
  # Use the same porcelain snapshot and exemptions as the refusal predicate.
  printf '%s\n' "$1" | awk '
    /^\?\? / { if (++untracked <= 10) paths = paths "  " substr($0, 4) "\n"; next }
    NF { tracked = 1 }
    END {
      if (tracked) print "uncommitted changes present (includes tracked edits)"
      else print "uncommitted changes present (untracked-only leftovers)"
      if (untracked) {
        print "untracked paths (up to 10):"
        printf "%s", paths
        if (untracked > 10) print "  ... additional untracked paths omitted"
      }
    }
  ' >&2
}

# Scratch and --force copies are scrubbed before Treehouse return. See the
# script header for why `git clean -fd` is not enough and why a dirty return
# is not reported as clean.
teardown_scrub_scratch_copy() {
  local wt=$1
  # A non-git path has no nested repository this clean can remove.
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$wt" clean -ffdq || {
    echo "error: could not clean scratch in worktree $wt before returning it; teardown aborted" >&2
    return 1
  }
}

# Callers run this only for a copy that was a Treehouse pool slot before the
# return; a return removes any other copy, and the pool cannot lose it.
teardown_note_dirty_return() {
  local wt=$1 residue_rc=0 residue slot_dir slot_label
  if git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    residue=$(git -C "$wt" status --porcelain --untracked-files=all) || residue_rc=$?
    [ "$residue_rc" -ne 0 ] || [ -n "$residue" ] || return 0
  else
    residue_rc=1
  fi
  TEARDOWN_POOL_SLOT_LOST=1
  slot_dir=$(canonical_existing_dir "$wt") || slot_dir=$wt
  slot_label=$(basename "$(dirname "$slot_dir")")
  [ "$residue_rc" -eq 0 ] || residue="cannot verify: the copy is missing or not a readable git worktree after return"
  echo "warning: treehouse return left pool slot $slot_label ($wt) dirty or unverified; the pool lost this slot. Remaining paths:" >&2
  printf '%s\n' "$residue" | sed 's/^/  /' >&2
}

# A worker may have pushed from another checkout, so tracking refs that do not
# show the work prove nothing until they are refreshed. Runs at most once per
# teardown. Each fetch is bounded to 30 seconds and non-interactive, and
# --no-prune keeps a branch a remote has dropped visible, whatever fetch.prune
# says. The explicit
# refspec covers every branch even when a clone tracks only some of them. A failed
# fetch only leaves the last-known refs in place, so the unchanged checks below
# still refuse work those refs do not show; REMOTE_REFRESH_FAILED names it for the
# refusal. The no-mistakes gate is skipped: it is a local validation copy, and
# fetching it would count work as landed that no real remote holds.
REMOTE_REFS_REFRESHED=0
REMOTE_REFRESH_FAILED=
refresh_remote_refs() {
  local remote
  [ "$REMOTE_REFS_REFRESHED" = 0 ] || return 0
  REMOTE_REFS_REFRESHED=1
  while IFS= read -r remote; do
    case "$remote" in ''|no-mistakes) continue ;; esac
    GIT_TERMINAL_PROMPT=0 fm_run_timed 30 git -C "$WT" fetch --quiet --no-prune --no-tags --no-recurse-submodules \
      "$remote" "+refs/heads/*:refs/remotes/$remote/*" </dev/null >/dev/null 2>&1 \
      || REMOTE_REFRESH_FAILED="$REMOTE_REFRESH_FAILED${REMOTE_REFRESH_FAILED:+, }$remote"
  done <<EOF
$(git -C "$WT" remote 2>/dev/null)
EOF
}

report_remote_refresh_failure() {
  [ -n "$REMOTE_REFRESH_FAILED" ] || return 0
  echo "Could not refresh remote: $REMOTE_REFRESH_FAILED. This verdict used the last-known refs, so the work may be there; retry once the remote is reachable." >&2
}

# Sets the caller's $dirty from a fresh status read, or refuses when the copy
# cannot be inspected.
read_worktree_dirt() {
  local dirty_raw
  if ! dirty_raw=$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' || true)
}

validate_worktree_teardown_safety() {
  local dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch OPEN_PR_URL
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    scout) return 0 ;;
  esac

  read_worktree_dirt || return

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --exclude='no-mistakes/*' --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  # Dirty work refuses either way, so only a clean copy is worth the network.
  if [ -n "$unpushed_raw" ] && [ -z "$dirty" ] && [ "$REMOTE_REFS_REFRESHED" = 0 ]; then
    refresh_remote_refs
    # The task's processes are still running, so edits may have arrived during
    # the wait; the refusals below act on this fresh read.
    read_worktree_dirt || return
    if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --exclude='no-mistakes/*' --remotes -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on a remote"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && report_worktree_dirt "$dirty"
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      report_remote_refresh_failure
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    report_worktree_dirt "$dirty"
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      if [ -n "${CONTENT_LANDED_PROOF_ERROR:-}" ]; then
        echo "REFUSED: content-landed proof unavailable for worktree $WT: $CONTENT_LANDED_PROOF_ERROR." >&2
        echo "Restore or upgrade Git and retry the content check." >&2
      elif [ -n "$PR_URL" ]; then
        if [ "$PR_MERGE_LOOKUP" = open ]; then
          echo "REFUSED: recorded PR $PR_URL is not merged; cleanup requires GitHub to report it merged." >&2
        else
          echo "REFUSED: cannot verify recorded PR $PR_URL with GitHub; cleanup requires a confirmed merge." >&2
        fi
      else
        echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
        echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      fi
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      report_remote_refresh_failure
      return 1
    fi
  fi

  if [ -z "$PR_URL" ]; then
    case "$MODE" in
      direct-PR|no-mistakes) ;;
      *) return 0 ;;
    esac
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if open_pr_for_branch "$branch"; then
      echo "REFUSED: PR $OPEN_PR_URL is still open; cleanup waits for it to merge, because bin/fm-pr-merge.sh needs this task record." >&2
      return 1
    fi
    return 0
  fi

  case "$PR_URL" in
    https://github.com/*/pull/[0-9]*) ;;
    *) return 0 ;;
  esac
  if [ -n "$PR_URL" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! pr_is_merged "$branch"; then
      if [ "$PR_MERGE_LOOKUP" = open ]; then
        echo "REFUSED: recorded PR $PR_URL is not merged; cleanup requires GitHub to report it merged." >&2
      else
        echo "REFUSED: cannot verify recorded PR $PR_URL with GitHub; cleanup requires a confirmed merge." >&2
      fi
      return 1
    fi
  fi
}

# Fix 1 (see script header): does the active-or-most-recent no-mistakes run in
# worktree $1 belong to THIS task, and is it parked at a gate awaiting an agent
# that is about to be removed? Prints nothing; returns 0 only on a genuine
# match so the caller knows it is safe to abort - never a guess. Identity
# binds through the strict object-local head rule, with bin/fm-nm-run-lib.sh's
# shared ledger-anchored continuation rule as the only recognition for a head
# this copy cannot resolve at all.
NM_TEARDOWN_TIMEOUT=${FM_TEARDOWN_NM_TIMEOUT:-10}
case "$NM_TEARDOWN_TIMEOUT" in ''|*[!0-9]*) NM_TEARDOWN_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the parked-run
# continuation proof may scan, mirroring bin/fm-crew-state.sh's limit posture
# (generous: rows of other branches interleave freely in the real ledger).
NM_TEARDOWN_RUNS_LIMIT=${FM_TEARDOWN_NM_RUNS_LIMIT:-200}
case "$NM_TEARDOWN_RUNS_LIMIT" in ''|*[!0-9]*) NM_TEARDOWN_RUNS_LIMIT=200 ;; esac
TASK_RUN_ID=
task_status_is_own_parked_run() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 branch run_id run_branch run_head status outcome awaiting has_gate ledger
  TASK_RUN_ID=
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  [ -z "$outcome" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$status" ] || return 1
  case "$status" in
    completed|failed|cancelled|passed|checks-passed|running|fixing|ci) return 1 ;;
  esac
  if ! fm_nm_head_matches_worktree "$wt" "$run_head"; then
    # The strict object-local rule rejected this run head. That rejection is
    # final when the head object resolves in this copy (diverged or rewritten
    # tips are genuine mismatches), but when the object is absent entirely -
    # the pipeline committed its fix round in its own repo and this copy
    # never fetched it - the ONE shared runs-ledger rule in
    # bin/fm-nm-run-lib.sh owns the only remaining recognition, and it prints
    # nothing for any ledger shape it cannot prove, so the run stays
    # untouched unless the ledger proves this exact continuation. Cleanup
    # consumes only an explicitly active (`running`) proved word: a terminal
    # newest row is finished history, never this parked run's abort
    # authorization (the read path classifies the same owner's answer; the
    # abort here must never fire for a run that already ended).
    [ -n "$run_head" ] || return 1
    [ -z "$(fm_nm_resolve_commit "$wt" "$run_head")" ] || return 1
    ledger=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" runs --limit "$NM_TEARDOWN_RUNS_LIMIT")
    [ "$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger" "$run_head")" = running ] || return 1
  fi
  awaiting=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  has_gate=$(printf '%s\n' "$out" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && echo 1 || echo 0)
  case "$status" in
    awaiting_approval|fix_review) TASK_RUN_ID=$run_id; return 0 ;;
  esac
  if [ -n "$awaiting" ] || [ "$has_gate" = 1 ]; then
    TASK_RUN_ID=$run_id
    return 0
  fi
  return 1
}

task_run_is_own_parked_run() {  # <worktree>
  local wt=$1 out
  # Accepted best-effort residual: query failures stay fail-open because making
  # no-mistakes availability a prerequisite would block ship tasks with no run.
  out=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" axi status)
  task_status_is_own_parked_run "$wt" "$out"
}

task_status_is_terminal_run() {  # <axi-status-output> <run-id>
  local out=$1 expected_id=$2 run_id outcome
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$run_id" = "$expected_id" ] || return 1
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    cancelled|failed|passed|checks-passed|passed-with-override|passed-with-skips) return 0 ;;
  esac
  return 1
}

task_status_is_run_not_found() {  # <status-error> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# Abort THIS task's own parked no-mistakes run before the worker that would
# have answered its gate is removed, so no run is left orphaned holding a
# fleet slot. Only KIND=ship drives a no-mistakes validation of its own
# worktree (scouts and secondmates never do, mirroring bin/fm-crew-state.sh);
# a run not attributed to this exact branch+head is left completely alone.
conclude_task_no_mistakes_run() {  # <worktree>
  local wt=$1 out run_id
  [ "$KIND" = ship ] || return 0
  [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  task_run_is_own_parked_run "$wt" || return 0
  run_id=$TASK_RUN_ID
  echo "teardown: no-mistakes run for $ID is parked at a gate; aborting before the worker is removed" >&2
  # Accepted best-effort residual: abort supports run-id targeting but no atomic
  # live-state condition; fully closing the resume race needs upstream compare-and-cancel.
  fm_nm_run_checked "$wt" "$NM_TEARDOWN_TIMEOUT" axi abort --run "$run_id" >/dev/null 2>&1 || true
  if out=$(fm_nm_run_bounded "$wt" "$NM_TEARDOWN_TIMEOUT" axi status --run "$run_id" 2>&1); then
    task_status_is_terminal_run "$out" "$run_id" && return 0
  elif task_status_is_run_not_found "$out" "$run_id"; then
    return 0
  fi
  echo "REFUSED: no-mistakes run for $ID is still parked after axi abort; confirm it stopped (no-mistakes axi status) or abort it manually (no-mistakes axi abort --run <id>) before retrying teardown." >&2
  return 1
}

# Fix 2 (see script header): pids of every process whose CURRENT WORKING
# DIRECTORY is exactly $1 or under it, from one bounded system-wide `lsof -a
# -d cwd` scan (never the recursive +D file-tree walk, which lsof itself
# documents as slow). Never $$ (this script's own pid). Empty output when
# nothing matches; failure means the scan could not establish a safe result.
pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

task_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(fm_nm_trim "$value")
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

task_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(task_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

task_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

task_pids_under_roots() {  # <dir>...
  TASK_PIDS=
  TASK_PIDS_FAILED_DIR=
  local dir dir_pids pids=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! dir_pids=$(pids_with_cwd_under "$dir"); then
      TASK_PIDS_FAILED_DIR=$dir
      return 1
    fi
    pids="$pids
$dir_pids"
  done
  TASK_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

reap_task_backend_process_group() {  # <label>
  local label=$1 leader leader_start pgid current_pgid own_pgid
  if [ "$BACKEND" != tmux ]; then
    echo "warning: lsof is unavailable; cannot resolve a process-group fallback for $BACKEND task $ID" >&2
    return 0
  fi
  leader=$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null) || leader=""
  case "$leader" in ''|*[!0-9]*)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  leader_start=$(task_process_identity "$leader") || {
    echo "warning: lsof is unavailable; cannot identify the tmux pane process group for $ID" >&2
    return 0
  }
  pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || pgid=""
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*|0|1)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null) || own_pgid=""
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  if [ "$pgid" = "$own_pgid" ]; then
    echo "warning: lsof is unavailable; refusing to signal teardown's own process group for $ID" >&2
    return 0
  fi
  task_process_identity_matches "$leader" "$leader_start" || return 0
  current_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || current_pgid=""
  current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
  [ "$current_pgid" = "$pgid" ] || return 0
  echo "teardown: reaping leaked $label process group for $ID: $pgid" >&2
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 1
  if task_process_identity_matches "$leader" "$leader_start" \
     && [ "$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')" = "$pgid" ] \
     && kill -0 -- "-$pgid" 2>/dev/null; then
    echo "teardown: force-killing leaked $label process group for $ID: $pgid" >&2
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
}

# Reap every process rooted (by cwd) under this task's own worktree or tasktmp
# - both unique per task and never shared - before either is removed. TERM
# first, then KILL after a short grace period for anything still alive; a
# process that exits on its own between the two passes is simply absent from
# the recheck. A missing lsof uses the backend process-group fallback; an lsof
# scan error refuses before destructive teardown.
reap_task_worktree_processes() {  # <label> <dir>...
  local label=$1 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift
  if ! command -v lsof >/dev/null 2>&1; then
    reap_task_backend_process_group "$label"
    return 0
  fi
  while [ "$pass" -le "$max_passes" ]; do
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    pids=$TASK_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(task_process_identity "$pid"); then
        if ! task_pids_under_roots "$@"; then
          echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        if task_pid_list_contains "$TASK_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $ID; preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    echo "teardown: reaping leaked $label process(es) for $ID: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "teardown: force-killing leaked $label process(es) for $ID: ${remaining_pids[*]}" >&2
      if ! task_pids_under_roots "$@"; then
        echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
        return 1
      fi
      current_pids=$TASK_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if task_pid_list_contains "$current_pids" "$pid" \
           && task_process_identity_matches "$pid" "$identity"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  if ! task_pids_under_roots "$@"; then
    echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
    return 1
  fi
  [ -z "$TASK_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $ID remain after $max_passes reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
  return 1
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

# The task's own live slot, canonicalized, or empty when this record has no slot
# to release (a secondmate home, a record with no worktree=, or a path that is
# already gone). Every slot-ownership check below is scoped to that value, so a
# record with nothing live to return skips them rather than refusing.
teardown_live_slot_path() {
  fm_treehouse_pool_slot "$PROJ" "$WT" || return 1
  canonical_existing_dir "$WT"
}

require_exclusive_worktree_slot_record() {
  local record_meta=$1 record_id=$2 record_state=$3 worktree=$4 slot rc=0
  slot=$(canonical_existing_dir "$worktree") || return 0
  # A slot whose owner claim names another task was reassigned, so this record's
  # teardown is records-only and touches nothing under it; another record naming
  # the slot is then no hazard, and refusing would strand this stale record and
  # block the claimant's own teardown behind it.
  fm_treehouse_slot_owner_state "$slot" "$record_id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" != other ] || return 0
  fm_worktree_other_record "$record_state" "$record_meta" "$slot" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *)
      echo "REFUSED: cannot resolve the Firstmate home; nothing was changed" >&2
      return 1
      ;;
  esac
  echo "REFUSED: task $record_id's recorded worktree $slot is also task $FM_WORKTREE_OTHER_ID's recorded $FM_WORKTREE_OTHER_FIELD." >&2
  echo "Returning that pool slot would kill $FM_WORKTREE_OTHER_ID's processes and reset its copy, so nothing was changed - not even with --force." >&2
  echo "Reconcile whichever record is wrong (bin/fm-crew-state.sh $record_id; bin/fm-crew-state.sh $FM_WORKTREE_OTHER_ID), then re-run teardown." >&2
  return 1
}

require_exclusive_task_worktree_slot() {
  local slot
  slot=$(teardown_live_slot_path) || return 0
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$slot"
}

# Positive slot ownership, read from the claim the task that took the slot wrote
# into the slot itself (bin/fm-wake-lib.sh owns the claim and its states).
#
# For a slot this task still claims, or one with no claim, the record scan above
# proves that no OTHER task record names it. It cannot prove that THIS record is
# not the stale one, because the task that took the slot next may leave no record
# this scan can reach: its own worker may have exited and its record been cleaned
# up, or it may belong to a home this machine does not register. The claim closes that gap from the other side - it names the
# task that actually took the slot, and it is written under the same project lock
# that allocates it - so a claim naming another task is proof the slot was
# reassigned after this record was written.
#
# A claim naming another task does not refuse: it means the slot is no longer
# this task's, so the record's own cleanup proceeds and every slot step is
# skipped (see the script header for why refusing would strand the record and
# why skipping discards nothing). Returns TEARDOWN_SLOT_REASSIGNED_RC for that
# state so each caller gates its slot steps on one determination; the claimant
# stays in FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME.
#
# An absent claim proceeds as the slot's owner: a slot taken before claims
# existed, or already returned to the pool, carries none, and refusing those
# would strand every task in flight across the change for no evidence at all.
# Those keep exactly the record-scan protection they had before.
TEARDOWN_SLOT_REASSIGNED_RC=3
require_owned_worktree_slot_record() {  # <task-id> <worktree>
  local record_id=$1 worktree=$2 marker
  fm_treehouse_slot_owner_state "$worktree" "$record_id"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) return 0 ;;
    other)
      echo "warning: task $record_id's recorded worktree $worktree was reassigned to task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, which claimed that pool slot after this record was written; that slot is no longer $record_id's, so its processes, copy, and claim are left untouched and only $record_id's own cleanup runs." >&2
      return "$TEARDOWN_SLOT_REASSIGNED_RC"
      ;;
  esac
  marker=$(fm_treehouse_slot_owner_marker "$worktree" 2>/dev/null) || marker="beside $worktree"
  echo "REFUSED: task $record_id's recorded worktree $worktree carries a slot-owner claim that cannot be read, so the slot cannot be proved to still be this task's; nothing was changed - not even with --force." >&2
  echo "Inspect or repair the claim file at $marker (task= and home= lines), then re-run teardown." >&2
  return 1
}

# The one ownership determination for this task's recorded slot. Every later
# step that would read or touch $WT consults teardown_owns_worktree, so a
# reassigned slot is skipped consistently rather than by each step's own guess.
TEARDOWN_SLOT_REASSIGNED=0
TEARDOWN_SLOT_REASSIGNED_TO=
TEARDOWN_SLOT_REASSIGNED_HOME=
require_owned_task_worktree_slot() {
  local slot rc=0
  slot=$(teardown_live_slot_path) || return 0
  require_owned_worktree_slot_record "$ID" "$slot" || rc=$?
  case "$rc" in
    0) return 0 ;;
    "$TEARDOWN_SLOT_REASSIGNED_RC")
      TEARDOWN_SLOT_REASSIGNED=1
      TEARDOWN_SLOT_REASSIGNED_TO=$FM_TREEHOUSE_SLOT_OWNER_ID
      TEARDOWN_SLOT_REASSIGNED_HOME=$FM_TREEHOUSE_SLOT_OWNER_HOME
      return 0
      ;;
  esac
  return 1
}

teardown_owns_worktree() {
  [ "$TEARDOWN_SLOT_REASSIGNED" != 1 ]
}

teardown_release_herdr_locks() {
  local lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 0
  while IFS=$'\t' read -r lock_session lock_path; do
    [ -n "$lock_path" ] || continue
    fm_lock_release "$lock_path" || true
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  TEARDOWN_HERDR_LOCK_RECORDS=
}

teardown_herdr_session_lock_held() {  # <session>
  local session=$1 lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 1
  while IFS=$'\t' read -r lock_session lock_path; do
    [ "$lock_session" != "$session" ] || return 0
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  return 1
}

teardown_herdr_require_prerequisites() {  # <task-id>
  local task_id=$1 prerequisite
  teardown_require_backend_prerequisites herdr "$task_id" || return 1
  for prerequisite in \
    fm_backend_herdr_parse_target \
    fm_backend_herdr_pane_presence_state \
    fm_backend_herdr_workspace_presence_state \
    fm_backend_herdr_endpoint_confirmed_gone \
    fm_backend_herdr_explicit_close_pane_confirmed \
    fm_backend_herdr_presentation_session_lock_path; do
    if ! declare -F "$prerequisite" >/dev/null 2>&1; then
      echo "error: herdr teardown prerequisites are unavailable for $task_id; nothing was changed - restore the adapter and rerun teardown" >&2
      return 1
    fi
  done
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1 \
    || ! declare -F fm_lock_release >/dev/null 2>&1; then
    echo "error: herdr teardown lock machinery is unavailable for $task_id; nothing was changed - restore the lock support and rerun teardown" >&2
    return 1
  fi
}

teardown_herdr_preflight_target() {  # <target> <task-id>
  local target=$1 task_id=$2 session pane presence lock_path verified_lock_path lock_session held_path attempt
  teardown_herdr_require_prerequisites "$task_id" || return 1
  if ! fm_backend_herdr_parse_target "$target"; then
    echo "error: herdr endpoint $target for $task_id could not be parsed exactly; nothing was changed - repair the endpoint metadata and rerun teardown" >&2
    return 1
  fi
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    dead|present) ;;
    *)
      echo "error: herdr endpoint $target for $task_id has ambiguous structured presence; nothing was changed - restore reliable endpoint inspection and rerun teardown" >&2
      return 1
      ;;
  esac
  if ! lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session"); then
    echo "error: herdr session presentation lock could not be resolved for $task_id; nothing was changed - rerun teardown once the session is reachable and unambiguous" >&2
    return 1
  fi
  if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
    while IFS=$'\t' read -r lock_session held_path; do
      if [ "$lock_session" = "$session" ]; then
        if [ "$held_path" != "$lock_path" ]; then
          echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
          return 1
        fi
        return 0
      fi
    done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  fi
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock_path"; then
      if ! verified_lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") \
        || [ "$verified_lock_path" != "$lock_path" ]; then
        fm_lock_release "$lock_path" || true
        echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
        return 1
      fi
      if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
        TEARDOWN_HERDR_LOCK_RECORDS="$TEARDOWN_HERDR_LOCK_RECORDS
$session	$lock_path"
      else
        TEARDOWN_HERDR_LOCK_RECORDS="$session	$lock_path"
      fi
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: herdr session presentation lock is contended for $task_id; nothing was changed - rerun teardown once the contention clears" >&2
  return 1
}

# is left on disk naming what survived. The default is therefore to stop
# without removing the task's records, exactly as the Herdr confirmed-gone
# gates already do for the same hazard. What each backend can actually prove
# about its own close is bin/fm-backend.sh's fm_backend_kill contract.
#
# Returns 0 when the caller must continue anyway and 1 when it must stop.
# <honors-force> is 1 at exactly one site, the generic non-Herdr/non-Orca/non-T3
# close, where --force is the operator's existing authority to discard this
# task's records deliberately AND continuing is actually reachable: the
# worktree is already returned by then and nothing after it needs the backend
# that could not close.
# It is 0 everywhere else. The Orca site refuses under --force too, because
# the step immediately after it removes the Orca worktree through the same CLI
# whose absence is the only thing that arm ever reports, so a forced continue
# would die there having removed nothing while this message claimed otherwise.
# The T3 site refuses under --force because stop and archive must succeed before
# its worktree or home can be released (see the native cleanup site below).
#
# What is retained is this run's records, not a durable guarantee: a task
# carrying a backlog transition already wrote its pending-close marker, and the
# next session start replays that marker and removes the retained record. The
# message says so rather than promising a retention teardown does not own.
endpoint_close_refusal() {  # <subject> <backend> <target> <honors-force>
  local subject=$1 backend=$2 target=$3 honors_force=$4
  echo "error: the $backend endpoint $target for $subject could not be closed, so it may still be live." >&2
  if [ "$honors_force" = 1 ] && [ "$FORCE" = "--force" ]; then
    echo "error: --force authorizes continuing past a close that failed, so this cleanup proceeds toward removing the task's records; reconcile $target yourself, because nothing here can still be relied on to name it." >&2
    return 0
  fi
  echo "error: stopping this cleanup without removing the task's records, so the record naming $target is still here to reconcile from." >&2
  echo "error: that retention is not durable across a session start: if this task carries a backlog transition, the next session replays its pending close and removes the retained record, so reconcile the surviving endpoint yourself rather than trusting the retention." >&2
  if [ "$honors_force" = 1 ]; then
    echo "error: rerun teardown once the close can succeed, or rerun with --force to discard this task's records deliberately." >&2
  fi
  return 1
}

report_home_writes() {  # <snapshot> <saved-report>
  local snapshot=$1 saved=$2 writes rest
  [ -e "$snapshot" ] || return 0
  if ! writes=$("$SCRIPT_DIR/fm-home-write-diff.sh" report "$snapshot"); then
    echo "warning: could not compare ~/.claude and ~/.pi/agent with their state when $ID was spawned" >&2
    return 0
  fi
  [ -n "$writes" ] || return 0
  rest=$(printf '%s\n' "$writes" | grep -v '^routine ' || true)
  if [ -z "$rest" ]; then
    echo "teardown $ID note: routine sign-in token renewal in ~/.pi/agent/auth.json while $ID was live; provider entries unchanged"
    return 0
  fi
  if mkdir -p "${saved%/*}" && printf '%s\n' "$writes" >"$saved"; then
    echo "warning: ~/.claude or ~/.pi/agent changed while $ID was live; nothing was reverted (saved to $saved):" >&2
  else
    echo "warning: ~/.claude or ~/.pi/agent changed while $ID was live; nothing was reverted:" >&2
  fi
  printf '%s\n' "$writes" | sed 's/^/  /' >&2
}

require_exclusive_task_worktree_slot || exit 1
require_owned_task_worktree_slot || exit 1

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

preserve_scout_lavish_boards() {  # <task-id>
  local id=$1 reg="$STATE/procevent" source artifact dest name tmp use_export=0
  [ -d "$reg" ] || return 0
  if command -v lavish-axi >/dev/null 2>&1 && lavish-axi export --help >/dev/null 2>&1; then
    use_export=1
  fi
  for source in "$reg"/*.source; do
    [ -e "$source" ] || continue
    grep -qxF 'adapter=lavish' "$source" || continue
    grep -qxF "owner_task=$id" "$source" || continue
    artifact=$(awk '/^argv:$/ { in_argv = 1; next } in_argv && ++n == 3 { print; exit }' "$source") \
      || { echo "error: teardown refused: cannot read the Lavish board path from $source" >&2; return 1; }
    [ -n "$artifact" ] || { echo "error: teardown refused: $source records no board path" >&2; return 1; }
    name=${artifact##*/}
    dest="$DATA/$id/$name"
    mkdir -p "$DATA/$id" || { echo "error: teardown refused: cannot create $DATA/$id to preserve $artifact" >&2; return 1; }
    tmp=$(umask 077; mktemp "$DATA/$id/.board.XXXXXX") || { echo "error: teardown refused: cannot stage the preserved board in $DATA/$id" >&2; return 1; }
    if [ "$use_export" = 1 ]; then
      if ! lavish-axi export "$artifact" --out "$tmp" >/dev/null; then
        rm -f -- "$tmp"
        echo "error: teardown refused: lavish-axi export failed to preserve $artifact" >&2
        return 1
      fi
    elif ! cp -- "$artifact" "$tmp"; then
      rm -f -- "$tmp"
      echo "error: teardown refused: cannot copy $artifact to $dest" >&2
      return 1
    fi
    mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; echo "error: teardown refused: cannot place the preserved board at $dest" >&2; return 1; }
    echo "preserved: $dest"
  done
}

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if ! grep -Eq '^#{1,6}[[:space:]]+References[[:space:]]*$' "$REPORT"; then
    echo "REFUSED: scout task $ID's report at $REPORT has no References section." >&2
    echo "Add a \"## References\" heading listing the sources the findings rely on, then run teardown again." >&2
    exit 1
  fi
  home_is_execution_home || scout_captain_gate_verify || exit 1
fi

if [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

TEARDOWN_PR_RESULT=
if teardown_owns_worktree && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

# A Herdr close may reposition shared workspace order, so the whole
# destructive sequence below (pane close, worktree return, record removal)
# runs under the named-session presentation lock, acquired BEFORE anything is
# returned or erased: a contended lock refuses here while the isolated copy,
# every durable record, and the endpoint are all still intact for a plain
# rerun. An unresolvable lock path (for example an unreachable server) also
# refuses before any destructive step.
TEARDOWN_HERDR_SESSION=
TEARDOWN_HERDR_PANE=
if [ "$BACKEND" = herdr ]; then
  teardown_herdr_preflight_target "$T" "$ID" || exit 1
  fm_backend_herdr_parse_target "$T" || exit 1
  TEARDOWN_HERDR_SESSION=$FM_BACKEND_HERDR_SESSION
  TEARDOWN_HERDR_PANE=$FM_BACKEND_HERDR_PANE
fi

BACKLOG_CLOSED=0
BACKLOG_TRANSITION=$TEARDOWN_BACKLOG_TRANSITION
BACKLOG_TRANSITION_FLAGS=()
[ "$BACKLOG_TRANSITION" = close ] || BACKLOG_TRANSITION_FLAGS=(--retain)
BACKLOG_SKIP_REASON=
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  backlog_done_args || {
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID is not replayable; refusing destructive teardown" >&2
    exit 1
  }
fi

# The initial landed/discard-work checks above have passed (or --force skipped
# them). Fix 1 and Fix 2 (see script header) run here, unconditionally on
# --force, and before branch deletion or worktree return - a still-parked run or a
# leaked process can own live work in this exact worktree. Not for
# kind=secondmate: a secondmate home's own runtime lifecycle is owned by the
# dedicated process-event and firstmate-home removal machinery further below,
# not by task-worktree cleanup.
if teardown_owns_worktree; then
  conclude_task_no_mistakes_run "$WT"
fi

# A Herdr pane's top-level shell lives in its leased copy, so the reap and the
# Treehouse return below would end it and Herdr would remove the pane outside
# the locked, focus-preserving close. Herdr therefore closes its exact pane here,
# before anything ends processes in the copy.
HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
# Precondition: the recorded endpoint $T is proven gone.
teardown_herdr_journal_orphaned() {
  fm_backend_source herdr || return 1
  fm_backend_herdr_projection_journal_orphaned \
    "$HERDR_PRESENTATION_JOURNAL" "$ID" "$TEARDOWN_HERDR_SESSION" "$T"
}
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
FOCUS_HELD_DEFERRAL=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  # The presentation lock was acquired above, before any destructive step; a
  # contended lock already refused this teardown while everything was intact.
  if teardown_herdr_session_lock_held "$HERDR_PRESENTATION_SESSION"; then
    # stderr is deliberately NOT discarded here. This is the highest-frequency
    # projected-close call site, and the helper's only stderr output is a real
    # warning - unverifiable workspace.move support, a refused focus-unsafe
    # close, an unconfirmed repositioned-workspace removal, or a failed exact
    # restore.
    # Swallowing them left a wrong active workspace with no operator-visible
    # signal at all. The close stays non-fatal exactly as before: the presence
    # gate below is what decides whether any durable record may be removed.
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" = herdr ]; then
  if teardown_herdr_session_lock_held "$TEARDOWN_HERDR_SESSION"; then
    fm_backend_herdr_kill_serialized "$TEARDOWN_HERDR_SESSION" "$TEARDOWN_HERDR_PANE" 2>/dev/null || true
  else
    echo "warning: herdr session presentation lock path is unavailable; skipping the pane close rather than closing unlocked" >&2
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID was not retired by its close; no workspace cleanup was attempted" >&2
fi
# A refused or skipped Herdr close must stop before the reaper or Treehouse
# return can end the pane shell in the task copy. Confirm the exact pane is gone
# while the copy and every durable record are still intact.
if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || true
  if ! declare -F fm_backend_herdr_endpoint_confirmed_gone >/dev/null 2>&1; then
    echo "error: herdr endpoint confirmation is unavailable for $ID; retaining every durable task record" >&2
    exit 1
  fi
  if ! fm_backend_herdr_endpoint_confirmed_gone "$T"; then
    if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ] \
      && fm_backend_herdr_projection_journal_snapshot \
        "$HERDR_PRESENTATION_JOURNAL" "$ID" 2>/dev/null \
      && fm_backend_herdr_projection_target_tab_focus_held \
        "$HERDR_PRESENTATION_SESSION" "$FM_BACKEND_HERDR_JOURNAL_TAB_ID"; then
      # The pane is alive only because the viewer is looking at it. Finishing
      # every other step and leaving the retained journal as the durable
      # pending-close record beats failing cleanup: the watcher's heartbeat
      # retry closes it once focus moves.
      FOCUS_HELD_DEFERRAL=1
    else
      echo "error: herdr pane $T for $ID is not confirmed gone after its close was refused, skipped, or failed; retaining every durable task record - rerun teardown once the close can run under the session lock" >&2
      exit 1
    fi
  fi
  if [ "$FOCUS_HELD_DEFERRAL" = 0 ] && teardown_herdr_session_lock_held "$TEARDOWN_HERDR_SESSION"; then
    fm_backend_herdr_home_header_retire "$STATE" "$TEARDOWN_HERDR_SESSION" "$ID"
  fi
fi

if teardown_owns_worktree; then
  reap_task_worktree_processes worktree "$WT" "$TASK_TMP"
else
  reap_task_worktree_processes tasktmp "$TASK_TMP"
fi

# A worker can write after the first proof, including while its run is concluded
# or its processes exit. Inspect the stopped copy before dropping its branch or
# returning it on either backend path.
if teardown_owns_worktree && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  validate_worktree_teardown_safety || exit 1
fi

if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
# Roll the accepted legacy incarnation's stamp back to the record's exact
# pre-stamp bytes. Uses perl - already in the teardown lifecycle's curated PATH
# (truncate is not, and is absent on stock macOS) - and verifies the restored
# size before reporting success, so a rollback that cannot be proven complete
# is reported as not rolled back.
teardown_legacy_stamp_rollback() {
  [ "$TEARDOWN_LEGACY_PRESTAMP_SIZE" -gt 0 ] 2>/dev/null || return 1
  perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' -- \
    "$META" "$TEARDOWN_LEGACY_PRESTAMP_SIZE" || return 1
  [ "$(wc -c < "$META" | tr -d ' ')" = "$TEARDOWN_LEGACY_PRESTAMP_SIZE" ]
}

  # The accepted legacy incarnation is stamped under the meta lock already
  # held, right before the close marker binds to it: every refusal above leaves
  # the record byte-identical, and every later replay reads the same stamped
  # token the marker carries. A failed close-marker write rolls the stamp back
  # to the record's pre-stamp bytes, so a retried teardown re-runs the
  # dead-or-agent-less endpoint gate instead of sailing past it on a stamp the
  # abandoned attempt left behind.
  if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_LEGACY_PRESTAMP_SIZE=$(wc -c < "$META" | tr -d ' ')
    TEARDOWN_LEGACY_STAMP_FAILED=
    if [ -s "$META" ] && [ -n "$(tail -c 1 -- "$META" 2>/dev/null)" ]; then
      printf '\n' >> "$META" || TEARDOWN_LEGACY_STAMP_FAILED=newline
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      printf 'spawn_gen=%s\n' "$TEARDOWN_META_SPAWN_GEN" >> "$META" \
        || TEARDOWN_LEGACY_STAMP_FAILED=append
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ] \
       && ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
      TEARDOWN_LEGACY_STAMP_FAILED=validate
    fi
    if [ -n "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      teardown_legacy_stamp_rollback \
        || echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      if [ "$TEARDOWN_LEGACY_STAMP_FAILED" = validate ]; then
        echo "error: the stamped legacy incarnation does not validate for $ID ($FM_BACKLOG_TRANSITION_ERROR); refusing destructive teardown" >&2
      else
        echo "error: could not stamp the accepted legacy incarnation into task $ID's record; refusing destructive teardown" >&2
      fi
      exit 1
    fi
  fi
  BACKLOG_CLOSED=1
  META_SPAWN_GEN=$TEARDOWN_META_SPAWN_GEN
  if ! fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$META_SPAWN_GEN" \
      "${BACKLOG_TRANSITION_FLAGS[@]+"${BACKLOG_TRANSITION_FLAGS[@]}"}" \
      "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ] \
       && teardown_legacy_stamp_rollback; then
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); the accepted legacy incarnation was rolled back, retaining every durable task record" >&2
    else
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
      if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
        echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      fi
    fi
    exit 1
  fi
else
  if [ "$CLEANUP_RECOVERY" = orca ]; then
    BACKLOG_SKIP_REASON="Orca cleanup recovery is not a launched backlog worker"
  else
    BACKLOG_SKIP_REASON=$TEARDOWN_BACKLOG_SKIP_REASON
  fi
fi

if [ "$KIND" = ship ] && teardown_owns_worktree && [ -e "$CONFIG/pipeline-spend" ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-pipeline-spend.sh" record "$ID" >/dev/null \
    || echo "warning: could not record $ID's no-mistakes pipeline spend; cleanup continues" >&2
fi

# Fix 3 (see script header): sweep remote job workers abandoned by an already
# pruned code root. Best effort - a sweep failure never blocks this teardown.
"$SCRIPT_DIR/fm-remote-job-reap-orphans.sh" >&2 || true

# Preserve every Lavish board this scout armed before the scratch copy returns.
if [ "$KIND" = scout ]; then
  preserve_scout_lavish_boards "$ID" || exit 1
fi

# A t3code thread is stopped and archived BEFORE its slot goes back to the pool
# or, for a secondmate, before its home is removed: a live thread whose
# worktreePath disappears re-creates it on the next turn, so returning the slot
# first would hand T3 a path another task may take, and the archived transcript
# is the only record of a secondmate once its home is gone. The kill is
# idempotent (an archived or deleted thread is already the end state), so a
# re-run after a failed return converges; an unreachable server refuses rather
# than returning a slot a live thread still points at. The secondmate's fm-
# T3 project is deliberately left in place: project.delete refuses while the
# archived thread exists and would take that transcript with it under force.
if [ "$BACKEND" = t3code ]; then
  fm_backend_kill t3code "$T" || {
    echo "error: could not stop and archive T3 thread $T for $ID; start T3 Code (or archive the thread there) and re-run teardown" >&2
    endpoint_close_refusal "$ID" t3code "$T" 0 || exit 1
  }
fi
# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$BACKEND" = orca ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  if [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
      "$WT/.opencode/plugins/fm-busy-state.js" \
      "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
    remove_harness_worktree_wiring "$WT"
  fi
  if [ -n "$T_ORCA" ]; then
    fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" \
      || { endpoint_close_refusal "$ID" "$BACKEND" "$T" 0; exit 1; }
  fi
  fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
elif ! teardown_owns_worktree; then
  :
elif [ -d "$WT" ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook and environment files so a reused pool worktree cannot fire
  # signals for a dead task or hand a t3code env block or channel statement to
  # its next holder.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
    "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
  remove_harness_worktree_wiring "$WT"
  if [ "$BACKEND" = t3code ]; then
    "$SCRIPT_DIR/fm-t3code-codex-env.sh" cleanup "$WT" || exit 1
    git -C "$WT" ls-files --error-unmatch CLAUDE.local.md >/dev/null 2>&1 || rm -f "$WT/CLAUDE.local.md"
  fi
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  post_lock_cleanup_check=
  if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ]; then
    post_lock_cleanup_check=validate_worktree_teardown_safety
  fi
  if [ "$KIND" = scout ] || [ "$FORCE" = "--force" ]; then
    teardown_scrub_scratch_copy "$WT" || exit 1
  fi
  wt_pool_slot=0
  fm_treehouse_pool_slot "$PROJ" "$WT" && wt_pool_slot=1
  teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" || {
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    exit 1
  }
  [ "$wt_pool_slot" = 0 ] || teardown_note_dirty_return "$WT"
  # The slot is back in the pool, so this task's claim on it is spent. Dropping
  # it here - and only after a return that succeeded - keeps a returned slot
  # unclaimed until its next holder claims it, and leaves the claim in place
  # whenever the return did not actually happen.
  fm_treehouse_slot_owner_release "$WT" "$ID"
fi

if [ "$BACKEND" != orca ] && [ "$BACKEND" != t3code ] && [ "$BACKEND" != herdr ] && [ "$TEARDOWN_WINDOWLESS" != 1 ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" \
    || endpoint_close_refusal "$ID" "$BACKEND" "$T" 1 || exit 1
fi
teardown_export_records "$STATE" "$ID" || exit 1
remove_grok_turnend_auth "$STATE" "$ID" || exit 1
remove_kimi_turnend_auth "$STATE" "$ID" || exit 1
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
if [ -n "$TASK_TMP" ] && { [ -e "$TASK_TMP" ] || [ -L "$TASK_TMP" ]; }; then
  # Installed hooks dirs are mode 500 by design, so plain rm fails inside them.
  chmod -R u+w "$TASK_TMP" 2>/dev/null || true
  rm -rf "$TASK_TMP" || { echo "error: could not remove task temp dir $TASK_TMP for $ID" >&2; exit 1; }
fi
# Retire only this Firstmate home's launch namespace. Its never-reused per-spawn
# files leave the equal task-id namespace of every other home untouched.
teardown_launch_home_token() {
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}
LAUNCH_HOME_TOKEN=$(teardown_launch_home_token "$FM_HOME") || LAUNCH_HOME_TOKEN=
if [ -n "$LAUNCH_HOME_TOKEN" ]; then
  rm -rf "/tmp/fm-$ID+$LAUNCH_HOME_TOKEN"
fi
if [ "$KIND" = ship ] || [ "$KIND" = scout ]; then
  TASK_RESULT=$(teardown_task_result "$KIND" "$MODE" "$PR_URL" "$TEARDOWN_PR_RESULT")
  teardown_archive_result "$KIND" "$MODE" "$TASK_RESULT" || {
    echo "error: could not archive the result for $ID; retaining task records for retry" >&2
    exit 1
  }
fi
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
retire_busy_state "$STATE" "$ID" "$BUSY_GEN" || exit 1
# Opt-in fleet activity ledger (docs/fleet-ledger.md), before the status log is
# retired so its last lines are captured; off costs one file test.
[ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" cleaned_up "$ID" || true
teardown_retire_status "$STATE" "$ID" || exit 1
fm_wake_queue_prune_task "$STATE" "$ID" "$T" 2>/dev/null || true
report_home_writes "$STATE/$ID.home-snapshot" "$DATA/$ID/home-writes.txt"
rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress" "$STATE/$ID.home-snapshot" \
  "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.omp-ext.ts" "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.kimi-turnend-token" "$STATE/$ID.muse-session" \
  "$STATE/$ID.muse-session-current" "$STATE/$ID.cursor-session" \
  "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
  "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note" \
  "$STATE/$ID.reconcile-nudged" "$STATE/$ID.gemini-settings.json" \
  "$STATE/$ID.claude-settings.json" "$STATE/$ID.devin-config.json" \
  "$STATE/$ID.polytoken-busy.sh" "$STATE/$ID.cloud-session" "$STATE/$ID.pr-register-refused" \
  "$STATE/.$ID.branch-outcome-index"
# kiro's per-task home is a directory (its relocated KIRO_HOME holds the hook
# agent config, the trust setting, and this task's sessions), so it needs a
# recursive removal rather than the file rm above.
rm -rf "$STATE/$ID.kiro-home"
# The steering inbox (bin/fm-task-inbox-lib.sh) is runtime state for the
# retired endpoint; teardown only runs after landing is confirmed, so any
# leftover unhandled steer here is moot rather than unlanded work.
# state/<id>.git-hooks is the spawn-owned commit-msg strip directory, left
# read-only by its installer, and state/<id>.push-guard is a forge=external
# task's read-only push guard record (bin/fm-git-push-guard.sh).
chmod u+w "$STATE/$ID.git-hooks" 2>/dev/null || true
# A task's polytoken config dir and sessions roots are directory trees (the
# mirrored worker config and the versioned session tree the launch wrote
# beside its sessions root), so they are removed recursively with the inbox
# and the git-hooks dir rather than the flat file list above.
# state/<id>.cortex-plugin is the per-task Cortex Code plugin directory
# (bin/fm-cortex-plugin.sh) carrying the busy-state hooks.
rm -rf "$STATE/$ID.inbox" "$STATE/$ID.git-hooks" "$STATE/$ID.push-guard" \
  "$STATE/$ID.cortex-plugin" "$STATE/$ID.hermes-hooks" \
  "$STATE/$ID.polytoken-config" \
  "$STATE/$ID.polytoken-sessions" "$STATE/$ID.polytoken-sessions-v1"
# A presentation journal the close path left behind is orphaned once the
# recorded pane is proven gone (the Herdr gate above) unless it still names a
# live projected workspace - a version 2 binding of some other pane, or a
# version 1 attempt whose token-bearing workspace is still present - which the
# session-start sweep alone may judge (header).
if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
  if [ "$FOCUS_HELD_DEFERRAL" = 1 ]; then
    : # The journal is the durable pending-close record; the retry owns it now.
  elif teardown_herdr_journal_orphaned; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: retaining herdr presentation journal for $ID; it still names a projected workspace the session-start sweep owns, not the closed endpoint" >&2
  fi
fi
# The record is gone, so the backlog must not still show this task in flight
# when teardown reports success. Still under this task's meta lock, so a steer
# racing the same id stays serialized exactly as it was before. A captain-held
# row takes the retain transition here instead of the close: same record, same
# ordering, the row returns to Queued with its deliverable recorded.
if [ "$BACKLOG_CLOSED" = 1 ]; then
  BACKLOG_CLOSE_MARKER=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if ! fm_backlog_atomic_transition "$BACKLOG_TRANSITION" "$STATE/$ID.meta" "$BACKLOG_CLOSE_MARKER" \
      "$DATA" "$ID" "$STATE" "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    if [ "$BACKLOG_TRANSITION" = retain ]; then
      echo "error: $ID's endpoint and local copy are cleaned up, but its captain-held backlog item could not be returned to Queued atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending retention is recorded and the next session start retries it" >&2
    else
      echo "error: $ID's endpoint and local copy are cleaned up, but its backlog item could not be closed atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending close is recorded and the next session start retries it" >&2
    fi
    exit 1
  fi
else
  if ! fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    echo "error: $ID's endpoint and local copy are cleaned up, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
if [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
if [ "$TEARDOWN_POOL_SLOT_LOST" = 1 ]; then
  echo "teardown $ID finished its cleanup and removed its task record, but a returned pool slot did not come back clean (see the warning above); clear those paths so the pool can reuse the slot" >&2
elif [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ]; then
  echo "teardown $ID complete (window ${T:-none}, worktree $WT, legacy record accepted without spawn_gen: endpoint $TEARDOWN_LEGACY_ENDPOINT, incarnation $TEARDOWN_META_SPAWN_GEN)"
elif teardown_owns_worktree; then
  echo "teardown $ID complete (window ${T:-none}, worktree $WT)"
else
  echo "teardown $ID complete (window ${T:-none}; pool slot $WT left to task $TEARDOWN_SLOT_REASSIGNED_TO${TEARDOWN_SLOT_REASSIGNED_HOME:+ (home $TEARDOWN_SLOT_REASSIGNED_HOME)}, which it was reassigned to)"
fi
if [ "$FOCUS_HELD_DEFERRAL" = 1 ]; then
  echo "teardown $ID note: herdr pane $HERDR_PRESENTATION_PANE still holds the viewer's focus, so its close is deferred to the watcher's next heartbeat; the retained presentation journal is the pending-close record"
fi
backlog_refresh_reminder
[ "$TEARDOWN_POOL_SLOT_LOST" = 0 ] || exit "$TEARDOWN_LOST_SLOT_EXIT"
