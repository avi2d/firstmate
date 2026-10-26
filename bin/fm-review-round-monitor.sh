#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.review-rounds"
CHECK_ID=review-rounds
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
MAX_LINE=1000

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
NM_DB=$(fm_nm_state_db "$FM_HOME")

usage() {
  cat <<'EOF'
Usage:
  fm-review-round-monitor.sh [check]   print one wake line per live run that newly reaches its third review fix round
  fm-review-round-monitor.sh status    list this home's live runs with their review fix round counts, read-only
  fm-review-round-monitor.sh arm       write and register state/review-rounds.check.sh
  fm-review-round-monitor.sh disarm    remove the check shim, its trust binding, and the de-dupe record
  fm-review-round-monitor.sh --help    print this help

A review fix round is a step_rounds row with trigger_type auto_fix on the review step.
A run is live until its status is completed, failed, or cancelled.
Only runs whose branch matches a state/<id>.meta branch= line are this home's tasks.
The state database is resolved by fm_nm_state_db, opened with mode=ro, and never written.
EOF
}

run_reader() {
  local mode=$1
  command -v python3 >/dev/null 2>&1 || {
    printf 'fm-review-round-monitor: python3 is required to read the no-mistakes state database\n' >&2
    return 1
  }
  python3 -I - "$mode" "$STATE" "$NM_DB" "$RECORD" <<'PY'
import glob
import json
import os
import sqlite3
import sys
import tempfile
from contextlib import closing
from pathlib import Path

mode, state, db_path, record_path = sys.argv[1:5]
LIMIT = 3
SCHEMA = "fm-review-round-monitor-v1"
# Not fm_nm_run_status_class: it has no live class for fixing or the gate statuses, which are live here.
TERMINAL = ("completed", "failed", "cancelled")
# Epoch seconds stay below this until the year 5138.
MS_FLOOR = 100_000_000_000


def seconds(stamp):
    return stamp / 1000 if stamp >= MS_FLOOR else stamp


def tasks_by_branch():
    found = {}
    for path in sorted(glob.glob(os.path.join(state, "*.meta"))):
        branch = ""
        with open(path, encoding="utf-8", errors="replace") as meta:
            for line in meta:
                if line.startswith("branch="):
                    branch = line[len("branch="):].strip()
        if branch:
            found.setdefault(branch, os.path.basename(path)[: -len(".meta")])
    return found


def snapshot():
    uri = Path(os.path.abspath(db_path)).as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=30)) as db:
        runs = db.execute(
            "select r.id, r.branch, rp.working_path from runs r"
            " join repos rp on rp.id = r.repo_id"
            " where r.status not in (?, ?, ?)",
            TERMINAL,
        ).fetchall()
        stamps = {}
        for run_id, _, _ in runs:
            rows = db.execute(
                "select r.created_at from step_rounds r"
                " join step_results sr on sr.id = r.step_result_id"
                " where sr.run_id = ? and sr.step_name = 'review' and r.trigger_type = 'auto_fix'",
                (run_id,),
            ).fetchall()
            stamps[run_id] = sorted(seconds(row[0]) for row in rows)
    return runs, stamps


def observe():
    runs, stamps = snapshot()
    tasks = tasks_by_branch()
    rows = []
    for run_id, branch, working_path in runs:
        task = tasks.get(branch)
        if task is None:
            continue
        rounds = stamps[run_id]
        rows.append({
            "run": run_id,
            "task": task,
            "branch": branch,
            "project": os.path.basename(working_path.rstrip("/")),
            "rounds": len(rounds),
            "third": rounds[LIMIT - 1] if len(rounds) >= LIMIT else None,
        })
    return rows, {run_id for run_id, _, _ in runs}


def read_record():
    try:
        with open(record_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}, ""
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        return {}, ""
    return dict(data.get("woken") or {}), str(data.get("failure") or "")


def write_record(woken, failure):
    fd, tmp = tempfile.mkstemp(dir=state, prefix=".review-rounds.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump({"schema": SCHEMA, "woken": woken, "failure": failure}, handle, sort_keys=True)
        os.replace(tmp, record_path)
    except BaseException:
        os.unlink(tmp)
        raise


def check():
    if not os.path.exists(db_path):
        return ""
    woken, failure = read_record()
    try:
        rows, live = observe()
    except (sqlite3.Error, OSError) as err:
        message = "review fix rounds: the no-mistakes state database could not be read: " + str(err).replace("\n", " ")
        if message == failure:
            return ""
        write_record(woken, message)
        return message
    fresh = []
    for row in rows:
        if row["rounds"] >= LIMIT and row["run"] not in woken:
            woken[row["run"]] = {"task": row["task"], "branch": row["branch"], "rounds": row["rounds"]}
            fresh.append(row)
    # The record is written before the wake prints: a failed write retries the wake, never repeats it.
    write_record({run_id: entry for run_id, entry in woken.items() if run_id in live}, "")
    if not fresh:
        return ""
    return "decision: third review fix round reached - " + "; ".join(
        "task %s, project %s, branch %s, %d review fix rounds in run %s"
        % (row["task"], row["project"], row["branch"], row["rounds"], row["run"])
        for row in fresh
    )


def status():
    if not os.path.exists(db_path):
        sys.stderr.write("no no-mistakes state database at " + db_path + "\n")
        return 1
    try:
        rows, _ = observe()
    except (sqlite3.Error, OSError) as err:
        sys.stderr.write("could not read the no-mistakes state database: " + str(err) + "\n")
        return 1
    woken, _ = read_record()
    for row in rows:
        third = "-" if row["third"] is None else str(int(row["third"]))
        flag = "yes" if row["run"] in woken else "no"
        print("%s %s %s rounds=%d third_round_at=%s woken=%s" % (row["task"], row["project"], row["branch"], row["rounds"], third, flag))
    return 0


if mode == "status":
    sys.exit(status())
line = check()
if line:
    print(line)
PY
}

check_action() {
  local line
  [ -d "$STATE" ] || return 0
  line=$(run_reader check) || return 1
  [ -n "$line" ] || return 0
  fm_cap_line_var "$line" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-review-round-monitor.sh - review fix round poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-review-round-monitor.sh") check"
}

action_arm() {
  local home tmp
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-review-round-monitor: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077 && mktemp "$STATE/.fm-review-round-monitor.XXXXXX") || return 1
  if ! { shim_content "$home" > "$tmp" && chmod 0700 "$tmp" && mv -f -- "$tmp" "$CHECK_SHIM"; }; then
    rm -f -- "$tmp"
    printf 'fm-review-round-monitor: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'fm-review-round-monitor: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" || return 1
  rm -f -- "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) check_action ;;
  status) run_reader status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

