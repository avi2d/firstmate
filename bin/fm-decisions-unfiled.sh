#!/usr/bin/env bash
# fm-decisions-unfiled.sh - list dated captain.md rulings no decisions record cites.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
exec python3 - "$@" <<'PY'
import argparse
import os
import re
import sys

BULLET_RE = re.compile(r"^-\s+(\d{4}-\d{2}-\d{2}):\s*(.*)$")
DATE_RE = re.compile(r"^Date:\s*(\d{4}-\d{2}-\d{2})", re.MULTILINE)
QUOTED_RE = re.compile(r'"([^"]+)"')
WORD_RE = re.compile(r"[a-z0-9]+")


def words(s):
    return WORD_RE.findall(s.casefold())


def parse_args():
    home = os.environ.get("FM_HOME", "")
    data = os.environ.get("FM_DATA_OVERRIDE", os.path.join(home, "data"))
    projects = os.environ.get("FM_PROJECTS_OVERRIDE", os.path.join(home, "projects"))
    parser = argparse.ArgumentParser(
        prog="fm-decisions-unfiled.sh",
        description="List dated captain.md rulings no decisions record cites.",
        epilog=(
            "A ruling is cited when the captain's words section of a same-date "
            "record quotes its own quoted words; the rest of the record and the "
            "ruling's surrounding prose never count. "
            "A quoted fragment counts when it appears byte for byte in that "
            "section, when a quote line of that section appears inside it, or when at least three quarters of its case-folded words "
            "appear in one quote line of a same-date record, so a corrected "
            "paraphrase still cites. A bullet with no quoted words falls back to "
            "date alone, and a record without a words section cites nothing. "
            "Reads only; prints one date-plus-opening-words line per uncited "
            "ruling, nothing when every ruling is cited."
        ),
    )
    parser.add_argument("--captain", default=os.path.join(data, "captain.md"))
    parser.add_argument("--decisions", default=os.path.join(projects, "decisions"))
    return parser.parse_args()


def words_section(text):
    lines = text.splitlines()
    for start, line in enumerate(lines):
        if line.startswith("## ") and "captain's words" in line.casefold():
            break
    else:
        return None
    end = start + 1
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    return lines[start + 1:end]


def load_records(adr_dir):
    if not os.path.isdir(adr_dir):
        return None
    dated = set()
    sections = {}
    quotes = {}
    try:
        names = sorted(os.listdir(adr_dir))
    except OSError:
        return dated, sections, quotes
    for name in names:
        if not name.endswith(".md"):
            continue
        try:
            with open(os.path.join(adr_dir, name), encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            continue
        section = words_section(text)
        if section is None:
            continue
        match = DATE_RE.search(text)
        if not match:
            continue
        date = match.group(1)
        dated.add(date)
        sections.setdefault(date, []).append("\n".join(section))
        for line in section:
            stripped = line.strip()
            if stripped.startswith(">"):
                quote = stripped[1:].strip()
                if quote:
                    quotes.setdefault(date, []).append(quote)
    return dated, sections, quotes


def is_cited(date, fragments, dated, sections, quotes):
    if not fragments:
        return date in dated
    for fragment in fragments:
        for section in sections.get(date, []):
            if fragment in section:
                return True
        for quote in quotes.get(date, []):
            if quote in fragment:
                return True
    for fragment in fragments:
        fragment_words = words(fragment)
        if not fragment_words:
            continue
        for quote in quotes.get(date, []):
            common = set(fragment_words) & set(words(quote))
            if len(common) * 4 >= 3 * len(fragment_words):
                return True
    return False


def opening_words(text):
    parts = text.split()
    body = " ".join(parts[:12])
    if len(parts) > 12:
        body += " ..."
    return body


def main():
    args = parse_args()
    if not args.captain or not os.path.isfile(args.captain):
        return 0
    loaded = load_records(os.path.join(args.decisions, "docs", "adr"))
    if loaded is None:
        return 0
    dated, sections, quotes = loaded
    try:
        with open(args.captain, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return 0
    for line in lines:
        match = BULLET_RE.match(line)
        if not match:
            continue
        date, text = match.group(1), match.group(2)
        fragments = [m for m in QUOTED_RE.findall(text) if m]
        if not is_cited(date, fragments, dated, sections, quotes):
            sys.stdout.write("%s: %s\n" % (date, opening_words(text)))
    return 0


sys.exit(main())
PY
