#!/usr/bin/env bash
# bin/fm-skill-trigger-index.sh [--check|--write] [--root <repo>]
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

INDEX_NAME = "agent-skill-trigger-index"
STUB_MARKER = "stub only redirects"
STUB_TARGET_RE = re.compile(r"Load `?([A-Za-z0-9-]+)`? instead")
ENTRY_RE = re.compile(r"^- `([A-Za-z0-9-]+)` - ", re.M)


def die(message: str) -> "NoReturn":
    print(f"fm-skill-trigger-index: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_frontmatter(skill_file: Path) -> str:
    text = skill_file.read_text(encoding="utf-8")
    match = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not match:
        die(f"{skill_file} has no YAML frontmatter")
    return match.group(1)


def read_description(frontmatter: str, skill_file: Path) -> str:
    lines = frontmatter.split("\n")
    try:
        index = next(i for i, line in enumerate(lines) if line.startswith("description:"))
    except StopIteration:
        die(f"{skill_file} frontmatter has no description")
    first = lines[index][len("description:"):].strip()
    if first in (">", ">-", "|", "|-", "|+"):
        collected: list[str] = []
        for line in lines[index + 1:]:
            if line.startswith((" ", "\t")):
                collected.append(line.strip())
            elif line.strip() == "":
                collected.append("")
            else:
                break
        return " ".join(" ".join(collected).split())
    if first == "" or first.startswith(("#", "{", "[")):
        die(f"{skill_file} has an unreadable description scalar")
    return first


def split_sentences(description: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+(?=[A-Z])", description.strip()) if s]


def load_skills(skills_dir: Path) -> dict[str, str]:
    skills: dict[str, str] = {}
    for entry in sorted(skills_dir.iterdir(), key=lambda p: p.name):
        if not (entry / "SKILL.md").is_file():
            continue
        frontmatter = read_frontmatter(entry / "SKILL.md")
        invocable = re.search(r"^user-invocable:\s*(true|false)\s*$", frontmatter, re.M)
        if not invocable:
            die(f"{entry / 'SKILL.md'} must declare user-invocable: true or false")
        if invocable.group(1) == "true":
            continue
        if entry.name == INDEX_NAME:
            continue
        skills[entry.name] = read_description(frontmatter, entry / "SKILL.md")
    return skills


def check_stubs(skills: dict[str, str]) -> None:
    for name, description in skills.items():
        if STUB_MARKER not in description:
            continue
        target = STUB_TARGET_RE.search(description)
        if not target or target.group(1) not in skills:
            die(f"stub {name} must name its redirect target with 'Load `<skill>` instead'")


def render_body(skills: dict[str, str]) -> str:
    out = [
        "# Agent-only reference skills",
        "",
        "These skills are not captain-invocable; load them only at their precise triggers.",
        "Each entry repeats its skill's own description word for word; the description is the trigger.",
        "After changing a skill description, run `bin/fm-skill-trigger-index.sh --write`.",
        "",
    ]
    for name in sorted(skills):
        sentences = split_sentences(skills[name])
        if not sentences:
            die(f"skill {name} has an empty description")
        out.append(f"- `{name}` - {sentences[0]}")
        out.extend(f"  {sentence}" for sentence in sentences[1:])
    return "\n".join(out) + "\n"


def split_committed(index_file: Path) -> tuple[str, str]:
    lines = index_file.read_text(encoding="utf-8").split("\n")
    dashes = [i for i, line in enumerate(lines) if line == "---"]
    if len(dashes) < 2 or dashes[0] != 0:
        die(f"{index_file} must keep its frontmatter header")
    head = "\n".join(lines[: dashes[1] + 1]) + "\n"
    return head, "\n".join(lines[dashes[1] + 1:])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    root = Path(args.root)
    skills_dir = root / ".agents" / "skills"
    index_file = skills_dir / INDEX_NAME / "SKILL.md"
    if not index_file.is_file():
        die(f"index not found at {index_file}")
    if args.write and args.check:
        die("--check and --write exclude each other")
    skills = load_skills(skills_dir)
    check_stubs(skills)
    head, _ = split_committed(index_file)
    expected = head + render_body(skills)
    if args.write:
        index_file.write_text(expected, encoding="utf-8")
        print(f"fm-skill-trigger-index: wrote {len(skills)} skills to {index_file}")
        return
    if args.check:
        if index_file.read_text(encoding="utf-8") == expected:
            print(f"fm-skill-trigger-index: ok skills={len(skills)}")
            return
        committed = index_file.read_text(encoding="utf-8")
        for name in sorted(set(skills) - set(ENTRY_RE.findall(committed))):
            print(f"fm-skill-trigger-index: missing from index: {name}")
        for name in sorted(set(ENTRY_RE.findall(committed)) - set(skills)):
            print(f"fm-skill-trigger-index: index names unknown skill: {name}")
        if set(ENTRY_RE.findall(committed)) == set(skills):
            print("fm-skill-trigger-index: an entry's wording drifted from its skill description:")
            print("".join(difflib.unified_diff(
                committed.splitlines(keepends=True),
                expected.splitlines(keepends=True),
                "committed", "generated")))
        print("fm-skill-trigger-index: run `bin/fm-skill-trigger-index.sh --write` to refresh")
        raise SystemExit(1)
    sys.stdout.write(expected)


main()
PY
