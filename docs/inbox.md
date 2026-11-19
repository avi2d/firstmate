# Inbox contract

`fm-inbox.sh` captures notes for firstmate, reads status from durable records, and answers side questions.

## Notes

`note` queues an idea while firstmate is mid-turn and cannot answer.
It writes a durable record and appends one `check` wake, so the note survives a crash and is presented at the next drain.
`announce` may append that wake for an already saved note.
These are the only subcommands that touch the wake queue.

`note --request-id` is the idempotent capture path.
A repeat of the same request ID returns the original note instead of creating a second one.
It prints `replay`, or JSON `"outcome":"replay"`, to distinguish a retry from a first submission.
The binding is recorded before announcement, so a crash between save and wake still replays the original note.
Without `--request-id`, each call creates a note.
`announce` repairs the wake for an already saved note without creating another.
An acknowledged note receives no wake from `announce` or a request ID replay.
Both report it as acknowledged and exit 0.

`announce` refuses a note with unknown announcement state.
A note written before the home tracked announcement markers already appended its own wake at creation, and no record proves that.
Announcing it again could duplicate the wake.
Notes carry `announce_marker=1`, which makes a missing marker mean not announced rather than unknown.
Receipts report unknown as null.

A note body is text, not options.
Only the documented flags are parsed.
Anything else starting with `--` begins the body, and `--` ends option parsing.
Without `--request-id` or `--json`, human `note`, `list`, and `drain` output and exit conventions remain unchanged.
A saved note whose wake fails exits 1.
With `--request-id` or `--json`, a saved but unannounced note exits 3.
A genuine failure with nothing saved exits 1, so the caller can repair the announcement rather than enqueue again.

`receipts` is the bounded JSON view of pending and handled notes, their acknowledgement, announcement, and recorded reply.
Default bounds omit records rather than implying the first page contains everything.
`omitted[]` names the surface and how to reveal it.

`reply` publishes the primary's answer against a note ID.
Each reply has a durable per-home sequence, so the receipts cursor is a strict total order and replies recorded in the same second remain readable.
Only one reply per note is accepted.

`ready` is the read-only primary-readiness projection of lock, wake-consumer health, away posture, and observation time.
It never acquires the session lock or infers liveness from a lock file, session, or pane.

## Status and questions

`status` answers what is happening from durable records only.
It reads no network and appends no wake, so it can run in a loop without interrupting work.
`ask` answers a side question with a one-shot model call that never touches firstmate, the backlog, or the wake queue.
A side question does not become work.

## Configuration and privacy

A region, model ID, and AWS profile name an account and its choices, so no default is shipped.
Each is read from the home's gitignored `config/` directory or the matching environment variable.
Model-backed commands refuse with the path to write when a required value is missing.
This configuration is the opt-in for `ask`.

| File | Environment | Purpose |
| --- | --- | --- |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region, required. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model, required by `ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile, optional. |

An absent profile or an explicitly empty `FM_INBOX_PROFILE` uses credentials already in the environment.
`note`, `announce`, `reply`, `receipts`, `ready`, `status`, `list`, and `drain` make no model call and need no configuration.
`--json`, `receipts`, and `ready` require Python 3.
`FM_HOME` selects the operational home whose state and data are used.
`ask` sends the question to Bedrock.
The other commands make no network call.
