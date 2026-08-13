#!/usr/bin/env python3
"""Read a Firstmate backlog as a dependency graph and reject unsafe dispatch.

Usage: fm-backlog-graph-lint.py [path/to/backlog.md]

With no path, checks $FM_HOME/data/backlog.md (or data/backlog.md when FM_HOME
is unset). The command is read-only. It exits 0 for a valid graph and 1 with
diagnostics for malformed structured records, dangling blockers, or cycles.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ID = r"[A-Za-z0-9][A-Za-z0-9._-]*"
HEADING = re.compile(r"^##\s+(.*?)\s*$", re.IGNORECASE)
CHECKBOX = re.compile(rf"^- \[([ x])\] ({ID}) - (.*)$")
LEGACY_IN_FLIGHT = re.compile(rf"^- \*\*({ID})\*\* - (.*)$")
STRUCTURED_SHAPE = re.compile(r"^- (?:\[[^]]*\]|\*\*[^*]+\*\*)")
TAIL_BLOCKED_BY = re.compile(rf"\s*blocked-by:\s*({ID})(?:\s+-\s+.*)?\s*$")
TRAILING_TAG = re.compile(
    rf"(?:\s*\((?:[^()]*(?:repo|kind|priority|since|merged|reported|done|closed|hold|hold-kind|hold-until):[^()]*)\)\s*|"
    rf"\s*(?:blocked-by|parent|discovered-from):\s*{ID}(?:\s+-\s+.*)?\s*)$"
)


@dataclass(frozen=True)
class Node:
    state: str
    deps: tuple[str, ...]
    line: int


def section_state(line: str) -> str | None:
    match = HEADING.match(line)
    if not match:
        return None
    title = match.group(1).lower()
    if title == "in flight":
        return "in_flight"
    if title == "queued":
        return "queued"
    if title.startswith("done"):
        return "done"
    return None


def extract_blocked_by(rest: str) -> tuple[str, ...]:
    """Mirror tasks-axi's trailing-tag direction without parsing its full schema."""
    deps: list[str] = []
    tail = rest
    while True:
        match = TAIL_BLOCKED_BY.search(tail)
        if not match:
            break
        deps.append(match.group(1))
        tail = tail[: match.start()]
        # A reason is free text to end-of-line, so another edge cannot follow it.
        if " - " in rest[match.start() :]:
            break
        # Strip non-dependency canonical tags between repeated bare edges.
        while True:
            tag = TRAILING_TAG.search(tail)
            if not tag or tag.group(0).lstrip().startswith(("blocked-by:", "parent:", "discovered-from:")):
                break
            tail = tail[: tag.start()]
    return tuple(reversed(deps))


def parse(path: Path) -> tuple[dict[str, Node], list[str]]:
    nodes: dict[str, Node] = {}
    problems: list[str] = []
    state: str | None = None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return nodes, [f"INPUT: cannot read {path}: {exc.strerror or exc}"]

    for number, line in enumerate(lines, start=1):
        heading = section_state(line)
        if HEADING.match(line):
            state = heading
            continue
        if state is None:
            continue
        match = CHECKBOX.match(line)
        rest: str | None = None
        node_id: str | None = None
        if match:
            mark, node_id, rest = match.groups()
            if state == "done" and mark != "x":
                problems.append(f"MALFORMED: line {number}: Done tasks must use - [x]")
                continue
            if state != "done" and mark != " ":
                problems.append(f"MALFORMED: line {number}: active tasks must use - [ ]")
                continue
        elif state == "in_flight":
            legacy = LEGACY_IN_FLIGHT.match(line)
            if legacy:
                node_id, rest = legacy.groups()
        if node_id is None or rest is None:
            if STRUCTURED_SHAPE.match(line):
                problems.append(f"MALFORMED: line {number}: invalid structured task record")
            continue
        if node_id in nodes:
            problems.append(f"MALFORMED: line {number}: duplicate task id {node_id!r}")
            continue
        nodes[node_id] = Node(state=state, deps=extract_blocked_by(rest), line=number)
    return nodes, problems


def find_cycles(nodes: dict[str, Node]) -> list[list[str]]:
    """Return distinct cycles through blockers that are not already Done."""
    active = {node_id for node_id, node in nodes.items() if node.state != "done"}
    edges = {
        node_id: [dep for dep in nodes[node_id].deps if dep in active]
        for node_id in active
    }
    colors = dict.fromkeys(active, 0)
    path: list[str] = []
    cycles: list[list[str]] = []
    seen: set[tuple[str, ...]] = set()

    def visit(node_id: str) -> None:
        colors[node_id] = 1
        path.append(node_id)
        for dep in edges[node_id]:
            color = colors[dep]
            if color == 0:
                visit(dep)
            elif color == 1:
                cycle = path[path.index(dep) :] + [dep]
                canonical = min(
                    tuple(cycle[index:-1] + cycle[:index] + [cycle[index]])
                    for index in range(len(cycle) - 1)
                )
                if canonical not in seen:
                    seen.add(canonical)
                    cycles.append(list(canonical))
        path.pop()
        colors[node_id] = 2

    for node_id in sorted(active):
        if colors[node_id] == 0:
            visit(node_id)
    return cycles


def lint(path: Path) -> list[str]:
    nodes, problems = parse(path)
    for node_id, node in sorted(nodes.items()):
        if node.state == "done":
            continue
        for dep in node.deps:
            if dep not in nodes:
                problems.append(
                    f"DANGLING: {node_id} (line {node.line}) blocked-by {dep!r} is not in the backlog"
                )
    for cycle in find_cycles(nodes):
        problems.append("CYCLE: " + " -> ".join(cycle))
    return problems


def default_path() -> Path:
    home = os.environ.get("FM_HOME")
    return Path(home, "data", "backlog.md") if home else Path("data/backlog.md")


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: fm-backlog-graph-lint.py [path/to/backlog.md]", file=sys.stderr)
        return 2
    path = Path(argv[1]) if len(argv) == 2 else default_path()
    problems = lint(path)
    if problems:
        print(f"BACKLOG GRAPH INVALID: {path}")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"BACKLOG GRAPH OK: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
