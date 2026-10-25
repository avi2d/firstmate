#!/usr/bin/env python3
# Usage: fm-day-review.py collect|merge|render ...; bin/fm-day-review.sh owns the contract.
from __future__ import annotations

import argparse
import glob
import html
import json
import os
import re
import socket
import sqlite3
import statistics
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime, timedelta
from datetime import time as dt_time
from pathlib import Path
from zoneinfo import ZoneInfo

COLLECT_SCHEMA = "fm-day-review-collect.v1"
NUMBERS_SCHEMA = "fm-day-review-numbers.v1"
NOTES_SCHEMA = "fm-day-review-notes.v1"

# Dollars per million tokens: input, output, cache read, cache write.
LIST_PRICES = {
    "claude-opus-5-5": (4.0, 20.0, 0.2, 5.0),
    "claude-sonnet-5-5": (2.0, 10.0, 0.1, 2.5),
    "claude-haiku-5-5": (0.1, 0.5, 0.01, 0.125),
    "claude-fable-5-1": (10.0, 50.0, 0.25, 12.5),
}
HAIKU_LONG_PROMPT = 100000
HAIKU_LONG_PRICES = (0.5, 2.5, 0.05, 0.625)

LONG_CONVERSATION_TURNS = 400
STEER_RERING_SECONDS = 120
# A finished task id that goes quiet this long and then speaks again is a new task.
REUSED_ID_GAP = 6 * 3600
STATUS_HEAD = re.compile(r"^([a-z][a-z-]*)\b")
STATUS_AT = re.compile(r"\[at=([1-9][0-9]{0,11})\]")
INBOX_BRIEF = re.compile(r"steering inbox is \x60([^\x60]+)/state/([A-Za-z0-9._-]+)\.inbox\x60")
DOORBELL = "Firstmate instruction waiting"
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
EVENT_TEXT_STATES = ("needs-decision", "blocked", "failed", "done")
BUCKETS = ("working", "decision", "checks", "merge", "restart")
STATE_BUCKET = {
    "needs-decision": "decision",
    "blocked": "decision",
    "captain-held": "decision",
    "paused": "checks",
    "waiting": "checks",
    "awaiting": "checks",
    "parked": "checks",
}
FIX_STEPS = ("review", "ci", "lint", "test", "document", "rebase")
USAGE_KEYS = ("turns", "input", "output", "cacheRead", "cacheWrite")

METRICS = {
    "tasks_finished": "tasks finished",
    "usd_total": "API price of the day in dollars",
    "usd_per_task": "API price per finished task in dollars",
    "max_task_usd": "price of the costliest task in dollars",
    "supervisor_usd": "supervisor price in dollars",
    "median_task_minutes": "median minutes from start to finish",
    "decision_wait_minutes": "minutes waiting on a decision",
    "checks_wait_minutes": "minutes waiting on checks or a slot",
    "merge_wait_minutes": "minutes from done to merged",
    "restart_minutes": "minutes lost to restarts",
    "restarts": "worker restarts",
    "long_conversations": "worker conversations over 400 turns",
    "long_conversation_usd": "price of conversations over 400 turns",
    "cache_read_share": "percent of tokens that were cache rereads",
    "review_errors": "review findings of error severity",
    "review_fix_rounds": "review fix rounds",
    "ci_fix_rounds": "failed CI rounds before green",
    "lint_fix_rounds": "lint fix rounds",
    "test_fix_rounds": "test fix rounds",
    "worker_questions": "worker questions",
    "steers": "steering messages to workers",
}
AREAS = ("speed", "cost", "quality")
BANNED_PROSE = (
    ("\u2014", "an em dash"),
    ("\u2013", "an en dash"),
    (" - ", "a hyphen used as a dash"),
    ("(", "a parenthesis"),
    (")", "a parenthesis"),
)


def die(message: str, code: int = 1):
    print("fm-day-review: " + message, file=sys.stderr)
    raise SystemExit(code)


def iso_epoch(value: str) -> float | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def zero_usage() -> dict:
    return dict.fromkeys(USAGE_KEYS, 0)


def add_usage(into: dict, usage: dict) -> None:
    for key in USAGE_KEYS:
        into[key] = into.get(key, 0) + int(usage.get(key, 0) or 0)


def usage_tokens(usage: dict) -> int:
    return sum(int(usage.get(k, 0) or 0) for k in ("input", "output", "cacheRead", "cacheWrite"))


def bare_model(model: str) -> str:
    return (model or "").split("/")[-1]


def message_price(model: str, usage: dict) -> float | None:
    rates = LIST_PRICES.get(bare_model(model))
    if rates is None:
        return None
    prompt = usage["input"] + usage["cacheRead"] + usage["cacheWrite"]
    if bare_model(model) == "claude-haiku-5-5" and prompt > HAIKU_LONG_PROMPT:
        rates = HAIKU_LONG_PRICES
    return (
        usage["input"] * rates[0]
        + usage["output"] * rates[1]
        + usage["cacheRead"] * rates[2]
        + usage["cacheWrite"] * rates[3]
    ) / 1e6


def model_slot(models: dict, model: str, provider: str) -> dict:
    return models.setdefault(
        model, {"provider": provider, "all": zero_usage(), "window": zero_usage(), "usdAll": 0.0, "usdWindow": 0.0}
    )


def charge(slot: dict, model: str, turn: dict, in_window: bool) -> None:
    price = message_price(model, turn)
    add_usage(slot["all"], turn)
    if price is not None:
        slot["usdAll"] += price
    if in_window:
        add_usage(slot["window"], turn)
        if price is not None:
            slot["usdWindow"] += price


def parse_status_line(line: str) -> tuple[str, int, str] | None:
    if ":" not in line:
        return None
    head, text = line.split(":", 1)
    verb = STATUS_HEAD.match(head.split("[", 1)[0].strip())
    stamps = STATUS_AT.findall(head)
    if not verb or len(stamps) != 1:
        return None
    return verb.group(1), int(stamps[0]), text.strip()


def status_streams(home: Path) -> dict[str, list[Path]]:
    state, data = home / "state", home / "data"
    paths = glob.glob(str(state / "status-archive" / "*" / "*.status"))
    paths += glob.glob(str(data / "*" / "status.log")) + glob.glob(str(data / "*" / "status.[0-9]*.log"))
    by_task: dict[str, list[Path]] = {}
    for path in sorted(paths):
        by_task.setdefault(Path(path).parent.name, []).append(Path(path))
    for path in sorted(glob.glob(str(state / "*.status"))):
        by_task.setdefault(Path(path).name[: -len(".status")], []).append(Path(path))
    return {task: files for task, files in by_task.items() if TASK_ID.match(task)}


def final_segment(files: list[Path]) -> tuple[list[dict], float]:
    seen, events = set(), []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            parsed = parse_status_line(line)
            if not parsed or parsed in seen:
                continue
            seen.add(parsed)
            state, at, body = parsed
            events.append({"state": state, "at": at, "text": body[:240] if state in EVENT_TEXT_STATES else ""})
    events.sort(key=lambda e: e["at"])
    ends = [i for i, e in enumerate(events) if e["state"] in ("done", "failed")]
    if not ends:
        return [], 0
    last = ends[-1]
    start, floor = 0, 0
    for i in reversed(range(last)):
        if events[i]["state"] in ("done", "failed") and events[i + 1]["at"] - events[i]["at"] > REUSED_ID_GAP:
            start, floor = i + 1, events[i]["at"]
            break
    return events[start : last + 1], floor


def terminal_outcomes(home: Path) -> dict[str, dict]:
    found: dict[str, dict] = {}
    for path in glob.glob(str(home / "state" / "terminal-outcomes" / "*")):
        fields = {}
        try:
            for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
                key, sep, value = line.partition("=")
                if sep:
                    fields[key] = value
        except OSError:
            continue
        task = fields.get("task_id", "")
        if not task:
            continue
        entry = found.setdefault(task, {"incarnations": {}, "pr": ""})
        spawn = re.match(r"^s([1-9][0-9]{0,11})\.", fields.get("incarnation", ""))
        if spawn:
            entry["incarnations"][fields["incarnation"]] = int(spawn.group(1))
        if fields.get("pr"):
            entry["pr"] = fields["pr"]
    return found


def merge_times(home: Path) -> dict[str, list[float]]:
    merged: dict[str, list[float]] = {}
    try:
        lines = (home / "state" / "merge-on-green.log").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return merged
    for line in lines:
        parts = line.split(" ", 3)
        if len(parts) >= 3 and parts[2] == "merged":
            at = iso_epoch(parts[0])
            if at is not None:
                merged.setdefault(parts[1], []).append(at)
    return merged


def backlog_record(bin_dir: Path, home: Path, task: str) -> dict:
    tool = bin_dir / "fm-tasks-axi.sh"
    if not tool.is_file():
        return {}
    try:
        out = subprocess.run(
            [str(tool), "show", task, "--full"],
            env=dict(os.environ, FM_HOME=str(home)),
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    record = {}
    for line in out.splitlines():
        match = re.match(r"^  (title|kind|repo|links): (.*)$", line)
        if match:
            value = match.group(2)
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
            record[match.group(1)] = value
    return record


def message_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def session_head(path: Path) -> tuple[str, str]:
    cwd, brief = "", ""
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for index, line in enumerate(handle):
                if index > 200:
                    break
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if index == 0:
                    cwd = entry.get("cwd", "") or ""
                    continue
                message = entry.get("message") or {}
                if entry.get("type") == "message" and message.get("role") == "user":
                    brief = message_text(message)
                    break
    except OSError:
        pass
    return cwd, brief


def real(path: str) -> str:
    return os.path.realpath(path) if path else ""


def scan_session(path: Path, since: float, until: float) -> dict:
    models: dict[str, dict] = {}
    steers, last_bell = 0, None
    first = last = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if '"usage"' not in line and DOORBELL not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            message = entry.get("message") or {}
            at = iso_epoch(entry.get("timestamp", ""))
            if entry.get("type") != "message" or at is None or at >= until:
                continue
            if message.get("role") == "user":
                if DOORBELL in message_text(message)[:120]:
                    if last_bell is None or at - last_bell > STEER_RERING_SECONDS:
                        steers += 1
                    last_bell = at
                continue
            usage = message.get("usage")
            if message.get("role") != "assistant" or not isinstance(usage, dict):
                continue
            first = at if first is None else min(first, at)
            last = at if last is None else max(last, at)
            model = bare_model(message.get("model", "")) or "unknown"
            turn = {
                "turns": 1,
                "input": int(usage.get("input", 0) or 0),
                "output": int(usage.get("output", 0) or 0),
                "cacheRead": int(usage.get("cacheRead", 0) or 0),
                "cacheWrite": int(usage.get("cacheWrite", 0) or 0),
            }
            charge(model_slot(models, model, message.get("provider", "")), model, turn, at >= since)
    return {"models": models, "steers": steers, "first": first, "last": last}


def collect_sessions(home: Path, roots: list[str], scan_from: float, since: float, until: float, nm_root: str) -> list[dict]:
    home_real = real(str(home))
    nm_worktrees = real(os.path.join(nm_root, "worktrees")) + os.sep
    records = []
    for root in roots:
        for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
            file = Path(path)
            try:
                if file.stat().st_mtime < scan_from:
                    continue
            except OSError:
                continue
            cwd, brief = session_head(file)
            if real(cwd).startswith(nm_worktrees):
                continue
            role, task = "", ""
            inbox = INBOX_BRIEF.search(brief)
            if inbox and real(inbox.group(1)) == home_real:
                role, task = "worker", inbox.group(2)
            elif cwd and real(cwd) == home_real:
                role = "supervisor"
            if not role:
                continue
            try:
                scanned = scan_session(file, since, until)
            except OSError:
                continue
            if scanned["models"]:
                records.append({"file": real(path), "role": role, "task": task, **scanned})
    return records


def collect_runs(db_path: Path, scan_from: float, since: float, until: float) -> tuple[list[dict], str]:
    if not db_path.is_file():
        return [], "no-mistakes database not found at " + str(db_path)
    runs = []
    try:
        with closing(sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
            db.row_factory = sqlite3.Row
            for run in db.execute(
                "select id, branch, status, pr_url, created_at from runs where updated_at >= ? and created_at < ?",
                (int(scan_from), int(until)),
            ):
                record = {
                    "id": run["id"],
                    "branch": run["branch"] or "",
                    "status": run["status"] or "",
                    "pr": run["pr_url"] or "",
                    "created": run["created_at"],
                    "findings": {},
                    "findingFiles": [],
                    "fixRounds": {},
                    "models": {},
                }
                seen = set()
                for row in db.execute(
                    "select sr.step_name, r.trigger_type, r.findings_json from step_rounds r"
                    " join step_results sr on sr.id = r.step_result_id where sr.run_id = ? order by r.round",
                    (run["id"],),
                ):
                    step = row["step_name"]
                    if row["trigger_type"] == "auto_fix":
                        record["fixRounds"][step] = record["fixRounds"].get(step, 0) + 1
                    try:
                        findings = json.loads(row["findings_json"] or "{}").get("findings") or []
                    except (ValueError, AttributeError):
                        continue
                    for finding in findings:
                        if not isinstance(finding, dict):
                            continue
                        key = (step, finding.get("id"), str(finding.get("description", ""))[:200])
                        severity = finding.get("severity")
                        if key in seen or severity not in ("error", "warning", "info"):
                            continue
                        seen.add(key)
                        counts = record["findings"].setdefault(step, {"error": 0, "warning": 0, "info": 0})
                        counts[severity] += 1
                        if step == "review" and severity != "info" and finding.get("file"):
                            record["findingFiles"].append(str(finding["file"]))
                for row in db.execute(
                    "select model, fresh_input_tokens, cache_read_tokens, cache_creation_tokens, output_tokens, started_at"
                    " from agent_invocations where run_id = ?",
                    (run["id"],),
                ):
                    model = bare_model(row["model"] or "") or "unknown"
                    cache_write = int(row["cache_creation_tokens"] or 0)
                    turn = {
                        "turns": 1,
                        "input": max(int(row["fresh_input_tokens"] or 0) - cache_write, 0),
                        "output": int(row["output_tokens"] or 0),
                        "cacheRead": int(row["cache_read_tokens"] or 0),
                        "cacheWrite": cache_write,
                    }
                    charge(model_slot(record["models"], model, ""), model, turn, since <= (row["started_at"] or 0) < until)
                runs.append(record)
    except sqlite3.Error as error:
        return runs, "no-mistakes database unreadable: " + str(error)
    return runs, ""


def collect(args: argparse.Namespace) -> None:
    home = Path(args.home)
    since, until = float(args.since), float(args.until)
    if not (home / "state").is_dir():
        die("home has no state directory: " + str(home))
    outcomes = terminal_outcomes(home)
    merged = merge_times(home)
    tasks = []
    for task, files in status_streams(home).items():
        events, floor = final_segment(files)
        if not events or not (since <= events[-1]["at"] < until):
            continue
        if task not in outcomes and not (home / "data" / task / "brief.md").is_file():
            continue
        outcome = outcomes.get(task, {"incarnations": {}, "pr": ""})
        spawns = [at for at in outcome["incarnations"].values() if floor < at <= events[-1]["at"]]
        record = backlog_record(Path(args.bin), home, task)
        pr = outcome["pr"]
        if not pr:
            link = re.search(r"pr:(https://\S+)", record.get("links", ""))
            pr = link.group(1).rstrip(",") if link else ""
        merges = [at for at in merged.get(task, []) if at >= events[-1]["at"] - 3600]
        tasks.append(
            {
                "id": task,
                "title": record.get("title", "") or task,
                "kind": record.get("kind", ""),
                "project": record.get("repo", "").split("/")[-1],
                "pr": pr,
                "incarnations": len(spawns),
                "spawnedAt": min(spawns) if spawns else None,
                "outcome": events[-1]["state"],
                "mergedAt": min(merges) if merges else None,
                "events": events,
            }
        )
    scan_from = min([since] + [t["spawnedAt"] or t["events"][0]["at"] for t in tasks])
    nm_root = os.path.dirname(args.nm_db)
    sessions = collect_sessions(home, args.session_root or [], scan_from, since, until, nm_root)
    runs, run_gap = collect_runs(Path(args.nm_db), scan_from, since, until)
    json.dump(
        {
            "schema": COLLECT_SCHEMA,
            "host": args.host or socket.gethostname(),
            "home": real(str(home)),
            "since": since,
            "until": until,
            "tasks": tasks,
            "sessions": sessions,
            "runs": runs,
            "gaps": [run_gap] if run_gap else [],
        },
        sys.stdout,
        separators=(",", ":"),
    )
    sys.stdout.write("\n")


def clean(text: str) -> str:
    text = re.sub(r"\s*[—–]\s*|\s+-\s+", ", ", str(text))
    return re.sub(r"\s*[()]\s*", " ", text).strip()


def prose_problems(texts: list[str]) -> list[str]:
    return [f"{name} in: {text}" for text in texts for mark, name in BANNED_PROSE if mark in text]


def n_of(n: int, word: str, plural: str = "") -> str:
    return f"{n} {word}" if n == 1 else f"{n} {plural or word + 's'}"


def span(m: int) -> str:
    return f"{n_of(m, 'minute')} or about {round(m / 60)} hours" if m >= 120 else n_of(m, "minute")


def minutes(seconds: float) -> int:
    return int(round(max(seconds, 0) / 60))


def money(usd: float) -> str:
    return f"${usd:,.0f}" if usd >= 100 else f"${usd:,.2f}"


def count_tokens(n: int) -> str:
    for size, unit in ((1e9, " B"), (1e6, " M"), (1e3, " k")):
        if n >= size:
            return f"{n / size:.1f}{unit}"
    return str(n)


def overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def ids_list(ids: list[str]) -> str:
    shown = sorted(ids)[:4]
    more = len(ids) - len(shown)
    return ", ".join(shown) + (f" and {more} more" if more > 0 else "")


def task_start(task: dict, sessions: list[dict]) -> float:
    firsts = [s["first"] for s in sessions if s["first"] is not None]
    return min([task["events"][0]["at"], *firsts] + ([task["spawnedAt"]] if task.get("spawnedAt") else []))


def time_split(task: dict, sessions: list[dict], until: float) -> dict:
    start, end = task_start(task, sessions), task["events"][-1]["at"]
    events = [{"state": "working", "at": start}] + task["events"]
    gaps = []
    ordered = sorted((s for s in sessions if s["first"] is not None), key=lambda s: s["first"])
    for before, after in zip(ordered, ordered[1:]):
        if after["first"] > before["last"]:
            gaps.append((max(before["last"], start), min(after["first"], end)))
    split = dict.fromkeys(BUCKETS, 0.0)
    for here, nxt in zip(events, events[1:]):
        t0, t1 = here["at"], nxt["at"]
        lost = sum(overlap(t0, t1, g0, g1) for g0, g1 in gaps if g1 > g0)
        split["restart"] += lost
        split[STATE_BUCKET.get(here["state"], "working")] += (t1 - t0) - lost
    merged_at = task.get("mergedAt")
    if merged_at and merged_at > end:
        split["merge"] = min(merged_at, until) - end
    return {key: minutes(value) for key, value in split.items()}


def add_models(into: dict, models: dict, part: str) -> None:
    for model, slot in models.items():
        target = into.setdefault(model, {"usage": zero_usage(), "usd": 0.0, "priced": model in LIST_PRICES})
        add_usage(target["usage"], slot[part])
        target["usd"] += slot["usdAll" if part == "all" else "usdWindow"]


def priced_usd(models: dict) -> float:
    return sum(m["usd"] for m in models.values())


def all_tokens(models: dict) -> int:
    return sum(usage_tokens(m["usage"]) for m in models.values())


def unpriced(models: dict) -> dict:
    return {k: usage_tokens(v["usage"]) for k, v in models.items() if not v["priced"] and usage_tokens(v["usage"])}


def run_matches(run: dict, task_id: str, start: float) -> bool:
    branch = run["branch"]
    return (branch == task_id or branch.endswith("/" + task_id)) and run["created"] >= start - 600


def task_reasons(task: dict, median_minutes: float, median_usd: float) -> list[str]:
    reasons: list[tuple[float, str]] = []
    split = task["minutes"]
    if split["decision"] >= 15:
        reasons.append((split["decision"], f"{span(split['decision'])} waiting on a decision across {n_of(task['questions'], 'question')}"))
    if split["checks"] >= 15:
        reasons.append((split["checks"], f"{span(split['checks'])} waiting on checks or a free slot"))
    if task["restarts"]:
        reasons.append((split["restart"] + 30, f"{n_of(task['restarts'], 'restart')}, {span(split['restart'])} between conversations"))
    if split["merge"] >= 30:
        reasons.append((split["merge"], f"{span(split['merge'])} from done to merged"))
    if task["longestTurns"] > LONG_CONVERSATION_TURNS:
        reasons.append((task["longestTurns"] / 4, f"one conversation ran {task['longestTurns']} turns, {task['cacheShare']}% of its tokens were cache rereads"))
    if task["fixRounds"].get("review", 0) >= 2:
        reasons.append((task["fixRounds"]["review"] * 20, f"{n_of(task['fixRounds']['review'], 'review fix round')} with {n_of(task['review']['error'], 'error finding') if task['review']['error'] else 'no error findings'}"))
    if task["fixRounds"].get("ci", 0):
        reasons.append((task["fixRounds"]["ci"] * 20, f"CI failed {n_of(task['fixRounds']['ci'], 'time')} before green"))
    if task["steers"] >= 3:
        reasons.append((task["steers"] * 5, f"{n_of(task['steers'], 'steering message')}"))
    if split["working"] >= 60:
        reasons.append((split["working"] / 2, f"{span(split['working'])} of worker time"))
    if not reasons:
        return []
    flagged = task["totalMinutes"] >= max(60, 2 * median_minutes) or task["usd"] >= max(5, 2 * median_usd)
    return [text for _, text in sorted(reasons, key=lambda r: -r[0])[:3]] if flagged else []


def load_json(path: str | None, schema: str) -> dict | None:
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or data.get("schema") != schema:
        die(f"{path} is not a {schema} document")
    return data


def merge(args: argparse.Namespace) -> None:
    zone = ZoneInfo(args.zone)
    since, until = float(args.since), float(args.until)
    tasks, sessions, runs = [], {}, {}
    gaps = list(args.gap or [])
    labels = []
    for spec in args.inputs:
        label, sep, path = spec.partition("=")
        if not sep or not label:
            die("merge input must be label=path: " + spec, 2)
        data = load_json(path, COLLECT_SCHEMA)
        if data is None:
            die("missing collect output: " + path)
        labels.append(label)
        for gap in data.get("gaps", []):
            gaps.append(f"{label}: {gap}")
        for session in data["sessions"]:
            sessions.setdefault((data["host"], session["file"]), dict(session, label=label, home=data["home"]))
        for run in data["runs"]:
            runs.setdefault((data["host"], run["id"]), dict(run, host=data["host"], label=None))
        for task in data["tasks"]:
            tasks.append(dict(task, label=label, host=data["host"], home=data["home"]))

    finished = []
    for task in tasks:
        end = task["events"][-1]["at"]
        floor = (task.get("spawnedAt") or task["events"][0]["at"]) - REUSED_ID_GAP
        own = [
            s
            for (host, _), s in sessions.items()
            if host == task["host"] and s["role"] == "worker" and s["task"] == task["id"] and s["home"] == task["home"] and (s["last"] or 0) >= floor
        ]
        start = task_start(task, own)
        own_runs = [r for (host, _), r in runs.items() if host == task["host"] and r["label"] is None and run_matches(r, task["id"], start)]
        for run in own_runs:
            run["label"] = task["label"]
        models: dict = {}
        for session in own:
            add_models(models, session["models"], "all")
        pipeline: dict = {}
        for run in own_runs:
            add_models(pipeline, run["models"], "all")
            add_models(models, run["models"], "all")
        review = {"error": 0, "warning": 0, "info": 0}
        fix_rounds: dict = {}
        files: set = set()
        for run in own_runs:
            for severity, n in run["findings"].get("review", {}).items():
                review[severity] += n
            for step, n in run["fixRounds"].items():
                fix_rounds[step] = fix_rounds.get(step, 0) + n
            files.update(run["findingFiles"])
        longest = max(own, key=lambda s: sum(m["all"]["turns"] for m in s["models"].values()), default=None)
        longest_turns = sum(m["all"]["turns"] for m in longest["models"].values()) if longest else 0
        longest_tokens = sum(usage_tokens(m["all"]) for m in longest["models"].values()) if longest else 0
        longest_reads = sum(m["all"]["cacheRead"] for m in longest["models"].values()) if longest else 0
        split = time_split(task, own, until)
        finished.append(
            {
                "id": task["id"],
                "title": clean(task["title"]),
                "home": task["label"],
                "kind": task["kind"],
                "project": task["project"],
                "pr": task["pr"],
                "outcome": task["outcome"],
                "start": start,
                "end": end,
                "mergedAt": task.get("mergedAt"),
                "minutes": split,
                "totalMinutes": minutes(end - start),
                "restarts": max(task["incarnations"] - 1, len(own) - 1, 0),
                "questions": sum(1 for e in task["events"] if e["state"] == "needs-decision"),
                "questionTexts": [e["text"] for e in task["events"] if e["state"] == "needs-decision"],
                "steers": sum(s["steers"] for s in own),
                "sessions": len(own),
                "models": models,
                "pipelineUsd": priced_usd(pipeline),
                "usd": priced_usd(models),
                "tokens": all_tokens(models),
                "unpriced": unpriced(models),
                "longestTurns": longest_turns,
                "cacheShare": round(100 * longest_reads / longest_tokens) if longest_tokens else 0,
                "runs": [r["id"] for r in own_runs],
                "review": review,
                "fixRounds": fix_rounds,
                "reviewFiles": sorted(files),
            }
        )

    day_models: dict = {}
    by_home = {label: 0.0 for label in labels}
    price_rows: dict = {}
    supervisor_usd = 0.0
    long_sessions = []
    for (host, _), session in sessions.items():
        window: dict = {}
        add_models(window, session["models"], "window")
        add_models(day_models, session["models"], "window")
        usd = priced_usd(window)
        by_home[session["label"]] += usd
        if session["role"] == "supervisor":
            supervisor_usd += usd
            key = ("supervisor", session["label"])
            name = f"{session['label']}, supervision"
        else:
            key = ("task", session["label"], session["task"])
            name = session["task"]
        row = price_rows.setdefault(key, {"name": name, "home": session["label"], "usd": 0.0, "turns": 0, "models": set()})
        row["usd"] += usd
        row["turns"] += sum(m["usage"]["turns"] for m in window.values())
        row["models"].update(k for k, v in window.items() if v["usage"]["turns"])
        turns_all = sum(m["all"]["turns"] for m in session["models"].values())
        if session["role"] == "worker" and turns_all > LONG_CONVERSATION_TURNS and usd > 0:
            long_sessions.append({"task": session["task"], "turns": turns_all, "usd": usd})
    for (host, _), run in runs.items():
        window = {}
        add_models(window, run["models"], "window")
        if not all_tokens(window):
            continue
        add_models(day_models, run["models"], "window")
        usd = priced_usd(window)
        label = run["label"] or "work not yet finished"
        by_home[label] = by_home.get(label, 0.0) + usd
        key = ("pipeline", label)
        name = f"{label}, validation pipeline" if run["label"] else "validation of work not yet finished"
        row = price_rows.setdefault(key, {"name": name, "home": run["label"] or "", "usd": 0.0, "turns": 0, "models": set()})
        row["usd"] += usd
        row["turns"] += sum(m["usage"]["turns"] for m in window.values())
        row["models"].update(k for k, v in window.items() if v["usage"]["turns"])
    rows = sorted(
        ({**row, "models": sorted(row["models"])} for row in price_rows.values() if row["usd"] > 0.005),
        key=lambda r: -r["usd"],
    )

    day_usage = zero_usage()
    for slot in day_models.values():
        add_usage(day_usage, slot["usage"])
    day_tokens = usage_tokens(day_usage)
    usd_total = priced_usd(day_models)
    task_minutes = [t["totalMinutes"] for t in finished]
    task_usd = [t["usd"] for t in finished]
    median_minutes = statistics.median(task_minutes) if task_minutes else 0
    median_usd = statistics.median(task_usd) if task_usd else 0
    for task in finished:
        task["reasons"] = task_reasons(task, median_minutes, median_usd)

    def total(field: str, bucket: str | None = None) -> int:
        return sum((t[field][bucket] if bucket else t[field]) for t in finished)

    def rounds(step: str) -> int:
        return sum(t["fixRounds"].get(step, 0) for t in finished)

    metrics = {
        "tasks_finished": len(finished),
        "usd_total": round(usd_total, 2),
        "usd_per_task": round(sum(task_usd) / len(task_usd), 2) if task_usd else None,
        "max_task_usd": round(max(task_usd), 2) if task_usd else None,
        "supervisor_usd": round(supervisor_usd, 2),
        "median_task_minutes": median_minutes if task_minutes else None,
        "decision_wait_minutes": total("minutes", "decision"),
        "checks_wait_minutes": total("minutes", "checks"),
        "merge_wait_minutes": total("minutes", "merge"),
        "restart_minutes": total("minutes", "restart"),
        "restarts": total("restarts"),
        "long_conversations": len(long_sessions),
        "long_conversation_usd": round(sum(s["usd"] for s in long_sessions), 2),
        "cache_read_share": round(100 * day_usage["cacheRead"] / day_tokens) if day_tokens else None,
        "review_errors": sum(t["review"]["error"] for t in finished),
        "review_fix_rounds": rounds("review"),
        "ci_fix_rounds": rounds("ci"),
        "lint_fix_rounds": rounds("lint"),
        "test_fix_rounds": rounds("test"),
        "worker_questions": total("questions"),
        "steers": total("steers"),
    }

    unpriced_day = unpriced(day_models)
    if unpriced_day:
        names = ", ".join(sorted(k if k != "unknown" else "an unnamed model" for k in unpriced_day))
        gaps.append(f"{count_tokens(sum(unpriced_day.values()))} tokens on {names} have no list price and are left out of every price.")
    blind = [t["id"] for t in finished if not t["sessions"]]
    if blind:
        gaps.append(f"{n_of(len(blind), 'finished task')} {'has' if len(blind) == 1 else 'have'} no worker conversation log where {'it' if len(blind) == 1 else 'they'} ran, so {'its' if len(blind) == 1 else 'their'} tokens and restarts are missing: {ids_list(blind)}.")
    unmerged = [t["id"] for t in finished if t["pr"] and not t["mergedAt"]]
    if unmerged:
        gaps.append(f"{n_of(len(unmerged), 'task')} with a PR {'has' if len(unmerged) == 1 else 'have'} no automatic merge record, so {'its' if len(unmerged) == 1 else 'their'} wait to merge is not counted: {ids_list(unmerged)}.")
    gaps.append("Captain corrections and follow up fixes or reverts have no record yet, so quality leaves them out.")

    notes = load_json(args.notes, NOTES_SCHEMA) or {"schema": NOTES_SCHEMA, "reviews": [], "lessons": {}}
    day = datetime.fromtimestamp(until, zone).date().isoformat()
    numbers = {
        "schema": NUMBERS_SCHEMA,
        "day": day,
        "zone": args.zone,
        "since": since,
        "until": until,
        "generatedAt": time.time(),
        "homes": [{"label": k, "usd": round(v, 2)} for k, v in sorted(by_home.items(), key=lambda kv: -kv[1])],
        "models": {k: {"usd": round(v["usd"], 2), "priced": v["priced"], **v["usage"]} for k, v in day_models.items()},
        "dayUsage": day_usage,
        "priceRows": rows,
        "longConversations": long_sessions,
        "tasks": sorted(finished, key=lambda t: -t["usd"]),
        "metrics": metrics,
        "recommendations": recommendations(finished, metrics, long_sessions, usd_total),
        "previousAdvice": previous_advice(notes, day, metrics),
        "lessons": lessons_today(finished, notes, day),
        "gaps": gaps,
    }
    texts = [r["text"] for r in numbers["recommendations"]] + [p["text"] for p in numbers["previousAdvice"]]
    texts += [l["text"] for l in numbers["lessons"]] + [r for t in finished for r in t["reasons"]] + gaps
    problems = prose_problems(texts)
    if problems:
        die("generated prose breaks the board style: " + "; ".join(problems))
    json.dump(numbers, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")


def top_by(finished: list[dict], key) -> dict | None:
    best = max(finished, key=key, default=None)
    return best if best is not None and key(best) > 0 else None


def recommendations(finished: list[dict], metrics: dict, long_sessions: list[dict], usd_total: float) -> list[dict]:
    recs = []
    waits = {
        "decision": (metrics["decision_wait_minutes"], "decision_wait_minutes"),
        "checks": (metrics["checks_wait_minutes"], "checks_wait_minutes"),
        "merge": (metrics["merge_wait_minutes"], "merge_wait_minutes"),
        "restart": (metrics["restart_minutes"], "restart_minutes"),
    }
    bucket, (value, metric) = max(waits.items(), key=lambda kv: kv[1][0])
    worst = top_by(finished, lambda t: t["minutes"][bucket])
    if worst is None:
        recs.append({"area": "speed", "metric": None, "value": None, "text": "No finished task recorded a wait today, so there is no speed advice."})
    else:
        most = f"most on {worst['id']} at {n_of(worst['minutes'][bucket], 'minute')}"
        text = {
            "decision": f"Answer worker questions sooner. Finished work waited {span(value)} on a decision across {n_of(metrics['worker_questions'], 'question')}, {most}.",
            "checks": f"Find why workers sat {span(value)} waiting on checks or a free slot, {most}.",
            "merge": f"Merge finished PRs sooner. They waited {span(value)} from done to merged, {most}.",
            "restart": f"Find why workers restarted {n_of(metrics['restarts'], 'time')}, losing {span(value)} between conversations, {most}.",
        }[bucket]
        recs.append({"area": "speed", "metric": metric, "value": value, "text": text})

    options = []
    if long_sessions:
        share = round(100 * metrics["long_conversation_usd"] / usd_total) if usd_total else 0
        options.append(
            (
                metrics["long_conversation_usd"],
                {
                    "metric": "long_conversations",
                    "value": metrics["long_conversations"],
                    "text": f"Hand a worker over to a fresh conversation before 400 turns. {n_of(metrics['long_conversations'], 'conversation')} passed it and cost {money(metrics['long_conversation_usd'])}, {share}% of the day.",
                },
            )
        )
    if usd_total and metrics["supervisor_usd"]:
        share = round(100 * metrics["supervisor_usd"] / usd_total)
        options.append(
            (
                metrics["supervisor_usd"] if share >= 30 else 0,
                {
                    "metric": "supervisor_usd",
                    "value": metrics["supervisor_usd"],
                    "text": f"Restart supervisor sessions sooner and steer less. Supervision cost {money(metrics['supervisor_usd'])}, {share}% of the day.",
                },
            )
        )
    costly = top_by(finished, lambda t: t["usd"])
    if costly:
        share = round(100 * costly["usd"] / usd_total) if usd_total else 0
        cause = costly["reasons"][0] if costly["reasons"] else f"{costly['longestTurns']} turns in its longest conversation"
        options.append(
            (
                costly["usd"] * 0.9,
                {
                    "metric": "max_task_usd",
                    "value": metrics["max_task_usd"],
                    "text": f"Split work like {costly['id']} into smaller tasks. It cost {money(costly['usd'])}, {share}% of the day, with {cause}.",
                },
            )
        )
    if options:
        recs.append({"area": "cost", **max(options, key=lambda o: o[0])[1]})
    else:
        recs.append({"area": "cost", "metric": None, "value": None, "text": "No priced tokens were recorded today, so there is no cost advice."})

    def affected(test) -> int:
        return sum(1 for t in finished if test(t))

    quality = [
        (
            affected(lambda t: t["review"]["error"] > 0),
            "review_errors",
            f"Ask workers to check their own change against the review before handing off. Review found {n_of(metrics['review_errors'], 'error')} on {affected(lambda t: t['review']['error'] > 0)} of {n_of(len(finished), 'task')}.",
        ),
        (
            affected(lambda t: t["fixRounds"].get("ci", 0) > 0),
            "ci_fix_rounds",
            f"Run the project's checks before pushing. CI failed {n_of(metrics['ci_fix_rounds'], 'time')} before green on {n_of(affected(lambda t: t['fixRounds'].get('ci', 0) > 0), 'task')}.",
        ),
        (
            affected(lambda t: t["fixRounds"].get("lint", 0) > 0),
            "lint_fix_rounds",
            f"Run the linter before validation. Lint needed {n_of(metrics['lint_fix_rounds'], 'fix round')} on {n_of(affected(lambda t: t['fixRounds'].get('lint', 0) > 0), 'task')}.",
        ),
        (
            affected(lambda t: t["questions"] > 0),
            "worker_questions",
            f"Put the likely answers in the instructions up front. Workers asked {n_of(metrics['worker_questions'], 'question')} on {n_of(affected(lambda t: t['questions'] > 0), 'task')}.",
        ),
    ]
    tasks_hit, metric, text = max(quality, key=lambda q: (q[0], metrics[q[1]]))
    if tasks_hit:
        recs.append({"area": "quality", "metric": metric, "value": metrics[metric], "text": text})
    else:
        recs.append({"area": "quality", "metric": None, "value": None, "text": "No review errors, failed checks or worker questions were recorded today."})
    return recs


def previous_advice(notes: dict, day: str, metrics: dict) -> list[dict]:
    earlier = [r for r in notes.get("reviews", []) if r.get("day", "") < day]
    if not earlier:
        return []
    last = earlier[-1]
    tasks_then = last.get("metrics", {}).get("tasks_finished") or 0
    tasks_now = metrics.get("tasks_finished") or 0
    verdicts = []
    for rec in last.get("recommendations", []):
        metric, before = rec.get("metric"), rec.get("value")
        if metric not in METRICS or before is None:
            continue
        now = metrics.get(metric)
        # Raw totals rise and fall with the number of tasks, so only the per task rate is compared.
        if now is None or not tasks_then or not tasks_now:
            verdict, sentence = "no data", "There is no figure per finished task to compare."
        else:
            rate_then, rate_now = before / tasks_then, now / tasks_now
            per_task = f"Per finished task that is {rate_then:.1f} then and {rate_now:.1f} now, so it"
            if round(rate_now, 1) < round(rate_then, 1):
                verdict, sentence = "improved", f"{per_task} moved the right way."
            elif round(rate_now, 1) == round(rate_then, 1):
                verdict, sentence = "no change", f"{per_task} did not move."
            else:
                verdict, sentence = "worse", f"{per_task} moved the wrong way."
        shown = "no figure" if now is None else now
        verdicts.append(
            {
                "area": rec.get("area", ""),
                "metric": metric,
                "before": before,
                "after": now,
                "verdict": verdict,
                "text": f"The {rec.get('area', '')} advice on {last['day']} targeted {METRICS[metric]}: {before} then over {n_of(tasks_then, 'finished task')}, {shown} now over {n_of(tasks_now, 'finished task')}. {sentence}",
            }
        )
    return verdicts


LESSON_TEXT = {
    "ci": "Run the project's CI checks before pushing. CI failed before green on {k} tasks: {ids}.",
    "lint": "Run the linter before handing work to validation. Lint needed fixes on {k} tasks: {ids}.",
    "test": "Run and extend the tests before handing off. Tests needed fixes on {k} tasks: {ids}.",
    "document": "Update the docs in the same change. Documentation needed fixes on {k} tasks: {ids}.",
    "rebase": "Start from the latest base branch. Rebasing needed fixes on {k} tasks: {ids}.",
}


def lessons_today(finished: list[dict], notes: dict, day: str) -> list[dict]:
    found = []
    for step, template in LESSON_TEXT.items():
        hit = [t["id"] for t in finished if t["fixRounds"].get(step, 0) > 0]
        if len(hit) >= 2:
            found.append({"key": "step:" + step, "tasks": hit, "text": template.format(k=len(hit), ids=ids_list(hit))})
    by_file: dict = {}
    for task in finished:
        for file in task["reviewFiles"]:
            by_file.setdefault((task["project"], file), []).append(task["id"])
    for (project, file), hit in sorted(by_file.items()):
        hit = sorted(set(hit))
        if len(hit) >= 2:
            where = f"{project} {file}" if project else file
            found.append(
                {"key": f"file:{project}:{file}", "tasks": hit, "text": f"Read the callers and tests of {where} before changing it. Review found problems there on {len(hit)} tasks: {ids_list(hit)}."}
            )
    known = notes.get("lessons", {})
    for lesson in found:
        days = set(known.get(lesson["key"], {}).get("days", [])) | {day}
        lesson["days"] = len(days)
    return found


STYLE = """
:root{color-scheme:light}
body{margin:0;background:#f7f8fa;color:#1d2330;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1060px;margin:0 auto;padding:28px 24px 60px}
h1{font-size:26px;margin:0 0 4px}h2{font-size:18px;margin:34px 0 12px}
.sub{color:#5a6475;margin:0 0 20px}
.kpis{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.kpi{background:#fff;border:1px solid #dfe3ea;border-radius:10px;padding:14px 16px;min-width:0}
.kpi b{display:block;font-size:26px;color:#1a4fb5}.kpi span{color:#5a6475;font-size:13px}
.card{background:#fff;border:1px solid #dfe3ea;border-radius:10px;padding:16px 18px;min-width:0;overflow-x:auto}
.bar{display:grid;grid-template-columns:minmax(0,300px) minmax(0,1fr) 80px;gap:12px;align-items:center;padding:5px 0}
.lbl{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.lbl .m{display:block;font-weight:400;color:#6b7486;font-size:12px}
.track{background:#eef1f6;border-radius:6px;height:14px}.fill{background:#3b73d9;height:14px;border-radius:6px}
.usd{text-align:right;font-variant-numeric:tabular-nums;font-weight:600}
.grid2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px}
.why h3{margin:0 0 6px;font-size:15px;overflow-wrap:anywhere}.why p{margin:0;color:#3a4252}
.tag{display:inline-block;font-size:12px;padding:1px 8px;border-radius:10px;margin-right:6px}
.t-cost{background:#fdecec;color:#a12a2a}.t-time{background:#fff4dd;color:#8a5a00}.t-q{background:#e8f3ec;color:#1f6b3a}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eceff4;vertical-align:top}th{color:#5a6475;font-weight:600}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.rec{border-left:4px solid #3b73d9;background:#fff;border-radius:8px;padding:12px 16px;margin:10px 0}
.rec b{color:#1a4fb5}
.improved{color:#1f6b3a}.worse{color:#a12a2a}
.note{color:#6b7486;font-size:13px}
@media (max-width:720px){.kpis,.grid2{grid-template-columns:minmax(0,1fr)}.bar{grid-template-columns:minmax(0,1fr) 80px}.track{display:none}}
"""

AREA_TITLE = {"speed": "Speed.", "cost": "Price.", "quality": "Quality."}
SPLIT_TITLE = (
    ("working", "working"),
    ("decision", "waiting on a decision"),
    ("checks", "waiting on checks or a slot"),
    ("merge", "done to merged"),
    ("restart", "restarts"),
)


def esc(value) -> str:
    return html.escape(str(value), quote=True)


def page(title: str, body: str) -> str:
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<title>{esc(title)}</title><style>{STYLE}</style></head><body><main>{body}</main></body></html>\n"
    )


def short_model(model: str) -> str:
    return model.replace("claude-", "").replace("-5-5", " 5.5").replace("-5-1", " 5.1")


def window_sentence(numbers: dict) -> str:
    zone = ZoneInfo(numbers["zone"])
    since = datetime.fromtimestamp(numbers["since"], zone)
    until = datetime.fromtimestamp(numbers["until"], zone)
    city = numbers["zone"].split("/")[-1].replace("_", " ")
    return f"From {since:%A %H:%M} to {until:%A %H:%M}, {city} time."


def hours(m: int) -> str:
    return f"{m / 60:.1f} h" if m >= 90 else f"{m} min"


def render_board(numbers: dict) -> str:
    m = numbers["metrics"]
    day = datetime.fromisoformat(numbers["day"])
    usage = numbers["dayUsage"]
    tokens = usage_tokens(usage)
    merged = sum(1 for t in numbers["tasks"] if t["mergedAt"])
    homes = ", ".join(f"{money(h['usd'])} {esc(h['label'])}" for h in numbers["homes"] if h["usd"] >= 0.01)
    median = "no data" if m["median_task_minutes"] is None else hours(int(m["median_task_minutes"]))
    out = [f"<h1>Day review, {day.day} {day:%B}</h1>"]
    out.append(f"<p class=\"sub\">{esc(window_sentence(numbers))} Price is what the same tokens would cost on the Anthropic API at list price, not the subscription spend.</p>")
    out.append("<div class=\"kpis\">")
    out.append(f"<div class=\"kpi\"><b>{m['tasks_finished']}</b><span>tasks finished, {merged} merged</span></div>")
    out.append(f"<div class=\"kpi\"><b>{money(m['usd_total'])}</b><span>API price{', ' + homes if homes else ''}</span></div>")
    share = "" if m["cache_read_share"] is None else f", {m['cache_read_share']}% cache rereads"
    out.append(f"<div class=\"kpi\"><b>{count_tokens(tokens)}</b><span>tokens{share}</span></div>")
    out.append(f"<div class=\"kpi\"><b>{median}</b><span>median time from start to done</span></div>")
    out.append("</div>")
    out.append("<h2>Recommendations</h2>")
    for rec in numbers["recommendations"]:
        out.append(f"<div class=\"rec\"><b>{AREA_TITLE[rec['area']]}</b> {esc(rec['text'])}</div>")
    if numbers["previousAdvice"]:
        out.append("<h2>Did the last advice help</h2><div class=\"card\"><table>")
        for item in numbers["previousAdvice"]:
            out.append(f"<tr><td class=\"{esc(item['verdict'].replace(' ', '-'))}\">{esc(item['verdict'])}</td><td>{esc(item['text'])}</td></tr>")
        out.append("</table></div>")
    rows = numbers["priceRows"][:10]
    if rows:
        top = rows[0]["usd"] or 1
        out.append("<h2>Where the price went</h2><div class=\"card\">")
        for row in rows:
            meta = " · ".join(esc(part) for part in (row["home"], ", ".join(short_model(x) for x in row["models"]), n_of(row["turns"], "turn")) if part)
            out.append(
                f"<div class=\"bar\"><div class=\"lbl\">{esc(row['name'])}<span class=\"m\">{meta}</span></div>"
                f"<div class=\"track\"><div class=\"fill\" style=\"width:{100 * row['usd'] / top:.1f}%\"></div></div>"
                f"<div class=\"usd\">{money(row['usd'])}</div></div>"
            )
        out.append("</div>")
    flagged = [t for t in numbers["tasks"] if t["reasons"]][:6]
    if flagged:
        out.append("<h2>Why these tasks were long or costly</h2><div class=\"grid2 why\">")
        for task in flagged:
            tags = f"<span class=\"tag t-cost\">{money(task['usd'])}</span><span class=\"tag t-time\">{hours(task['totalMinutes'])}</span>"
            if task["review"]["error"]:
                tags += f"<span class=\"tag t-q\">{n_of(task['review']['error'], 'review error')}</span>"
            elif task["fixRounds"].get("ci"):
                tags += f"<span class=\"tag t-q\">{n_of(task['fixRounds']['ci'], 'failed CI round')}</span>"
            out.append(f"<div class=\"card\">{tags}<h3>{esc(task['id'])}</h3><p>{esc('. '.join(r[0].upper() + r[1:] for r in task['reasons']))}.</p></div>")
        out.append("</div>")
    if numbers["lessons"]:
        out.append("<h2>Lessons from repeated mistakes</h2><div class=\"card\"><table><tr><th>Lesson</th><th class=\"n\">Days seen</th></tr>")
        for lesson in numbers["lessons"]:
            out.append(f"<tr><td>{esc(lesson['text'])}</td><td class=\"n\">{lesson['days']}</td></tr>")
        out.append("</table></div>")
    out.append("<h2>Not measured</h2><div class=\"card\">")
    out.extend(f"<p class=\"note\">{esc(gap)}</p>" for gap in numbers["gaps"])
    out.append("</div>")
    out.append("<p class=\"note\"><a href=\"full.html\">Full numbers for every task</a></p>")
    return page(f"Day review {numbers['day']}", "\n".join(out))


def render_full(numbers: dict) -> str:
    out = [f"<h1>Day review numbers, {esc(numbers['day'])}</h1>", f"<p class=\"sub\">{esc(window_sentence(numbers))} <a href=\"board.html\">Back to the board</a></p>"]
    out.append("<h2>Finished tasks</h2><div class=\"card\"><table><tr><th>Task</th><th>Home</th>")
    out.extend(f"<th class=\"n\">{esc(label)} min</th>" for _, label in SPLIT_TITLE)
    out.append("<th class=\"n\">Restarts</th><th class=\"n\">Questions</th><th class=\"n\">Steers</th><th class=\"n\">Tokens</th><th class=\"n\">Price</th><th>Models</th><th class=\"n\">Review e/w/i</th><th>Fix rounds</th><th>PR</th></tr>")
    for t in numbers["tasks"]:
        rounds = ", ".join(f"{step} {n}" for step, n in sorted(t["fixRounds"].items())) or "none"
        pr = f"<a href=\"{esc(t['pr'])}\">{esc(t['pr'].rsplit('/', 3)[-3] + ' ' + t['pr'].rsplit('/', 1)[-1])}</a>" if t["pr"].startswith("https://") else ""
        models = ", ".join(f"{short_model(k)} {money(v['usd']) if v['priced'] else 'unpriced'}" for k, v in sorted(t["models"].items()))
        out.append(f"<tr><td>{esc(t['id'])}<br><span class=\"note\">{esc(t['title'])}</span></td><td>{esc(t['home'])}</td>")
        out.extend(f"<td class=\"n\">{t['minutes'][key]}</td>" for key, _ in SPLIT_TITLE)
        out.append(
            f"<td class=\"n\">{t['restarts']}</td><td class=\"n\">{t['questions']}</td><td class=\"n\">{t['steers']}</td>"
            f"<td class=\"n\">{count_tokens(t['tokens'])}</td><td class=\"n\">{money(t['usd'])}</td><td>{esc(models) or 'no log'}</td>"
            f"<td class=\"n\">{t['review']['error']}/{t['review']['warning']}/{t['review']['info']}</td><td>{esc(rounds)}</td><td>{pr}</td></tr>"
        )
    out.append("</table></div><h2>Price by source</h2><div class=\"card\"><table><tr><th>Source</th><th>Home</th><th class=\"n\">Turns</th><th class=\"n\">Price</th></tr>")
    for row in numbers["priceRows"]:
        out.append(f"<tr><td>{esc(row['name'])}</td><td>{esc(row['home'])}</td><td class=\"n\">{row['turns']}</td><td class=\"n\">{money(row['usd'])}</td></tr>")
    out.append("</table></div><h2>Models</h2><div class=\"card\"><table><tr><th>Model</th><th class=\"n\">Turns</th><th class=\"n\">Input</th><th class=\"n\">Output</th><th class=\"n\">Cache read</th><th class=\"n\">Cache write</th><th class=\"n\">Price</th></tr>")
    for name, model in sorted(numbers["models"].items(), key=lambda kv: -kv[1]["usd"]):
        price = money(model["usd"]) if model["priced"] else "no list price"
        out.append(
            f"<tr><td>{esc(short_model(name))}</td><td class=\"n\">{model['turns']}</td><td class=\"n\">{count_tokens(model['input'])}</td><td class=\"n\">{count_tokens(model['output'])}</td>"
            f"<td class=\"n\">{count_tokens(model['cacheRead'])}</td><td class=\"n\">{count_tokens(model['cacheWrite'])}</td><td class=\"n\">{price}</td></tr>"
        )
    out.append("</table></div><h2>Day figures</h2><div class=\"card\"><table>")
    for key, label in METRICS.items():
        value = numbers["metrics"].get(key)
        out.append(f"<tr><td>{esc(label)}</td><td class=\"n\">{'no data' if value is None else esc(value)}</td></tr>")
    out.append("</table></div>")
    questions = [(t["id"], q) for t in numbers["tasks"] for q in t["questionTexts"] if q]
    if questions:
        out.append("<h2>Worker questions</h2><div class=\"card\"><table>")
        out.extend(f"<tr><td>{esc(task)}</td><td>{esc(q)}</td></tr>" for task, q in questions)
        out.append("</table></div>")
    out.append("<h2>Sources and gaps</h2><div class=\"card\">")
    out.append("<p class=\"note\">Durations come from task status records, merge times from the automatic merge log, tokens from worker and supervisor conversation logs and the validation pipeline database, prices from the list prices in bin/fm-day-review.py, and review and CI results from the validation pipeline database.</p>")
    out.extend(f"<p class=\"note\">{esc(gap)}</p>" for gap in numbers["gaps"])
    out.append("</div>")
    return page(f"Day review numbers {numbers['day']}", "\n".join(out))


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def render(args: argparse.Namespace) -> None:
    numbers = load_json(args.numbers, NUMBERS_SCHEMA)
    if numbers is None:
        die("missing numbers: " + args.numbers)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_atomic(out / "board.html", render_board(numbers))
    write_atomic(out / "full.html", render_full(numbers))
    print(out / "board.html")


def record(args: argparse.Namespace) -> None:
    numbers = load_json(args.numbers, NUMBERS_SCHEMA)
    if numbers is None:
        die("missing numbers: " + args.numbers)
    notes = load_json(args.notes, NOTES_SCHEMA) or {"schema": NOTES_SCHEMA, "reviews": [], "lessons": {}}
    day = numbers["day"]
    notes["reviews"] = [r for r in notes["reviews"] if r.get("day") != day]
    notes["reviews"].append(
        {
            "day": day,
            "until": numbers["until"],
            "metrics": numbers["metrics"],
            "recommendations": [{k: r[k] for k in ("area", "metric", "value")} for r in numbers["recommendations"]],
        }
    )
    notes["reviews"] = notes["reviews"][-90:]
    for lesson in numbers["lessons"]:
        known = notes["lessons"].setdefault(lesson["key"], {"days": [], "tasks": []})
        known["text"] = lesson["text"]
        known["days"] = sorted(set(known["days"]) | {day})
        known["tasks"] = sorted(set(known["tasks"]) | set(lesson["tasks"]))
    write_atomic(Path(args.notes), json.dumps(notes, indent=1, sort_keys=True) + "\n")
    lines = ["# Day review lessons", "", "Repeated mistakes the daily review found, most frequent first.", ""]
    for _, lesson in sorted(notes["lessons"].items(), key=lambda kv: (-len(kv[1]["days"]), kv[0])):
        lines.append(f"- {lesson['text']} Seen on {n_of(len(lesson['days']), 'day')}, last on {lesson['days'][-1]}.")
    write_atomic(Path(args.lessons), "\n".join(lines) + "\n")


def due(args: argparse.Namespace) -> None:
    match = re.fullmatch(r"([01][0-9]|2[0-3]):([0-5][0-9])", args.time)
    try:
        zone = ZoneInfo(args.zone)
    except (ValueError, KeyError, OSError):
        zone = None
    if not match or zone is None:
        print("bad-config")
        return
    local = datetime.fromtimestamp(args.now, zone)
    at = dt_time(int(match.group(1)), int(match.group(2)))
    scheduled = datetime.combine(local.date(), at, tzinfo=zone)
    day = local.date().isoformat()
    if not args.force and (local < scheduled or args.last_day == day):
        print("waiting")
        return
    until = int(args.now) if args.force and local < scheduled else int(scheduled.timestamp())
    day_before = datetime.combine(local.date() - timedelta(days=1), at, tzinfo=zone).timestamp()
    since = args.last_until if args.last_until and day_before - 6 * 86400 <= args.last_until < until else day_before
    print(f"due {day} {int(since)} {until}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="fm-day-review.py")
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("due")
    d.add_argument("--time", required=True)
    d.add_argument("--zone", required=True)
    d.add_argument("--now", required=True, type=float)
    d.add_argument("--last-day", default="")
    d.add_argument("--last-until", type=float, default=0)
    d.add_argument("--force", action="store_true")
    d.set_defaults(func=due)
    c = sub.add_parser("collect")
    c.add_argument("--home", required=True)
    c.add_argument("--bin", required=True)
    c.add_argument("--since", required=True, type=float)
    c.add_argument("--until", required=True, type=float)
    c.add_argument("--nm-db", required=True)
    c.add_argument("--session-root", action="append")
    c.add_argument("--host")
    c.set_defaults(func=collect)
    m = sub.add_parser("merge")
    m.add_argument("--since", required=True, type=float)
    m.add_argument("--until", required=True, type=float)
    m.add_argument("--zone", required=True)
    m.add_argument("--notes")
    m.add_argument("--gap", action="append")
    m.add_argument("inputs", nargs="+")
    m.set_defaults(func=merge)
    r = sub.add_parser("render")
    r.add_argument("numbers")
    r.add_argument("--out-dir", required=True)
    r.set_defaults(func=render)
    k = sub.add_parser("record")
    k.add_argument("numbers")
    k.add_argument("--notes", required=True)
    k.add_argument("--lessons", required=True)
    k.set_defaults(func=record)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
