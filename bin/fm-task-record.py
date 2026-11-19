from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

TASK_ID = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]*")
STATUS_HEADER = re.compile(r"^([a-z][a-z-]*)(?:\s+\[[^\]]*\])*\s*:")
STAMP = re.compile(r"\[at=([1-9][0-9]{0,11})\]")
WAIT_BUCKET = {"paused": "pipeline_wait_s", "needs-decision": "decision_wait_s",
               "captain-held": "decision_wait_s", "blocked": "blocked_s"}
BUCKETS = ("working_s", *dict.fromkeys(WAIT_BUCKET.values()))
TERMINAL = {"done", "failed", "dropped", "cancelled"}
BACKLOG_ROW = re.compile(r"^[-*]\s+(?:\[[ xX]\]\s+(\S+)|\*\*([^*]+)\*\*)\s+-\s+(.*)$")
PR_URL = re.compile(r'https://[^\s<>"()]+/(?:pull|pulls|-/merge_requests)/[0-9]+(?=$|[\s<>"(),])')
MIN_CASES = 5
RESULTS = ("accepted", "failed", "dropped", "missing")


@dataclass
class BacklogRow:
    state: str
    title: str
    notes: list[str] = field(default_factory=list)
    recorded_kind: str | None = None
    recorded_repo: str | None = None
    recorded_result: str | None = None
    recorded_pr: str | None = None

    def tag(self, key: str) -> str | None:
        match = re.search(r"(?:\(|,\s*)" + re.escape(key) + r":\s*([^,)]+)", self.title)
        return match[1].strip() if match else None

    @property
    def kind(self) -> str | None:
        prefix = re.match(r"^(SCOUT|SHIP)\b", self.title, re.ASCII)
        return self.recorded_kind or self.tag("kind") or (prefix[1].lower() if prefix else None)

    @property
    def repo(self) -> str | None:
        return self.recorded_repo or self.tag("repo")

    @property
    def pr(self) -> str | None:
        return self.recorded_pr or pr_in(self.title)

    @property
    def result(self) -> str | None:
        if self.state != "done":
            return None
        if self.recorded_result:
            return self.recorded_result
        if self.notes and self.notes[-1] == "discarded":
            return "dropped"
        if re.search(r"(?:\(|,\s*)(?:merged|reported) \d{4}-\d{2}-\d{2}(?:[,)])", self.title):
            return "accepted"
        title = re.sub(r"(?:\s+\([^()]*\))+$", "", self.title)
        if title.endswith(" local main") or self.notes and self.notes[-1] == "local main":
            return "accepted"
        return None


def read_record(path: Path) -> str | None:
    try:
        if not path.is_symlink() and path.is_file():
            return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        pass
    return None


def markdown_backlog_rows(data: Path) -> dict[str, BacklogRow]:
    rows = {}
    for name in ("done-archive.md", "backlog.md"):
        section = "done" if name == "done-archive.md" else ""
        current = None
        for line in (read_record(data / name) or "").splitlines():
            match = BACKLOG_ROW.match(line)
            if line.startswith("## "):
                section = line[3:].strip().lower()
                current = None
            elif match and section in {"done", "in flight", "queued"}:
                task = match[1] or match[2]
                current = BacklogRow(section, match[3])
                rows[task] = current
            elif current and line.startswith((" ", "\t")) and line.strip():
                current.notes.append(line.strip())
            elif line.strip():
                current = None
    return rows


def lean_backlog_rows(data: Path) -> dict[str, BacklogRow]:
    store = Path(__file__).with_name("fm-backlog-md") / "store.cjs"
    reader = r"""
const { board, projectTask, sectionBody } = require(process.argv[1]);
const { tickets } = board(process.argv[2]);
const now = new Date().toISOString();
const rows = Array.from(tickets.values(), ticket => {
  const task = projectTask(ticket, tickets, now);
  const notes = sectionBody(ticket, 'finalSummary').trim().split('\n');
  const pr = task.links.find(link => link.kind === 'pr')?.url ?? null;
  const report = task.links.some(link => link.kind === 'report' && link.url === 'data/' + task.id + '/report.md');
  const result = task.state !== 'done' ? null :
    notes.includes('discarded') ? 'dropped' :
    pr || report || notes.includes('local main') ? 'accepted' : null;
  return [task.id, task.state, task.kind, task.repo, result, pr];
});
process.stdout.write(JSON.stringify(rows));
"""
    try:
        raw = subprocess.check_output(["node", "-e", reader, store, data], text=True,
                                      timeout=10, stderr=subprocess.PIPE)
        return {task: BacklogRow(state, "", recorded_kind=kind, recorded_repo=repo,
                                 recorded_result=result, recorded_pr=pr)
                for task, state, kind, repo, result, pr in json.loads(raw)}
    except (OSError, ValueError, subprocess.SubprocessError):
        print("fm-task-record: Backlog.md could not be read; backlog fields may be missing", file=sys.stderr)
        return {}


def backlog_rows(data: Path, config: Path) -> dict[str, BacklogRow]:
    if (read_record(config / "backlog-backend") or "").strip() == "backlog-md":
        return lean_backlog_rows(data)
    return markdown_backlog_rows(data)


def fields(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in (read_record(path) or "").splitlines() if "=" in line)


def archived_results(state: Path) -> dict[str, dict[str, str]]:
    results = {}
    archive = state / "status-archive"
    if archive.is_symlink():
        return results
    for path in archive.glob("*/result"):
        if path.parent.is_symlink():
            continue
        record = fields(path)
        if record.get("kind") in {"ship", "scout"} and record.get("result") in RESULTS:
            results[path.parent.name] = record
    return results


def brief_birth(path: Path) -> int | None:
    try:
        birth = getattr(path.stat(), "st_birthtime", None)
        if birth is None:
            birth = int(subprocess.check_output(
                ["stat", "-c", "%W", "--", path], text=True, stderr=subprocess.DEVNULL, timeout=3
            ))
        return int(birth) if birth > 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


@dataclass(frozen=True)
class Event:
    verb: str
    at: int | None
    key: str | None
    body: str


def events_for(path: Path) -> list[Event]:
    events = []
    for line in (read_record(path) or "").splitlines():
        header = STATUS_HEADER.match(line)
        if not header:
            continue
        stamps = STAMP.findall(header[0])
        key = re.search(r"\[key=([A-Za-z0-9._-]+)\]", header[0])
        events.append(Event(header[1], int(stamps[0]) if len(stamps) == 1 else None,
                            key[1] if key else None, line[header.end():].strip()))
    return events


def stop_index(events: list[Event]) -> int | None:
    done = next((i for i, e in enumerate(events) if e.verb == "done"), None)
    return done if done is not None else next((i for i, e in enumerate(events) if e.verb in TERMINAL), None)


def timing(events: list[Event], start: int | None) -> dict[str, int]:
    if start is None or not events or events[-1].at is None:
        return {}
    durations = dict.fromkeys(BUCKETS, 0)
    bucket, opened_key, last = "working_s", None, start
    for event in events:
        if event.verb not in WAIT_BUCKET and event.verb not in {"working", "resolved", *TERMINAL}:
            continue
        if event.at is None or event.at < last:
            return {}
        durations[bucket] += event.at - last
        last = event.at
        if event.verb in WAIT_BUCKET:
            bucket, opened_key = WAIT_BUCKET[event.verb], event.key
        elif event.verb == "working" or (event.verb == "resolved" and opened_key == event.key):
            bucket, opened_key = "working_s", None
    return {**durations, "elapsed_s": last - start}


def status_paths(state: Path, data: Path) -> dict[str, list[Path]]:
    sources = defaultdict(list)
    for path in sorted((state / "status-archive").glob("*/*.status")):
        sources[path.parent.name].append(path)
    for path in sorted(data.glob("*/status*.log")):
        if re.fullmatch(r"status(?:\.[0-9]+)?\.log", path.name):
            sources[path.parent.name].append(path)
    for path in sorted(state.glob("*.status")):
        sources[path.stem].append(path)
    return sources


def status_score(events: list[Event]) -> tuple[int, int]:
    return max((e.at or 0 for e in events), default=0), len(events)


def epoch(value: str) -> float | None:
    try:
        at = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return at.timestamp() if at.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


def spawn_epoch(generation: str) -> int | None:
    match = re.fullmatch(r"s([1-9][0-9]{0,11})\.[A-Za-z0-9._-]+", generation)
    return int(match[1]) if match else None


def generations(state: Path) -> dict[str, set[str]]:
    by_task = defaultdict(set)
    for path in (state / "terminal-outcomes").glob("*"):
        receipt = fields(path)
        if receipt.get("schema") == "fm-terminal-outcome.v1" and receipt.get("task_id"):
            by_task[receipt["task_id"]].add(receipt.get("incarnation", ""))
    return by_task


def relaunch_count(meta: dict[str, str], receipts: set[str], start: int | None,
                   stop: int | None) -> str | int | None:
    current, first = meta.get("spawn_gen", ""), meta.get("first_spawn_gen", "")
    recorded = {gen for gen in (current, first) if spawn_epoch(gen) is not None}
    if start is not None and stop is not None:
        recorded.update(gen for gen in receipts if (stamp := spawn_epoch(gen)) and start <= stamp <= stop)
    if len(recorded) > 1:
        return f">={len(recorded) - 1}"
    if not first and current in recorded and stop is not None and spawn_epoch(current) <= stop:
        return 0
    return None


def steer_count(inbox: Path, stop: int | None) -> int | None:
    if stop is None or inbox.is_symlink() or not inbox.is_dir():
        return None
    stamps = {}
    for path in [*inbox.glob("*.msg"), *(inbox / "handled").glob("*.msg")]:
        if not re.fullmatch(r"[0-9]+\.msg", path.name):
            continue
        record = read_record(path)
        header, sep, _ = (record or "").partition("\n--\n")
        if not sep:
            return None
        values = dict(line.split("=", 1) for line in header.splitlines() if "=" in line)
        stamps[path.name] = epoch(values.get("at", ""))
    if None in stamps.values():
        return None
    return sum(at <= stop for at in stamps.values())


TOKEN_KEYS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens")


def spend_by_task(data: Path) -> dict[str, list[dict]]:
    records = defaultdict(list)
    for line in (read_record(data / "pipeline-spend.jsonl") or "").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and isinstance(row.get("task"), str) and row.get("source") == "no-mistakes-state":
            records[row["task"]].append(row)
    return records


def pipeline_spend(records: list[dict], run_ids: set[str], generation: str,
                   start: int | None, stop: int | None) -> dict:
    matching = []
    for record in records:
        runs, total = record.get("runs"), record.get("total")
        if not isinstance(runs, list) or not isinstance(total, dict) or not isinstance(total.get("invocations"), int):
            continue
        ids = {run["id"] for run in runs if isinstance(run, dict) and isinstance(run.get("id"), str)}
        recorded_gen = record.get("spawn_gen")
        born = spawn_epoch(recorded_gen) if isinstance(recorded_gen, str) else None
        if run_ids:
            match = run_ids == ids
        elif generation:
            match = recorded_gen == generation
        else:
            match = born is not None and start is not None and stop is not None and start <= born <= stop
        if match:
            matching.append(total)
    if len(matching) != 1:
        return {}
    total = matching[0]
    tokens = {}
    for key in TOKEN_KEYS:
        count = total.get(key)
        if not isinstance(count, dict):
            continue
        value, unknown = count.get("total"), count.get("unknown")
        if isinstance(value, int) and isinstance(unknown, int) and 0 <= unknown < total["invocations"]:
            tokens[f"pipeline_{key}"] = f">={value}" if unknown else value
    return tokens


def open_run_db(path: Path) -> sqlite3.Connection | None:
    try:
        if path.is_file():
            return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
    except sqlite3.Error:
        pass
    return None


def run_rounds(db: sqlite3.Connection | None, pr: str | None, meta: dict[str, str],
               start: int | None, stop: int | None) -> tuple[set[str], dict]:
    if db is None:
        return set(), {}
    try:
        runs = set()
        if pr:
            runs.update(row[0] for row in db.execute("SELECT id FROM runs WHERE pr_url = ?", (pr,)))
        if meta.get("branch") and meta.get("project") and start is not None and stop is not None:
            runs.update(row[0] for row in db.execute(
                "SELECT runs.id FROM runs JOIN repos ON runs.repo_id = repos.id "
                "WHERE repos.working_path = ? AND runs.branch = ? AND runs.created_at BETWEEN ? AND ? "
                "AND (coalesce(runs.pr_url, '') = '' OR ? IS NULL OR runs.pr_url = ?)",
                (meta["project"], meta["branch"], start, stop, pr, pr)))
    except sqlite3.Error:
        return set(), {}
    if not runs:
        return runs, {}
    review = fix = 0
    try:
        for run in runs:
            counts = db.execute(
                "SELECT count(CASE WHEN s.step_name = 'review' THEN 1 END), "
                "count(CASE WHEN r.trigger_type = 'auto_fix' THEN 1 END) "
                "FROM step_rounds r JOIN step_results s ON r.step_result_id = s.id WHERE s.run_id = ?",
                (run,)).fetchone()
            review += counts[0]
            fix += counts[1]
    except sqlite3.Error:
        return runs, {}
    return runs, {"review_rounds": review, "pipeline_fix_rounds": fix}


def pr_in(text: str) -> str | None:
    match = PR_URL.search(text)
    return match[0] if match else None


def task_record(task: str, paths: list[Path], state: Path, data: Path,
                backlog: BacklogRow | None, receipts: set[str], spend: list[dict],
                db: sqlite3.Connection | None, archived: dict[str, str]) -> dict | None:
    live = state / f"{task}.status"
    meta = fields(state / f"{task}.meta")
    streams = [(path, events_for(path)) for path in paths]
    live_events = next((events for path, events in streams if path == live), [])
    if meta and (live_events or archived):
        archived = {}
        path, events = live, live_events
        if not any(e.verb in TERMINAL for e in live_events):
            return None
    else:
        path, events = max(streams, key=lambda stream: (status_score(stream[1]), stream[0] == live),
                           default=(None, []))
    stop = stop_index(events)
    if stop is None and not archived and (
        not backlog or backlog.state != "done" or backlog.kind not in {"ship", "scout"}
    ):
        return None
    meta = meta if path == live or path is None else {}
    brief_path = data / task / "brief.md"
    brief = read_record(brief_path) or ""
    setup = brief.partition("\n# Setup\n")[2].partition("\n# Rules\n")[0]
    mode = re.search(r"^Delivery contract: mode=(\S+)", brief, re.MULTILINE)
    project = re.search(r"^You are in a disposable git worktree of (.+), at a detached HEAD", setup, re.MULTILINE)
    kind = archived.get("kind") or meta.get("kind") or (backlog.kind if backlog else None)
    if not kind:
        kind = "scout" if "\nThis is a SCOUT task:" in setup else "ship" if mode else None
    if kind == "secondmate":
        return None

    measured = events[:stop + 1] if stop is not None else []
    end = measured[-1] if measured else None
    result = backlog.result if backlog else None
    if end and end.verb in {"dropped", "cancelled"}:
        result = "dropped"
    elif end and end.verb == "failed" and result != "dropped":
        result = "failed"
    pr = (pr_in(end.body) if end and end.verb == "done" else None) or meta.get("pr")
    backlog_pr = backlog.pr if backlog else None
    if pr and backlog_pr and pr != backlog_pr:
        result = None if result == "accepted" else result
    if archived:
        result = archived["result"] if archived["result"] != "missing" else None
    start = brief_birth(brief_path) if brief else None
    stop_at = end.at if end else None
    attribution_pr = pr or (backlog_pr if result == "accepted" else None)
    run_ids, rounds = run_rounds(db, attribution_pr, meta, start, stop_at)
    return {
        "id": task, "kind": kind,
        "repo": (backlog.repo if backlog else None)
        or (Path(meta["project"]).name if meta.get("project") else None) or (project[1] if project else None),
        "mode": archived.get("mode") or meta.get("mode") or (mode[1] if mode else None),
        "size_band": meta.get("size_band") or (backlog.tag("size-band") if backlog else None),
        "result": result, **timing(measured, start),
        "blockers": sum(e.verb == "blocked" for e in measured) if measured else None,
        "decisions": sum(e.verb == "needs-decision" for e in measured) if measured else None,
        "steers": steer_count(state / f"{task}.inbox", stop_at) if path == live else None,
        "relaunches": relaunch_count(meta, receipts, start, stop_at),
        "pr": pr or backlog_pr, **rounds,
        **pipeline_spend(spend, run_ids, meta.get("spawn_gen", ""), start, stop_at),
    }


def print_table(columns: tuple[str, ...], rows: list[dict]) -> None:
    print("\t".join(columns))
    for row in rows:
        print("\t".join("missing" if row.get(key) is None else
                        str(row[key]).replace("\t", " ").replace("\n", " ").replace("\r", " ")
                        for key in columns))


def aggregate(rows: list[dict]) -> None:
    counts = Counter(row["result"] for row in rows)
    complete = [row for row in rows if row.get("elapsed_s") is not None]
    bad = counts["failed"] + counts["dropped"]
    known = len(rows) - counts[None]
    print(f"Cases: {len(rows)} ({counts['accepted']} accepted, {counts['failed']} failed, "
          f"{counts['dropped']} dropped, {counts[None]} missing result)")
    print(f"Failed or dropped: {bad}/{known} ({bad / known:.1%}) of known results" if known else
          "Failed or dropped: missing (no known results)")
    print(f"Cases with timing: {len(complete)}/{len(rows)}")
    if len(complete) < MIN_CASES:
        print(f"No time range: at least {MIN_CASES} cases with timing are required.")
        return
    summaries = []
    for metric in ("working_s", "elapsed_s"):
        values = sorted(row[metric] for row in complete)
        summaries.append({"metric": metric, "median": statistics.median(values),
                          "p90": values[math.ceil(0.9 * len(values)) - 1]})
    print_table(("metric", "median", "p90"), summaries)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="fm-task-record.sh",
        description="Read this Firstmate home's retained task records without changing them.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""FM_HOME selects the home. FM_STATE_OVERRIDE and FM_DATA_OVERRIDE select
the record directories. FM_CONFIG_OVERRIDE selects the config directory.
Output is tab-separated. Filters match exactly. One row is shown per
retained task ID, using the latest retained status log.

The clock starts at brief creation and stops at the first done line, or
the first failure or drop when there is no done line. Durations are seconds.
Paused time counts as pipeline wait. A decision, a block, and active work
each have their own bucket. Untimed transitions make timing missing.
The cleanup result takes priority over older evidence, even if it is missing.
For tasks without a cleanup result, the command checks the status and backlog.
A done line alone does not prove acceptance.
Aggregate uses all matching timed cases, including failed and dropped
cases, and reports timing coverage. Use --result accepted for accepted cases
only. P90 uses the nearest rank.
Review rounds and pipeline fix rounds come from no-mistakes. Pipeline
token counts come from the optional spend ledger. They exclude worker
tokens and do not estimate cost. >= marks a recorded lower bound.""")
    parser.add_argument("--aggregate", action="store_true", help="summarize the matching cases")
    parser.add_argument("--nm-db", type=Path, help="no-mistakes database (default: NM_HOME/state.sqlite)")
    parser.add_argument("--result", choices=RESULTS, help="include only cases with this result")
    for name in ("kind", "repo", "mode", "size-band"):
        parser.add_argument(f"--{name}")
    args = parser.parse_args()
    home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or Path(__file__).resolve().parents[1])
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state")
    data = Path(os.environ.get("FM_DATA_OVERRIDE") or home / "data")
    if not state.is_dir() and not data.is_dir():
        parser.error(f"no state or data directory in {home}")
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or home / "config")
    backlog = backlog_rows(data, config)
    paths = status_paths(state, data)
    results = archived_results(state)
    receipts = generations(state)
    spend = spend_by_task(data)
    filters = {key: getattr(args, key) for key in ("kind", "repo", "mode", "size_band")}
    rows = []
    db_path = args.nm_db or Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes") / "state.sqlite"
    db = open_run_db(db_path)
    try:
        for task in sorted(paths.keys() | backlog.keys() | results.keys()):
            if not TASK_ID.fullmatch(task):
                continue
            row = task_record(task, paths.get(task, []), state, data, backlog.get(task),
                              receipts.get(task, set()), spend.get(task, []), db, results.get(task, {}))
            if row and args.result and (row["result"] or "missing") != args.result:
                continue
            if row and all(value is None or row.get(key) == value for key, value in filters.items()):
                rows.append(row)
    finally:
        if db is not None:
            db.close()
    if args.aggregate:
        aggregate(rows)
    else:
        print_table(("id", "kind", "repo", "mode", "size_band", "result", *BUCKETS, "elapsed_s",
                     "steers", "blockers", "decisions", "relaunches", "review_rounds", "pipeline_fix_rounds",
                     *(f"pipeline_{key}" for key in TOKEN_KEYS), "pr"), rows)


if __name__ == "__main__":
    main()
