# 0014: Typed dispatch resolver contract

Date: 2026-10-28.
Status: accepted.

## Contract

Opt-in gate: FM_DISPATCH_PROVIDER and FM_DISPATCH_MODEL select the provider and model from the environment or $FM_HOME/.env (environment wins).
With no provider set, retain the original typesafe.ai/jev-latest key gate exactly.
OpenRouter requires both its provider selection and a model.
The selected key lives in a non-exported shell variable and reaches curl through fd 3, never argv, logs, or child environments.

What it does when on with at least one rule: one POST with the project name and the brief's `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a scout brief (the whole brief when it has neither section), as state and ONE Choice question whose options are every rule's `when` from config/crew-dispatch.json plus one fixed generic none option.
The provider returns the matched rule, a probability per option, and a confidence.
Everything after that is jq: the confidence floor (0.6 on the answer confidence, or a rule's declared `min_confidence` on that rule's probability, falling to the most probable other option that clears its own floor), the rule's declared `approval` and `floor`, each profile's declared `provider` and `floor`, the quota rows from ONE quota-axi --json snapshot (schema 5 or 6; each candidate binds to one row through quota_row in bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/... reads its own account's row and an expanded provider with no row for the candidate is unmeasured, never blocked), ONE clauth status --json snapshot when a profile names a claude_account, whose own windows replace that candidate's quota row and which makes it ineligible when clauth cannot vouch for it (bin/fm-clauth-lib.sh), and the spendPriority argmax over the eligible candidates, or, under a top-level `array_order: preference`, the first eligible candidate in array order, quota uncertainty disclosed and never skipped.
The model never sees quota, catalogs, approvals, confidence floors, `why`, or `use`.
With no rules, it returns a non-clear result so firstmate keeps using the existing intake.
docs/configuration.md "Crew dispatch profiles" owns the declared fields and "Typed dispatch resolution" owns this tool's operator contract.

Never-send check: when the optional $FM_HOME/config/dispatch-never-send list exists, every string value of the built request is checked against it before the POST.
Each non-blank, non-# line is a literal matched case-insensitively, with surrounding whitespace trimmed and every run of whitespace, on both sides, treated as one space.
A match, or a list that is not a readable regular file, prints one "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most the list line number, never its value, prints nothing on stdout, and exits 0 with no network or quota call, exactly like the absent-key off path.

Authority: this tool never replaces firstmate's judgment, quota-array-dispatch, the captain-approval gate, or fm-spawn.sh validation; it publishes one inspectable answer plus every candidate's evidence, in code.
