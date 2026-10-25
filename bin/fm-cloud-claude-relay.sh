#!/usr/bin/env bash
# fm-cloud-claude-relay.sh - the process in a cloud-claude task pane: it starts the task's
# Claude Code cloud session, forwards the steering inbox to it, and reports the pull request.

set -u

# Pane liveness reads the process name and argv[0]; a claude path component is
# what marks this pane as holding a live worker.
if [ "${FM_CLOUD_RELAY_NAMED:-}" != 1 ]; then
  export FM_CLOUD_RELAY_NAMED=1
  exec -a claude/cloud-relay bash "$0" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

usage() {
  echo "usage: fm-cloud-claude-relay.sh --task <id> --worktree <dir> --brief <file> --status <file> --repo <owner/repo> --branch <branch> --base <branch> --deadline <minutes> --gen <busy-gen> [--poll <seconds>]" >&2
  exit 2
}

TASK='' WT='' BRIEF='' STATUS='' REPO='' BRANCH='' BASE='' DEADLINE_MIN='' GEN='' POLL=60
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --task) TASK=$2 ;;
    --worktree) WT=$2 ;;
    --brief) BRIEF=$2 ;;
    --status) STATUS=$2 ;;
    --repo) REPO=$2 ;;
    --branch) BRANCH=$2 ;;
    --base) BASE=$2 ;;
    --deadline) DEADLINE_MIN=$2 ;;
    --gen) GEN=$2 ;;
    --poll) POLL=$2 ;;
    *) usage ;;
  esac
  shift 2
done
for required in "$TASK" "$WT" "$BRIEF" "$STATUS" "$REPO" "$BRANCH" "$BASE" "$DEADLINE_MIN" "$GEN"; do
  [ -n "$required" ] || usage
done
case "$DEADLINE_MIN$POLL" in *[!0-9]*) usage ;; esac
INBOX=${FM_TASK_INBOX:?FM_TASK_INBOX must name the steering inbox}
CLAUDE_BIN=${FM_CLOUD_CLAUDE_BIN:-claude}
SESSION_FILE="$(dirname "$STATUS")/$TASK.cloud-session"

say() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

busy_event() {  # <busy|idle> <event> [--turn-ended]
  "$SCRIPT_DIR/fm-busy-event.sh" apply "$(dirname "$STATUS")" "$TASK" "$1" --gen "$GEN" \
    --source cloud-relay --event "$2" ${3:+"$3"} >/dev/null 2>&1 || say "busy state not recorded: $1 $2"
}

report() {  # <status line>
  printf '%s\n' "$(status_stamp_line "$1")" >>"$STATUS" || say "could not append to $STATUS: $1"
}

cloud_prompt() {
  local intent spec
  intent=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$BRIEF" "## Firstmate spec")
  cat <<EOF
You are an autonomous worker in a Claude Code cloud session for $REPO. Nobody reads this session's chat, so work without waiting for answers.

# Task
## Captain's intent
$intent

## Firstmate spec
$spec

# Delivery
- Work on branch $BRANCH, which this session checked out; commit there and push it to origin.
- When the work is complete and its tests pass, open one ready-for-review pull request from $BRANCH into $BASE through the GitHub REST API: gh api repos/$REPO/pulls -f head=$BRANCH -f base=$BASE -f title=... -f body=.... gh pr and other GraphQL commands are blocked in this environment. Never open it as a draft.
- That pull request is the only signal that the task is done. A later message in this session may ask for changes: push them to the same branch and pull request.
- Never add Co-Authored-By trailers, generated-with lines, or session links to commits or the pull request.
EOF
}

# claude --cloud refuses to create a session without an interactive terminal,
# so the pane's terminal is passed through script(1), which also records the id.
create_session() {
  local log
  log=$(mktemp "${TMPDIR:-/tmp}/fm-cloud-create.XXXXXX") || return 1
  case "$(uname -s)" in
    Linux) script -qec "$(printf '%q ' "$CLAUDE_BIN" --cloud "$(cloud_prompt)" --on-branch "$BRANCH")" "$log" ;;
    *) script -q "$log" "$CLAUDE_BIN" --cloud "$(cloud_prompt)" --on-branch "$BRANCH" ;;
  esac
  SESSION=$(perl -pe 's/\e\[[0-9;?<>=]*[A-Za-z]//g; s/\e\][^\a]*\a//g' "$log" |
    grep -Eo 'claude --teleport (session|cse)_[A-Za-z0-9]+' | tail -n 1 | awk '{ print $3 }')
  rm -f "$log"
  [ -n "$SESSION" ] || return 1
  printf '%s\n' "$SESSION" >"$SESSION_FILE"
}

forward() {  # <text>
  local out
  out=$("$CLAUDE_BIN" -p --cloud "$SESSION" "$1" 2>&1) && return 0
  say "message not delivered: $out"
  case "$out" in
    *archived*|*"Session not found"*)
      if [ "$CLOSED_REPORTED" = 0 ]; then
        report "blocked [key=cloud-session-closed]: cloud session $SESSION no longer accepts messages ($out); steers wait in the inbox"
        CLOSED_REPORTED=1
      fi
      ;;
  esac
  return 1
}

utc_minute_ceiling() {  # <epoch> -> YYYY-MM-DDTHH:MMZ
  local t=$(( ($1 + 59) / 60 * 60 ))
  date -u -r "$t" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%MZ
}

# The relay only sees GitHub, so the wait is declared rather than proven busy:
# the watcher's busy-turn bound would otherwise flag a long cloud run as a wedge.
expect_new_work() {
  AWAITING=1
  AWAIT_SINCE=$(date +%s)
  busy_event busy awaiting-pr
  report "paused: cloud session $SESSION is working on $BRANCH; this pane reports its ready pull request, or flags the deadline, until $(utc_minute_ceiling $((AWAIT_SINCE + DEADLINE_MIN * 60)))"
}

forward_inbox() {
  local record body
  mkdir -p "$INBOX/handled" || return 0
  for record in "$INBOX"/[0-9]*.msg; do
    [ -f "$record" ] || continue
    body=$(fm_task_inbox_body "$record") || continue
    forward "$body" || return 0
    mv "$record" "$INBOX/handled/" || return 0
    say "forwarded steer ${record##*/}"
    expect_new_work
  done
}

# The cloud session pushes the branch; the local copy fast-forwards onto it so
# the done report and cleanup see the same published head as the pull request.
sync_head() {  # <sha>
  git -C "$WT" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" &&
    git -C "$WT" merge --quiet --ff-only "$1" &&
    [ "$(git -C "$WT" rev-parse HEAD)" = "$1" ]
}

check_pr() {
  local row url state draft sha
  row=$(GH_HOST=github.com gh api -X GET "repos/$REPO/pulls" -f "head=${REPO%%/*}:$BRANCH" -f state=open \
    --jq '.[0] // empty | [.html_url, .state, (.draft | tostring), .head.sha] | @tsv' 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r url state draft sha <<<"$row"
  [ "$state" = open ] && [ "$draft" = false ] || return 0
  [ "$sha" != "$SYNCED_HEAD" ] || return 0
  if ! sync_head "$sha"; then
    if [ "$SYNC_REPORTED" != "$sha" ]; then
      report "blocked [key=cloud-sync]: $url is at $sha but the local copy at $WT could not fast-forward onto it"
      SYNC_REPORTED=$sha
    fi
    return 0
  fi
  SYNCED_HEAD=$sha
  say "local copy now at $sha ($url)"
  [ "$AWAITING" = 1 ] || return 0
  if [ "$DEADLINE_REPORTED" = 1 ]; then
    report "resolved [key=cloud-deadline]: the cloud session pushed $sha to $url"
    DEADLINE_REPORTED=0
  fi
  report "done: PR $url"
  AWAITING=0
  busy_event idle pr-ready --turn-ended
}

check_deadline() {
  [ "$AWAITING" = 1 ] && [ "$DEADLINE_REPORTED" = 0 ] || return 0
  [ $(($(date +%s) - AWAIT_SINCE)) -ge $((DEADLINE_MIN * 60)) ] || return 0
  report "blocked [key=cloud-deadline]: cloud session $SESSION pushed no ready pull request for $BRANCH within $DEADLINE_MIN minutes; inspect https://claude.ai/code/$SESSION"
  DEADLINE_REPORTED=1
  busy_event idle deadline --turn-ended
}

trap 'exit 0' TERM INT HUP
cd "$WT" || { report "failed: cloud relay could not enter $WT"; exit 1; }

SESSION=
[ ! -s "$SESSION_FILE" ] || SESSION=$(head -n 1 "$SESSION_FILE")
if [ -z "$SESSION" ]; then
  if ! push_out=$(git push --quiet -u origin "HEAD:refs/heads/$BRANCH" 2>&1); then
    report "failed: could not push $BRANCH to origin before starting the cloud session: $push_out"
    exit 1
  fi
  say "starting the cloud session for $REPO on $BRANCH"
  create_session || {
    report "failed: claude --cloud printed no session id for $TASK; the pane above shows its output"
    exit 1
  }
fi
say "cloud session $SESSION: https://claude.ai/code/$SESSION"

AWAITING=0 AWAIT_SINCE=0 DEADLINE_REPORTED=0 CLOSED_REPORTED=0 SYNC_REPORTED=
SYNCED_HEAD=$(git rev-parse HEAD)
expect_new_work
while :; do
  forward_inbox
  check_pr
  check_deadline
  if [ "$AWAITING" = 1 ]; then
    say "waiting for a ready pull request on $BRANCH ($(( (AWAIT_SINCE + DEADLINE_MIN * 60 - $(date +%s)) / 60 )) min to deadline)"
  else
    say "pull request open; waiting for steers"
  fi
  if IFS= read -r -t "$POLL" line; then
    case "$line" in
      ': Firstmate instruction waiting:'*|'') ;;
      *) forward "$line" && expect_new_work ;;
    esac
  elif [ $? -le 128 ]; then
    sleep "$POLL"
  fi
done
