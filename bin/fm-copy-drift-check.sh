#!/usr/bin/env bash
# Report local copies behind origin's default branch or holding stale uncommitted work; usage below owns the contract.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RECORD="$STATE/.copy-drift"
CHECK_ID=copy-drift
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
RECORD_SCHEMA=fm-copy-drift-v1
MAX_LINE=1000
STALE_SECS=86400
CODE_ROOT_LABEL='firstmate code root'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-copy-drift-check.sh [check]   report copies behind origin or holding stale uncommitted work (silent when all are current and clean)
  fm-copy-drift-check.sh arm       write and register state/copy-drift.check.sh
  fm-copy-drift-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-copy-drift-check.sh --help    print this help

Copies: the firstmate code root and every clone directly under this home's projects/.
For each copy with an origin remote it fetches origin, then reports the commits on
origin's default branch that the local default branch lacks. For every copy it
reports an uncommitted change whose oldest modified tracked or untracked file is
more than a day old, naming that file. It never pulls, resets, stashes, or checks out.

Environment:
  FM_COPY_DRIFT_INTERVAL    seconds between sweeps, 0 or 60-86400 (default 86400; 0 sweeps every run)
  FM_COPY_DRIFT_FETCH_SECS  bound on the parallel fetches, 1-60 (default 15), cut to fit FM_CHECK_TIMEOUT

See docs/configuration.md "Local copy drift" for what a report means.
EOF
}

die_usage() {
  printf 'fm-copy-drift-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_COPY_DRIFT_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*) die_usage 'FM_COPY_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400' ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  die_usage 'FM_COPY_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400'
fi

FETCH_SECS=${FM_COPY_DRIFT_FETCH_SECS:-15}
case "$FETCH_SECS" in
  ''|*[!0-9]*|0) die_usage 'FM_COPY_DRIFT_FETCH_SECS must be a whole number from 1 to 60' ;;
esac
[ "$FETCH_SECS" -le 60 ] || die_usage 'FM_COPY_DRIFT_FETCH_SECS must be a whole number from 1 to 60'

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# The watcher kills a check at FM_CHECK_TIMEOUT, and a killed sweep prints nothing.
LOCAL_SCAN_RESERVE=5
FETCH_MAX=$((CHECK_TIMEOUT - LOCAL_SCAN_RESERVE))
[ "$FETCH_MAX" -ge 1 ] || FETCH_MAX=1
[ "$FETCH_SECS" -le "$FETCH_MAX" ] || FETCH_SECS=$FETCH_MAX

if [ "$(uname)" = Darwin ]; then
  STAT_MTIME_AND_NAME=(/usr/bin/stat -f '%m %N')
else
  STAT_MTIME_AND_NAME=(stat -c '%Y %n')
fi

now_epoch() {
  case "${FM_COPY_DRIFT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_COPY_DRIFT_NOW" ;;
  esac
}

FINDINGS=
TMP=
COPY_LABELS=()
COPY_DIRS=()
FETCH_SLOT=()

emit() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$text
  else
    FINDINGS="$FINDINGS; $text"
  fi
}

plural() {
  local count=$1 noun=$2
  if [ "$count" -eq 1 ]; then
    printf '%s %s\n' "$count" "$noun"
  else
    printf '%s %ss\n' "$count" "$noun"
  fi
}

is_clone_root() {
  local dir=$1 top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] && [ "$top" -ef "$dir" ]
}

already_listed() {
  local dir=$1 seen
  for seen in "${COPY_DIRS[@]}"; do
    [ "$seen" -ef "$dir" ] && return 0
  done
  return 1
}

collect_copies() {
  local dir
  if is_clone_root "$FM_ROOT"; then
    COPY_LABELS+=("$CODE_ROOT_LABEL")
    COPY_DIRS+=("$FM_ROOT")
  fi
  [ -d "$PROJECTS" ] || return 0
  for dir in "$PROJECTS"/*; do
    [ -d "$dir" ] || continue
    is_clone_root "$dir" || continue
    already_listed "$dir" && continue
    COPY_LABELS+=("projects/$(basename "$dir")")
    COPY_DIRS+=("$dir")
  done
}

has_origin() {
  git -C "$1" remote get-url origin >/dev/null 2>&1
}

git_store() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s\n' "$1"
}

# Sets FETCH_SLOT[i] to the copy whose fetch result copy i reads.
fetch_all() {
  local i j store
  local stores=()
  FETCH_SLOT=()
  for i in "${!COPY_DIRS[@]}"; do
    has_origin "${COPY_DIRS[$i]}" || continue
    store=$(git_store "${COPY_DIRS[$i]}")
    stores[i]=$store
    FETCH_SLOT[i]=$i
    # Worktrees of one repository share its refs, and concurrent fetches into them collide on its ref locks.
    for j in "${!stores[@]}"; do
      if [ "$j" -lt "$i" ] && [ "${stores[$j]}" = "$store" ]; then
        FETCH_SLOT[i]=$j
        break
      fi
    done
    [ "${FETCH_SLOT[$i]}" = "$i" ] || continue
    (
      fm_run_timed "$FETCH_SECS" git -C "${COPY_DIRS[$i]}" fetch --quiet origin >/dev/null 2>&1
      printf '%s\n' "$?" > "$TMP/fetch.$i"
    ) &
  done
  wait
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

behind_findings() {
  local label=$1 dir=$2 fetch_status=$3 branch behind
  case "$fetch_status" in
    0) ;;
    124)
      emit "$label could not be compared: fetching origin took longer than ${FETCH_SECS}s"
      return 0
      ;;
    *)
      emit "$label could not be compared: fetching origin failed"
      return 0
      ;;
  esac
  branch=$(default_branch "$dir") || {
    emit "$label could not be compared: origin's default branch is unknown"
    return 0
  }
  if ! git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    emit "$label could not be compared: it has no local $branch branch"
    return 0
  fi
  behind=$(git -C "$dir" rev-list --count "refs/heads/$branch..refs/remotes/origin/$branch" 2>/dev/null) || {
    emit "$label could not be compared: counting commits on origin/$branch failed"
    return 0
  }
  [ "$behind" -eq 0 ] || emit "$label is $(plural "$behind" commit) behind origin/$branch"
}

# Prints "<epoch> <path>" for the oldest changed path, or nothing when the copy is clean.
oldest_change() {
  local dir=$1 list=$TMP/changed record path
  : > "$list"
  while IFS= read -r -d '' record; do
    path=${record:3}
    # A deleted file has no mtime to age.
    [ -e "$dir/$path" ] || [ -L "$dir/$path" ] || continue
    printf '%s\0' "$dir/$path" >> "$list"
  done < <(git -C "$dir" --no-optional-locks status --porcelain=v1 -z --untracked-files=all --no-renames 2>/dev/null)
  [ -s "$list" ] || return 0
  xargs -0 "${STAT_MTIME_AND_NAME[@]}" < "$list" 2>/dev/null | sort -n | head -n 1
}

stale_findings() {
  local label=$1 dir=$2 now=$3 oldest mtime path days
  oldest=$(oldest_change "$dir")
  [ -n "$oldest" ] || return 0
  mtime=${oldest%% *}
  path=${oldest#* }
  path=${path#"$dir"/}
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ $((now - mtime)) -gt "$STALE_SECS" ] || return 0
  days=$(((now - mtime) / 86400))
  emit "$label has an uncommitted change $(plural "$days" day) old: $path"
}

cleanup_check() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  TMP=
}

record_epoch() {
  local schema line
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  {
    IFS= read -r schema && IFS= read -r line
  } < "$RECORD" || return 1
  [ "$schema" = "$RECORD_SCHEMA" ] || return 1
  line=${line#epoch=}
  case "$line" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$line"
}

record_write() {
  local now=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-copy-drift.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\nepoch=%s\n' "$RECORD_SCHEMA" "$now" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

action_check() {
  local now last deadline i status
  now=$(now_epoch)
  if [ "$INTERVAL" -ne 0 ] && last=$(record_epoch) \
    && [ "$now" -ge "$last" ] && [ $((now - last)) -lt "$INTERVAL" ]; then
    return 0
  fi
  command -v git >/dev/null 2>&1 || {
    printf 'copy drift: git is required to compare local copies\n'
    return 0
  }

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-copy-drift.XXXXXX" 2>/dev/null) || return 0
  trap cleanup_check EXIT HUP INT TERM
  deadline=$(($(date +%s) + CHECK_TIMEOUT - 1))

  collect_copies
  fetch_all
  for i in "${!COPY_DIRS[@]}"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      emit "check incomplete: time ran out before ${COPY_LABELS[$i]}"
      break
    fi
    if has_origin "${COPY_DIRS[$i]}"; then
      status=$(cat "$TMP/fetch.${FETCH_SLOT[$i]}" 2>/dev/null) || status=1
      behind_findings "${COPY_LABELS[$i]}" "${COPY_DIRS[$i]}" "${status:-1}"
    fi
    stale_findings "${COPY_LABELS[$i]}" "${COPY_DIRS[$i]}" "$now"
  done

  if [ -n "$FINDINGS" ]; then
    fm_cap_line "copy drift: $FINDINGS" "$MAX_LINE"
  fi
  record_write "$now" || true
  cleanup_check
  trap - EXIT HUP INT TERM
  return 0
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-copy-drift-check.sh - local copy drift poll shim.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-copy-drift-check.sh") check"
}

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-copy-drift-check.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

action_arm() {
  local home
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-copy-drift-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  shim_write "$(shim_content "$home")" || {
    printf 'fm-copy-drift-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    rm -f -- "$CHECK_SHIM"
    printf 'fm-copy-drift-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
  rm -f -- "$CHECK_SHIM" "$STATE/$CHECK_ID.check-trust" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
