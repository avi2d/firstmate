#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

home=$(fm_test_tmproot fm-task-record)
tool="$ROOT/bin/fm-task-record.sh"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data"
export FM_CONFIG_OVERRIDE="$home/config" TZ=UTC
mkdir -p "$FM_STATE_OVERRIDE/status-archive" "$FM_DATA_OVERRIDE"
db="$home/missing.sqlite"

make_task() {
  local id=$1 outcome=$2 work=$3
  local task_dir="$FM_DATA_OVERRIDE/$id" archive="$FM_STATE_OVERRIDE/status-archive/$id" start
  mkdir -p "$task_dir" "$archive"
  printf '%s\n' 'Delivery contract: mode=direct-PR' > "$task_dir/brief.md"
  case "$(uname -s)" in
    Darwin) start=$(stat -f %B "$task_dir/brief.md") ;;
    *) start=$(stat -c %W "$task_dir/brief.md") ;;
  esac
  [ "$start" -gt 0 ] || fail "fixture filesystem does not expose brief birth time"
  printf '%s\n' \
    "working [at=$start]: started" \
    "paused [at=$((start + work))]: CI" \
    "needs-decision [key=scope] [at=$((start + work + 7))]: scope" \
    "blocked [key=access] [at=$((start + work + 18))]: access" \
    "resolved [key=scope] [at=$((start + work + 20))]: scope answered" \
    "$outcome [at=$((start + work + 31))]: finished" \
    "working [at=$((start + work + 99))]: follow-up" > "$archive/$start.1.status"
}

cat > "$FM_DATA_OVERRIDE/backlog.md" <<'EOF'
## Done
- [x] one - Landed (kind: ship) (repo: demo) (merged 2026-01-01)
- [x] two - Failed (kind: ship) (repo: demo)
- [x] three - Dropped (kind: ship) (repo: demo)
  discarded
- [x] four - Ready (kind: ship) (repo: demo) (done 2026-01-01)
EOF

make_task one 'done' 10
make_task two failed 20
make_task three dropped 30
make_task four 'done' 40
out=$("$tool" --nm-db "$db" --mode direct-PR)
assert_contains "$out" "$(printf 'one\tship\tdemo\tdirect-PR\tmissing\taccepted\t10\t7\t11\t13\t41')" \
  "a resolution for one decision must not end a different blocker, and follow-up must not add time"
assert_contains "$out" "$(printf 'four\tship\tdemo\tdirect-PR\tmissing\tmissing\t40')" \
  "worker done must not stand in for acceptance"

under=$("$tool" --nm-db "$db" --aggregate --mode direct-PR)
assert_contains "$under" "No time range: at least 5 cases with timing are required." \
  "four timed cases must not produce a range"
[ ! -e "$db" ] || fail "a missing database was created by a read"

make_task five failed 50
summary=$("$tool" --nm-db "$db" --aggregate --mode direct-PR)
assert_contains "$summary" "Cases: 5 (1 accepted, 2 failed, 1 dropped, 1 missing result)" \
  "non-successful work must remain in the sample"
assert_contains "$summary" "$(printf 'working_s\t30\t50')" \
  "working time must count failed and dropped work without counting waits"
assert_contains "$summary" "$(printf 'elapsed_s\t61\t81')" \
  "elapsed percentiles must include waits but not follow-up"

echo "fm-task-record: ok"
