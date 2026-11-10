#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml: one daily schedule and manual
# dispatch run every job, and every job carries a finite timeout.
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


# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting. An unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_MACOS>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_MACOS" => ARGV[2],
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2"
}

# Print true or false: whether one job's job-level `if` resolves true under one
# simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_MACOS> <needs status>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_MACOS" => ARGV[3],
  "needs.status" => ARGV[4],
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, so no one-off timeout value appears outside these lists.
LINT_TIER_JOBS='lint'
STATIC_TIER_JOBS='static'
FAST_TIER_JOBS='test-coverage tests-timing-aggregate'
NORMAL_TIER_JOBS='tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr tests-hc'
ALL_TIER_JOBS="$LINT_TIER_JOBS $STATIC_TIER_JOBS $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS"

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

test_triggers_are_one_daily_schedule_and_manual_dispatch() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "trigger contract"
doc = YAML.load_file(ARGV[0])
triggers = doc.key?(true) ? doc[true] : doc.fetch("on")
raise "triggers must be exactly schedule and workflow_dispatch, got #{triggers.keys}" unless triggers.keys.sort == ["schedule", "workflow_dispatch"]
crons = triggers.fetch("schedule").map { |entry| entry.fetch("cron") }
raise "schedule must have one cron entry, got #{crons}" unless crons.length == 1
minute, hour, day, month, weekday = crons.first.split
raise "schedule must run once a day: #{crons.first}" unless minute.match?(/\A\d+\z/) && hour.match?(/\A\d+\z/) && [day, month, weekday] == ["*", "*", "*"]
RUBY
  pass "ci.yml runs on one daily schedule and manual dispatch only"
}

test_every_job_runs_on_the_scheduled_and_manual_runs() {
  local all event actual
  all=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  for event in schedule workflow_dispatch; do
    actual=$(jobs_running_under "$event" '' | LC_ALL=C sort) \
      || fail "could not resolve the job conditions for $event"
    [ "$actual" = "$all" ] \
      || fail "$event must run every job"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$all" | tr '\n' ' ')"
  done
  pass "a scheduled run and a manual run each run every job"
}

# FM_CI_SKIP_MACOS=1 removes only the macOS job; no other job reads that variable.
test_fork_skip_variable_removes_only_the_macos_job() {
  local all expected event actual
  all=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  expected=$(printf '%s\n' "$all" | grep -vx macos-stock-bash)
  for event in schedule workflow_dispatch; do
    actual=$(jobs_running_under "$event" 1 | LC_ALL=C sort) \
      || fail "could not resolve the job conditions for $event with FM_CI_SKIP_MACOS=1"
    [ "$actual" = "$expected" ] \
      || fail "$event with FM_CI_SKIP_MACOS=1 must skip only the macOS job"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"
  done
  pass "FM_CI_SKIP_MACOS=1 removes only the macOS job from each run"
}

test_no_job_condition_keys_on_a_pull_request_or_push() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if job["if"].to_s.match?(/pull_request|push/)
end
' "$CI_WORKFLOW") || fail "could not read job conditions from ci.yml"
  [ -z "$reported" ] || fail "these jobs still key on a pull request or push event:"$'\n'"$reported"
  pass "no job condition names a pull request or push event"
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

# Every job sits in exactly one tier, and the workflow carries exactly five
# distinct job-level timeouts: lint, static, and one per remaining tier.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct dupes
  expected=$(printf '%s\n' "$ALL_TIER_JOBS" | tr ' ' '\n' | LC_ALL=C sort)
  dupes=$(printf '%s\n' "$expected" | uniq -d)
  [ -z "$dupes" ] || fail "a job is listed in more than one timeout tier: $dupes"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(printf '%s\n' "$expected" | while read -r job; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 5 ] \
    || fail "ci.yml must carry exactly five distinct job timeouts (lint, static, fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the timeout tiers"
}

test_lint_and_static_keep_their_caps() {
  [ "$(tier_timeout lint $LINT_TIER_JOBS)" = 15 ] || fail "lint must cap at 15 minutes, got $(job_timeout lint)"
  [ "$(tier_timeout static $STATIC_TIER_JOBS)" = 10 ] || fail "the static gate must cap at 10 minutes, got $(job_timeout static)"
  pass "lint caps at 15 minutes and the static gate at 10"
}

# The aggregate summarizes the lanes and must still run after one fails, so its summary lands.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event actual
  for event in schedule workflow_dispatch; do
    actual=$(job_runs_under tests-timing-aggregate "$event" '' failure) \
      || fail "could not resolve the aggregate condition for $event"
    [ "$actual" = true ] || fail "after a failed lane, the aggregate on $event must still run, got $actual"
  done
  pass "the timing aggregate runs after a failed lane on each scheduled and manual run"
}

test_no_ci_job_lists_a_dependency_twice() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "unique job dependencies"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
jobs.each do |name, job|
  needs = Array(job["needs"])
  dupes = needs.group_by { |n| n }.select { |_, v| v.length > 1 }.keys
  raise "#{name} lists #{dupes.join(", ")} twice in needs" unless dupes.empty?
end
RUBY
  pass "no ci job lists a dependency twice in needs"
}

test_no_ci_job_writes_issues() {
  ruby -ryaml -e '
writers = YAML.load_file(ARGV[0]).fetch("jobs").select { |_, job| (job["permissions"] || {})["issues"] == "write" }.keys
raise "no CI job may write issues, got #{writers.inspect}" unless writers.empty?
' "$CI_WORKFLOW" || fail "ci.yml grants issue write to a CI job"
  pass "no CI job writes issues"
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
  # Each heavy lane's family-run step owns the same 20-minute tripwire shape:
  # its own timeout, an always() cleanup step that must come after it, and a
  # bound below the shared job backstop.
  while read -r lane run_step cleanup_step; do
    step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == ARGV[2] }
raise "no #{ARGV[2]} step" unless index
teardown = steps.index { |s| s["id"] == ARGV[3] }
raise "no #{ARGV[3]} step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$lane" "$run_step" "$cleanup_step") || fail "could not read the $lane family-run step"
    case "$step" in ''|*[!0-9]*) fail "the $lane family-run step needs its own timeout-minutes, got $step" ;; esac
    [ "$step" = 20 ] \
      || fail "the $lane family-run step must be the 20-minute tripwire, got $step"
    [ "$step" -lt "$heavy" ] \
      || fail "the $lane step tripwire ($step) must stay below the job backstop ($heavy)"
  done <<'LANES'
tests-herdr run-real-herdr-family cleanup-herdr-lab-sessions
tests-hc run-real-hc-family cleanup-hc-lab-sessions
LANES
  pass "each heavy lane keeps a 20 minute step tripwire under a $heavy minute job backstop"
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
shards = lint.fetch("matrix").fetch("include")
raise "unexpected lint dimensions" unless shards.all? { |entry| entry.keys.sort == ["part_a", "part_b", "shard"] }
parts = shards.flat_map { |entry| [entry.fetch("part_a"), entry.fetch("part_b")] }
raise "lint shards must pair the twelve canonical partitions" unless parts.map(&:to_i).sort == (1..12).to_a
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of12", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_triggers_are_one_daily_schedule_and_manual_dispatch
test_every_job_runs_on_the_scheduled_and_manual_runs
test_fork_skip_variable_removes_only_the_macos_job
test_no_job_condition_keys_on_a_pull_request_or_push
test_no_ci_job_lists_a_dependency_twice
test_no_ci_job_writes_issues
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_lint_and_static_keep_their_caps
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
