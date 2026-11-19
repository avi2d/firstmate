---
name: updatefirstmate
description: Update this Firstmate checkout when the user invokes /updatefirstmate or asks to pull the latest Firstmate.
user-invocable: true
metadata:
  internal: true
---

# Update Firstmate

Run `bin/fm-update.sh` from this home.
It fast-forwards the code from `origin` or from the branch named in `config/self-update-source`.
It does not change project clones, task worktrees, or runtime state.
It skips a dirty checkout, a different branch, or a divergence it cannot safely reconcile.

Read the result.
If the updater prints `reread-firstmate: yes`, read `AGENTS.md` again before continuing.
A re-read does not reload the current session's hooks or extensions.

Report what changed or why the update was skipped.
