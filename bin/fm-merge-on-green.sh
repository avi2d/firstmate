#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
Merge this home's green +yolo task pull requests with no agent turn.

Usage:
  fm-merge-on-green.sh sweep
  fm-merge-on-green.sh assess <task-id>
  fm-merge-on-green.sh pending

sweep   Assess every task in this home that recorded a GitHub pr=, or whose
        done line names one, and act:
        merge a green pull request through bin/fm-pr-merge.sh once it is
        settled, or bring a head that is behind its base up to date with
        gh pr update-branch, which merges the base in and never rebases.
        Green is settled when its last check finished at least
        FM_MERGE_ON_GREEN_SETTLE_SECS ago (default 10), or when the same head
        read green on two sweeps that far apart.
        Every other verdict leaves the pull request on the supervised path.
        A pull request skipped for what the forge reported is read again only
        after FM_MERGE_ON_GREEN_SKIP_RECHECK_SECS (default 60).
        A failed merge or update is retried at the same head only after
        FM_MERGE_ON_GREEN_RETRY_SECS (default 300).
        Verdict changes are appended to state/merge-on-green.log.
assess  Print one task's verdict without acting:
        <verdict><TAB><task><TAB><url><TAB><head><TAB><reason>
pending Exit 0 while some yolo task's GitHub pull request is not yet merged,
        or a yolo ship that can still open one is under way;
        1 when there is nothing left to merge.

Verdicts: green (merge once settled), update (behind its base), wait (checks
running or a forge read failed), skip (stays on the supervised path).
docs/configuration.md "Merge on green" owns the eligibility contract.
EOF
  exit 2
}

SETTLE_SECS=${FM_MERGE_ON_GREEN_SETTLE_SECS:-10}
RETRY_SECS=${FM_MERGE_ON_GREEN_RETRY_SECS:-300}
SKIP_RECHECK_SECS=${FM_MERGE_ON_GREEN_SKIP_RECHECK_SECS:-60}
FORGE_TIMEOUT=${FM_MERGE_ON_GREEN_FORGE_TIMEOUT:-20}
LOG_MAX_BYTES=262144
LOG="$STATE/merge-on-green.log"

VERDICT=
REASON=
URL=
HEAD=
DIFF_HEAD=
DIFF_RESULT=
CHECKS_DONE_AT=0

meta_value() {  # <meta> <key>
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#"$2="} ;; esac
  done < "$1"
  printf '%s' "$value"
}

verdict() {  # <verdict> <reason>
  VERDICT=$1
  REASON=$2
}

# Sets REPORT_LINE to the worker's latest done or ready report and
# AFTER_REPORT to the verb of any working, paused, or failed report after it.
REPORT_LINE=
AFTER_REPORT=
read_status_report() {  # <status-file>
  local line verb first
  REPORT_LINE='' AFTER_REPORT=''
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    first=${verb%%[[:space:]]*}
    case "$first" in
      done|ready) REPORT_LINE=$line AFTER_REPORT='' ;;
      working|paused|failed) [ -z "$REPORT_LINE" ] || AFTER_REPORT=$first ;;
    esac
  done < "$1"
}

names_url() {  # <text> <url>
  case "${1//"$2"[0-9]/}" in *"$2"*) return 0 ;; esac
  return 1
}

# A bare pull request number names no repository, so gh reads it inside the
# task copy and prints the canonical URL instead of one built from the number.
resolve_bare_pr() {  # <meta> <number>
  local meta=$1 num=$2 wt dir json url
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  wt=$(meta_value "$meta" worktree)
  dir=
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    dir=$wt
  else
    wt=$(meta_value "$meta" project)
    [ -n "$wt" ] && [ -d "$wt" ] && dir=$wt
  fi
  [ -n "$dir" ] || return 1
  json=$(cd "$dir" && forge gh pr view "$num" --json url,headRefName) || return 1
  url=$(printf '%s' "$json" | jq -r '.url // ""' 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  fm_pr_url_parse "$url" 2>/dev/null || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  printf '%s\n' "$FM_PR_URL"
}

# The newest GitHub pull request the done or ready reports name, so a later
# report supersedes the recorded one instead of ending at the earlier merge.
# A bare number resolves through the task copy, never from the number alone.
latest_status_pr_url() {  # <status-file> <meta>
  local file=$1 meta=$2 line verb first note url num rest last=
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    first=${verb%%[[:space:]]*}
    case "$first" in done|ready) ;; *) continue ;; esac
    note=$(status_line_note "$line")
    if url=$(fm_dod_pr_url_from_done_note "$note" 2>/dev/null); then
      if fm_pr_url_parse "$url" 2>/dev/null && [ "$FM_PR_PROVIDER" = github ]; then
        last=$FM_PR_URL
      fi
      continue
    fi
    rest=$(printf '%s' "$note" | sed 's|https\?://[^ ]*| |g')
    num=$(printf '%s' "$rest" | grep -Eo '(^|[^[:alnum:]])PR[ \t]*#?[0-9]+' | tail -1 | grep -Eo '[0-9]+$') || continue
    [ -n "$num" ] || continue
    if url=$(resolve_bare_pr "$meta" "$num"); then
      last=$url
    fi
  done < "$file"
  [ -n "$last" ] && printf '%s\n' "$last"
  return 0
}

# A report names the pull request with its URL or with the bare number that
# latest_status_pr_url resolved above.
report_names_pr() {  # <line> <url> <number>
  names_url "$1" "$2" && return 0
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(status_line_note "$1")" | sed 's|https\?://[^ ]*| |g' \
    | grep -Eq "(^|[^[:alnum:]])PR[ \t]*#?$3([^[:alnum:]]|$)"
}

# A clause naming a boundary flags it unless it is negated, so an ambiguous
# mention keeps the pull request on the supervised path. A comma continues a
# negated boundary list, as in "no credential, token or security change".
done_line_flags_boundary() {  # <done-line>
  printf '%s\n' "${1#*:}" | LC_ALL=C awk '
    {
      line = tolower($0)
      gsub(/https?:\/\/[^ ]+/, " ", line)
      gsub(/ - /, ";", line)
      n = split(line, clauses, /[;.()]/)
      for (i = 1; i <= n; i++) {
        m = split(clauses[i], parts, /,/)
        carried = 0
        for (j = 1; j <= m; j++) {
          c = " " parts[j] " "
          if (c !~ /credential|token|secret|security|auth|permission|sandbox|isolation/) { carried = 0; continue }
          if (carried || c ~ /[^a-z](no|not|none|without|never|nothing|unchanged|untouched)[^a-z]/ || c ~ /n'\''t[^a-z]/) { carried = 1; continue }
          found = 1
        }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# Prints what puts a diff across a credential or security boundary and exits 0,
# or exits 1 when it touches none.
diff_touches_boundary() {
  LC_ALL=C awk '
    /^diff --git / {
      name = substr($0, 12)
      path = tolower(name)
      workflow = (index(path, "a/.github/workflows/") == 1 || index(path, " b/.github/workflows/") > 0)
      if (path ~ /credential|auth|token|secret|sandbox|runner[-_]?isolation|id_rsa|id_ed25519|\/\.env|\.pem( |$)|\.key( |$)/) {
        print "touches " name
        hit = 1
        exit
      }
      next
    }
    workflow && /^[+-]/ && !/^(\+\+\+|---) / {
      line = tolower($0)
      if (line ~ /permissions|(read|write)-all/ \
          || line ~ /^[+-][ \t]*(actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses)[ \t]*:[ \t]*(read|write|none)/) {
        print "changes workflow permissions in " name
        hit = 1
        exit
      }
    }
    END { exit hit ? 0 : 1 }
  '
}

# pending, red:<names>, none, or green for one live pull-request view, then a
# tab and the epoch the last check finished, or 0 when a check run's finish is
# unreported.
checks_state() {  # <pull-request-json>
  printf '%s' "$1" | jq -r '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup[]
        | if .__typename == "CheckRun" then
            {name: (.name // ""),
             pending: (.status != "COMPLETED"),
             ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
             at: (.completedAt // "")}
          else
            {name: (.context // ""),
             pending: (.state == "PENDING" or .state == "EXPECTED"),
             ok: (.state == "SUCCESS"),
             at: (.startedAt // .createdAt // "")}
          end
        | .at |= (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}(\\.[0-9]+)?Z$") and (startswith("0001") | not)
                  then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) else 0 end) ]
    | (if length == 0 then "none"
       elif any(.[]; .pending) then "pending"
       elif all(.[]; .ok) then "green"
       else "red:" + ([.[] | select(.ok | not) | .name] | unique | join(", "))
       end) + "\t" + (if length > 0 and all(.[]; .at > 0) then (map(.at) | max | tostring) else "0" end)
  ' 2>/dev/null
}

forge() {
  fm_run_timed "$FORGE_TIMEOUT" "$@" 2>/dev/null
}

record_path() { printf '%s/%s.merge-on-green\n' "$STATE" "$1"; }

REC_VERDICT=
REC_HEAD=
REC_SINCE=
REC_REASON=
REC_DIFF_HEAD=
REC_DIFF_RESULT=
REC_ATTEMPT_KIND=
REC_ATTEMPT_HEAD=
REC_ATTEMPT_AT=
REC_CHECKED_AT=
record_load() {  # <task-id>
  local file key value
  REC_VERDICT='' REC_HEAD='' REC_SINCE='' REC_REASON='' REC_DIFF_HEAD='' REC_DIFF_RESULT='' REC_CHECKED_AT=''
  REC_ATTEMPT_KIND='' REC_ATTEMPT_HEAD='' REC_ATTEMPT_AT=''
  file=$(record_path "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      verdict) REC_VERDICT=$value ;;
      head) REC_HEAD=$value ;;
      since) REC_SINCE=$value ;;
      reason) REC_REASON=$value ;;
      diff_head) REC_DIFF_HEAD=$value ;;
      diff_result) REC_DIFF_RESULT=$value ;;
      attempt_kind) REC_ATTEMPT_KIND=$value ;;
      attempt_head) REC_ATTEMPT_HEAD=$value ;;
      attempt_at) REC_ATTEMPT_AT=$value ;;
      checked_at) REC_CHECKED_AT=$value ;;
    esac
  done < "$file"
  case "$REC_SINCE" in ''|*[!0-9]*) REC_SINCE=0 ;; esac
  case "$REC_ATTEMPT_AT" in ''|*[!0-9]*) REC_ATTEMPT_AT=0 ;; esac
  case "$REC_CHECKED_AT" in ''|*[!0-9]*) REC_CHECKED_AT=0 ;; esac
}

record_save() {  # <task-id>
  local file tmp
  file=$(record_path "$1")
  tmp=$(umask 077; mktemp "$STATE/.merge-on-green.XXXXXX") || return 1
  {
    printf 'verdict=%s\n' "$REC_VERDICT"
    printf 'head=%s\n' "$REC_HEAD"
    printf 'since=%s\n' "$REC_SINCE"
    printf 'reason=%s\n' "$(printf '%s' "$REC_REASON" | fm_wake_clean_field)"
    printf 'diff_head=%s\n' "$REC_DIFF_HEAD"
    printf 'diff_result=%s\n' "$(printf '%s' "$REC_DIFF_RESULT" | fm_wake_clean_field)"
    printf 'attempt_kind=%s\n' "$REC_ATTEMPT_KIND"
    printf 'attempt_head=%s\n' "$REC_ATTEMPT_HEAD"
    printf 'attempt_at=%s\n' "$REC_ATTEMPT_AT"
    printf 'checked_at=%s\n' "$REC_CHECKED_AT"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

log_line() {  # <task-id> <event> <detail>
  local size
  size=0
  [ ! -f "$LOG" ] || size=$(wc -c < "$LOG") || size=0
  size=${size//[!0-9]/}
  if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then
    tail -c $((LOG_MAX_BYTES / 2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f -- "$LOG.tmp" "$LOG"
  fi
  printf '%s %s %s %s head=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$URL" "${HEAD:0:12}" \
    "$(printf '%s' "$3" | fm_wake_clean_field)" >> "$LOG"
}

assess() {  # <task-id>
  local id=$1 meta kind yolo project posture hold_rc open json fields
  local state draft mergeable merge_state base checks diff behind base_enc
  local adopted candidate supersede head_branch expected_branch
  VERDICT='' REASON='' URL='' HEAD='' DIFF_HEAD='' DIFF_RESULT='' CHECKS_DONE_AT=0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { verdict skip "no task record"; return; }
  adopted=
  URL=$(meta_value "$meta" pr)
  read_status_report "$STATE/$id.status"
  candidate=$(latest_status_pr_url "$STATE/$id.status" "$meta") || candidate=
  if [ -n "$candidate" ] && [ "$candidate" != "$URL" ]; then
    # A later report names the next pull request while the record still
    # holds the earlier one, so the newest report wins once the recorded
    # one has landed instead of the task ending at the earlier merge while
    # its follow-up sits green. A missed recording turn leaves no pr= at
    # all, and the same newest report fills that gap instead of leaving a
    # green pull request unmerged. A recorded pull request that has not
    # landed keeps its claim, so a mistyped report cannot hijack it.
    supersede=1
    if [ -n "$URL" ] && fm_pr_url_parse "$URL" 2>/dev/null && [ "$FM_PR_PROVIDER" = github ]; then
      fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || supersede=
    fi
    if [ -n "$supersede" ]; then
      URL=$candidate
      adopted=1
    fi
  fi
  [ -n "$URL" ] || { verdict skip "no recorded pull request"; return; }
  # latest_status_pr_url parsed in a subshell, so its globals are lost
  # there and every URL is parsed again in this shell.
  if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
    verdict skip "not a GitHub pull request"
    return
  fi
  URL=$FM_PR_URL
  kind=$(meta_value "$meta" kind)
  [ "${kind:-ship}" = ship ] || { verdict skip "not a ship task"; return; }
  yolo=$(meta_value "$meta" yolo)
  [ "$yolo" = on ] || { verdict skip "task yolo is ${yolo:-unset}"; return; }
  project=$(meta_value "$meta" project)
  project=${project%/}
  project=${project##*/}
  [ -n "$project" ] || { verdict skip "no recorded project"; return; }
  posture=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$project" 2>/dev/null) || posture=
  case "$posture" in
    *" on") ;;
    *) verdict skip "the registry entry for $project does not carry +yolo"; return ;;
  esac
  if fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    verdict skip "already merged"
    return
  fi
  hold_rc=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1 || hold_rc=$?
  case "$hold_rc" in
    0) verdict skip "held for the captain"; return ;;
    1|3) ;;
    *) verdict skip "the captain hold could not be read"; return ;;
  esac
  merge_hold_rc=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-merge-hold.sh" open "$URL" >/dev/null 2>&1 || merge_hold_rc=$?
  case "$merge_hold_rc" in
    0) verdict skip "the pull request is held for the captain"; return ;;
    1) ;;
    *) verdict skip "the merge hold could not be read"; return ;;
  esac
  open=$(status_open_decisions "$STATE/$id.status")
  if [ -n "$open" ]; then
    verdict skip "open decision or blocker ${open%%$'\t'*}"
    return
  fi
  [ -n "$REPORT_LINE" ] || { verdict wait "the worker has not reported done"; return; }
  report_names_pr "$REPORT_LINE" "$URL" "$FM_PR_NUMBER" || { verdict wait "the done report does not name this pull request"; return; }
  case "$AFTER_REPORT" in
    failed) verdict skip "the worker reported a failure after done"; return ;;
    ?*) verdict wait "the worker reported $AFTER_REPORT after done"; return ;;
  esac
  if done_line_flags_boundary "$REPORT_LINE"; then
    verdict skip "the done line flags a credential, token or security-boundary change"
    return
  fi

  json=$(forge gh pr view "$URL" --json state,isDraft,headRefOid,headRefName,baseRefName,mergeable,mergeStateStatus,statusCheckRollup) \
    || { verdict wait "the pull request could not be read"; return; }
  fields=$(printf '%s' "$json" | jq -r '[.state, .headRefOid, .baseRefName, .mergeable, .mergeStateStatus] | map(tostring) | join("\t")' 2>/dev/null) \
    || { verdict wait "the pull request could not be read"; return; }
  IFS=$'\t' read -r state HEAD base mergeable merge_state <<EOF
$fields
EOF
  [ "$state" = OPEN ] || { verdict skip "the pull request is ${state:-unreadable}"; return; }
  draft=$(fm_pr_json_draft_state "$json")
  [ "$draft" = false ] || { verdict skip "the pull request is a draft or its draft state is unreadable"; return; }
  if [ -n "$adopted" ]; then
    # An adopted URL is merged only when the forge shows its head is this
    # task's ship branch, so a URL the task does not own stays supervised.
    head_branch=$(printf '%s' "$json" | jq -r '.headRefName // ""' 2>/dev/null) || head_branch=
    expected_branch=$(meta_value "$meta" branch)
    [ -n "$expected_branch" ] || expected_branch="fm/$id"
    [ "$head_branch" = "$expected_branch" ] || { verdict skip "the done report names a pull request the task does not own"; return; }
  fi
  fm_pr_head_valid "$HEAD" || { verdict wait "the head commit could not be read"; return; }
  checks=$(checks_state "$json") || checks=
  CHECKS_DONE_AT=${checks##*$'\t'}
  checks=${checks%$'\t'*}
  case "$CHECKS_DONE_AT" in ''|*[!0-9]*) CHECKS_DONE_AT=0 ;; esac
  case "$checks" in
    green) ;;
    none) verdict wait "no check has reported yet"; return ;;
    pending) verdict wait "checks are still running"; return ;;
    red:*) verdict skip "checks are not green: ${checks#red:}"; return ;;
    *) verdict wait "the checks could not be read"; return ;;
  esac
  if [ "$mergeable" = CONFLICTING ] || [ "$merge_state" = DIRTY ]; then
    verdict skip "the branch conflicts with $base"
    return
  fi

  record_load "$id"
  if [ "$REC_DIFF_HEAD" = "$HEAD" ] && [ -n "$REC_DIFF_RESULT" ]; then
    DIFF_RESULT=$REC_DIFF_RESULT
  else
    diff=$(forge gh pr diff "$URL") || { verdict wait "the diff could not be read"; return; }
    DIFF_RESULT=$(printf '%s\n' "$diff" | diff_touches_boundary) || DIFF_RESULT=clear
  fi
  DIFF_HEAD=$HEAD
  [ "$DIFF_RESULT" = clear ] || { verdict skip "the diff $DIFF_RESULT"; return; }

  base_enc=$(printf '%s' "$base" | jq -sRr @uri 2>/dev/null) || base_enc=
  [ -n "$base_enc" ] || { verdict wait "the base branch could not be read"; return; }
  behind=$(forge gh api "repos/$FM_PR_OWNER/$FM_PR_REPO/compare/$base_enc...$HEAD" --jq .behind_by) || behind=
  case "$behind" in
    ''|*[!0-9]*) verdict wait "could not compare the head with $base" ;;
    0) verdict green "every check is green" ;;
    *) verdict update "the head is $behind commits behind $base" ;;
  esac
}

attempted_recently() {  # <kind> <now>
  [ "$REC_ATTEMPT_KIND" = "$1" ] && [ "$REC_ATTEMPT_HEAD" = "$HEAD" ] \
    && [ $(($2 - REC_ATTEMPT_AT)) -lt "$RETRY_SECS" ]
}

merge_task() {  # <task-id> <now>
  local id=$1 now=$2 out rc=0
  REC_ATTEMPT_KIND=merge REC_ATTEMPT_HEAD=$HEAD REC_ATTEMPT_AT=$now
  record_save "$id" || true
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-pr-merge.sh" "$id" "$URL" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_line "$id" merge-refused "$(printf '%s\n' "$out" | grep -E '^(error|actionable):|^  - ' | tail -4 | tr '\n' ' ')"
    return
  fi
  log_line "$id" merged "$(printf '%s\n' "$out" | grep '^verified:' | tail -1)"
  # A secondmate home's own merge reports only upward, and no turn of this home
  # performed it, so the home gets the wake its merge poll would have queued.
  if fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null 2>&1; then
    fm_wake_append check "merged-$id-$URL" "check: merge landed: $id $URL" || true
  fi
}

update_task() {  # <task-id> <now>
  local id=$1 now=$2 out rc=0
  REC_ATTEMPT_KIND=update REC_ATTEMPT_HEAD=$HEAD REC_ATTEMPT_AT=$now
  record_save "$id" || true
  out=$(forge gh pr update-branch "$URL") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_line "$id" update-failed "exit $rc $(printf '%s' "$out" | tail -1)"
  else
    log_line "$id" updated "merged the base into the head"
  fi
}

sweep_task() {  # <task-id>
  local id=$1 now prev_verdict prev_reason prev_head
  now=$(date +%s)
  record_load "$id"
  # A skip with a recorded head came from a forge read, so it is read again on
  # the slower cadence.
  if [ "$REC_VERDICT" = skip ] && [ -n "$REC_HEAD" ] \
    && [ $((now - REC_CHECKED_AT)) -lt "$SKIP_RECHECK_SECS" ]; then
    return 0
  fi
  assess "$id"
  record_load "$id"
  prev_verdict=$REC_VERDICT prev_reason=$REC_REASON prev_head=$REC_HEAD
  if [ "$VERDICT" != "$prev_verdict" ] || [ "$HEAD" != "$prev_head" ] || [ "$REASON" != "$prev_reason" ]; then
    REC_SINCE=$now
    log_line "$id" "$VERDICT" "$REASON"
  fi
  REC_VERDICT=$VERDICT REC_HEAD=$HEAD REC_REASON=$REASON REC_CHECKED_AT=$now
  if [ -n "$DIFF_HEAD" ]; then
    REC_DIFF_HEAD=$DIFF_HEAD REC_DIFF_RESULT=$DIFF_RESULT
  fi
  record_save "$id" || true
  case "$VERDICT" in
    green)
      if ! { [ "$CHECKS_DONE_AT" -gt 0 ] && [ $((now - CHECKS_DONE_AT)) -ge "$SETTLE_SECS" ]; }; then
        [ "$prev_verdict" = green ] && [ "$prev_head" = "$HEAD" ] || return 0
        [ $((now - REC_SINCE)) -ge "$SETTLE_SECS" ] || return 0
      fi
      attempted_recently merge "$now" && return 0
      merge_task "$id" "$now"
      ;;
    update)
      attempted_recently update "$now" && return 0
      update_task "$id" "$now"
      ;;
  esac
}

cmd_sweep() {
  local lock meta id
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
  lock="$STATE/.merge-on-green.lock"
  fm_lock_try_acquire "$lock" || exit 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    if ! grep -q '^pr=https://github\.com/' "$meta" 2>/dev/null; then
      # No recorded pr= is not proof of no pull request: the recording turn
      # can be missed while a done or ready line still names it, and assess
      # adopts it once the forge proves it is this task's.
      grep -Eq '(^|[^[:alnum:]])PR( +#?[0-9]+| +https://github\.com/)' "$STATE/$id.status" 2>/dev/null || continue
    fi
    sweep_task "$id"
  done
  for meta in "$STATE"/*.merge-on-green; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.merge-on-green}
    [ -e "$STATE/$id.meta" ] || rm -f -- "$meta"
  done
  fm_lock_release "$lock"
}

cmd_pending() {
  local meta id url
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_pr_task_id_valid "$id" || continue
    [ "$(meta_value "$meta" yolo)" = on ] || continue
    url=$(meta_value "$meta" pr)
    if [ -z "$url" ] && [ "$(meta_value "$meta" kind)" = ship ] \
      && [ "$(meta_value "$meta" mode)" != local-only ] \
      && [ "$(meta_value "$meta" forge)" != external ]; then
      # A yolo ship with no recorded pull request can still open one: a done
      # or ready line naming it is adopted by the sweep, and a task with no
      # report at all keeps the watch alive until its report lands.
      read_status_report "$STATE/$id.status"
      if [ -n "$REPORT_LINE" ]; then
        url=$(latest_status_pr_url "$STATE/$id.status" "$meta") || url=
      else
        return 0
      fi
    fi
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" 2>/dev/null || continue
    [ "$FM_PR_PROVIDER" = github ] || continue
    fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" && continue
    return 0
  done
  return 1
}

cmd_assess() {
  [ "$#" -eq 1 ] || usage
  fm_pr_task_id_valid "$1" || usage
  assess "$1"
  printf '%s\t%s\t%s\t%s\t%s\n' "$VERDICT" "$1" "$URL" "$HEAD" "$REASON"
}

case "${1-}" in
  sweep) shift; [ "$#" -eq 0 ] || usage; cmd_sweep ;;
  assess) shift; cmd_assess "$@" ;;
  pending) shift; [ "$#" -eq 0 ] || usage; cmd_pending ;;
  *) usage ;;
esac
