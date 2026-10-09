---
name: fork-drift-sync
description: >-
  Agent-only response to a fork drift check wake.
  Load on a `fork drift:` check wake naming a project behind its upstream.
  Dispatches the merge-commit sync ship in the project's registered delivery mode, merges the green PR, and runs that project's existing rollout.
user-invocable: false
metadata:
  internal: true
---

# fork-drift-sync

Use this playbook on a `fork drift:` check wake that names a project, its behind and ahead counts, and the upstream head or tag.
The wake is the dispatch trigger; the sync itself is ordinary ship work.
Dispatch one sync ship for the named project in its registered delivery mode.
The worker merges the upstream into the fork with a merge commit, never a rebase or squash, and opens the pull request the selected delivery path requires.
Merge the green pull request with `bin/fm-pr-merge.sh`, passing the merge strategy after `--` (`--merge` keeps the merge commit).
Then run that project's existing rollout: refresh the local clone through `bin/fm-fleet-sync.sh` and propagate to secondmates through `secondmate-provisioning`.
A red pull request, a required check that has not reported, and any destructive or security-sensitive step still escalate to the captain.
