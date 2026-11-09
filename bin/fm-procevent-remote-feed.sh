#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CURSOR_ROOT="$STATE/remote-feeds"
WAIT_SECONDS=${FM_REMOTE_FEED_WAIT_SECONDS:-55}
MAX_DOC_BYTES=${FM_REMOTE_FEED_MAX_DOC_BYTES:-262144}
SSH_UNAVAILABLE=255
DOCUMENT_LOCAL_FAILURE=2

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Remote-worker status-feed adapter for the generic process-event runner.

Usage:
  fm-procevent-remote-feed.sh arm <route>
  fm-procevent-remote-feed.sh ensure-armed <route>
  fm-procevent-remote-feed.sh handle <route> <sequence> <result-file>
  fm-procevent-remote-feed.sh autohandle <source-id> <sequence> <result-file>
  fm-procevent-remote-feed.sh classify <result-file>
  fm-procevent-remote-feed.sh terminal <result-file>
  fm-procevent-remote-feed.sh self-announcing
  fm-procevent-remote-feed.sh source-id <route>
  fm-procevent-remote-feed.sh relisten
  fm-procevent-remote-feed.sh retire <route> [--force]
EOF
  exit 2
}

INGEST_TMP=''
FETCH_ERR=''
FETCH_TMP=''
SOURCE_OUT=''
SPLIT_TMP=''
cleanup_temp_paths() {
  rm -rf -- ${INGEST_TMP:+"$INGEST_TMP"} ${FETCH_ERR:+"$FETCH_ERR"} ${FETCH_TMP:+"$FETCH_TMP"} ${SOURCE_OUT:+"$SOURCE_OUT"} ${SPLIT_TMP:+"$SPLIT_TMP"}
}
trap cleanup_temp_paths EXIT

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

empty_hash() { sha256_file /dev/null; }

validate_route() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid execution-home route: $1" ;; esac
}

validate_task() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|*..*) die "invalid task id: $1" ;; esac
}

route_is_remote() {
  local route=$1 remote
  remote=$(secondmate_registry_field "$DATA/remote-homes.md" "$route" remote 2>/dev/null || true)
  [ "$remote" = 1 ] || die "route $route is not a configured execution home"
}

source_id() {
  validate_route "$1"
  printf 'remote-feed-%s\n' "$1"
}

feed_lifecycle_lock_path() { printf '%s/.remote-feed-lifecycle-%s.lock\n' "$1" "$2"; }
cursor_dir() { printf '%s/%s\n' "$CURSOR_ROOT" "$1"; }
cursor_path() { printf '%s/%s/%s.cursor\n' "$CURSOR_ROOT" "$1" "$2"; }
ingest_receipt_path() { printf '%s/%s/%s.%s.ingested\n' "$CURSOR_ROOT" "$1" "$2" "$3"; }
mirrored_source_path() { printf '%s/.remote-feed-mirrored-%s\n' "$STATE" "$1"; }

read_cursor() {
  local path=$1 offset hash schema
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash) || die "cannot establish the empty cursor hash"
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "feed cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path")
  offset=$(sed -n 's/^offset=//p' "$path")
  hash=$(sed -n 's/^prefix_sha256=//p' "$path")
  [ "$schema" = fm-remote-feed-cursor.v1 ] || die "feed cursor has an incompatible schema: $path"
  case "$offset" in ''|*[!0-9]*) die "feed cursor has an invalid offset: $path" ;; esac
  case "$hash" in *[!A-Fa-f0-9]*|'') die "feed cursor has an invalid hash: $path" ;; esac
  [ "${#hash}" -eq 64 ] || die "feed cursor has an invalid hash length: $path"
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
}

write_cursor() {
  local path=$1 offset=$2 hash=$3 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-remote-feed-cursor.v1\n'
    printf 'offset=%s\n' "$offset"
    printf 'prefix_sha256=%s\n' "$hash"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

continuity_prefix() {
  printf '%.12s' "$CURSOR_HASH"
}

ingest_receipt_matches() {
  local path=$1 result=$2 stored actual count
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || die "feed ingestion receipt is unsafe: $path"
  count=$(grep -c '^result_sha256=' "$path" 2>/dev/null || true)
  [ "$count" -eq 1 ] || die "feed ingestion receipt is malformed: $path"
  stored=$(sed -n 's/^result_sha256=//p' "$path")
  case "$stored" in *[!A-Fa-f0-9]*|'') die "feed ingestion receipt is malformed: $path" ;; esac
  [ "${#stored}" -eq 64 ] || die "feed ingestion receipt is malformed: $path"
  actual=$(sha256_file "$result") || die "cannot hash feed result"
  [ "$stored" = "$actual" ] || die "feed result generation conflicts with its ingestion receipt"
}

write_ingest_receipt() {
  local path=$1 result=$2 dir tmp hash
  if [ -e "$path" ] || [ -L "$path" ]; then
    ingest_receipt_matches "$path" "$result"
    return $?
  fi
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  hash=$(sha256_file "$result") || return 1
  tmp=$(umask 077; mktemp "$dir/.ingested.XXXXXX") || return 1
  printf 'result_sha256=%s\n' "$hash" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

result_field() {
  LC_ALL=C awk -v prefix="$2=" '
    $0 == "" { exit }
    index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$1"
}

classify_block() {
  local file=$1 schema status
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  status=$(result_field "$file" status 2>/dev/null || true)
  [ "$schema" = fm-remote-delta.v1 ] || { printf 'malformed\n'; return 0; }
  case "$status" in
    delta) printf 'delta\n' ;;
    continuity-broken) printf 'continuity-broken\n' ;;
    *) printf 'malformed\n' ;;
  esac
}
split_frames() {
  local result=$1 destdir=$2 line tasks task bytes i=0 block seen
  [ -f "$result" ] && [ ! -L "$result" ] || return 1
  seen="$destdir/.seen"
  : > "$seen" || return 1
  exec 9< "$result" || return 1
  IFS= read -r line <&9 || { exec 9<&-; return 1; }
  [ "$line" = schema=fm-remote-feed.v1 ] || { exec 9<&-; return 1; }
  IFS= read -r line <&9 || { exec 9<&-; return 1; }
  case "$line" in tasks=*) tasks=${line#tasks=} ;; *) exec 9<&-; return 1 ;; esac
  case "$tasks" in ''|*[!0-9]*|0) exec 9<&-; return 1 ;; esac
  [ "$tasks" -le 1024 ] || { exec 9<&-; return 1; }
  while [ "$i" -lt "$tasks" ]; do
    IFS= read -r line <&9 || { exec 9<&-; return 1; }
    case "$line" in task=*) task=${line#task=} ;; *) exec 9<&-; return 1 ;; esac
    case "$task" in ''|*[!A-Za-z0-9._-]*|*..*) exec 9<&-; return 1 ;; esac
    if grep -Fxq -- "$task" "$seen"; then exec 9<&-; return 1; fi
    printf '%s\n' "$task" >> "$seen"
    IFS= read -r line <&9 || { exec 9<&-; return 1; }
    case "$line" in bytes=*) bytes=${line#bytes=} ;; *) exec 9<&-; return 1 ;; esac
    case "$bytes" in ''|*[!0-9]*|0) exec 9<&-; return 1 ;; esac
    [ "$bytes" -le 1048576 ] || { exec 9<&-; return 1; }
    block="$destdir/$task.block"
    head -c "$bytes" <&9 > "$block" || { exec 9<&-; return 1; }
    [ -s "$block" ] || { exec 9<&-; return 1; }
    printf '%s %s\n' "$task" "$block"
    i=$((i + 1))
  done
  if IFS= read -r line <&9; then
    case "$line" in '') ;; *) exec 9<&-; return 1 ;; esac
    if IFS= read -r line <&9; then exec 9<&-; return 1; fi
  fi
  exec 9<&-
}

classify_result() {
  local file=$1 split class block task broken=0 deltas=0
  split=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-remote-feed-classify.XXXXXX") || { printf 'malformed\n'; return 0; }
  SPLIT_TMP=$split
  if ! split_frames "$file" "$split" > "$split/frames"; then
    rm -rf -- "$split"; SPLIT_TMP=''
    printf 'malformed\n'; return 0
  fi
  while read -r task block; do
    [ -n "$task" ] && [ -n "$block" ] || { rm -rf -- "$split"; SPLIT_TMP=''; printf 'malformed\n'; return 0; }
    class=$(classify_block "$block")
    case "$class" in
      delta) deltas=$((deltas + 1)) ;;
      continuity-broken) broken=$((broken + 1)) ;;
      *) rm -rf -- "$split"; SPLIT_TMP=''; printf 'malformed\n'; return 0 ;;
    esac
  done < "$split/frames"
  rm -rf -- "$split"; SPLIT_TMP=''
  [ $((deltas + broken)) -gt 0 ] || { printf 'malformed\n'; return 0; }
  [ "$deltas" -gt 0 ] || { printf 'continuity-broken\n'; return 0; }
  printf 'delta\n'
}
cmd_arm_locked() {
  local route=${1:-} sid
  validate_route "$route"
  route_is_remote "$route"
  sid=$(source_id "$route")
  "$SCRIPT_DIR/fm-procevent.sh" register remote-feed "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-remote-feed.sh" source "$route" || return 1
  printf 'armed: %s\n' "$sid"
}

cmd_ensure_armed() {
  local route=${1:-} lock sid owner
  validate_route "$route"
  route_is_remote "$route"
  sid=$(source_id "$route")
  lock=$(feed_lifecycle_lock_path "$STATE" "$route")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote feed lifecycle for $route"
    LIFECYCLE_LOCK=$lock
    trap 'cleanup_temp_paths; fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    owner=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null | awk -v id="$sid" '$1 == id { print $3; exit }' || true)
    if [ "$owner" = live ]; then
      printf 'armed: %s\n' "$sid"
      return 0
    fi
    cmd_arm_locked "$route"
  )
}

cmd_arm() {
  local route=${1:-} lock
  validate_route "$route"
  lock=$(feed_lifecycle_lock_path "$STATE" "$route")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote feed lifecycle for $route"
    LIFECYCLE_LOCK=$lock
    trap 'cleanup_temp_paths; fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    cmd_arm_locked "$@"
  )
}

WINDOW_CLOSED_EMPTY=75
JOB_PREEMPTED=76

route_tasks() {
  local route=$1 meta task placed
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=$(basename "$meta" .meta)
    case "$task" in ''|*[!A-Za-z0-9._-]*|*..*) continue ;; esac
    placed=$(fm_meta_get "$meta" remote_route 2>/dev/null || true)
    [ "$placed" = "$route" ] || continue
    printf '%s\n' "$task"
  done
}

cmd_source() {
  local route=${1:-} rc=0 output class vector task path
  validate_route "$route"
  route_is_remote "$route"
  output=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-remote-feed-source.XXXXXX") \
    || die "cannot stage remote feed source output"
  SOURCE_OUT=$output
  vector=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-remote-feed-vector.XXXXXX") \
    || die "cannot stage the feed cursor vector"
  if [ -z "$(route_tasks "$route")" ]; then
    rm -f -- "$vector"
    return "$WINDOW_CLOSED_EMPTY"
  fi
  while IFS= read -r task || [ -n "$task" ]; do
    [ -n "$task" ] || continue
    path=$(cursor_path "$route" "$task")
    read_cursor "$path"
    printf '%s %s %s\n' "$task" "$CURSOR_OFFSET" "$CURSOR_HASH" >> "$vector"
  done <<EOF
$(route_tasks "$route")
EOF
  "$SCRIPT_DIR/fm-on.sh" --stdin "$route" fm-remote-status-feed.sh "$WAIT_SECONDS" \
    < "$vector" > "$output" || rc=$?
  rm -f -- "$vector"
  if [ "$rc" -eq "$WINDOW_CLOSED_EMPTY" ]; then
    rm -f -- "$output"
    return "$WINDOW_CLOSED_EMPTY"
  elif [ "$rc" -eq "$JOB_PREEMPTED" ]; then
    rm -f -- "$output"
    return "$WINDOW_CLOSED_EMPTY"
  fi
  class=$(classify_result "$output")
  if [ "$rc" -ne 0 ] || [ "$class" = malformed ]; then
    rm -f -- "$output"
    [ "$rc" -ne 0 ] && return "$rc"
    return 1
  fi
  cat "$output"
  rc=$?
  rm -f -- "$output"
  return "$rc"
}
safe_feed_doc_path() {
  local task=$1 pointer=$2 rest
  case "$pointer" in data/"$task"/*.md) ;; *) return 1 ;; esac
  rest=${pointer#data/}
  case "/$rest/" in */../*|*/./*) return 1 ;; esac
  case "$pointer" in *'//'*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  return 0
}

process_document_pointers() {
  LC_ALL=C awk -v mode="$1" -v mapfile="$2" '
    BEGIN {
      if (mapfile != "") {
        while ((getline entry < mapfile) > 0) {
          separator = index(entry, "\t")
          if (separator > 0)
            replacements[substr(entry, 1, separator - 1)] = substr(entry, separator + 1)
        }
        close(mapfile)
      }
    }
    {
      rest = "\001" $0
      rewritten = ""
      while (match(rest, /[^A-Za-z0-9._\/-]report=data\/[A-Za-z0-9._\/-]+[.]md/)) {
        doc = substr(rest, RSTART + 8, RLENGTH - 8)
        next_index = RSTART + RLENGTH
        next_char = next_index <= length(rest) ? substr(rest, next_index, 1) : ""
        if (next_char == "" || next_char !~ /[A-Za-z0-9._\/-]/) {
          if (mode == "extract") {
            if (!seen[doc]++) print doc
          } else {
            replacement = doc in replacements ? replacements[doc] : doc
            rewritten = rewritten substr(rest, 1, RSTART + 7) replacement
            rest = substr(rest, next_index)
            continue
          }
        }
        if (mode != "extract")
          rewritten = rewritten substr(rest, 1, next_index - 1)
        rest = substr(rest, next_index)
      }
      if (mode != "extract") print substr(rewritten rest, 2)
    }
  '
}

extract_document_pointers() {
  process_document_pointers extract '' < "$1"
}

rewrite_document_pointers() {
  process_document_pointers rewrite "$2" < "$1" > "$3"
}

summarize_fetch_reason() {
  local reason
  reason=$(LC_ALL=C tr '\000-\010\011\013-\037\177' ' ' < "$1" 2>/dev/null \
    | awk 'NF { last = $0 } END { if (last != "") print last }' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  reason=${reason#error: }
  reason=${reason%": $2"}
  [ -n "$reason" ] || reason='the remote reader gave no reason'
  [ "${#reason}" -le 160 ] || reason="${reason:0:157}..."
  printf '%s' "$reason"
}

FETCH_DOC_REASON=''
fetch_document() {
  local route=$1 task=$2 rel=$3 result_var=$4 base destination parent parent_real tmp err local_rel rc=0
  FETCH_DOC_REASON=''
  if ! safe_feed_doc_path "$task" "$rel"; then
    FETCH_DOC_REASON='pointer is outside the task data directory'
    return 1
  fi
  base="$DATA/$task"
  destination="$base/${rel#data/"$task"/}"
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return "$DOCUMENT_LOCAL_FAILURE"
  [ ! -L "$base" ] && [ ! -L "$parent" ] || return "$DOCUMENT_LOCAL_FAILURE"
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return "$DOCUMENT_LOCAL_FAILURE"
  case "$parent_real" in "$base"|"$base"/*) ;; *) return "$DOCUMENT_LOCAL_FAILURE" ;; esac
  [ ! -L "$destination" ] || return "$DOCUMENT_LOCAL_FAILURE"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-remote-doc-reason.XXXXXX") || return "$DOCUMENT_LOCAL_FAILURE"
  FETCH_ERR=$err
  tmp=$(umask 077; mktemp "$parent/.remote-doc.XXXXXX") || { rm -f -- "$err"; FETCH_ERR=''; return "$DOCUMENT_LOCAL_FAILURE"; }
  FETCH_TMP=$tmp
  "$SCRIPT_DIR/fm-on.sh" "$route" fm-remote-file.sh get "$rel" "$MAX_DOC_BYTES" < /dev/null > "$tmp" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCH_DOC_REASON=$(summarize_fetch_reason "$err" "$rel")
    rm -f -- "$tmp" "$err"
    FETCH_TMP='' FETCH_ERR=''
    [ "$rc" -ne "$SSH_UNAVAILABLE" ] || return "$SSH_UNAVAILABLE"
    return 1
  fi
  rm -f -- "$err"
  FETCH_ERR=''
  chmod 600 "$tmp" || { rm -f -- "$tmp"; FETCH_TMP=''; return "$DOCUMENT_LOCAL_FAILURE"; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; FETCH_TMP=''; return "$DOCUMENT_LOCAL_FAILURE"; }
  FETCH_TMP=''
  local_rel="$rel"
  printf -v "$result_var" '%s' "$local_rel"
}

normalize_payload() {
  LC_ALL=C tr '\000-\010\013-\037\177' '?' < "$1" > "$2"
}

append_status_once() {
  grep -Fqx -- "$2" "$1" 2>/dev/null && return 1
  printf '%s\n' "$2" >> "$1" || return 2
  return 0
}
stage_mirror_lines() {
  LC_ALL=C awk \
    -v rewritten_file="$2" \
    -v source_record="$3" \
    -v status_file="$4" \
    -v status_additions="$5" \
    -v source_additions="$6" '
    BEGIN {
      printf "%s", "" > status_additions
      printf "%s", "" > source_additions
      while ((getline line < source_record) > 0) mirrored[line] = 1
      close(source_record)
      while ((getline line < status_file) > 0) present[line] = 1
      close(status_file)
    }
    {
      source = $0
      read_result = getline rewritten < rewritten_file
      if (read_result <= 0) {
        failed = 1
        exit 1
      }
      if (source == "" || (source in mirrored)) next
      mirrored[source] = 1
      print source > source_additions
      if (!(rewritten in present)) {
        present[rewritten] = 1
        print rewritten > status_additions
      }
    }
    END {
      if (!failed && (getline extra < rewritten_file) > 0) failed = 1
      close(rewritten_file)
      if (close(status_additions) != 0) failed = 1
      if (close(source_additions) != 0) failed = 1
      if (failed) exit 1
    }
  ' "$1"
}

ingest_task_block() {
  local route=$1 task=$2 block=$3 seq=$4 class schema status path from to from_hash to_hash payload_hash payload_bytes reason
  local actual_bytes actual_hash line doc local_doc appended=0 cursor_already=0 lock status_file source_record tmp
  local fetch_rc append_rc offered='' delivered_map='' mirrored='' status_additions='' source_additions='' undelivered=''
  validate_route "$route"
  validate_task "$task"
  [ -f "$block" ] && [ ! -L "$block" ] || die "feed block is unavailable or unsafe for $task"
  class=$(classify_block "$block")
  [ "$class" != malformed ] || die "feed block is malformed for $task"
  schema=$(result_field "$block" schema) || die "feed block schema is ambiguous for $task"
  status=$(result_field "$block" status) || die "feed block status is ambiguous for $task"
  path=$(result_field "$block" path) || die "feed block path is ambiguous for $task"
  from=$(result_field "$block" from_offset) || die "feed block start offset is ambiguous for $task"
  to=$(result_field "$block" to_offset) || die "feed block end offset is ambiguous for $task"
  from_hash=$(result_field "$block" from_prefix_sha256) || die "feed block start hash is ambiguous for $task"
  to_hash=$(result_field "$block" to_prefix_sha256) || die "feed block end hash is ambiguous for $task"
  payload_hash=$(result_field "$block" payload_sha256) || die "feed block payload hash is ambiguous for $task"
  payload_bytes=$(result_field "$block" payload_bytes) || die "feed block payload size is ambiguous for $task"
  reason=$(result_field "$block" reason) || die "feed block reason is ambiguous for $task"
  [ "$schema" = fm-remote-delta.v1 ] && [ "$path" = "state/$task.status" ] || die "feed block identifies the wrong source for $task"
  case "$from$to$payload_bytes" in *[!0-9]*) die "feed block carries a nonnumeric size or offset for $task" ;; esac
  for hash in "$from_hash" "$to_hash" "$payload_hash"; do
    case "$hash" in *[!A-Fa-f0-9]*|'') die "feed block carries an invalid SHA-256 value for $task" ;; esac
    [ "${#hash}" -eq 64 ] || die "feed block carries an invalid SHA-256 length for $task"
  done
  status_file="$STATE/$task.status"
  mkdir -p "$STATE" || die "cannot create parent state directory"
  [ ! -L "$status_file" ] || die "parent status log is a symlink"
  lock="$STATE/.remote-feed-ingest-$task.lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock remote feed ingest for $task"
  if [ ! -e "$status_file" ]; then
    (umask 077; : > "$status_file") \
      || { fm_lock_release "$lock"; die "cannot create parent status log"; }
  fi
  [ -f "$status_file" ] && [ ! -L "$status_file" ] \
    || { fm_lock_release "$lock"; die "parent status log is unsafe"; }
  source_record=$(mirrored_source_path "$task")
  if [ -L "$source_record" ] || { [ -e "$source_record" ] && [ ! -f "$source_record" ]; }; then
    fm_lock_release "$lock"
    die "remote feed mirrored-source record is unsafe: $source_record"
  fi
  if [ ! -e "$source_record" ]; then
    (umask 077; : > "$source_record") \
      || { fm_lock_release "$lock"; die "cannot create remote feed mirror identity"; }
  fi
  chmod 600 "$source_record" \
    || { fm_lock_release "$lock"; die "cannot secure remote feed mirror identity"; }
  read_cursor "$(cursor_path "$route" "$task")"
  if [ "$CURSOR_OFFSET" -eq "$to" ] && [ "$CURSOR_HASH" = "$to_hash" ]; then
    cursor_already=1
  elif [ "$CURSOR_OFFSET" -ne "$from" ] || [ "$CURSOR_HASH" != "$from_hash" ]; then
    fm_lock_release "$lock"
    die "feed block does not continue the current cursor for $task"
  fi
  if [ "$class" = continuity-broken ]; then
    line="blocked [key=remote-feed-continuity-$task]: remote status feed continuity broke for $task on $route ($reason) at offset ${CURSOR_OFFSET} prefix $(continuity_prefix)"
    append_rc=0
    if status_event_recorded "$status_file" "$line"; then
      append_rc=1
    else
      append_status_once "$status_file" "$(status_stamp_line "$line")" || append_rc=$?
    fi
    [ "$append_rc" -ne 2 ] || { fm_lock_release "$lock"; die "cannot append continuity escalation"; }
    [ "$append_rc" -ne 0 ] || appended=$((appended + 1))
    write_cursor "$(cursor_path "$route" "$task")" "$to" "$to_hash" || { fm_lock_release "$lock"; die "cannot adopt the proven feed cursor"; }
    if [ -n "$seq" ]; then
      write_ingest_receipt "$(ingest_receipt_path "$route" "$task" "$seq")" "$FM_FEED_INGEST_RESULT" \
        || { fm_lock_release "$lock"; die "cannot commit feed ingestion receipt"; }
    fi
    fm_lock_release "$lock"
    printf 'ingested: %s appended=%s offset=%s break=%s\n' "$task" "$appended" "$to" "$reason"
    return 0
  fi
  [ "$status" = delta ] && [ "$payload_bytes" -gt 0 ] || { fm_lock_release "$lock"; die "delta block has no payload for $task"; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-feed-ingest.XXXXXX") || { fm_lock_release "$lock"; die "cannot create ingest staging directory"; }
  payload="$tmp/payload"
  blank=$(LC_ALL=C awk '$0 == "" { print NR; exit }' "$block")
  case "$blank" in ''|*[!0-9]*) fm_lock_release "$lock"; rm -rf -- "$tmp"; die "delta block has no payload boundary for $task" ;; esac
  tail -n "+$((blank + 1))" "$block" > "$payload"
  actual_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  actual_hash=$(sha256_file "$payload")
  if [ "$actual_bytes" -ne "$payload_bytes" ] || [ "$actual_hash" != "$payload_hash" ]; then
    fm_lock_release "$lock"; rm -rf -- "$tmp"; die "delta block payload does not match its digest for $task"
  fi
  normalized_payload="$tmp/normalized-payload"
  normalize_payload "$payload" "$normalized_payload" || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot normalize feed payload"; }
  if ! offered=$(extract_document_pointers "$normalized_payload"); then
    fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot extract feed document pointers"
  fi
  delivered_map="$tmp/delivered.map"
  : > "$delivered_map" || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot stage the delivered document map"; }
  while IFS= read -r doc || [ -n "$doc" ]; do
    [ -n "$doc" ] || continue
    fetch_rc=0
    local_doc=''
    fetch_document "$route" "$task" "$doc" local_doc || fetch_rc=$?
    if [ "$fetch_rc" -eq 1 ]; then
      if [ -n "$undelivered" ]; then
        undelivered="$undelivered
$doc	$FETCH_DOC_REASON"
      else
        undelivered="$doc	$FETCH_DOC_REASON"
      fi
      continue
    fi
    [ "$fetch_rc" -ne "$SSH_UNAVAILABLE" ] \
      || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "remote transport was unavailable while fetching $doc"; }
    [ "$fetch_rc" -eq 0 ] \
      || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "could not store referenced remote document: $doc"; }
    printf '%s\t%s\n' "$doc" "$local_doc" >> "$delivered_map" \
      || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot stage the delivered document map"; }
  done <<EOF
$offered
EOF
  mirrored="$tmp/mirrored"
  rewrite_document_pointers "$normalized_payload" "$delivered_map" "$mirrored" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot rewrite feed document pointers"; }
  status_additions="$tmp/status-additions"
  source_additions="$tmp/source-additions"
  : > "$status_additions" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot stage feed mirror identity"; }
  : > "$source_additions" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot stage feed mirror identity"; }
  stage_mirror_lines "$normalized_payload" "$mirrored" "$source_record" "$status_file" \
    "$status_additions" "$source_additions" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot stage feed mirror identity"; }
  cat "$status_additions" >> "$status_file" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot append remote feed"; }
  appended=$(LC_ALL=C awk 'END { print NR + 0 }' "$status_additions") \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot count appended feed lines"; }
  cat "$source_additions" >> "$source_record" \
    || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot commit feed mirror identity"; }
  while IFS='	' read -r doc reason || [ -n "$doc" ]; do
    [ -n "$doc" ] || continue
    line="note: remote document did not transfer for $task: $doc - $reason"
    append_rc=0
    if status_event_recorded "$status_file" "$line"; then
      append_rc=1
    else
      append_status_once "$status_file" "$(status_stamp_line "$line")" || append_rc=$?
    fi
    [ "$append_rc" -ne 2 ] || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot append remote document note"; }
    [ "$append_rc" -ne 0 ] || appended=$((appended + 1))
  done <<EOF
$undelivered
EOF
  if [ -n "$seq" ]; then
    write_ingest_receipt "$(ingest_receipt_path "$route" "$task" "$seq")" "$FM_FEED_INGEST_RESULT" \
      || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot commit feed ingestion receipt"; }
  fi
  if [ "$cursor_already" -eq 0 ]; then
    write_cursor "$(cursor_path "$route" "$task")" "$to" "$to_hash" || { fm_lock_release "$lock"; rm -rf -- "$tmp"; die "cannot commit feed cursor"; }
  fi
  fm_lock_release "$lock"
  rm -rf -- "$tmp"
  printf 'ingested: %s appended=%s offset=%s\n' "$task" "$appended" "$to"
}

cmd_ingest() {
  local route=${1:-} result=${2:-} seq=${3:-} split task block rc=0 tasks=0 appended=0 breaks=0 line count
  validate_route "$route"
  route_is_remote "$route"
  [ -f "$result" ] && [ ! -L "$result" ] || die "feed result is unavailable or unsafe: $result"
  split=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-remote-feed-ingest.XXXXXX") || die "cannot create feed ingest staging directory"
  INGEST_TMP=$split
  FM_FEED_INGEST_RESULT=$result
  export FM_FEED_INGEST_RESULT
  if ! split_frames "$result" "$split" > "$split/frames"; then
    die "feed result is malformed"
  fi
  while read -r task block; do
    [ -n "$task" ] && [ -n "$block" ] || die "feed result frame is malformed"
    tasks=$((tasks + 1))
  done < "$split/frames"
  [ "$tasks" -gt 0 ] || die "feed result carries no task"
  while read -r task block; do
    receipt=$(ingest_receipt_path "$route" "$task" "$seq")
    if [ -n "$seq" ] && ingest_receipt_matches "$receipt" "$result"; then
      continue
    fi
    line=$(ingest_task_block "$route" "$task" "$block" "$seq") || rc=$?
    [ "$rc" -eq 0 ] || { rm -rf -- "$split"; INGEST_TMP=''; unset FM_FEED_INGEST_RESULT; return "$rc"; }
    count=$(printf '%s' "$line" | sed -n 's/^ingested: .* appended=\([0-9][0-9]*\) .*/\1/p')
    case "$count" in ''|*[!0-9]*) rm -rf -- "$split"; INGEST_TMP=''; unset FM_FEED_INGEST_RESULT; die "feed ingest reported an unreadable count" ;; esac
    appended=$((appended + count))
    case "$line" in *' break='*) breaks=$((breaks + 1)) ;; esac
  done < "$split/frames"
  rm -rf -- "$split"
  INGEST_TMP=''
  unset FM_FEED_INGEST_RESULT
  printf 'ingested: %s tasks=%s appended=%s breaks=%s\n' "$route" "$tasks" "$appended" "$breaks"
}
cmd_handle_locked() {
  local route=${1:-} seq=${2:-} result=${3:-} sid class rc=0
  validate_route "$route"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  sid=$(source_id "$route")
  class=$(classify_result "$result")
  [ "$class" != malformed ] || die "feed result is malformed"
  cmd_ingest "$route" "$result" "$seq" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  cmd_arm_locked "$route" || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  return "$rc"
}

cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} route rc=0
  case "$sid" in
    remote-feed-?*) route=${sid#remote-feed-} ;;
    *) die "not a remote feed source: $sid" ;;
  esac
  validate_route "$route"
  [ "$(source_id "$route")" = "$sid" ] || die "source id does not identify one execution home: $sid"
  cmd_handle "$route" "$seq" "$result" || rc=$?
  return "$rc"
}

cmd_handle() {
  local route=${1:-} lock
  validate_route "$route"
  lock=$(feed_lifecycle_lock_path "$STATE" "$route")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote feed lifecycle for $route"
    LIFECYCLE_LOCK=$lock
    trap 'cleanup_temp_paths; fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    cmd_handle_locked "$@"
  )
}

cmd_retire() {
  local route=${1:-} force=${2:-} sid lock inbox path base seq pending=0
  validate_route "$route"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  sid=$(source_id "$route")
  lock=$(feed_lifecycle_lock_path "$STATE" "$route")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote feed lifecycle for $route"
    LIFECYCLE_LOCK=$lock
    trap 'cleanup_temp_paths; fm_lock_release "$LIFECYCLE_LOCK"' EXIT
    "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || return 1
    inbox="$STATE/procevent-inbox"
    if [ -d "$inbox" ] && [ ! -L "$inbox" ]; then
      for path in "$inbox/$sid".*.result; do
        [ -e "$path" ] || continue
        base=${path%.result}
        seq=${base##*.}
        [ -e "$base.handled" ] || pending=$((pending + 1))
      done
      if [ "$force" != --force ] && [ "$pending" -gt 0 ]; then
        die "remote feed retirement refused with $pending unhandled captured result(s)"
      fi
      if [ "$force" = --force ]; then
        for path in "$inbox/$sid".*.result "$inbox/$sid".*.adapter "$inbox/$sid".*.handled; do
          [ -e "$path" ] || continue
          rm -f -- "$path" || die "cannot discard remote feed capture: $path"
        done
      fi
    fi
    rm -rf -- "$(cursor_dir "$route")"
  )
}

require_parent_lifecycle_lock() {
  local route=$1 lock owner pid
  lock=$(feed_lifecycle_lock_path "$STATE" "$route")
  if [ -L "$lock" ]; then
    owner=$(fm_lock_link_owner "$lock" 2>/dev/null || true)
    [ -n "$owner" ] || die "remote feed lifecycle lock ownership is invalid"
  else
    owner=$lock
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  [ "$pid" = "$PPID" ] || die "remote feed lifecycle lock is not held by the caller"
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$@" ;;
  ensure-armed) shift; [ "$#" -eq 1 ] || usage; cmd_ensure_armed "$@" ;;
  arm-locked) shift; [ "$#" -eq 1 ] || usage; require_parent_lifecycle_lock "$1"; cmd_arm_locked "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$@" ;;
  handle) shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  ingest) shift; [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage; cmd_ingest "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; [ -s "$1" ] ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  relisten) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
