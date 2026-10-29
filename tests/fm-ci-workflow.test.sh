#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml: the PR gate is static and capped,
# the full suite runs daily, and every job carries a finite timeout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups, the status functions, !, ==, !=, &&,
# ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each ruby -e below prepends this so every resolver shares one
# evaluator.
# shellcheck disable=SC2016  # the ${{ }} below is Ruby text, not a shell expansion
EXPRESSION_RUBY='
require "strscan"
class Expression
  def self.evaluate(source, context)
    new(source, context).parse
  end

  STATUS_FUNCTIONS = %w[always() success() failure() cancelled()].freeze

  # A job or step `if` is a bare expression or one wrapped in ${{ }}, an
  # absent condition means the job runs, and a condition that calls no status
  # function gets the implicit success() check GitHub documents.
  def self.condition(raw, context)
    source = raw.to_s.strip
    source = Regexp.last_match(1) if source =~ /\A\$\{\{(.*)\}\}\z/m
    source = "success()" if source.empty?
    source = "success() && (#{source})" unless new(source, context).status_check?
    truthy?(evaluate(source, context))
  end

  # A result is truthy unless it is false, nil, or the empty string.
  def self.truthy?(value)
    value != false && !value.nil? && value != ""
  end

  def initialize(source, context)
    @context = context
    @tokens = []
    scanner = StringScanner.new(source)
    until scanner.eos?
      next if scanner.skip(/\s+/)
      if scanner.scan(/\x27([^\x27]*)\x27/) then @tokens << [:string, scanner[1]]
      elsif scanner.scan(/\|\||&&|==|!=|[()!]/) then @tokens << [:operator, scanner.matched]
      elsif scanner.scan(/[A-Za-z_][\w.\-]*(?:\(\))?/) then @tokens << [:name, scanner.matched]
      else raise "unsupported expression syntax at: #{scanner.rest}"
      end
    end
  end

  def status_check?
    @tokens.any? { |kind, value| kind == :name && STATUS_FUNCTIONS.include?(value) }
  end

  def parse
    result = parse_or
    raise "unexpected trailing token: #{@tokens.first.inspect}" unless @tokens.empty?
    result
  end

  private

  def take?(operator)
    return false unless @tokens.first == [:operator, operator]
    @tokens.shift
    true
  end

  def parse_or
    left = parse_and
    while take?("||")
      right = parse_and
      left = Expression.truthy?(left) ? left : right
    end
    left
  end

  def parse_and
    left = parse_comparison
    while take?("&&")
      right = parse_comparison
      left = Expression.truthy?(left) ? right : left
    end
    left
  end

  def parse_comparison
    left = parse_unary
    loop do
      operator = ["==", "!="].find { |candidate| take?(candidate) } or break
      right = parse_unary
      unless left.class == right.class
        raise "the resolver only compares operands of one type: #{left.inspect} #{operator} #{right.inspect}"
      end
      equal = left.is_a?(String) ? left.casecmp?(right) : left == right
      left = operator == "==" ? equal : !equal
    end
    left
  end

  def parse_unary
    return !Expression.truthy?(parse_unary) if take?("!")
    parse_primary
  end

  def parse_primary
    if take?("(")
      inner = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return inner
    end
    kind, value = @tokens.shift
    raise "expected an operand, got #{kind.inspect}" unless kind == :string || kind == :name
    return value if kind == :string
    if STATUS_FUNCTIONS.include?(value)
      status = @context.fetch("needs.status", "success")
      return value == "always()" || value == "#{status}()"
    end
    raise "unresolvable context reference: #{value}" unless @context.key?(value)
    @context.fetch(value)
  end
end
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting; an unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_PUSH" => ARGV[2],
  "vars.FM_CI_SKIP_MACOS" => ARGV[3],
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2" "$3"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
PR_TIER_JOBS='lint invariants secrets'
FAST_TIER_JOBS='test-coverage tests-timing-aggregate daily-test-issue'
NORMAL_TIER_JOBS='tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly four
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  expected=$(printf '%s\n' "$PR_TIER_JOBS $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS" | tr ' ' '\n' | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(printf '%s\n' "$expected" | while read -r job; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 4 ] \
    || fail "ci.yml must carry exactly four distinct job timeouts (pr, fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the four timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# The fork opt-out is opt-in: with neither variable set, pull request and push
# runs carry only the static gate and the daily run carries every other job.
# FM_CI_SKIP_PUSH=1 empties only the push run, and FM_CI_SKIP_MACOS=1 removes
# only the macOS job from the daily run. A "-" in the table means unset.
test_fork_skip_variables_are_opt_in() {
  local all pr push_gate daily event skip_push skip_macos expected want actual
  all=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  pr=$(printf '%s\n' "$PR_TIER_JOBS" | tr ' ' '\n' | LC_ALL=C sort)
  # Push runs the PR gate without the pull-request-only secrets scan.
  push_gate=$(printf '%s\n' "$pr" | grep -vx secrets)
  daily=$(comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$pr"))
  printf '%s\n' "$all" | grep -qx macos-stock-bash \
    || fail "the macOS job is missing from ci.yml, so the table below would prove nothing"
  while read -r event skip_push skip_macos expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    case $expected in
      pr) want=$pr ;;
      pushgate) want=$push_gate ;;
      daily) want=$daily ;;
      daily-but-macos) want=$(printf '%s\n' "$daily" | grep -vx macos-stock-bash) ;;
      none) want= ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under "$event" "$skip_push" "$skip_macos" | LC_ALL=C sort) \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos"
    [ "$actual" = "$(printf '%s' "$want")" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push                - - pushgate
pull_request        - - pr
push                1 - none
pull_request        1 - pr
pull_request        - 1 pr
push                - 1 pushgate
schedule            - - daily
workflow_dispatch   - - daily
schedule            - 1 daily-but-macos
workflow_dispatch   - 1 daily-but-macos
TABLE
  pass "the fork skip variables change nothing unless set, and each skips only its own run or job"
}

# Pull request runs carry the capped static gate, and push runs carry it
# without the pull-request-only secrets scan.
test_pull_request_and_push_runs_carry_only_their_capped_gates() {
  local pr push_gate event actual want job
  pr=$(printf '%s\n' "$PR_TIER_JOBS" | tr ' ' '\n' | LC_ALL=C sort)
  # Push runs the PR gate without the pull-request-only secrets scan.
  push_gate=$(printf '%s\n' "$pr" | grep -vx secrets)
  for event in pull_request push; do
    actual=$(jobs_running_under "$event" '' '' | LC_ALL=C sort) || fail "could not resolve the jobs $event runs"
    case $event in pull_request) want=$pr ;; push) want=$push_gate ;; esac
    [ "$actual" = "$want" ] || fail "$event must run only its capped gate ($(printf '%s' "$want" | tr '\n' ' ')), ran: $(printf '%s' "$actual" | tr '\n' ' '))"
  done
  while read -r job; do
    [ "$(job_timeout "$job")" = 10 ] \
      || fail "$job must cap at 10 minutes on a pull request or push run, got $(job_timeout "$job")"
  done <<<"$pr"
  pass "pull request and push runs carry only their capped gates"
}

# Only the failure issue job may write issues, and it must need every other daily
# job so its outcome reflects the whole daily run.
test_daily_run_reports_failures_through_one_issue_job() {
  local needs daily event result expected actual
  ruby -ryaml -e '
writers = YAML.load_file(ARGV[0]).fetch("jobs").select { |_, job| (job["permissions"] || {})["issues"] == "write" }.keys
raise "only daily-test-issue may write issues, got #{writers.inspect}" unless writers == ["daily-test-issue"]
' "$CI_WORKFLOW" || fail "ci.yml grants issue write outside the daily failure job"
  needs=$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("daily-test-issue").fetch("needs").sort' "$CI_WORKFLOW") \
    || fail "could not read the daily-test-issue needs"
  daily=$(jobs_running_under schedule '' '' | grep -vx daily-test-issue | LC_ALL=C sort)
  [ "$needs" = "$daily" ] \
    || fail "daily-test-issue must need every other daily job"$'\n'"needs: $(printf '%s' "$needs" | tr '\n' ' ')"$'\n'"daily: $(printf '%s' "$daily" | tr '\n' ' ')"
  while read -r event result expected; do
    actual=$(job_runs_under daily-test-issue "$event" '' '' "$result") \
      || fail "could not resolve the daily-test-issue condition for $event"
    [ "$actual" = "$expected" ] \
      || fail "daily-test-issue on $event after a $result must resolve $expected, got $actual"
  done <<'TABLE'
schedule           failure true
schedule           success true
workflow_dispatch  failure true
pull_request       failure false
push               failure false
TABLE
  pass "the daily failure issue runs after the daily run only and is the sole job granted issue writes"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> <needs status>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_PUSH" => ARGV[3],
  "vars.FM_CI_SKIP_MACOS" => ARGV[4],
  "needs.status" => ARGV[5],
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate summarizes the daily lanes and must still run after a failed lane
# so its summary lands; pull request and push runs never carry it.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event expected actual
  while read -r event expected; do
    actual=$(job_runs_under tests-timing-aggregate "$event" '' '' failure) \
      || fail "could not resolve the aggregate condition for $event"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event must resolve $expected, got $actual"
  done <<'TABLE'
schedule           true
workflow_dispatch  true
pull_request       false
push               false
TABLE
  pass "the timing aggregate runs after a failed daily lane and never on pull request or push runs"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_fork_skip_variables_are_opt_in
test_pull_request_and_push_runs_carry_only_their_capped_gates
test_daily_run_reports_failures_through_one_issue_job
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
