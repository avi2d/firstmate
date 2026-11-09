#!/usr/bin/env bash
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=${FM_REMOTE_FEED_MAX_BYTES:-262144}
POLL_SECONDS=${FM_REMOTE_FEED_POLL_SECONDS:-0.5}
SETTLED_POLL_SECONDS=${FM_REMOTE_FEED_SETTLED_POLL_SECONDS:-1}
FAST_WINDOW_SECONDS=2

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Blocking, multiplexed delta read over every task status log in this home.

Usage:
  fm-remote-status-feed.sh [wait-seconds] < cursor-vector

The cursor vector arrives on stdin, one line per task watched:
  <task-id> <offset> <prefix-sha256>

The feed polls each listed state/<task-id>.status through
fm-remote-delta-read.sh with a zero wait, so every per-task read keeps that
reader's snapshot, continuity, whole-line, and bound behavior unchanged. It
returns as soon as any task yields a delta or a continuity break, framed as
one envelope over whole per-task blocks:

  schema=fm-remote-feed.v1
  tasks=<n>
  task=<id>
  bytes=<block-bytes>
  <exactly block-bytes of fm-remote-delta.v1 output>

A task whose log cannot be read safely this round is skipped for the round,
so one wedged log never stalls the other tasks. A window with no complete
new line exits 75, the same empty-window signal the single-log reader uses.
EOF
  exit 2
}

[ "$#" -le 1 ] || usage
WAIT=${1:-55}
case "$WAIT" in ''|*[!0-9]*) die "wait-seconds must be a nonnegative integer" ;; esac
[ "$WAIT" -le 300 ] || die "wait-seconds exceeds the 300-second safety bound"
case "$MAX_BYTES" in ''|*[!0-9]*|0) die "FM_REMOTE_FEED_MAX_BYTES must be a positive integer" ;; esac
[ "$MAX_BYTES" -le 1048576 ] || die "FM_REMOTE_FEED_MAX_BYTES exceeds the safety bound"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-feed.XXXXXX") || die "cannot create feed staging directory"
trap 'rm -rf -- "$TMP"' EXIT
trap 'exit 75' TERM

VECTOR="$TMP/vector"
cat > "$VECTOR" || die "cannot read the cursor vector"

TASKS="$TMP/tasks"
: > "$TASKS" || die "cannot stage the task list"
seen="$TMP/seen"
: > "$seen" || die "cannot stage the deduplication record"
LC_ALL=C awk 'NF == 0 { next } { print }' "$VECTOR" > "$TMP/nonblank" || die "cannot normalize the cursor vector"
while IFS=' ' read -r task offset hash extra; do
  case "$task" in ''|*[!A-Za-z0-9._-]*|*..*) die "cursor vector carries an invalid task id" ;; esac
  case "$offset" in ''|*[!0-9]*) die "cursor vector carries an invalid offset for $task" ;; esac
  case "$hash" in *[!A-Fa-f0-9]*|'') die "cursor vector carries an invalid prefix hash for $task" ;; esac
  [ "${#hash}" -eq 64 ] || die "cursor vector carries an invalid prefix hash length for $task"
  [ -z "${extra:-}" ] || die "cursor vector carries a malformed line for $task"
  if grep -Fxq -- "$task" "$seen"; then die "cursor vector lists $task twice"; fi
  printf '%s\n' "$task" >> "$seen"
  printf '%s %s %s\n' "$task" "$offset" "$hash" >> "$TASKS"
done < "$TMP/nonblank"

collected="$TMP/collected"
: > "$collected" || die "cannot stage the collection record"
total=0
count=0

scan_once() {
  local task offset hash block bytes
  while IFS=' ' read -r task offset hash; do
    [ -n "$task" ] || continue
    block="$TMP/block-$task"
    if "$SCRIPT_DIR/fm-remote-delta-read.sh" "state/$task.status" "$offset" "$hash" 0 > "$block" 2>/dev/null; then
      bytes=$(LC_ALL=C wc -c < "$block" | tr -d ' ')
      case "$bytes" in ''|*[!0-9]*|0) continue ;; esac
      if [ "$count" -gt 0 ] && [ $((total + bytes)) -gt "$MAX_BYTES" ]; then
        continue
      fi
      printf '%s %s\n' "$task" "$bytes" >> "$collected"
      total=$((total + bytes))
      count=$((count + 1))
    fi
  done < "$TASKS"
  [ "$count" -eq 0 ]
}

START=$SECONDS
if [ ! -s "$TASKS" ]; then
  while [ $((SECONDS - START)) -lt "$WAIT" ]; do
    sleep "$SETTLED_POLL_SECONDS"
  done
  exit 75
fi
while scan_once; do
  [ $((SECONDS - START)) -lt "$WAIT" ] || exit 75
  if [ $((SECONDS - START)) -le "$FAST_WINDOW_SECONDS" ]; then
    sleep "$POLL_SECONDS"
  else
    sleep "$SETTLED_POLL_SECONDS"
  fi
done

printf 'schema=fm-remote-feed.v1\n'
printf 'tasks=%s\n' "$count"
while read -r task bytes; do
  printf 'task=%s\n' "$task"
  printf 'bytes=%s\n' "$bytes"
  cat "$TMP/block-$task"
done < "$collected"
