# 0010: Per pull request merge hold

Date: 2026-10-23.
Status: accepted.

## Context

Standing auto-merge merged a pull request ten seconds after it went green although the supervisor had told that worker home to hold the merge for the captain.
The only hold the merge paths read was the task hold, and answering or releasing that hold for any other reason reopened the merge.
A steered instruction to hold lives in chat, and the merge program never reads chat.

## Decision

Key the hold by provider, host, path, and number under state/merge-holds in the merging home.
Read the hold in bin/fm-merge-on-green.sh before any other verdict and refuse the merge in bin/fm-pr-merge.sh beside the task hold.
Keep a repeated hold on its first record and make release idempotent.
Leave the hold in place across task hold answers and releases until the supervisor releases the pull request by its URL.

## Consequences

A held pull request stays on the supervised path and keeps its merge on green source armed, so release merges it on a later sweep with no rearming.
A hold blocks base updates as well as merges, because an update changes the head under review.
Teardown leaves holds alone, so a hold outlives its task and needs an explicit release.
