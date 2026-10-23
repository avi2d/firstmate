# 0009: Fixture Git isolation from host config and pane-injected hooks

Accepted 2026-10-23.

Firstmate tests build fixture repos that must behave the same inside a worker pane and in CI.
A worker pane exports core.hooksPath through GIT_CONFIG_KEY_n so the per-task hooks run for every pane command.
Environment injected config outranks every config file, so a fixture repo cannot switch those hooks off in its own config.
The pane also exports GIT_CONFIG_PARAMETERS, which is the same channel serialized for child processes.
tests/git-config-helpers.sh runs before a fixture's first Git operation and neutralizes these layers on entry.
It points GIT_CONFIG_GLOBAL at /dev/null and sets GIT_CONFIG_NOSYSTEM to 1, so fixture Git ignores host global and system config.
It unsets GIT_CONFIG_PARAMETERS outright, since the serialized form cannot be filtered entry by entry.
It deletes core.hooksPath entries from the numbered GIT_CONFIG_KEY_n variables and renumbers the survivors, so other injected entries keep their effect.
It deletes injected entries with no value, since git refuses every invocation while one is present.
It unsets GIT_CONFIG_SYSTEM and the repository location variables, since an absolute GIT_DIR would land fixture refs in the caller's repository.
Repository-local config, inline git -c, and values set after sourcing stay authoritative, and the regression suite asserts on each of those.
The change reaches only the sourcing shell and its children, so the developer's own config files are never written and outside commits keep their config.
tests/lib.sh and tests/herdr-test-safety.sh source the helper for every suite, bin/fm-test-run.sh sources it per suite in run_script_bounded, and any other suite sources it directly so a hand run stays isolated.
tests/fm-test-fixtures.test.sh drives every entry point above and is the regression, and the changed-file map selects it for a change to the helper.
The shape mirrors the checks suite fix that strips hooksPath from injected entries and pins the global and system layers.
