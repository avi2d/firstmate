#!/usr/bin/env bash
# Report watched forks whose upstream has moved; usage below owns the contract.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fork-upstream.json"
RECORD="$STATE/.fork-drift"
CHECK_ID="fork-drift"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-fork-drift-v1
MAX_LINE=1000

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-fork-drift-check.sh [check]   report new upstream heads or releases (silent when current)
  fm-fork-drift-check.sh arm       write and register state/fork-drift.check.sh
  fm-fork-drift-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-fork-drift-check.sh --help    print this help

Watched forks are read from config/fork-upstream.json (local, gitignored).
See docs/configuration.md for the schema and docs/examples/fork-upstream.json for a starting point.
EOF
}

die_usage() {
  printf 'fm-fork-drift-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_FORK_DRIFT_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-fork-drift-check: FM_FORK_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-fork-drift-check: FM_FORK_DRIFT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PROBE_SECS=${FM_FORK_DRIFT_PROBE_SECS:-10}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-fork-drift-check: FM_FORK_DRIFT_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-fork-drift-check: FM_FORK_DRIFT_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_FORK_DRIFT_BUDGET_SECS:-25}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-fork-drift-check: FM_FORK_DRIFT_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-fork-drift-check: FM_FORK_DRIFT_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

PROBE_MIN_SECS=1
CLOCK_ROUNDING_SECS=1
KILL_GRACE_SECS=1

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

record_epoch_now() {
  case "${FM_FORK_DRIFT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FORK_DRIFT_NOW" ;;
  esac
}

real_epoch() { date +%s; }

FINDINGS=
DEADLINE=0
INCOMPLETE_REPORTED=0
TMP=
TMP_LASTS=
COUNT_DIRS=

emit() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$text
  else
    FINDINGS="$FINDINGS; $text"
  fi
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

budget_allows() {
  local name=$1
  budget_exhausted || return 0
  if [ "$INCOMPLETE_REPORTED" -eq 0 ]; then
    INCOMPLETE_REPORTED=1
    emit "check incomplete: the time budget ran out before $name"
  fi
  return 1
}

probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

CONFIG_PROBLEM=

config_validate() {
  local problem status
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read the fork registry'
    return 1
  fi
  problem=$(jq -r '
    def entry_problem($e):
      if ($e | type) != "object" then "every entry in forks must be an object"
      elif ($e.project | type) != "string" or ($e.project | test("^[A-Za-z0-9._+-]+$") | not) then "every fork needs a project of letters, digits, dot, underscore, plus, and dash"
      elif ($e.fork | type) != "string" or ($e.fork | length) == 0 or ($e.fork | test("[[:cntrl:][:space:]]")) then "fork \($e.project) needs a non-empty fork without whitespace"
      elif ($e.upstream | type) != "string" or ($e.upstream | length) == 0 or ($e.upstream | test("[[:cntrl:][:space:]]")) then "fork \($e.project) needs a non-empty upstream without whitespace"
      elif ($e.trigger | type) != "string" or (["upstream-head", "release"] | index($e.trigger) | not) then "fork \($e.project) trigger must be upstream-head or release"
      elif ($e | has("branch")) and (($e.branch | type) != "string" or ($e.branch | test("^[A-Za-z0-9._/-]+$") | not)) then "fork \($e.project) branch must be a simple branch name"
      else empty
      end;
    def problems:
      if type != "object" then ["the top level must be an object"]
      elif (.forks | type) != "array" then ["forks must be an array"]
      elif (.forks | length) == 0 then ["forks must list at least one fork"]
      else
        [.forks[] | entry_problem(.)]
        + (if ([.forks[].project] | unique | length) != (.forks | length) then ["project names must be unique"] else [] end)
      end;
    problems | .[0] // "ok"
  ' "$CONFIG" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$problem" ]; then
    CONFIG_PROBLEM='the fork registry is not valid JSON'
    return 1
  fi
  if [ "$problem" != ok ]; then
    CONFIG_PROBLEM=$problem
    return 1
  fi
  CONFIG_PROBLEM=
  return 0
}

FIELD_SEP=$(printf '\037')

config_records() {
  jq -r '
    .forks[] | [
      .project,
      .fork,
      .upstream,
      .trigger,
      (.branch // "")
    ] | join("\u001f")
  ' "$CONFIG" 2>/dev/null
}

is_slug() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' 2>/dev/null
}

remote_url() {
  if is_slug "$1"; then
    printf 'https://github.com/%s.git\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

remote_usable() {
  is_slug "$1" && return 0
  case "$1" in
    /*) return 0 ;;
    *:* ) return 0 ;;
  esac
  return 1
}

RECORD_EPOCH=0
RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_REPORTED=
  rm -f -- "$TMP_LASTS" 2>/dev/null
  : > "$TMP_LASTS"
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported=*) RECORD_REPORTED=${line#reported=} ;;
      last=*)
        printf '%s\n' "${line#last=}" >> "$TMP_LASTS"
        ;;
    esac
  done < "$RECORD"
  return 0
}

record_last_get() {
  awk -v p="$1" '$1 == p { print $2; exit }' "$TMP_LASTS" 2>/dev/null
}

record_last_set() {
  local tmp
  tmp=$(mktemp "$TMP_LASTS.XXXXXX" 2>/dev/null) || return 1
  awk -v p="$1" -v t="$2" '$1 != p { print } END { print p, t }' "$TMP_LASTS" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$TMP_LASTS" || { rm -f -- "$tmp"; return 1; }
}

record_write() {
  local reported=$1 tmp project fork upstream trigger branch token
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
    if config_records >/dev/null 2>&1; then
      while IFS=$FIELD_SEP read -r project fork upstream trigger branch; do
        [ -n "$project" ] || continue
        token=$(record_last_get "$project")
        [ -n "$token" ] || continue
        printf 'last=%s %s\n' "$project" "$token"
      done < <(config_records)
    else
      grep -h '^last=' "$RECORD" 2>/dev/null || true
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

NOT_ISSUED=3

probe_run() {
  budget_exhausted && return "$NOT_ISSUED"
  fm_run_timed "$(probe_bound)" "$@"
}

short_sha() {
  printf '%s' "$1" | cut -c1-12
}

resolve_branch() {
  local url=$1 out status branch
  out=$(probe_run git ls-remote --symref "$url" HEAD 2>/dev/null)
  status=$?
  case "$status" in
    "$NOT_ISSUED") return "$NOT_ISSUED" ;;
    124) return 124 ;;
  esac
  [ "$status" -eq 0 ] || return 1
  branch=$(printf '%s\n' "$out" | awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  [ -n "$branch" ] || return 2
  printf '%s\n' "$branch"
}

read_head() {
  local url=$1 branch=$2 out status sha
  out=$(probe_run git ls-remote "$url" "refs/heads/$branch" 2>/dev/null)
  status=$?
  case "$status" in
    "$NOT_ISSUED") return "$NOT_ISSUED" ;;
    124) return 124 ;;
  esac
  [ "$status" -eq 0 ] || return 1
  sha=$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')
  case "$sha" in
    ''|*[!0-9a-f]*) return 2 ;;
  esac
  [ "${#sha}" -eq 40 ] || return 2
  printf '%s\n' "$sha"
}

read_release_local() {
  local url=$1 out status tag
  out=$(probe_run git ls-remote "$url" 2>/dev/null)
  status=$?
  case "$status" in
    "$NOT_ISSUED") return "$NOT_ISSUED" ;;
    124) return 124 ;;
  esac
  [ "$status" -eq 0 ] || return 1
  tag=$(printf '%s\n' "$out" \
    | awk '$2 ~ /^refs\/tags\// && $2 !~ /\^\{\}$/ { sub(/^refs\/tags\//, "", $2); print $2 }' \
    | awk '{ original = $0; line = $0; sub(/^v/, "", line); n = split(line, part, /[^0-9]+/); key = ""; for (i = 1; i <= n; i++) key = key sprintf("%08d", part[i] + 0); printf "%s\t%s\n", key, original }' \
    | sort | tail -n 1 | cut -f 2-)
  [ -n "$tag" ] || return 2
  printf '%s\n' "$tag"
}

read_release_slug() {
  local slug=$1 out status tag
  command -v gh-axi >/dev/null 2>&1 || return 4
  out=$(probe_run gh-axi api "repos/$slug/releases/latest" --jq '.tag_name' 2>/dev/null)
  status=$?
  case "$status" in
    "$NOT_ISSUED") return "$NOT_ISSUED" ;;
    124) return 124 ;;
  esac
  [ "$status" -eq 0 ] || return 1
  tag=$(printf '%s\n' "$out" | awk '$1 == "body:" { line = $0; sub(/^ *body: /, "", line); print line; exit }')
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}

compare_local() {
  local fork_url=$1 fork_ref=$2 up_url=$3 up_ref=$4 dir status behind ahead
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-drift-count.XXXXXX" 2>/dev/null) || return 1
  COUNT_DIRS="$COUNT_DIRS $dir"
  git init --bare -q "$dir" 2>/dev/null || return 1
  probe_run git -C "$dir" fetch --quiet "$fork_url" "$fork_ref:refs/fork-drift/fork" 2>/dev/null
  status=$?
  case "$status" in
    "$NOT_ISSUED"|124) return "$status" ;;
  esac
  [ "$status" -eq 0 ] || return 1
  probe_run git -C "$dir" fetch --quiet "$up_url" "$up_ref:refs/fork-drift/upstream" 2>/dev/null
  status=$?
  case "$status" in
    "$NOT_ISSUED"|124) return "$status" ;;
  esac
  [ "$status" -eq 0 ] || return 1
  behind=$(git -C "$dir" rev-list --count refs/fork-drift/fork..refs/fork-drift/upstream 2>/dev/null) || return 1
  ahead=$(git -C "$dir" rev-list --count refs/fork-drift/upstream..refs/fork-drift/fork 2>/dev/null) || return 1
  case "$behind" in ''|*[!0-9]*) return 1 ;; esac
  case "$ahead" in ''|*[!0-9]*) return 1 ;; esac
  rm -rf -- "$dir"
  printf '%s %s\n' "$behind" "$ahead"
}

fork_compare() {
  local fork_url=$1 fork_branch=$2 up_url=$3 up_ref=$4 trigger=$5
  local ref
  if [ "$trigger" = release ]; then
    ref="refs/tags/$up_ref"
  else
    ref="refs/heads/$up_ref"
  fi
  compare_local "$fork_url" "refs/heads/$fork_branch" "$up_url" "$ref"
}

report_state() {
  local last
  last=$(record_last_get "$1")
  [ "$2" != "$last" ] || return 0
  if [ -n "$3" ]; then
    emit "$3"
  fi
  record_last_set "$1" "$2"
}

probe_failure() {
  case "$2" in
    "$NOT_ISSUED") report_state "$1" error "$1 check failed: the time budget ran out before $3 was read" ;;
    124) report_state "$1" error "$1 check failed: $3 did not answer" ;;
    *) report_state "$1" error "$1 check failed: $3 could not be read" ;;
  esac
}

fork_findings() {
  local project=$1 fork=$2 upstream=$3 trigger=$4 branch=$5
  local fork_url up_url fork_branch up_branch status state token finding counts behind ahead

  remote_usable "$fork" || {
    report_state "$project" error "$project check failed: fork $fork is neither owner/repo nor a git URL"
    return 0
  }
  remote_usable "$upstream" || {
    report_state "$project" error "$project check failed: upstream $upstream is neither owner/repo nor a git URL"
    return 0
  }
  fork_url=$(remote_url "$fork")
  up_url=$(remote_url "$upstream")
  fork_branch=$branch
  up_branch=$branch
  if [ -z "$branch" ]; then
    fork_branch=$(resolve_branch "$fork_url")
    status=$?
    if [ "$status" -ne 0 ]; then
      probe_failure "$project" "$status" "the default branch of the fork"
      return 0
    fi
    up_branch=$(resolve_branch "$up_url")
    status=$?
    if [ "$status" -ne 0 ]; then
      probe_failure "$project" "$status" "the default branch of the upstream"
      return 0
    fi
  fi

  if [ "$trigger" = release ]; then
    if is_slug "$upstream"; then
      state=$(read_release_slug "$upstream")
      status=$?
      if [ "$status" -eq 4 ]; then
        report_state "$project" error "$project check failed: gh-axi is required to read releases of $upstream"
        return 0
      fi
    else
      state=$(read_release_local "$up_url")
      status=$?
    fi
    case "$status" in
      0) token="release:$state" ;;
      2)
        report_state "$project" error "$project check failed: upstream $upstream has no releases"
        return 0
        ;;
      *)
        probe_failure "$project" "$status" "upstream releases"
        return 0
        ;;
    esac
    [ "$token" != "$(record_last_get "$project")" ] || return 0
    counts=$(fork_compare "$fork_url" "$fork_branch" "$up_url" "$state" release)
    status=$?
    if [ "$status" -eq 0 ]; then
      behind=${counts% *}
      ahead=${counts#* }
      if [ "$behind" -eq 0 ]; then
        report_state "$project" "$token" ""
        return 0
      fi
      finding="$project upstream published $state ($behind behind / $ahead ahead)"
    else
      finding="$project upstream published $state"
    fi
    report_state "$project" "$token" "$finding"
    return 0
  fi

  state=$(read_head "$up_url" "$up_branch")
  status=$?
  case "$status" in
    0) token="head:$state" ;;
    2)
      report_state "$project" error "$project check failed: upstream $upstream has no branch $up_branch"
      return 0
      ;;
    *)
      probe_failure "$project" "$status" "the upstream head"
      return 0
      ;;
  esac
  [ "$token" != "$(record_last_get "$project")" ] || return 0
  counts=$(fork_compare "$fork_url" "$fork_branch" "$up_url" "$up_branch" upstream-head)
  status=$?
  if [ "$status" -eq 0 ]; then
    behind=${counts% *}
    ahead=${counts#* }
    if [ "$behind" -eq 0 ]; then
      report_state "$project" "$token" ""
      return 0
    fi
    finding="$project is $behind behind / $ahead ahead of $upstream at $(short_sha "$state")"
  else
    finding="$project upstream moved to $(short_sha "$state") but the fork comparison failed"
  fi
  report_state "$project" "$token" "$finding"
  return 0
}

cleanup_check() {
  local d
  # shellcheck disable=SC2086  # deliberate split on a space-joined dir list
  for d in $COUNT_DIRS; do
    [ -n "$d" ] || continue
    rm -rf -- "$d"
  done
  COUNT_DIRS=
  if [ -n "$TMP" ]; then
    rm -rf -- "$TMP"
    TMP=
  fi
}

action_check() {
  local name fork upstream trigger branch
  local line now

  [ -f "$CONFIG" ] || return 0

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-drift.XXXXXX" 2>/dev/null) || return 0
  TMP_LASTS="$TMP/lasts"
  : > "$TMP_LASTS"
  trap cleanup_check EXIT HUP INT TERM

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    cleanup_check
    trap - EXIT HUP INT TERM
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if [ -n "$BUDGET_CUT_FROM" ]; then
    emit "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  if ! command -v git >/dev/null 2>&1; then
    emit "fork upstream registry: git is required to read upstream state"
  elif ! config_validate; then
    emit "fork upstream registry: $CONFIG_PROBLEM"
  else
    while IFS=$FIELD_SEP read -r name fork upstream trigger branch; do
      [ -n "$name" ] || continue
      budget_allows "$name" || break
      fork_findings "$name" "$fork" "$upstream" "$trigger" "$branch"
    done < <(config_records)
  fi

  line=
  if [ -n "$FINDINGS" ]; then
    fm_cap_line_var "fork drift: load the fork-drift-sync skill - $FINDINGS" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  if [ -n "$line" ] && [ "$FINDINGS" != "$RECORD_REPORTED" ]; then
    printf '%s\n' "$line"
  fi
  record_write "$FINDINGS" || true
  cleanup_check
  trap - EXIT HUP INT TERM
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-fork-drift-check.sh - watched fork drift poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-fork-drift-check.sh") check"
}

SHIM_WRITE_TMP=

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
  tmp=$(umask 077; mktemp "$STATE/.fm-fork-drift-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-fork-drift-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm trap below.
arm_interrupted() {
  arm_rollback
  printf 'fm-fork-drift-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-fork-drift-check: no fork registry at %s\n' "$CONFIG" >&2
    return 1
  fi
  if ! config_validate; then
    printf 'fm-fork-drift-check: %s (%s)\n' "$CONFIG_PROBLEM" "$CONFIG" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-fork-drift-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-fork-drift-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-fork-drift-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-fork-drift-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
