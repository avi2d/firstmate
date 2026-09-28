#!/usr/bin/env bash
# fm-flake-watch.sh: one backlog task per red scheduled flake run.
# Usage: fm-flake-watch.sh [check|arm|disarm|--help]
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TASKS_BIN="$SCRIPT_DIR/fm-tasks-axi.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
CHECK_ID=flake-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
SEEN="$STATE/.flake-watch-seen"
ERROR_RECORD="$STATE/.flake-watch-error"
RECORD_SCHEMA=fm-flake-watch-v1
MAX_LINE=300

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-flake-watch.sh [check]   file one backlog task per new red scheduled flake run
  fm-flake-watch.sh arm       write and register state/flake-watch.check.sh
  fm-flake-watch.sh disarm    remove the check shim, its trust binding, and the records
  fm-flake-watch.sh --help    print this help

Watched repositories are avi2d/skills, avi2d/checks, avi2d/dotfiles,
avi2d/career, avi2d/learning, avi2d/smithers, and avi2d/website.
Each filed task names the repository, the failing test with its line,
the seed, and the run URL. A run already recorded in
state/.flake-watch-seen, or already owning its backlog task, is never
filed twice. Failure detail comes from the run's flake-report artifact;
a run whose artifact has expired still gets its one task, with the run
URL and a note that the detail is gone. A repository without a flake
workflow is skipped silently.
FM_FLAKE_WATCH_DAYS bounds how far back a red run is news (default 7).
FM_FLAKE_WATCH_NOW pins the clock as epoch seconds for tests.
EOF
}

die_usage() {
  printf 'fm-flake-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

OWNER=avi2d
REPOS="skills checks dotfiles career learning smithers website"
WORKFLOW=flake.yml
PER_PAGE=10

NOW=${FM_FLAKE_WATCH_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) printf 'fm-flake-watch: FM_FLAKE_WATCH_NOW must be epoch seconds\n' >&2; exit 2 ;; esac
DAYS=${FM_FLAKE_WATCH_DAYS:-7}
case "$DAYS" in ''|*[!0-9]*|0) printf 'fm-flake-watch: FM_FLAKE_WATCH_DAYS must be a positive whole number\n' >&2; exit 2 ;; esac
CUTOFF=$((NOW - DAYS * 86400))

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
BUDGET=${FM_FLAKE_WATCH_BUDGET:-20}
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=20 ;; esac
[ "$BUDGET" -le 25 ] || BUDGET=25
BUDGET_CAP=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_CAP" -ge 1 ] || BUDGET_CAP=1
[ "$BUDGET" -le "$BUDGET_CAP" ] || BUDGET=$BUDGET_CAP
DEADLINE=$((SECONDS + BUDGET))

past_budget() { [ "$SECONDS" -ge "$DEADLINE" ]; }

error_record_read() {
  ERROR_RECORDED=
  if [ -f "$ERROR_RECORD" ] && [ ! -L "$ERROR_RECORD" ]; then
    ERROR_RECORDED=$(sed -n '2p' "$ERROR_RECORD" 2>/dev/null)
  fi
}

error_record_write() {
  [ -n "${1:-}" ] || { rm -f -- "$ERROR_RECORD"; return 0; }
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-flake-watch.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n%s\n' "$RECORD_SCHEMA" "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$ERROR_RECORD" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

seen_has() {
  [ -f "$SEEN" ] && [ ! -L "$SEEN" ] && grep -qxF "$1" "$SEEN" 2>/dev/null
}

seen_add() {
  local key=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  if [ -e "$SEEN" ] && { [ -L "$SEEN" ] || [ ! -f "$SEEN" ]; }; then
    return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-flake-watch.XXXXXX" 2>/dev/null) || return 1
  if [ -f "$SEEN" ]; then
    cat "$SEEN" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  fi
  printf '%s\n' "$key" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$SEEN" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

api_body() {
  local out rc=0
  out=$(gh-axi "$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *404*) return 2 ;;
    esac
    printf '%s\n' "$out" | head -n 3
    return 1
  fi
  case "$out" in
    *"truncated: true"*) printf '%s\n' "$out" | head -n 3; return 1 ;;
  esac
  local raw
  raw=$(printf '%s\n' "$out" | sed -n 's/^  body: //p')
  [ -n "$raw" ] || { printf 'unreadable api response'; return 1; }
  printf '%s\n' "$raw" | jq -r '.' 2>/dev/null || { printf 'unreadable api response'; return 1; }
}

report_runs() {
  local repo=$1
  api_body api "/repos/$OWNER/$repo/actions/workflows/$WORKFLOW/runs?event=schedule&status=completed&per_page=$PER_PAGE" \
    --jq '.workflow_runs[] | "\(.id)\t\(.conclusion)\t\(.html_url)\t\(.created_at)"'
}

red_runs_since() {
  jq -R -s -r --argjson cutoff "$CUTOFF" '
    split("\n") | map(select(length > 0) | split("\t")
    | {id: .[0], conclusion: .[1], url: .[2], created: .[3]}
    | select(.conclusion == "failure" and ((.created | fromdateiso8601) >= $cutoff))) | .[] | "\(.id)\t\(.url)\t\(.created)"'
}

failure_detail() {
  local dir=$1
  jq -r '.failures[] | "\(.file)\t\(.line)\t\(.seeds | join(","))\t\(.test)"' "$dir/flake-report.json" 2>/dev/null
}

outside_detail() {
  local dir=$1
  jq -r '.outsideTests | join(",")' "$dir/flake-report.json" 2>/dev/null
}

file_task() {
  local task=$1 title=$2 repo=$3 body=$4
  BD_DUE_REQUIRED=false "$TASKS_BIN" add "$task" "$title" --kind ship --repo "$repo" --body "$body" >/dev/null 2>&1
}

action_check() {
  local repo runs rc=0 task title body detail outside first_file first_line first_seeds count failures
  local errors=0 filed=0 truncated=
  local error_line=
  local tmp report
  command -v gh-axi >/dev/null 2>&1 || error_line="gh-axi is not installed"
  command -v jq >/dev/null 2>&1 || error_line="jq is not installed"
  mkdir -p "$STATE" "$DATA" 2>/dev/null || error_line="cannot write $STATE"
  error_record_read
  if [ -z "${error_line:-}" ]; then
    for repo in $REPOS; do
      past_budget && { truncated=1; break; }
      runs=$(report_runs "$repo") || rc=$?
      if [ "$rc" -eq 2 ]; then rc=0; continue; fi
      if [ "$rc" -ne 0 ]; then
        errors=1
        error_line="$repo: ${runs:-flake run list failed}"
        rc=0
        continue
      fi
      [ -n "$runs" ] || continue
      while IFS="$(printf '\t')" read -r id url created; do
        [ -n "${id:-}" ] || continue
        past_budget && { truncated=1; break 2; }
        seen_has "$repo/$id" && continue
        task="flake-$repo-$id"
        if "$TASKS_BIN" show "$task" >/dev/null 2>&1; then
          seen_add "$repo/$id" || true
          continue
        fi
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-flake-watch.XXXXXX" 2>/dev/null) || {
          errors=1; error_line="cannot stage the flake report for $repo run $id"; continue
        }
        report=
        if gh-axi run download "$id" -R "$OWNER/$repo" --name flake-report --dir "$tmp" >/dev/null 2>&1 \
          && [ -f "$tmp/flake-report.json" ]; then
          report=1
          detail=$(failure_detail "$tmp")
          outside=$(outside_detail "$tmp")
        fi
        rm -rf -- "$tmp"
        if [ -n "${report:-}" ] && [ -n "${detail:-}" ]; then
          count=$(printf '%s\n' "$detail" | wc -l | tr -d '[:space:]')
          first_file=$(printf '%s\n' "$detail" | head -n 1 | cut -f1)
          first_line=$(printf '%s\n' "$detail" | head -n 1 | cut -f2)
          first_seeds=$(printf '%s\n' "$detail" | head -n 1 | cut -f3)
          if [ "$count" = 1 ]; then
            title="$repo flake red: $first_file:$first_line seed $first_seeds"
          else
            title="$repo flake red: $count failing tests, first $first_file:$first_line seed $first_seeds"
          fi
          failures=$(printf '%s\n' "$detail" | while IFS="$(printf '\t')" read -r file fline seeds name; do
            printf -- '- %s:%s seed %s %s\n' "$file" "$fline" "$seeds" "$name"
          done)
          body=$(printf 'Scheduled flake run %s failed on %s.\nRun: %s\n\nFailing tests:\n%s\n\nReproduce a failing run with bun test --randomize --seed=<seed>.' \
            "$id" "$created" "$url" "$failures")
        else
          if [ -n "${report:-}" ] && [ -n "${outside:-}" ] && [ "$outside" != "null" ] && [ -n "$outside" ]; then
            title="$repo flake red: run failed outside any test, seed $outside"
          else
            title="$repo flake red: run $id needs a look"
          fi
          body=$(printf 'Scheduled flake run %s failed on %s.\nRun: %s\n\nThe flake-report artifact carried no failing-test detail (expired or missing); read the run log for the failing test and seed.' \
            "$id" "$created" "$url")
        fi
        if file_task "$task" "$title" "$repo" "$body"; then
          seen_add "$repo/$id" || true
          filed=$((filed + 1))
          fm_cap_line_var "flake-watch: filed $task ($title)" "$MAX_LINE"
          printf '%s\n' "$FM_LINE_CAP_LINE"
        else
          errors=1
          error_line="could not file $task"
        fi
      done <<EOF
$(printf '%s\n' "$runs" | red_runs_since)
EOF
    done
    [ -z "${truncated:-}" ] || { errors=1; error_line="stopped early at the ${BUDGET}s budget with repositories left unread"; }
  else
    errors=1
  fi
  if [ "$errors" -eq 1 ] && [ "${error_line:-}" != "${ERROR_RECORDED:-}" ]; then
    fm_cap_line_var "flake-watch: $error_line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
    error_record_write "$error_line" || true
  elif [ "$errors" -eq 0 ]; then
    error_record_write || true
  fi
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-flake-watch.sh - scheduled flake-run poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-flake-watch.sh") check"
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
  tmp=$(umask 077; mktemp "$STATE/.fm-flake-watch.XXXXXX" 2>/dev/null) || return 1
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
  tmp=$(umask 077; mktemp "$STATE/.fm-flake-watch.XXXXXX" 2>/dev/null) || return 1
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

action_arm() {
  local want home
  command -v gh-axi >/dev/null 2>&1 || { printf 'fm-flake-watch: gh-axi is not installed; cannot arm\n' >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'fm-flake-watch: jq is not installed; cannot arm\n' >&2; return 1; }
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-flake-watch: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-flake-watch: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap 'arm_rollback; printf "fm-flake-watch: arming was interrupted, so state/%s.check.sh is not armed\n" "$CHECK_ID" >&2; exit 1' HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-flake-watch: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-flake-watch: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$SEEN" "$ERROR_RECORD"
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
