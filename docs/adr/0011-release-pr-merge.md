# 0011: Merge a daily release PR outside any task

Date: 2026-10-26.
Status: accepted.

## Context

Daily `chore: release` pull requests, about ten open at once, were merged by hand outside `bin/fm-pr-merge.sh`, so its red-check, required-check and behind-base guards never saw them.
The script refused any pull request that no task owned, because every merge path read the owning task's metadata.

## Decision

`fm-pr-merge.sh --release <pr-url>` merges a GitHub pull request when its title starts with `chore: release` and no task metadata in the home names its URL.
Every forge guard a task pull request passes still applies at the live head, and so does the merge hold on the URL.
The task-bound steps are skipped because no task exists: the captain hold, the metadata record, the recorded-identity check, and the authority persistence.
The merge is recorded with `fm_merge_outcome_report` under the id `release-<number>`, so the outcome line matches a task merge's.

The release route reads the same away-posture authority as a task merge and does not read `yolo`: the caller decides approval, as it does for a task pull request.

A non-GitHub forge, a title outside the convention, or a pull request a task owns is refused before any merge command runs.

## Rationale moved from the merge script's header

Merge a task's PR or MR after recording pr= and any available pr_head= through
bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
addressed through gh by the derived owner and repository on the derived host,
exported as GH_HOST for the whole run, which is github.com or a GitHub
Enterprise host this home names in config/github-hosts; a GitLab merge
request is addressed through glab by the project URL rebuilt from the parsed
host and path, so any instance works and no host is hardcoded; a Forgejo
pull request is addressed through tea by the derived owner and repository
plus a "tea login" resolved fresh from the parsed host on every run. A Gerrit
change is refused outright: that adapter is read-only, and the refusal at the
parse below owns why.

Merge method on GitHub defaults to --squash when the caller passes none of
--squash, --merge, --rebase, or --method after the optional -- separator.
On Forgejo the merge style defaults to the repository's own
default_merge_style, read live, and a merge is refused when it cannot be read.
A GitHub merge is refused unless every pre-merge condition holds, each read
live at merge time rather than taken from recorded metadata: the pull request
is open, not a draft, mergeable, free of conflicts, every unwaived check
is green at the exact current head commit, where github_checks_not_green below
owns what makes a check green and judges each one by its current run, and
every unwaived check the forge requires for the base branch has reported at
that head. When mergeable is the only failing condition and reads UNKNOWN,
meaning GitHub has not finished recomputing it, the caller re-reads and
re-checks every condition after a short bounded wait instead of refusing;
once that bound is spent it reports mergeability still pending rather than
unmergeable, with the same nonzero exit as any other refusal.
A required check that never reported is absent from the checks
list rather than red, so github_read_required_contexts below reads the
required set from classic branch protection and active rulesets. Check-run
requirements retain their producer app binding: a same-named check run from another app cannot
satisfy them, and a duplicate name-only entry cannot weaken that binding.
Unbound requirements match by name. A bound requirement reported as a check
run also needs a matching producer in the check-runs read at the verified
head, while one reported as a commit status matches by name, because the
status carries no app id to compare. Status-creator app binding is not verified
here, so an attended --attended-override -- --admin merge can bypass that
protection without a missing-check waiver when a same-named status reported.
An unreadable producer read still refuses.
Successfully read requirements remain checked even if another
source fails, so known missing checks and all read errors are reported together.
github_branch_rules_unavailable_on_plan owns the narrow plan-unavailable
exception; every other unreadable required source refuses.
Every failing condition is reported, not just the first.
The verified head is then passed to gh as
--match-head-commit, so a push that lands between that read and the merge
fails the merge instead of landing commits nothing verified. Reading that
state needs gh and jq, and either one absent stops the merge before any
state is recorded. An attended --allow-red <check-name> may be passed once,
with the name as a separate argument; it waives only checks with that exact
name, still requires every other check green, and still binds the head. Its
twin, an attended --allow-missing <check-name>, follows the same rules for one
required check that has not reported: it waives only that exact name, still
requires every other required check to have reported and every check to be
green unless separately waived by --allow-red. It matches the required
context name even for an app-bound requirement, and never waives an unreadable
required source or producer read. Both are
refused while the away-posture record exists, and neither
applies on GitLab, where a merge already requires the head pipeline to have
succeeded, or on Forgejo, where a merge already requires the head's combined
commit status to have succeeded. After gh returns success, GitHub's live
state is read back and
accepted only when the pull request is merged or in the merge queue. gh's
GraphQL API supplies that queue-aware read; when that read fails, gh-axi's
own view still proves a landed merge, and every outcome it cannot prove
refuses, reporting the failed gh read and naming both failed reads when the
gh-axi view could not prove the outcome either.
If the pull request remains open and the base branch has an effective
merge_queue rule, an attended refusal names the queue's configured merge
method and exact --attended-override -- --auto --<method> retry flags. While
the away-posture record exists, asynchronous merge requests are refused and
queue retry flags are not offered because they would outlive away authority.
An attended caller that already passed the configured method with --auto is
told instead that the accepted request has not entered the queue and its queue
state has to be re-checked.
No method is selected for the caller in any case. A rules response that names
no queue rule, one that could not be read, rules that disagree, and a method
this script does not recognise are four distinct outcomes and are reported
apart, because each one leaves the operator somewhere different.
A caller-requested --auto that leaves the pull request neither merged nor
queued is refused the same way and says auto-merge was armed with nothing
landed or queued yet, or, when the merge command itself failed, that auto-merge
was only requested; both are read from the caller's own arguments rather than
from the forge's prose.
Every refusal that follows a merge command which returned success quotes that
command's own output, marked as the forge's text and kept apart from this
script's verdict, including the refusal for an outcome that cannot be read;
a merge command that failed keeps its original error surfaced raw and first.
GitLab adds no method flag at all: its merge method is the project's own
setting, which the merge API applies, and imposing squash there would override
that convention rather than mirror the GitHub default.

A GitLab merge is refused unless every pre-merge condition holds, each read
live at merge time rather than taken from recorded metadata: the merge request
is open, detailed_merge_status is mergeable, has_conflicts is false,
blocking_discussions_resolved is true, and the head pipeline succeeded at the
exact current head commit. Every failing condition is reported, not just the
first. An attended --allow-no-pipeline, for a repository that deliberately
runs no merge request pipeline, waives only the pipeline condition and only
when GitLab reports head_pipeline as present and null: a failed, running,
canceled, or stale pipeline still refuses, every other condition still
holds, and a project that requires a pipeline to succeed still refuses
through detailed_merge_status. It is refused while the away-posture record
exists and on any forge other than GitLab. The verified head is then passed
to glab as --sha, so a push that lands between that read and the merge fails
the merge instead of landing commits nothing verified. A recorded pr_head that disagrees with the live head is
reported rather than trusted, because a rebase moves the head and leaves the
recorded value stale. Reading that state needs glab and jq, and either one
absent stops the merge before any state is recorded.

A Forgejo merge is refused unless every pre-merge condition holds, each read
live at merge time: the pull request is open, not a draft, mergeable is
true, and the combined commit status at the exact current head, read across
every status page, is success (an unconfigured status, reported as "none",
refuses rather than being treated as nothing to check, the same reading
GitLab's null head_pipeline gets above). Every
failing condition is reported, not just the first. tea exposes no head-
binding flag on its own merge subcommand, so the verified head is instead
passed as head_commit_id to a direct call against Forgejo/Gitea's REST API
(through "tea api"), which rejects a mismatched value with "head out of
date" - verified against a real instance, along with every claim below about
tea's and the API's exact behavior. Also unlike gh and glab, that API call
reports an HTTP-level failure with exit status 0, so the merge is never
judged by its own exit status: only a follow-up read confirming merged=true
counts as landed. tea addresses a repository by owner/repository slug only;
the host comes from a named "tea login" rather than the URL the way gh and
glab take one, so the login registered for the parsed host is re-resolved
fresh at merge time (bin/fm-pr-check.sh already required one at arm time,
but a login can be renamed or removed afterwards). Reading and merging both
need tea and jq, and either one absent stops the merge before any state is
recorded. Forgejo has no merge-queue or scheduled-merge concept, so unlike
GitHub and GitLab there is no away-mode async/queued case to detect: every
accepted Forgejo merge here is immediate, and any caller-passed extra
argument beyond a merge method is refused rather than silently dropped,
because there is no established translation from a gh/glab-style flag into
a Forgejo API field yet.

Before either forge merge, the task's existing per-task control lock
serializes the captain-hold check through the forge command. A still-held or
unreadable row refuses before that command, so a captain approval must be
recorded as an `answer --release` before this entrypoint is invoked. While
an away record exists (a quiet-mode record is a present captain, so its
merges stay attended: bin/fm-afk-contract.sh mode) any green merge may
proceed under away authority:
the record's presence is the whole mechanical fact, and which merge the
captain's away words meant is the supervision session's reading
(bin/fm-branch-prompt.sh "Postures"). An unreadable record refuses rather
than being skipped, neither posture releases a captain hold, and away
authority lapses when the record is archived.
The authority read and synchronous forge command share the away record's
cross-subsystem lock, which bin/fm-afk-contract.sh owns, closing the common
live-owner TOCTOU; failure to take it refuses before the forge call. Async and
queued paths are refused while away. Two confused-agent-grade limitations are
accepted rather than hidden: queue or base changes after GitHub's preflight can
still enqueue, and killing this shell can orphan a forge child after stale-lock
recovery. docs/architecture.md owns those away-merge limits, while
docs/captain-hold-lifecycle.md owns the separate merge-to-cleanup residual.
A failed forge command releases the lock after it returns. A successful one
retains the lock until the accepted merge authority is persisted against the
still-matching task metadata.

Extra args must not include --repo or -R in any form, including a bundled
short-option cluster such as -yR, because the repository comes only from the
URL, nor --sha or --match-head-commit because the head comes only from the
live read. An existing task-meta pr= must equal the requested canonical URL,
unless that bound PR has already merged - proven by its recorded merge
notification - in which case the task's next PR is accepted so several PRs
from one task can each merge in turn; while the bound PR is still unmerged a
different URL is refused. Auto-merge (--auto), a protection bypass
(--admin), and branch
deletion (--delete-branch, -d and short-flag clusters, and GitLab's
--remove-source-branch) are refused by default; --attended-override, parsed
before the optional -- separator, re-enables those forge flags for an
explicit captain instruction and never skips the live green check, the
away-record read, or a captain hold.

Usage: fm-pr-merge.sh <task-id> <pr-url> [--attended-override] [--allow-red <check-name>] [--allow-missing <check-name>] [--allow-no-pipeline] [-- <extra forge merge args>]

On GitLab, this script confirms the MR is actually merged before reporting it;
an auto-merge-queued or unconfirmed request leaves the poll armed and records
no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
destination, normal-case deduplication, and at-least-once recovery.
A landed merge whose outcome cannot be written is reported loudly rather than
misreported as a failed merge.
