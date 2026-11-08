#!/usr/bin/env bash
# Wake this home once for each new actionable condition on a PR it owns.
#
# Usage:
#   fm-pr-health.sh poll
#   fm-pr-health.sh arm
#
# Opt-in: with config/pr-health-monitor absent, poll exits silently without
# reading or writing anything, and arm refuses (docs/configuration.md).
#
# Ownership is fm-contributions.sh owned: each task's recorded pr= and the
# durable records in data/<task>/contributions.json. poll adds one source and
# records each new URL through fm-contributions.sh enroll, so ownership
# outlives the worker: the open PR whose head is a live task copy's current
# branch (fm_pr_number_from_branch). Drafts and adopted branches count. A PR
# URL that merely appears in a status line is not owned, and a record the
# captain retired is never re-enrolled, so retirement ends the monitor's
# ownership even while the copy stays on that branch. A secondmate row's
# copy is never looked up, because its PR belongs to the secondmate's own home.
# No PR outside that set is ever read, so another home's PR is dropped without
# a forge read or a wake.
#
# Per owned open PR, poll reads the REST single-PR endpoint, which GitHub
# documents as starting the mergeability computation, and one GraphQL read for
# the head's complete, paginated check rollup with each context's isRequired.
# It prints one line per new condition, all in one check output, so one wake:
#   - conflict: REST mergeable is false. Null (UNKNOWN) is neither clean nor
#     conflicting and never clears an already reported condition.
#   - failing checks: a required context failed (a check run concluded other
#     than SUCCESS, NEUTRAL or SKIPPED, or a status is FAILURE or ERROR). When
#     no reported context is required, any failing reported context counts,
#     matching fm-pr-state.sh for unprotected stacked bases. Each name is judged
#     by its newest run (latest_checks in fm-contributions.jq), because GitHub
#     keeps a cancelled run beside the passing rerun that replaced it.
# A conflict wakes once per latest commit, even if the base moves or the
# condition clears and returns. A failing check wakes once per latest commit
# and check name: a check that newly fails at an already reported commit wakes
# once more, a name already reported there never repeats, and the line names
# only the newly failing checks. The two conditions have independent histories.
# A merged or closed PR is final and never read again. A failed or timed-out
# read, or a latest commit that differs between the two reads, leaves the PR's
# fingerprint untouched and prints nothing; fm-contributions.sh reports forge
# outages for the same URLs. Forge reads stop FM_CHECK_TIMEOUT (default 30)
# minus 5 seconds after the pass starts, and each read is capped at 5 seconds.
# Branch discovery and owned-PR reads each fan out in one concurrent wave;
# there is no rotating PR backlog or serial network wait per PR.
# Fingerprints are fm-pr-health.v1 in state/pr-health.json, written by rename
# under state/.pr-health.lock; a pass that finds the lock held exits silently.
# A line is printed before its fingerprint is saved, so a pass killed between
# the two repeats one wake rather than losing it. An unreadable fingerprint
# file is reported once and replaced.
#
# arm writes state/pr-health.check.sh, binds it through fm-check-register.sh,
# and arms the contribution observer that reads the PRs poll enrolls.
# The monitor never comments on, edits, or fixes a PR.
# GraphQL, jq and bash -c programs below are literal, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-pr-health: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

PR_URL_RE='https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*'
HEALTH="$STATE/pr-health.json"
LOCK_HELD=0
TMP=
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.pr-health.lock" || true
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

flag_on() { [ -e "$CONFIG/pr-health-monitor" ]; }

meta_value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

live_tasks() { # id <TAB> worktree, for each task that is not a secondmate
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    [ "$(meta_value "$meta" kind)" != secondmate ] || continue
    printf '%s\t%s\n' "$id" "$(meta_value "$meta" worktree)"
  done
}

owned_json() { # -> $TMP/owned.json
  "$SCRIPT_DIR/fm-contributions.sh" owned > "$TMP/owned.json" 2> "$TMP/owned.err"
}

save_health() { # json-file
  local staged
  staged=$(umask 077; mktemp "$STATE/.pr-health.XXXXXX")
  cp "$1" "$staged"
  fm_pr_regular_destination_on_device_or_absent "$HEALTH" "$(fm_pr_file_device "$STATE")" \
    || { rm -f -- "$staged"; fail 'unsafe fingerprint destination'; }
  mv -f -- "$staged" "$HEALTH"
}

gh_read() { # deadline args... : one bounded forge read
  local left=$(($1 - $(date +%s)))
  shift
  [ "$left" -gt 0 ] || return 124
  [ "$left" -le 5 ] || left=5
  fm_run_timed "$left" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

# The rollup names the check but not its step, so the step comes from the
# check's newest failed Actions job. Anything unreadable keeps the check-only
# wake, so this prints a detail fragment or nothing and never fails the pass.
resolve_failing_step() { # owner repo head name deadline -> detail or nothing
  local owner=$1 repo=$2 head=$3 name=$4 deadline=$5
  local runs ids run_id jobs job attempt steps count detail
  local run_ids=()
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$head" ] && [ -n "$name" ] || return 0
  runs=$(gh_read "$deadline" api "repos/$owner/$repo/actions/runs" -f "head_sha=$head" -f per_page=5 2>/dev/null) || return 0
  ids=$(printf '%s' "$runs" | jq -r '.workflow_runs // [] | .[0:2] | map(.id | tostring) | join(" ")' 2>/dev/null) || return 0
  [ -n "$ids" ] || return 0
  read -r -a run_ids <<< "$ids" || return 0
  for run_id in ${run_ids[@]+"${run_ids[@]}"}; do
    case "$run_id" in ''|*[!0-9]*) continue ;; esac
    jobs=$(gh_read "$deadline" api "repos/$owner/$repo/actions/runs/$run_id/jobs" -f filter=latest -f per_page=30 2>/dev/null) || continue
    job=$(printf '%s' "$jobs" | jq --arg name "$name" '
      [.jobs[]? | select(.name == $name and .status == "completed" and .conclusion == "failure")]
      | max_by(.run_attempt // 0) // empty' 2>/dev/null) || continue
    [ -n "$job" ] || continue
    attempt=$(printf '%s' "$job" | jq -r '.run_attempt // 0' 2>/dev/null) || continue
    steps=$(printf '%s' "$job" | jq -r '[.steps[]? | select(.conclusion == "failure") | .name][:3] | join(", ")' 2>/dev/null) || continue
    count=$(printf '%s' "$job" | jq -r '[.steps[]? | select(.conclusion == "failure")] | length' 2>/dev/null) || continue
    detail=""
    case "$attempt" in ''|0) ;; *) detail="attempt $attempt" ;; esac
    if [ -n "$steps" ]; then detail=${detail:+$detail, }"failing step: $steps"; fi
    [ "$count" -gt 3 ] 2>/dev/null && detail="$detail and $((count - 3)) more"
    [ -n "$detail" ] || continue
    printf '%s' "$detail"
    return 0
  done
  return 0
}

PR_QUERY='query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){
headRefOid
statusCheckRollup{contexts(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{__typename
... on CheckRun{name status conclusion startedAt isRequired(pullRequestNumber:$number)}
... on StatusContext{context state createdAt isRequired(pullRequestNumber:$number)}}}}}}}'

# The fingerprint step: previous fingerprint plus one REST and one GraphQL
# read -> {fp, conflict, failing, required, head}. A null result means the
# reads disagree and nothing moves. checks[] entries carry the head, the check
# name, and the newest observed run start; a new start wakes again, the same
# start never repeats, and an entry without a start is adopted silently.
STEP='
  $rest[0] as $r | ($gql[0].data.repository.pullRequest // null) as $g
  | ($prev[0] // {}) as $p
  | if $r.merged_at != null or $r.state == "closed" then {fp:($p + {final:true}),conflict:false,failing:[],required:false,head:null}
    elif $g == null or $g.headRefOid != $r.head.sha then null
    else
      $r.head.sha as $head
      | ($g.statusCheckRollup // null) as $roll
      | [$roll.contexts.nodes[]? | if .__typename == "CheckRun"
          then {name, started_at:.startedAt, required:(.isRequired == true),
                failing:(.status == "COMPLETED" and .conclusion != null and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not))}
          else {name:.context, started_at:.createdAt, required:(.isRequired == true),
                failing:(.state | IN("FAILURE","ERROR"))} end]
        | latest_checks as $ctx
      | any($ctx[]; .required) as $has_required
      | [$ctx[] | select(.failing and (.required or ($has_required | not)))] as $bad
      | ([$bad[].name]) as $bad_names
      | ($p.conflicts // []) as $conflicts | ($p.checks // []) as $checks
      | ($r.mergeable == false and ($conflicts | index($head) | not)) as $conflict_new
      | ([$checks[] | select(.head == $head)] | map({(.name): (.started_at // null)}) | add // {}) as $seen
      | [$bad[] | select(.name as $n | .started_at as $at
          | ($seen | has($n) | not) or ($seen[$n] != null and $at != null and $seen[$n] != $at))
        | {name, started_at}] as $new_failing
      | {fp:{conflicts:($conflicts + if $conflict_new then [$head] else [] end),
             checks:([$checks[] | select(.head != $head or (.name as $n | $bad_names | index($n) | not))]
                     + [$bad[] | {head:$head, name, started_at}])},
         conflict:$conflict_new, failing:$new_failing, required:$has_required, head:$head}
    end'

read_pr() { # url deadline output-directory -> rest.json gql.json
  local url=$1 deadline=$2 out=$3 number owner repo rest_rc=0 gql_rc=0
  fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || return 1
  number=$FM_PR_NUMBER
  owner=${FM_PR_PATH%%/*}; repo=${FM_PR_PATH#*/}
  gh_read "$deadline" api "repos/$owner/$repo/pulls/$number" > "$out/rest.json" 2>/dev/null &
  local rest_pid=$!
  gh_read "$deadline" api graphql --paginate --slurp -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    -f "query=$PR_QUERY" > "$out/pages.json" 2>/dev/null &
  local gql_pid=$!
  wait "$rest_pid" || rest_rc=$?
  wait "$gql_pid" || gql_rc=$?
  [ "$rest_rc" -eq 0 ] && [ "$gql_rc" -eq 0 ] || return 1
  jq -e '
    select(type == "array" and length > 0)
    | select(all(.[]; .errors == null and .data.repository.pullRequest != null))
    | map(.data.repository.pullRequest) as $pages
    | select(all($pages[]; .headRefOid == $pages[0].headRefOid))
    | select(($pages[-1].statusCheckRollup.contexts.pageInfo.hasNextPage // false) == false)
    | {data:{repository:{pullRequest:($pages[0] + {statusCheckRollup:{contexts:{nodes:
        [$pages[] | .statusCheckRollup.contexts.nodes[]?]}}})}}}' "$out/pages.json" > "$out/gql.json"
}

lookup_branch_pr() { # worktree branch deadline -> url
  local wt=$1 branch=$2 deadline=$3 left number url remote
  remote=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    git@github.com:*) remote="https://github.com/${remote#git@github.com:}" ;;
    ssh://git@github.com/*) remote="https://github.com/${remote#ssh://git@github.com/}" ;;
  esac
  fm_pr_url_parse "${remote%.git}/pull/1" && [ "$FM_PR_PROVIDER" = github ] || return 1
  left=$((deadline - $(date +%s)))
  [ "$left" -gt 0 ] || return 1
  [ "$left" -le 5 ] || left=5
  number=$(fm_run_timed "$left" bash -c '. "$1/fm-pr-lib.sh"; fm_pr_number_from_branch "$2" "$3" open' \
    _ "$SCRIPT_DIR" "$wt" "$branch") || return 1
  url=$(cd "$wt" && gh_read "$deadline" pr view "$number" --json url -q .url 2>/dev/null) || return 1
  printf '%s\n' "$url" | grep -Ex "$PR_URL_RE"
}

enroll_new() { # deadline : enroll recorded and branch PRs not yet durably owned
  local deadline=$1 id wt url branch default cached pid
  local pids=()
  : > "$TMP/enroll.tsv"
  jq -r --slurpfile health "$TMP/health.json" '
    .[] | select($health[0].prs[.url] == null) | .url as $url | .tasks[] | [., $url] | @tsv' \
    "$TMP/owned.json" >> "$TMP/enroll.tsv"
  mkdir "$TMP/branches"
  while IFS=$'\t' read -r id wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    default=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [ "$branch" != "${default#origin/}" ] || continue
    [ "$branch" != "$(meta_value "$STATE/$id.meta" base_branch)" ] || continue
    cached=$(jq -r --arg id "$id" --arg branch "$branch" --slurpfile owned "$TMP/owned.json" '
      .prs as $prs | .branches[$id] | select(.branch == $branch) | .url
      | select(($prs[.].final // false) | not)
      | select(. as $url | any($owned[0][]; .url == $url and .final) | not)' "$TMP/health.json")
    if [ -n "$cached" ]; then
      printf '%s\t%s\n' "$id" "$cached" >> "$TMP/enroll.tsv"
      continue
    fi
    (
      url=$(lookup_branch_pr "$wt" "$branch" "$deadline") || exit 0
      printf '%s\t%s\t%s\n' "$id" "$url" "$branch" > "$TMP/branches/$id"
    ) &
    pids+=("$!")
  done < <(live_tasks)
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || true; done
  for cached in "$TMP/branches/"*; do
    [ -f "$cached" ] || continue
    IFS=$'\t' read -r id url branch < "$cached"
    jq --arg id "$id" --arg branch "$branch" --arg url "$url" '.branches[$id] = {branch:$branch,url:$url}' \
      "$TMP/health.json" > "$TMP/next.json" && mv "$TMP/next.json" "$TMP/health.json"
    printf '%s\t%s\n' "$id" "$url" >> "$TMP/enroll.tsv"
  done
  while IFS=$'\t' read -r id url; do
    if jq -e --arg url "$url" '.prs[$url] != null' "$TMP/health.json" >/dev/null \
      && jq -e --arg id "$id" --arg url "$url" 'any(.[]; .url == $url and (.tasks | index($id)) != null)' "$TMP/owned.json" >/dev/null; then
      continue
    fi
    "$SCRIPT_DIR/fm-contributions.sh" enroll "$id" "$url" >/dev/null 2>&1 || continue
    jq --arg id "$id" --arg url "$url" '
      if any(.[]; .url == $url) then map(if .url == $url then .tasks = (.tasks + [$id] | unique) else . end)
      else . + [{url:$url,tasks:[$id],final:false}] end' "$TMP/owned.json" > "$TMP/next.json" \
      && mv "$TMP/next.json" "$TMP/owned.json"
  done < <(sort -u "$TMP/enroll.tsv")
}

poll() {
  local deadline timeout url step pid index=0 read_dir owners head_full short required_word
  local detail_owner detail_repo display shown extra name entry detail
  local pids=()
  flag_on || exit 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  deadline=$(( $(date +%s) + (timeout > 10 ? timeout - 5 : 5) ))
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.pr-health.lock" || exit 0
  LOCK_HELD=1
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-health.XXXXXX")
  if [ -e "$HEALTH" ] && ! jq -e '.schema == "fm-pr-health.v1" and (.prs | type == "object") and (.branches | type == "object")
    and all(.prs[]; ((.conflicts // []) | type == "array") and ((.checks // []) | type == "array" and all(.[]; type == "object")))' \
    "$HEALTH" > /dev/null 2>&1; then
    printf 'pr-health: unreadable fingerprint record replaced; conditions already reported may wake once more\n'
    rm -f -- "$HEALTH"
  fi
  if [ -e "$HEALTH" ]; then cp "$HEALTH" "$TMP/health.json"
  else printf '{"schema":"fm-pr-health.v1","prs":{},"branches":{},"ownership_error":false}\n' > "$TMP/health.json"; fi
  if ! owned_json; then
    if ! jq -e '.ownership_error == true' "$TMP/health.json" >/dev/null; then
      printf 'pr-health: owned PRs could not be read: %s\n' "$(head -n 1 "$TMP/owned.err" | cut -c1-160)"
      jq '.ownership_error = true' "$TMP/health.json" > "$TMP/next.json" && save_health "$TMP/next.json"
    fi
    exit 0
  fi
  enroll_new "$deadline"
  # Keep fingerprints and branch lookups only for what this home still owns.
  jq --slurpfile owned "$TMP/owned.json" --arg live "$(live_tasks | cut -f1 | paste -sd ' ' -)" '
    ($owned[0] | map(.url)) as $urls | ($live | split(" ")) as $ids
    | .ownership_error = false
    | .prs |= with_entries(select(.key | IN($urls[])))
    | .branches |= with_entries(select(.key | IN($ids[])))' "$TMP/health.json" > "$TMP/next.json"
  save_health "$TMP/next.json"
  cp "$TMP/next.json" "$TMP/health.json"
  jq -r --slurpfile health "$TMP/health.json" '
    .[] | select(.final | not) | select(($health[0].prs[.url].final // false) | not) | .url' "$TMP/owned.json" > "$TMP/urls"
  while IFS= read -r url; do
    index=$((index + 1))
    read_dir="$TMP/read-$index"
    mkdir "$read_dir"
    (
      read_pr "$url" "$deadline" "$read_dir" && : > "$read_dir/ok"
    ) &
    pids+=("$!")
  done < "$TMP/urls"
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || true; done
  index=0
  while IFS= read -r url; do
    index=$((index + 1))
    read_dir="$TMP/read-$index"
    [ -f "$read_dir/ok" ] || continue
    jq -L "$SCRIPT_DIR" -n --arg url "$url" --slurpfile rest "$read_dir/rest.json" --slurpfile gql "$read_dir/gql.json" \
      --slurpfile prev <(jq --arg url "$url" '.prs[$url] // {}' "$TMP/health.json") \
      "include \"fm-contributions\"; $STEP" > "$TMP/step.json" 2>/dev/null || continue
    step=$(cat "$TMP/step.json")
    [ "$step" != null ] || continue
    owners=$(jq -r --arg url "$url" '[.[] | select(.url == $url) | .tasks[]] | unique | join(", ")' "$TMP/owned.json")
    head_full=$(printf '%s' "$step" | jq -r '.head // ""')
    short=${head_full:0:7}
    if [ "$(printf '%s' "$step" | jq -r '.conflict')" = true ]; then
      printf 'pr-health: %s conflicts with its base at latest commit %s (task %s)\n' "$url" "$short" "$owners"
    fi
    if [ "$(printf '%s' "$step" | jq -r '.failing | length')" -gt 0 ]; then
      if [ "$(printf '%s' "$step" | jq -r '.required')" = true ]; then required_word='required '; else required_word=''; fi
      detail_owner=
      if fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ]; then
        detail_owner=$FM_PR_OWNER
        detail_repo=${FM_PR_PATH#*/}
      fi
      display=; shown=0; extra=0
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$shown" -lt 3 ]; then
          entry=$name
          if [ -n "$detail_owner" ]; then
            detail=$(resolve_failing_step "$detail_owner" "$detail_repo" "$head_full" "$name" "$deadline")
            if [ -n "$detail" ]; then entry="$name ($detail)"; fi
          fi
          display=${display:+$display, }$entry
          shown=$((shown + 1))
        else
          extra=$((extra + 1))
        fi
      done < <(printf '%s' "$step" | jq -r '.failing[].name')
      if [ "$extra" -gt 0 ]; then display="$display and $extra more"; fi
      printf 'pr-health: %s has failing %schecks at latest commit %s: %s (task %s)\n' \
        "$url" "$required_word" "$short" "$display" "$owners"
    fi
    jq --arg url "$url" --slurpfile step "$TMP/step.json" '.prs[$url] = $step[0].fp' "$TMP/health.json" > "$TMP/next.json"
    if ! cmp -s "$TMP/next.json" "$TMP/health.json"; then
      save_health "$TMP/next.json"
      cp "$TMP/next.json" "$TMP/health.json"
    fi
  done < "$TMP/urls"
}

arm() {
  local staged
  flag_on || fail 'config/pr-health-monitor is absent; the PR health monitor stays off'
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  fm_pr_regular_destination_on_device_or_absent "$STATE/pr-health.check.sh" "$(fm_pr_file_device "$STATE")" \
    || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.pr-health-check.XXXXXX")
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-health.sh") poll" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/pr-health.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" pr-health
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null || fail 'the contribution observer could not be armed'
}

case "${1:-}" in
  poll) [ "$#" -eq 1 ] || fail 'poll takes no arguments'; poll ;;
  arm) [ "$#" -eq 1 ] || fail 'arm takes no arguments'; arm ;;
  *) usage >&2; exit 2 ;;
esac
