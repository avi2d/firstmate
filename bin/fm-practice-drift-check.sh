#!/usr/bin/env bash
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/practice-drift.json"
RECORD="$STATE/.practice-drift"
CHECK_ID=practice-drift
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
TASKS_BIN="$SCRIPT_DIR/fm-tasks-axi.sh"
RECORD_SCHEMA=fm-practice-drift-v1
MAX_LINE=1000
DAY_SECS=86400
ISSUE_OVERDUE_SECS=$((7 * DAY_SECS))
RUN_HISTORY=10
JUDGE_RESERVE_SECS=3
BOT_LOGIN='github-actions[bot]'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-practice-drift-check.sh [check]   report practice findings that are new or cleared since the last sweep (silent when none changed)
  fm-practice-drift-check.sh arm       write and register state/practice-drift.check.sh
  fm-practice-drift-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-practice-drift-check.sh --help    print this help

Repositories: every clone directly under this home's projects/ whose origin is on GitHub.
The kit, named in config/practice-drift.json, applies to a clone whose package.json
depends on the kit package or is the kit itself. Every repository is read for its open
issues filed by github-actions[bot] carrying label night-run, daily-tests, or daily-ci;
a repository the kit applies to is also shallow
cloned at its default branch into a temporary directory and read for the rest.

Practice keys, recorded as <repository>:<key>:
  kit-pin          the kit pin is older than the kit's newest GitHub release
  retired-workflow a workflow under .github/workflows is the retired night-run workflow or runs checks-lint --night
  author           package.json names no author and no contributors
  ci-wiring        checks-ci-wiring from the newest kit release fails, with its summary
  merge-methods    the repository allows merge commits or rebase merges
  runs-on          the repository is private and sets no CI_RUNS_ON repository or organization variable
  schedule-<name>  the last completed scheduled run of workflow <name> on the default branch did not succeed
  release-pr-<n>   pull request <n> titled "chore: release" by github-actions[bot] open 7 days or longer
  issue-<n>        issue <n> by github-actions[bot] carrying label night-run, daily-tests, or daily-ci
                   is open; it prints when first seen and once more when it is 7 days old
                   and no row in this home's backlog names its URL

A sweep runs once a day, at the first check after the configured UTC hour, and prints one
"practice drift: <repository>: ..." line for each repository with a new, changed, cleared, or
unreadable finding. A read that fails is printed as unreadable on every sweep and keeps that
practice's recorded findings rather than clearing them. It never writes to GitHub, runs no
project tests, and never touches a clone under projects/.

Environment:
  FM_PRACTICE_DRIFT_HOUR         UTC hour of the daily sweep, 0-23 (default 15)
  FM_PRACTICE_DRIFT_BUDGET_SECS  bound on one sweep, 1-120 (default 25), cut to fit FM_CHECK_TIMEOUT

See docs/configuration.md "Practice drift" for the configuration file and what a report means.
EOF
}

die_usage() {
  printf 'fm-practice-drift-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

HOUR=${FM_PRACTICE_DRIFT_HOUR:-15}
case "$HOUR" in
  ''|*[!0-9]*) die_usage 'FM_PRACTICE_DRIFT_HOUR must be a whole number from 0 to 23' ;;
esac
[ "$((10#$HOUR))" -le 23 ] || die_usage 'FM_PRACTICE_DRIFT_HOUR must be a whole number from 0 to 23'
HOUR=$((10#$HOUR))

BUDGET_SECS=${FM_PRACTICE_DRIFT_BUDGET_SECS:-25}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0) die_usage 'FM_PRACTICE_DRIFT_BUDGET_SECS must be a whole number from 1 to 120' ;;
esac
[ "$BUDGET_SECS" -le 120 ] || die_usage 'FM_PRACTICE_DRIFT_BUDGET_SECS must be a whole number from 1 to 120'

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# The watcher kills a check at FM_CHECK_TIMEOUT, and a killed sweep prints nothing and records nothing.
BUDGET_MAX=$((CHECK_TIMEOUT - JUDGE_RESERVE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
[ "$BUDGET_SECS" -le "$BUDGET_MAX" ] || BUDGET_SECS=$BUDGET_MAX

now_epoch() {
  case "${FM_PRACTICE_DRIFT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PRACTICE_DRIFT_NOW" ;;
  esac
}

TMP=
DEADLINE=0
KIT_PACKAGE=
KIT_REPO=
BACKLOG_STATE=
LABELS=()
SLUGS=()
KIT_APPLIES=()

clean_field() {
  local text=$1
  printf '%s' "$text" | tr '\t\r\n' '   '
}

plural() {
  local count=$1 noun=$2
  if [ "$count" -eq 1 ]; then
    printf '%s %s\n' "$count" "$noun"
  else
    printf '%s %ss\n' "$count" "$noun"
  fi
}

bound() {
  local left
  left=$((DEADLINE - $(date +%s)))
  [ "$left" -ge 1 ] || left=1
  printf '%s\n' "$left"
}

out_of_time() {
  [ "$(date +%s)" -ge "$DEADLINE" ]
}

config_problem() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to read %s\n' "$CONFIG"
    return 0
  fi
  [ -f "$CONFIG" ] || { printf 'no practice drift configuration at %s\n' "$CONFIG"; return 0; }
  jq -r '
    if type != "object" or (.kit | type) != "object" then "the top level must be an object with a kit object"
    elif (.kit.package | type) != "string" or (.kit.package | test("^(@[a-z0-9._-]+/)?[a-z0-9._-]+$") | not) then "kit.package must be an npm package name"
    elif (.kit.repo | type) != "string" or (.kit.repo | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) then "kit.repo must be a GitHub owner/repo slug"
    else empty
    end
  ' "$CONFIG" 2>/dev/null || printf '%s is not valid JSON\n' "$CONFIG"
}

config_read() {
  KIT_PACKAGE=$(jq -r '.kit.package' "$CONFIG")
  KIT_REPO=$(jq -r '.kit.repo' "$CONFIG")
}

is_clone_root() {
  local dir=$1 top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] && [ "$top" -ef "$dir" ]
}

github_slug() {
  local dir=$1 url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  case "$url" in
    https://github.com/*) url=${url#https://github.com/} ;;
    git@github.com:*) url=${url#git@github.com:} ;;
    ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  printf '%s' "$url" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || return 1
  printf '%s\n' "$url"
}

manifest_uses_kit() {
  jq -e --arg p "$KIT_PACKAGE" '
    .name == $p
    or ((.dependencies // {}) | has($p))
    or ((.devDependencies // {}) | has($p))
  ' >/dev/null 2>&1
}

local_kit_applies() {
  local dir=$1 manifest
  manifest=$(git -C "$dir" show refs/remotes/origin/HEAD:package.json 2>/dev/null) \
    || manifest=$(git -C "$dir" show HEAD:package.json 2>/dev/null) \
    || return 1
  printf '%s' "$manifest" | manifest_uses_kit
}

collect_repos() {
  local dir label slug kit
  [ -d "$PROJECTS" ] || return 0
  for dir in "$PROJECTS"/*; do
    [ -d "$dir" ] || continue
    is_clone_root "$dir" || continue
    label=$(basename "$dir")
    case "$label" in *:*) continue ;; esac
    kit=0
    local_kit_applies "$dir" && kit=1
    slug=$(github_slug "$dir") || slug=
    if [ -z "$slug" ] && [ "$kit" -eq 0 ]; then
      continue
    fi
    LABELS+=("$label")
    SLUGS+=("$slug")
    KIT_APPLIES+=("$kit")
  done
}

# Leaves exactly one of <out>.json, the filter's result, or <out>.err, one of absent, timeout, or failed.
gh_read() {
  local out=$1 path=$2 filter=$3 raw status body
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'failed\n' > "$out.err"
    return 0
  fi
  if out_of_time; then
    printf 'timeout\n' > "$out.err"
    return 0
  fi
  raw=$(fm_run_timed "$(bound)" gh-axi api "$path" --full --jq "($filter) | tojson | @base64" 2>&1)
  status=$?
  if fm_timed_out "$status"; then
    printf 'timeout\n' > "$out.err"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    case "$raw" in
      *NOT_FOUND*|*'HTTP 404'*|*'Not Found'*) printf 'absent\n' > "$out.err" ;;
      *) printf 'failed\n' > "$out.err" ;;
    esac
    return 0
  fi
  body=$(printf '%s\n' "$raw" | awk '$1 == "body:" { print $2; exit }' | tr -d '"')
  if [ -n "$body" ] && printf '%s' "$body" | base64 -d > "$out.json" 2>/dev/null \
    && jq -e . "$out.json" >/dev/null 2>&1; then
    return 0
  fi
  rm -f -- "$out.json"
  printf 'failed\n' > "$out.err"
}

read_error() {
  local out=$1
  cat "$out.err" 2>/dev/null
}

why_unread() {
  local err=$1
  case "$err" in
    timeout) printf 'time ran out\n' ;;
    absent) printf 'GitHub answered not found\n' ;;
    *) printf 'the GitHub read failed\n' ;;
  esac
}

scheduled_workflows() {
  local tree=$1 file
  for file in "$tree"/.github/workflows/*.yml "$tree"/.github/workflows/*.yaml; do
    [ -f "$file" ] || continue
    grep -qE '^[[:space:]]*schedule:' "$file" 2>/dev/null || continue
    basename "$file"
  done
}

clone_main() {
  local out=$1 slug=$2 status
  if out_of_time; then
    printf 'timeout\n' > "$out/clone.err"
    return 1
  fi
  fm_run_timed "$(bound)" git clone --quiet --depth 1 \
    "https://github.com/$slug.git" "$out/tree" >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if fm_timed_out "$status"; then
    printf 'timeout\n' > "$out/clone.err"
  else
    printf 'failed\n' > "$out/clone.err"
  fi
  return 1
}

read_schedules() {
  local out=$1 slug=$2 branch file
  branch=$(git -C "$out/tree" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=main
  printf '%s\n' "$branch" > "$out/branch"
  mkdir -p "$out/schedule"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    gh_read "$out/schedule/$file" \
      "repos/$slug/actions/workflows/$file/runs?event=schedule&branch=$branch&status=completed&per_page=$RUN_HISTORY" \
      '[.workflow_runs[] | {conclusion, day: .created_at[0:10]}]' &
  done < <(scheduled_workflows "$out/tree")
  wait
}

read_issues() {
  local out=$1 slug=$2 number comments
  gh_read "$out/issues" "repos/$slug/issues?state=open&creator=github-actions%5Bbot%5D&per_page=100" \
    "[.[] | select(.pull_request == null and .user.login == \"$BOT_LOGIN\" and ([(.labels // [])[].name] | any(. == \"night-run\" or . == \"daily-tests\" or . == \"daily-ci\"))) | {number, url: .html_url, created: (.created_at | fromdateiso8601), comments}]"
  [ -f "$out/issues.json" ] || return 0
  mkdir -p "$out/comments"
  while IFS=$'\t' read -r number comments; do
    [ -n "$number" ] || continue
    gh_read "$out/comments/$number" "repos/$slug/issues/$number/comments?per_page=1&page=$comments" \
      '.[0] // null | if . == null then null else {day: .created_at[0:10], run: ([(.body // "") | match("actions/runs/([0-9]+)") | .captures[0].string] | first // null)} end' &
  done < <(jq -r '.[] | select(.comments > 0) | [.number, .comments] | @tsv' "$out/issues.json")
  wait
}

read_repo() {
  local out=$1 slug=$2 kit=$3
  mkdir -p "$out"
  [ -n "$slug" ] || return 0
  read_issues "$out" "$slug" &
  if [ "$kit" -eq 1 ]; then
    gh_read "$out/repo" "repos/$slug" \
      '{private, merge: .allow_merge_commit, rebase: .allow_rebase_merge}' &
    gh_read "$out/runs-on" "repos/$slug/actions/variables/CI_RUNS_ON" '.value' &
    gh_read "$out/org-vars" "repos/$slug/actions/organization-variables" '[.variables[]?.name]' &
    gh_read "$out/pulls" "repos/$slug/pulls?state=open&per_page=100" \
      "[.[] | select((.title | startswith(\"chore: release\")) and .user.login == \"$BOT_LOGIN\") | {number, url: .html_url, day: .created_at[0:10], created: (.created_at | fromdateiso8601)}]" &
    if clone_main "$out" "$slug"; then
      read_schedules "$out" "$slug"
    fi
  fi
  wait
}

read_kit() {
  local out=$1 tag
  mkdir -p "$out"
  gh_read "$out/release" "repos/$KIT_REPO/releases/latest" '.tag_name'
  [ -f "$out/release.json" ] || return 0
  tag=$(jq -r '. // empty' "$out/release.json")
  tag=${tag#v}
  printf '%s\n' "$tag" > "$out/newest"
  if ! command -v bun >/dev/null 2>&1; then
    printf 'bun is required to install the kit\n' > "$out/install.err"
    return 0
  fi
  mkdir -p "$out/install"
  printf '{"name":"fm-practice-drift-kit","private":true}\n' > "$out/install/package.json"
  if fm_run_timed "$(bound)" bun add --cwd "$out/install" --ignore-scripts "$KIT_PACKAGE@$tag" >/dev/null 2>&1 \
    && [ -x "$out/install/node_modules/.bin/checks-ci-wiring" ]; then
    printf '%s\n' "$out/install/node_modules/.bin/checks-ci-wiring" > "$out/ci-wiring"
  else
    printf 'installing kit %s failed\n' "$tag" > "$out/install.err"
  fi
}

run_ci_wiring() {
  local out=$1 bin=$2 status
  [ -d "$out/tree" ] || return 0
  ( cd "$out/tree" && fm_run_timed "$(bound)" "$bin" ) > "$out/ci-wiring.out" 2>&1
  status=$?
  printf '%s\n' "$status" > "$out/ci-wiring.rc"
}

# A prerelease or build suffix does not change a version's order here.
version_key() {
  local version=$1
  printf '%s' "$version" | awk -F. '{ printf "%08d%08d%08d\n", $1 + 0, $2 + 0, $3 + 0 }'
}

version_lt() {
  local left=$1 right=$2
  [ "$(version_key "$left")" \< "$(version_key "$right")" ]
}

pin_version() {
  local spec=$1
  spec=${spec#"${spec%%[!^~>=v ]*}"}
  printf '%s' "$spec" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || return 1
  printf '%s\n' "$spec"
}

finding() {
  local label=$1 key=$2 value=$3 text=$4
  printf '%s:%s\t%s\t%s\n' "$label" "$key" "$(clean_field "$value")" "$(clean_field "$text")" >> "$TMP/current"
}

unread() {
  local label=$1 prefix=$2 text=$3 kind
  case "$prefix" in
    ''|issue-|release-pr-|schedule-) kind=prefix ;;
    *) kind=exact ;;
  esac
  printf '%s:%s\t%s\n' "$label" "$prefix" "$kind" >> "$TMP/protected"
  [ -z "$text" ] || printf '%s\t%s\n' "$label" "$(clean_field "$text")" >> "$TMP/unread"
}

record_value() {
  local key=$1
  awk -F '\t' -v k="$key" '$1 == k { print $2; exit }' "$TMP/record"
}

backlog_load() {
  [ -z "$BACKLOG_STATE" ] || return 0
  if FM_HOME="$FM_HOME" fm_run_timed "$(bound)" "$TASKS_BIN" list --fields body,links --limit 100000 \
    > "$TMP/backlog" 2>/dev/null; then
    BACKLOG_STATE=loaded
  else
    BACKLOG_STATE=unread
  fi
}

backlog_names() {
  local url=$1 id
  grep -qE "$url([^0-9]|\$)" "$TMP/backlog" 2>/dev/null && return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    FM_HOME="$FM_HOME" fm_run_timed "$(bound)" "$TASKS_BIN" show "$id" --full 2>/dev/null \
      | grep -qE "$url([^0-9]|\$)" && return 0
  done < <(grep -oE 'use show [^ ]+ --full' "$TMP/backlog" | awk '{ print $2 }' | sort -u)
  return 1
}

judge_issues() {
  local label=$1 out=$2 err number url created comments age days prev value text last
  err=$(read_error "$out/issues")
  if [ -n "$err" ]; then
    unread "$label" issue- "issues unreadable: $(why_unread "$err")"
    return 0
  fi
  [ -f "$out/issues.json" ] || return 0
  while IFS=$'\t' read -r number url created comments; do
    [ -n "$number" ] || continue
    age=$((NOW - created))
    [ "$age" -ge 0 ] || age=0
    days=$((age / DAY_SECS))
    prev=$(record_value "$label:issue-$number")
    value=seen
    if [ "$prev" = overdue ]; then
      value=overdue
    elif [ "$age" -ge "$ISSUE_OVERDUE_SECS" ]; then
      backlog_load
      if [ "$BACKLOG_STATE" != loaded ]; then
        unread "$label" "issue-$number" "issue-$number: backlog unreadable"
        [ -z "$prev" ] || continue
      elif ! backlog_names "$url"; then
        value=overdue
      fi
    fi
    text="issue-$number: $url open $(plural "$days" day)"
    [ "$value" = overdue ] && text="$text with no backlog row"
    text="$text, $(plural "$comments" comment)"
    last=$(jq -r 'if . == null then empty else "last comment " + .day + (if .run then " by run " + .run else "" end) end' \
      "$out/comments/$number.json" 2>/dev/null)
    [ -z "$last" ] || text="$text, $last"
    finding "$label" "issue-$number" "$value" "$text"
  done < <(jq -r '.[] | [.number, .url, .created, .comments] | @tsv' "$out/issues.json")
}

judge_settings() {
  local label=$1 out=$2 err allowed private org_err
  err=$(read_error "$out/repo")
  if [ -n "$err" ]; then
    unread "$label" merge-methods "settings unreadable: $(why_unread "$err")"
    unread "$label" runs-on ''
    return 0
  fi
  if jq -e '.merge == null or .rebase == null' "$out/repo.json" >/dev/null 2>&1; then
    unread "$label" merge-methods "merge-methods unreadable: the GitHub read omitted merge settings"
  else
    allowed=$(jq -r '[(if .merge then "merge commits" else empty end), (if .rebase then "rebase merges" else empty end)] | join(" and ")' "$out/repo.json")
    [ -z "$allowed" ] || finding "$label" merge-methods "$allowed" "merge-methods: allows $allowed"
  fi
  private=$(jq -r '.private' "$out/repo.json")
  [ "$private" = true ] || return 0
  err=$(read_error "$out/runs-on")
  case "$err" in
    '') ;;
    absent)
      org_err=$(read_error "$out/org-vars")
      case "$org_err" in
        '')
          if jq -e 'any(. == "CI_RUNS_ON")' "$out/org-vars.json" >/dev/null 2>&1; then
            :
          else
            finding "$label" runs-on missing "runs-on: private and sets no CI_RUNS_ON variable"
          fi
          ;;
        absent) finding "$label" runs-on missing "runs-on: private and sets no CI_RUNS_ON variable" ;;
        *) unread "$label" runs-on "runs-on unreadable: $(why_unread "$org_err")" ;;
      esac
      ;;
    *) unread "$label" runs-on "runs-on unreadable: $(why_unread "$err")" ;;
  esac
}

judge_pulls() {
  local label=$1 out=$2 err number url day created age
  err=$(read_error "$out/pulls")
  if [ -n "$err" ]; then
    unread "$label" release-pr- "release pull requests unreadable: $(why_unread "$err")"
    return 0
  fi
  while IFS=$'\t' read -r number url day created; do
    [ -n "$number" ] || continue
    case "$created" in ''|*[!0-9]*) continue ;; esac
    age=$((NOW - created))
    [ "$age" -ge "$ISSUE_OVERDUE_SECS" ] || continue
    finding "$label" "release-pr-$number" open "release-pr-$number: $url open since $day"
  done < <(jq -r '.[] | [.number, .url, .day, .created] | @tsv' "$out/pulls.json")
}

judge_schedules() {
  local label=$1 out=$2 branch base name key err summary conclusion
  branch=$(cat "$out/branch" 2>/dev/null) || branch=main
  for base in $(find "$out/schedule" -maxdepth 1 -type f \( -name '*.json' -o -name '*.err' \) 2>/dev/null | sed -E 's/\.(json|err)$//' | sort -u); do
    name=$(basename "$base")
    key="schedule-${name%.*}"
    err=$(read_error "$base")
    if [ -n "$err" ]; then
      unread "$label" "$key" "$key unreadable: $(why_unread "$err")"
      continue
    fi
    summary=$(jq -r --argjson cap "$RUN_HISTORY" '
      if length == 0 or (.[0].conclusion | IN("success", "skipped", "neutral")) then empty
      else
        .[0].conclusion as $c
        | ([foreach .[] as $r (true; . and $r.conclusion == $c; .) | select(.)] | length) as $n
        | [$c, (if $n >= $cap then "at least \($n) scheduled runs in a row" elif $n > 1 then "\($n) scheduled runs in a row" else "last scheduled run " + .[0].day end)]
        | @tsv
      end
    ' "$base.json" 2>/dev/null)
    [ -n "$summary" ] || continue
    conclusion=${summary%%$'\t'*}
    finding "$label" "$key" "$conclusion" "$key: $name $conclusion on $branch, ${summary#*$'\t'}"
  done
}

judge_tree() {
  local label=$1 out=$2 newest=$3 err tree pin version is_self rc summary
  tree="$out/tree"
  err=$(cat "$out/clone.err" 2>/dev/null)
  if [ -n "$err" ]; then
    if [ "$err" = timeout ]; then err='time ran out'; else err='cloning main failed'; fi
    unread "$label" kit-pin "main unreadable: $err"
    unread "$label" retired-workflow ''
    unread "$label" author ''
    unread "$label" ci-wiring ''
    unread "$label" schedule- ''
    return 0
  fi
  if ! jq -e 'type == "object"' "$tree/package.json" >/dev/null 2>&1; then
    unread "$label" kit-pin "package.json unreadable at main"
    judge_retired_workflows "$label" "$tree"
    unread "$label" author ''
    judge_ci_wiring "$label" "$out"
    judge_schedules "$label" "$out"
    return 0
  fi
  is_self=0
  jq -e --arg p "$KIT_PACKAGE" '.name == $p' "$tree/package.json" >/dev/null 2>&1 && is_self=1
  pin=$(jq -r --arg p "$KIT_PACKAGE" '(.dependencies // {})[$p] // (.devDependencies // {})[$p] // empty' "$tree/package.json")
  version=
  [ -z "$pin" ] || version=$(pin_version "$pin") || version=
  if [ "$is_self" -eq 0 ] && [ -n "$pin" ]; then
    if [ -z "$version" ]; then
      finding "$label" kit-pin "$pin" "kit-pin: $pin is not a release version"
    elif [ -z "$newest" ]; then
      unread "$label" kit-pin "kit-pin unreadable: the newest kit release is unknown"
    elif version_lt "$version" "$newest"; then
      finding "$label" kit-pin "$pin" "kit-pin: pins $pin, newest release $newest"
    fi
  fi
  judge_retired_workflows "$label" "$tree"
  jq -e '
    ((.author | type) == "string" and (.author | length) > 0)
    or ((.author | type) == "object" and ((.author.name // "") | length) > 0)
    or ((.contributors // []) | length) > 0
  ' "$tree/package.json" >/dev/null 2>&1 \
    || finding "$label" author missing "author: package.json names no author and no contributors"
  judge_ci_wiring "$label" "$out"
  judge_schedules "$label" "$out"
}

judge_retired_workflows() {
  local label=$1 tree=$2 file files=
  for file in "$tree"/.github/workflows/*.yml "$tree"/.github/workflows/*.yaml; do
    [ -f "$file" ] || continue
    case "${file##*/}" in
      night-run.yml|night-run.yaml) ;;
      *) grep -qE '(checks-lint|lint\.ts).*--night' "$file" 2>/dev/null || continue ;;
    esac
    files="$files${files:+, }${file##*/}"
  done
  [ -z "$files" ] || finding "$label" retired-workflow "$files" "retired-workflow: $files"
}

judge_ci_wiring() {
  local label=$1 out=$2 rc summary
  if [ -f "$out/ci-wiring.rc" ]; then
    rc=$(cat "$out/ci-wiring.rc")
    if fm_timed_out "$rc"; then
      unread "$label" ci-wiring "ci-wiring unreadable: time ran out"
    elif [ "$rc" != 0 ]; then
      summary=$(grep -E '^ci-wiring: .*:$' "$out/ci-wiring.out" 2>/dev/null | sed -E 's/^ci-wiring: //; s/:$//' | paste -sd ';' - | sed 's/;/; /g')
      [ -n "$summary" ] || summary="exits $rc"
      finding "$label" ci-wiring "$summary" "ci-wiring: $summary"
    fi
  else
    unread "$label" ci-wiring "ci-wiring unreadable: $(cat "$TMP/kit/install.err" 2>/dev/null || printf 'the newest kit release is unknown')"
  fi
}

diff_record() {
  touch "$TMP/protected" "$TMP/current"
  awk -F '\t' -v next_file="$TMP/next" '
    FILENAME == ARGV[1] { protect[++np] = $1; kind[np] = $2; next }
    FILENAME == ARGV[2] { old[$1] = $2; order[++no] = $1; next }
    {
      cur[$1] = $2
      label = $1; sub(/:.*/, "", label)
      if (!($1 in old) || old[$1] != $2) print label "\t" $3
      print $1 "\t" $2 > next_file
    }
    END {
      for (i = 1; i <= no; i++) {
        key = order[i]
        if (key in cur) continue
        label = key; sub(/:.*/, "", label)
        kept = 0
        for (j = 1; j <= np; j++) {
          if (kind[j] == "prefix") { if (index(key, protect[j]) == 1) { kept = 1; break } }
          else if (key == protect[j]) { kept = 1; break }
        }
        if (kept) { print key "\t" old[key] > next_file; continue }
        practice = substr(key, length(label) + 2)
        word = (practice ~ /^(issue|release-pr)-/) ? "closed" : "cleared"
        print label "\t" practice " " word
      }
    }
  ' "$TMP/protected" "$TMP/record" "$TMP/current"
  touch "$TMP/next"
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

record_load() {
  : > "$TMP/record"
  record_epoch >/dev/null || return 0
  tail -n +3 "$RECORD" | awk -F '\t' 'NF == 2 && $1 ~ /^[^:]+:[^:]+$/' > "$TMP/record"
}

record_write() {
  local now=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-practice-drift.XXXXXX" 2>/dev/null) || return 1
  if ! { printf '%s\nepoch=%s\n' "$RECORD_SCHEMA" "$now"; sort "$TMP/next"; } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

sweep_slot() {
  local now=$1 slot
  slot=$((now - now % DAY_SECS + HOUR * 3600))
  [ "$now" -ge "$slot" ] || slot=$((slot - DAY_SECS))
  printf '%s\n' "$slot"
}

cleanup_check() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  TMP=
}

print_lines() {
  local items=$1 label line
  for label in "${LABELS[@]}"; do
    line=$(awk -F '\t' -v l="$label" '$1 == l { sub(/^[^\t]*\t/, ""); printf "%s%s", sep, $0; sep = "; " }' "$items")
    [ -n "$line" ] || continue
    fm_cap_line "practice drift: $label: $line" "$MAX_LINE"
  done
}

action_check() {
  local last problem i newest bin
  NOW=$(now_epoch)
  if last=$(record_epoch) && [ "$last" -le "$NOW" ] && [ "$last" -ge "$(sweep_slot "$NOW")" ]; then
    return 0
  fi
  command -v git >/dev/null 2>&1 || {
    printf 'practice drift: git is required to read the repositories\n'
    return 0
  }
  problem=$(config_problem)
  if [ -n "$problem" ]; then
    fm_cap_line "practice drift: $problem" "$MAX_LINE"
    return 0
  fi
  config_read

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-practice-drift.XXXXXX" 2>/dev/null) || return 0
  trap cleanup_check EXIT HUP INT TERM
  DEADLINE=$(($(date +%s) + BUDGET_SECS))

  collect_repos
  read_kit "$TMP/kit" &
  for i in "${!LABELS[@]}"; do
    read_repo "$TMP/r/$i" "${SLUGS[$i]}" "${KIT_APPLIES[$i]}" &
  done
  wait

  newest=$(cat "$TMP/kit/newest" 2>/dev/null)
  bin=$(cat "$TMP/kit/ci-wiring" 2>/dev/null)
  if [ -n "$bin" ]; then
    for i in "${!LABELS[@]}"; do
      [ "${KIT_APPLIES[$i]}" -eq 1 ] || continue
      run_ci_wiring "$TMP/r/$i" "$bin" &
    done
    wait
  fi

  record_load
  : > "$TMP/unread"
  for i in "${!LABELS[@]}"; do
    if [ -z "${SLUGS[$i]}" ]; then
      unread "${LABELS[$i]}" '' "unreadable: origin is not a GitHub repository"
      continue
    fi
    judge_issues "${LABELS[$i]}" "$TMP/r/$i"
    [ "${KIT_APPLIES[$i]}" -eq 1 ] || continue
    judge_tree "${LABELS[$i]}" "$TMP/r/$i" "$newest"
    judge_settings "${LABELS[$i]}" "$TMP/r/$i"
    judge_pulls "${LABELS[$i]}" "$TMP/r/$i"
  done

  diff_record > "$TMP/items"
  cat "$TMP/unread" >> "$TMP/items"
  print_lines "$TMP/items"
  record_write "$NOW" || true
  cleanup_check
  trap - EXIT HUP INT TERM
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-practice-drift-check.sh - practice drift poll shim.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-practice-drift-check.sh") check"
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
  tmp=$(umask 077; mktemp "$STATE/.fm-practice-drift-check.XXXXXX" 2>/dev/null) || return 1
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
  local home problem
  problem=$(config_problem)
  if [ -n "$problem" ]; then
    printf 'fm-practice-drift-check: %s\n' "$problem" >&2
    return 1
  fi
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-practice-drift-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  shim_write "$(shim_content "$home")" || {
    printf 'fm-practice-drift-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || {
    rm -f -- "$CHECK_SHIM"
    printf 'fm-practice-drift-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  FM_HOME="$FM_HOME" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
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
