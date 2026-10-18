#!/usr/bin/env bash
# Tests for the parked-run worker wake: a paused worker naming its run gets one steer at a worker-owed gate, and stays quiet otherwise.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-nm-run-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot nm-parked-worker-wake)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FM_FAKE_AXI_STATUS"
EOF
chmod +x "$FAKEBIN/no-mistakes"

toon_lint_parked() { cat <<'EOF'
run:
  id: "01LINTPARKED01"
  branch: fm/lint-fix
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,warning,lint.go,,auto-fix,unused import
gate: lint
EOF
}

toon_review_parked() { cat <<'EOF'
run:
  id: "01REVIEWPARKED01"
  branch: fm/review-fix
  status: fix_review
  awaiting_agent: parked 5m1s
  head: "def5678"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,warning,b.go,,auto-fix,stale comment
gate: review
EOF
}

toon_executing() { cat <<'EOF'
run:
  id: "01EXECUTING01"
  branch: fm/work
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    lint,12m3s,8s,44121,"lint 1/2"
EOF
}

toon_human_gate() { cat <<'EOF'
run:
  id: "01HUMANGATE01"
  branch: fm/human-fix
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

toon_prose_only_gate() { cat <<'EOF'
run:
  id: "01PROSEGATE01"
  branch: fm/prose-fix
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,the action field is one of no-op, auto-fix, ask-user, so pick one
    r2,warning,b.go,,auto-fix,ignored error
gate: review
EOF
}

toon_completed() { cat <<'EOF'
run:
  id: "01COMPLETED01"
  branch: fm/work
  status: completed
  head: "abc1234"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

t=$(toon_lint_parked)
fm_nm_run_is_parked "$t" || fail "lint awaiting_approval fixture did not read parked"
! fm_nm_toon_has_ask_user "$t" || fail "lint fixture with only auto-fix findings read as human-owed"
fm_nm_run_parked_awaiting_agent "$t" || fail "lint awaiting_approval fixture did not read as worker-owed"
pass "lint awaiting_approval parks at a worker-owed gate"

t=$(toon_review_parked)
fm_nm_run_is_parked "$t" || fail "review fix_review fixture did not read parked"
! fm_nm_toon_has_ask_user "$t" || fail "review fixture with only auto-fix findings read as human-owed"
fm_nm_run_parked_awaiting_agent "$t" || fail "review fix_review fixture did not read as worker-owed"
pass "review fix_review parks at a worker-owed gate"

t=$(toon_executing)
! fm_nm_run_is_parked "$t" || fail "executing run read as parked"
! fm_nm_run_parked_awaiting_agent "$t" || fail "executing run read as worker-owed"
pass "a still-executing run stays quiet"

t=$(toon_human_gate)
fm_nm_run_is_parked "$t" || fail "human-owed gate fixture did not read parked"
fm_nm_toon_has_ask_user "$t" || fail "gate with an ask-user row did not read as human-owed"
! fm_nm_run_parked_awaiting_agent "$t" || fail "human-owed gate read as worker-owed"
pass "a human-owed gate stays quiet"

t=$(toon_prose_only_gate)
! fm_nm_toon_has_ask_user "$t" || fail "ask-user prose inside description minted a human answer"
fm_nm_run_parked_awaiting_agent "$t" || fail "prose-only gate did not read as worker-owed"
pass "finding prose quoting ask-user never mints a human answer"

t=$(toon_completed)
! fm_nm_run_is_parked "$t" || fail "completed run read as parked"
! fm_nm_run_parked_awaiting_agent "$t" || fail "completed run read as worker-owed"
pass "a terminal run stays quiet"

make_case() {
  local state=$1 task=$2 branch=$3 kind=$4
  shift 4
  local wt="$TMP_ROOT/wt-$task"
  mkdir -p "$state" "$wt"
  git -C "$wt" init -q
  git -C "$wt" symbolic-ref HEAD "refs/heads/$branch"
  printf 'kind=%s\nbackend=tmux\nwindow=test:0\nworktree=%s\n' "$kind" "$wt" > "$state/$task.meta"
  printf '%s\n' "$*" > "$state/$task.status"
}

ring_probe() {
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    nm_parked_agent_ring "$2" "$3"
  ' _ "$WATCH" "$2" "$3"
}

inbox_count() {
  local f n=0
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

state=$(fm_test_tmproot nm-parked-case-lint)
export FM_FAKE_AXI_STATUS
FM_FAKE_AXI_STATUS=$(toon_lint_parked)
make_case "$state" t1 fm/lint-fix ship "paused: waiting on no-mistakes run 01LINTPARKED01 to clear its lint gate"
ring_probe "$state" test:0 t1 || fail "paused worker on a parked lint gate got no ring"
[ "$(inbox_count "$state" t1)" = 1 ] || fail "lint ring did not write exactly one steer"
grep -q "parked at lint" "$state"/t1.inbox/*.msg || fail "lint steer did not name the gate"
grep -q "01LINTPARKED01" "$state"/t1.inbox/*.msg || fail "lint steer did not name the run"
ring_probe "$state" test:0 t1 || true
[ "$(inbox_count "$state" t1)" = 1 ] || fail "lint ring duplicated its steer"
pass "paused worker on a parked lint gate rings once"

state=$(fm_test_tmproot nm-parked-case-review)
FM_FAKE_AXI_STATUS=$(toon_review_parked)
make_case "$state" t1 fm/review-fix ship "paused: waiting on no-mistakes run 01REVIEWPARKED01 to clear review"
ring_probe "$state" test:0 t1 || fail "paused worker on a parked review gate got no ring"
grep -q "parked at review" "$state"/t1.inbox/*.msg || fail "review steer did not name the gate"
pass "paused worker on a parked review gate rings"

state=$(fm_test_tmproot nm-parked-case-exec)
FM_FAKE_AXI_STATUS=$(toon_executing)
make_case "$state" t1 fm/work ship "paused: waiting on no-mistakes run 01EXECUTING01 to finish lint"
if ring_probe "$state" test:0 t1; then fail "paused worker on an executing run rang"; fi
[ "$(inbox_count "$state" t1)" = 0 ] || fail "executing run wrote a steer"
pass "paused worker on an executing run stays quiet"

state=$(fm_test_tmproot nm-parked-case-unrelated)
FM_FAKE_AXI_STATUS=$(toon_lint_parked)
make_case "$state" t1 fm/lint-fix ship "paused: waiting on the website release to land"
if ring_probe "$state" test:0 t1; then fail "pause naming no run rang"; fi
[ "$(inbox_count "$state" t1)" = 0 ] || fail "unrelated pause wrote a steer"
pass "a pause naming no run stays quiet"

state=$(fm_test_tmproot nm-parked-case-human)
FM_FAKE_AXI_STATUS=$(toon_human_gate)
make_case "$state" t1 fm/human-fix ship "paused: waiting on no-mistakes run 01HUMANGATE01 to clear review"
if ring_probe "$state" test:0 t1; then fail "paused worker on a human-owed gate rang"; fi
[ "$(inbox_count "$state" t1)" = 0 ] || fail "human-owed gate wrote a steer"
pass "paused worker on a human-owed gate stays quiet"

state=$(fm_test_tmproot nm-parked-case-held)
FM_FAKE_AXI_STATUS=$(toon_lint_parked)
make_case "$state" t1 fm/lint-fix ship "captain-held: waiting on the captain for run 01LINTPARKED01"
if ring_probe "$state" test:0 t1; then fail "captain-held transfer rang"; fi
[ "$(inbox_count "$state" t1)" = 0 ] || fail "captain-held transfer wrote a steer"
pass "a verified captain-held transfer stays quiet"

state=$(fm_test_tmproot nm-parked-case-mate)
FM_FAKE_AXI_STATUS=$(toon_lint_parked)
make_case "$state" t1 fm/lint-fix secondmate "paused: waiting on no-mistakes run 01LINTPARKED01 to clear its lint gate"
if ring_probe "$state" test:0 t1; then fail "secondmate pause rang"; fi
[ "$(inbox_count "$state" t1)" = 0 ] || fail "secondmate pause wrote a steer"
pass "a non-ship pause stays quiet"
