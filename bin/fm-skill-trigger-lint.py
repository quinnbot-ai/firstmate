#!/usr/bin/env python3
"""Warn about skill descriptions that are poor routing triggers."""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

TRIGGER_PHRASE_RE = re.compile(
    r"\b(?:use|load)\s+(?:when|before|after|on)\b|"
    r"\b(?:captain|user)\s+(?:invokes?|asks?|says?)\b|"
    r"\b(?:invoke|invoked|run|runs|start|starts)\b|"
    r"\b(?:before|after|when|on)\s+[a-z]",
    re.I,
)
INSTRUCTION_MARKERS = re.compile(
    r"\b(?:before|after|do not|never|it owns|contains|steps?|implementation details|must|should|ensure|confirm|read|run|pass|record)\b",
    re.I,
)
WORD_RE = re.compile(r"[a-z][a-z0-9-]{4,}")
STOPWORDS = {
    "about", "agent", "agents", "captain", "current", "firstmate", "from", "load", "when", "with", "this",
    "that", "skill", "skills", "before", "after", "using", "reports", "report", "work", "procedure",
    "reference", "policy", "playbook", "operator", "operations", "handling", "handle", "task", "tasks", "project",
    "invokes", "invoke", "explicitly", "says", "asks", "request", "requests", "whenever", "actionable",
}


@dataclass(frozen=True)
class Skill:
    path: str
    line: int
    description: str
    trigger_words: frozenset[str]


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    reason: str
    evidence: str


def refuse(message: str) -> "NoReturn":
    print(f"fm-skill-trigger-lint: refused: {message}", file=sys.stderr)
    raise SystemExit(2)


def safe_root(value: str) -> Path:
    supplied = Path(value).expanduser()
    if not supplied.is_absolute():
        supplied = Path.cwd() / supplied
    try:
        supplied.lstat()
    except FileNotFoundError:
        refuse(f"root does not exist: {value}")
    if not os.path.isdir(supplied) or os.path.islink(supplied):
        refuse(f"root is not a real directory: {value}")
    return supplied.resolve(strict=True)


def skill_paths(root: Path) -> list[Path]:
    result: list[Path] = []
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        dirs.sort()
        files.sort()
        for name in list(dirs):
            candidate = current_path / name
            if candidate.is_symlink():
                refuse(f"symlinked directory escapes root: {candidate}")
        for name in files:
            candidate = current_path / name
            if candidate.is_symlink():
                refuse(f"symlinked file escapes root: {candidate}")
            if name == "SKILL.md":
                resolved = candidate.resolve(strict=True)
                if root not in resolved.parents:
                    refuse(f"path escapes root: {candidate}")
                result.append(candidate)
    return result


def parse_frontmatter(path: Path, display: str) -> tuple[Skill | None, list[Finding]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return None, [Finding(display, 1, "malformed frontmatter", str(exc))]
    if not lines or lines[0].strip() != "---":
        return None, [Finding(display, 1, "malformed frontmatter", "missing opening ---")]
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return None, [Finding(display, 1, "malformed frontmatter", "missing closing ---")]
    description: str | None = None
    description_line = 1
    i = 1
    while i < end:
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):(?:[ \t]*(.*))?$", lines[i])
        if not match:
            if lines[i].strip():
                return None, [Finding(display, i + 1, "malformed frontmatter", lines[i].strip())]
            i += 1
            continue
        key, value = match.group(1), (match.group(2) or "").strip()
        if key != "description":
            i += 1
            while i < end and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
                i += 1
            continue
        if description is not None:
            return None, [Finding(display, i + 1, "malformed frontmatter", "duplicate description")]
        description_line = i + 1
        if value in {">", ">-", ">+", "|", "|-", "|+"}:
            block: list[str] = []
            i += 1
            while i < end and (lines[i].startswith((" ", "\t")) or not lines[i].strip()):
                block.append(lines[i].strip())
                i += 1
            description = " ".join(part for part in block if part).strip()
            continue
        description = value.strip("'\"")
        i += 1
    if description is None:
        return None, [Finding(display, 1, "malformed frontmatter", "description is missing")]
    return Skill(display, description_line, description, trigger_words(description)), []


def evidence(description: str) -> str:
    compact = " ".join(description.split())
    return compact if len(compact) <= 160 else compact[:157] + "..."


def trigger_words(description: str) -> frozenset[str]:
    match = TRIGGER_PHRASE_RE.search(description)
    if not match:
        return frozenset()
    clause = description[match.start() :].split(".", 1)[0]
    return frozenset(word.lower() for word in WORD_RE.findall(clause.lower()) if word.lower() not in STOPWORDS)


def warnings_for(skill: Skill) -> list[Finding]:
    result: list[Finding] = []
    description = skill.description
    if len(description) > 360 or (description.count(".") >= 4 and INSTRUCTION_MARKERS.search(description)):
        result.append(Finding(skill.path, skill.line, "instruction dump in frontmatter", evidence(description)))
    if not TRIGGER_PHRASE_RE.search(description):
        result.append(Finding(skill.path, skill.line, "missing trigger wording", evidence(description)))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Warn about non-concise skill routing descriptions.")
    parser.add_argument("--root", action="append", default=None, help="skill root to inspect (repeatable)")
    args = parser.parse_args()
    roots = args.root or [".agents/skills", "skills"]
    skills: list[Skill] = []
    findings: list[Finding] = []
    for root_value in roots:
        root = safe_root(root_value)
        for path in skill_paths(root):
            display = path.relative_to(Path.cwd()).as_posix() if path.is_relative_to(Path.cwd()) else path.as_posix()
            skill, parse_findings = parse_frontmatter(path, display)
            findings.extend(parse_findings)
            if skill:
                skills.append(skill)
                findings.extend(warnings_for(skill))
    for index, left in enumerate(skills):
        for right in skills[index + 1 :]:
            if Path(left.path).parent.parent != Path(right.path).parent.parent:
                continue
            overlap = left.trigger_words & right.trigger_words
            if len(overlap) >= 2:
                shared = ", ".join(sorted(overlap))
                findings.append(Finding(left.path, left.line, "overlapping adjacent trigger words", f"shared with {right.path}: {shared}"))
                findings.append(Finding(right.path, right.line, "overlapping adjacent trigger words", f"shared with {left.path}: {shared}"))
    for item in sorted(findings, key=lambda item: (item.path, item.line, item.reason, item.evidence)):
        print(f"skill-trigger-warning: {item.path}:{item.line}: {item.reason}; evidence: {item.evidence}")
    return 0


if __name__ == "__main__":
    main()
