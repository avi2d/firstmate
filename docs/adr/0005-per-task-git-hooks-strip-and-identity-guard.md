# 0005: Per-task git hooks strip AI trailers and refuse foreign identities

Accepted 2026-10-16.

Cursor and other non-Claude runtimes inject a Co-Authored-By trailer at the tooling layer after the worker types a clean message, so the typed message is not the commit object.
A prior per-machine attribution-off setting is not durable: it does not travel with Firstmate, it defaults back to on when unset, and it only feeds the tool request to the server, so the setting suppresses rather than prevents the trailer text the model emits.
Verified live on cursor-agent 2026.09.15 with attribution on: the trailer is already in .git/COMMIT_EDITMSG when the commit-msg hook runs, so the spawn-owned hook is the layer that sees the assembled message before the commit object is written.
Claude launches already carry attribution-off in their per-launch settings JSON, and the strip still runs for every launched runtime as defense in depth.
git commit --no-verify skips every hook, so a worker that passes it still lands the trailer, as would a runtime that writes the commit object without running git.
Both incidents that motivated the strip came through an ordinary hook-running commit, so the gap stays accepted rather than growing a push-side rewrite or a push-side check for trailers.
A trailer found on a fleet commit therefore points at one of those two paths, not at an unnoticed hole in the matcher.
Inside a fleet pane git reports the hooks directory as the repository hooks directory, so a hook manager run there targets it and would displace the strip.
Install leaves the directory and every hook in it read-only, so such a manager fails loudly instead of silently winning.
Hook managers therefore cannot install from inside fleet panes until a registered project genuinely needs one.
Workers twice committed under an invented identity copied from their own instructions, and a push-time CI gate caught either case only after the push, so the pre-commit hook refuses any author or committer that differs from the machine git config.
The reference identity is what plain git resolves from the machine config files, read with git -c values and GIT_AUTHOR_* and GIT_COMMITTER_* overrides removed and the pane GIT_CONFIG_* core.hooksPath entries kept.
A same-value override is allowed, since the committed identity is the configured one.
Amend and rebase replay commits without running the commit-time hooks, so the pre-push hook refuses a pushed range holding such a commit instead of rewriting history.
A merge of a tracked remote branch lands that branch's commits inside the pushed range, so every range excludes commits reachable from any remote-tracking ref and only commits new to all remotes are checked.
Neither hook prints an email address, and neither hook rewrites identity.
The guard installs on every ship and scout spawn with or without config/keep-ai-trailers, and only the trailer strip honors that flag.
