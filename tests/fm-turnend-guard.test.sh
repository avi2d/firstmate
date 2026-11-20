#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='Pi tool fm_watch_arm_pi'

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

test_predicate_source_needs_supervision() {
  local state="$TMP_ROOT/pred-source/state"
  mkdir -p "$state/procevent"
  : > "$state/procevent/source-only.source"
  fm_supervision_unhealthy "$state" 300 || fail "registered source with no beacon must be unhealthy"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "a process-event source must not count as a task"
  [ "$FM_SUP_SOURCES" -eq 1 ] || fail "expected one registered process-event source"
  pass "fm_supervision_unhealthy: source-only home needs supervision"
}

# Register a custom check the way an operator does, through the real
# bin/fm-check-register.sh, so these cases bind to the shipped registration
# artifacts rather than to a hand-written imitation of them.
register_custom_check() {
  local state=$1 id=$2
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/$id.check.sh"
  chmod 700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "fm-check-register.sh could not register $id"
}

test_predicate_registered_check_needs_supervision() {
  local state="$TMP_ROOT/pred-check/state"
  mkdir -p "$state"
  register_custom_check "$state" issue-comments
  fm_supervision_needed "$state" 300 || fail "a registered custom check did not register as supervision need"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "a registered custom check must not count as an in-flight task"
  [ "$FM_SUP_CHECKS" -eq 1 ] || fail "expected one registered custom check, got $FM_SUP_CHECKS"
  fm_supervision_unhealthy "$state" 300 || fail "a registered custom check with no beacon must be unhealthy"
  pass "fm_supervision_needed: a registered custom check needs supervision with no task in flight"
}

test_predicate_registered_check_survives_rebinding_drift() {
  local state="$TMP_ROOT/pred-check-drift/state"
  mkdir -p "$state"
  register_custom_check "$state" issue-comments
  printf '#!/usr/bin/env bash\necho drifted\n' > "$state/issue-comments.check.sh"
  fm_supervision_needed "$state" 300 \
    || fail "an edited registered check must keep supervision on so the sweep can report the rejection"
  [ "$FM_SUP_CHECKS" -eq 1 ] || fail "expected the edited check to stay counted, got $FM_SUP_CHECKS"
  pass "fm_supervision_needed: a registered check whose bytes drifted still needs supervision"
}

test_predicate_unregistered_check_needs_nothing() {
  local state="$TMP_ROOT/pred-check-unregistered/state"
  mkdir -p "$state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/rogue.check.sh"
  chmod 700 "$state/rogue.check.sh"
  if fm_supervision_needed "$state" 300; then
    fail "a check with no trust binding must not arm supervision"
  fi
  [ "$FM_SUP_CHECKS" -eq 0 ] || fail "an unregistered check must not be counted, got $FM_SUP_CHECKS"
  pass "fm_supervision_needed: false for a check.sh with no registration binding"
}

test_predicate_task_pr_poll_is_not_a_custom_check() {
  local state="$TMP_ROOT/pred-pr-poll/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/task1.check.sh"
  chmod 700 "$state/task1.check.sh"
  : > "$state/task1.pr-poll"
  fm_supervision_needed "$state" 300 || fail "the in-flight task itself must need supervision"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected the task to be the one in-flight need, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_CHECKS" -eq 0 ] || fail "a task PR poll must not count as a registered custom check"
  pass "fm_supervision_needed: a task PR poll without a trust binding is not a registered custom check"
}


# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  FM_HOME="$home" env PI_CODING_AGENT=true FM_PI_HARNESS=pi bash "$dir/bin/fm-turnend-guard.sh" </dev/null 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir"); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir"); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_source_only_home() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-source-only")
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/source-only.source"
  out=$(run_hook "$dir"); status=$?
  expect_code 2 "$status" "non-Claude hook must block when a source-only home has no watcher"
  assert_contains "$out" "1 process-event source(s) registered" "block reason must identify the source-only supervision need"
  pass "fm-turnend-guard: blocks a source-only home"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir"); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir"); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir"); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir"); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(FM_HOME="$home" env PI_CODING_AGENT=true FM_PI_HARNESS=pi bash "$dir/bin/fm-turnend-guard.sh" </dev/null 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}



test_hook_registered_check_only_blocks_with_check_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-check-only")
  register_custom_check "$dir/state" issue-comments
  out=$(run_hook "$dir"); status=$?
  expect_code 2 "$status" "default hook mode must block a registered-check-only blind turn"
  assert_contains "$out" "1 registered custom check(s), but no live watcher" "check-only blind stop must identify its supervision need"
  assert_not_contains "$out" "X-mode relay polling needs supervision" "check-only blind stop must not be misreported as relay polling"
  pass "fm-turnend-guard: registered-check-only supervision is named in the block banner"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(FM_HOME="$home" env PI_CODING_AGENT=true FM_PI_HARNESS=pi bash "$dir/bin/fm-turnend-guard.sh" </dev/null 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" env PI_CODING_AGENT=true FM_PI_HARNESS=pi bash "$dir/bin/fm-turnend-guard.sh" </dev/null 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir"); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" >/dev/null || expect_code 2 "$?" "unhealthy guard verdict"
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_pi_extension_injects_once_per_logical_agent_run() {
  local repo home ext log out status
  repo="$TMP_ROOT/pi-logical-run-root"
  home="$TMP_ROOT/pi-logical-run-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/pi-logical-run-guard.log"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`untyped operational prompt: ${message}`);
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (!message.includes("watcher cycle is missing, failed, or unhealthy")) throw new Error(`guard prompt omitted recovery-only state: ${message}`);
    if (message.includes("Resume supervision according to the session-start operating block")) throw new Error(`guard prompt used ordinary continuity: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`no-tool run injected ${prompts} follow-ups`);

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`multi-tool run produced ${prompts - 1} follow-ups`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
await settled({ type: "agent_settled" }, {});
if (attempts !== 2) throw new Error(`expected delivery retry, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: delivery failure resets the logical-run latch"
}

# A Pi command started from inside the live session, such as the `pi --help`
# capability probe, auto-loads this extension too and passes the ancestor walk
# in lockOwnership. Its pid dies at once, so the marker must stay on the live
# session above it, while a dead or foreign marker pid is still replaced.
test_pi_extension_keeps_marker_of_live_ancestor_session() {
  local repo home ext marker_case out status
  repo="$TMP_ROOT/pi-marker-guard-root"
  home="$TMP_ROOT/pi-marker-guard-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  for marker_case in nested dead foreign fresh; do
    rm -f "$home/state/.pi-turnend-extension-loaded"
    out=$(PLUGIN="$ext" FM_HOME="$home" MARKER_CASE="$marker_case" node --input-type=module 2>&1 <<'EOF'
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const marker = `${process.env.FM_HOME}/state/.pi-turnend-extension-loaded`;
const version = `sha256:${createHash("sha256").update(readFileSync(process.env.PLUGIN)).digest("hex")}`;
// The lock names the parent of this process: a live strict ancestor, exactly where
// the real session sits above a nested `pi --help`.
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.ppid}\n`);

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {},
};
async function load() {
  const mod = await import(pathToFileURL(process.env.PLUGIN).href);
  mod.default(pi);
}
function expectBoundToThisProcess(label) {
  const content = readFileSync(marker, "utf8");
  if (content !== `${version}\n${process.pid}\n`) {
    throw new Error(`${label}: marker was not bound to this process: ${JSON.stringify(content)}`);
  }
}
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

switch (process.env.MARKER_CASE) {
  case "nested": {
    const before = `${version}\n${process.ppid}\n`;
    writeFileSync(marker, before);
    await load();
    // "reload" exercises the session_start write path without a startup digest.
    await handlers.get("session_start")?.({ type: "session_start", reason: "reload" }, {});
    const after = readFileSync(marker, "utf8");
    if (after !== before) throw new Error(`nested load replaced the marker of the live session: ${JSON.stringify(after)}`);
    break;
  }
  case "dead": {
    const dead = spawnSync(process.execPath, ["-e", "0"], { stdio: "ignore" }).pid;
    if (!dead || pidAlive(dead)) throw new Error(`could not produce a dead pid (got ${dead})`);
    writeFileSync(marker, `${version}\n${dead}\n`);
    await load();
    expectBoundToThisProcess("marker on a dead pid");
    break;
  }
  case "foreign": {
    const foreign = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
    try {
      writeFileSync(marker, `${version}\n${foreign.pid}\n`);
      await load();
      expectBoundToThisProcess("marker on a live non-ancestor pid");
    } finally {
      foreign.kill("SIGTERM");
    }
    break;
  }
  case "fresh": {
    if (existsSync(marker)) throw new Error("fresh case started with a marker present");
    await load();
    expectBoundToThisProcess("fresh load");
    break;
  }
  default:
    throw new Error(`unknown marker case: ${process.env.MARKER_CASE}`);
}
EOF
)
    status=$?
    [ "$status" = 0 ] || fail "Pi turn-end marker guard failed for the '$marker_case' case (exit $status): $out"
    [ -z "$out" ] || fail "Pi turn-end marker guard '$marker_case' case printed output: $out"
  done
  pass ".pi primary extension: a nested load keeps the live session's turn-end marker"
}

# On Windows the session lock may hold a tagged win:<pid> (bin/fm-session-lock-lib.sh),
# and native Node sees that Windows pid directly. The extension records its marker
# for an owned or dead tagged holder and never for a live other one, while a
# malformed tag, and any tag off Windows, stays no identity at all. The platform is
# set per case so every host exercises both sides.
test_pi_extension_reads_a_windows_tagged_session_lock() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-tagged-lock-root"
  home="$TMP_ROOT/pi-tagged-lock-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const marker = `${process.env.FM_HOME}/state/.pi-turnend-extension-loaded`;
const lock = `${process.env.FM_HOME}/state/.lock`;
const version = `sha256:${createHash("sha256").update(readFileSync(process.env.PLUGIN)).digest("hex")}`;
const platform = Object.getOwnPropertyDescriptor(process, "platform");
let loads = 0;
async function loadOn(name) {
  rmSync(marker, { force: true });
  Object.defineProperty(process, "platform", { ...platform, value: name });
  try {
    const mod = await import(`${pathToFileURL(process.env.PLUGIN).href}?tagged=${(loads += 1)}`);
    mod.default({ on() {}, async sendUserMessage() {} });
  } finally {
    Object.defineProperty(process, "platform", platform);
  }
}

const dead = spawnSync(process.execPath, ["-e", "0"], { stdio: "ignore" }).pid;
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  const cases = [
    ["win32", `win:${process.pid}`, true, "an owned tagged lock"],
    ["win32", `win:${dead}`, true, "a dead tagged holder"],
    ["win32", `win:${other.pid}`, false, "a live other tagged holder"],
    ["win32", `${process.pid}`, true, "an owned local lock"],
    ["win32", "win:", false, "a bare tag"],
    ["win32", `win:${process.pid}x`, false, "a tag with trailing junk"],
    ["win32", `WIN:${process.pid}`, false, "a differently cased tag"],
    ["win32", "win:1", false, "a tagged pid 1"],
    ["linux", `win:${process.pid}`, false, "a tagged lock off Windows"],
    ["linux", `${process.pid}`, true, "an owned local lock off Windows"],
  ];
  for (const [name, value, expectMarker, label] of cases) {
    writeFileSync(lock, `${value}\n`);
    await loadOn(name);
    if (!expectMarker) {
      if (existsSync(marker)) throw new Error(`${label} (${name}) recorded a marker: ${readFileSync(marker, "utf8")}`);
      continue;
    }
    const content = existsSync(marker) ? readFileSync(marker, "utf8") : "";
    if (content !== `${version}\n${process.pid}\n`) {
      throw new Error(`${label} (${name}) did not record this process's marker: ${JSON.stringify(content)}`);
    }
  }
} finally {
  other.kill("SIGTERM");
}
EOF
)
  status=$?
  [ "$status" = 0 ] || fail "Pi turn-end guard misread a Windows-tagged session lock (exit $status): $out"
  [ -z "$out" ] || fail "Pi turn-end tagged-lock case printed output: $out"
  pass ".pi primary extension: the turn-end guard reads a Windows-tagged session lock only on Windows"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_predicate_source_needs_supervision
test_predicate_registered_check_needs_supervision
test_predicate_registered_check_survives_rebinding_drift
test_predicate_unregistered_check_needs_nothing
test_predicate_task_pr_poll_is_not_a_custom_check
test_hook_silent_when_no_work_in_flight
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_source_only_home
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_registered_check_only_blocks_with_check_banner
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_silent_in_crewmate_worktree
test_hook_runs_fast
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_pi_extension_keeps_marker_of_live_ancestor_session
test_pi_extension_reads_a_windows_tagged_session_lock
