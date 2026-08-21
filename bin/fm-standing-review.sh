#!/usr/bin/env bash
# fm-standing-review.sh - run one standing review and print at most one wake line.
#
# A standing review is a registered custom watcher check (AGENTS.md section 7):
# the watcher runs it every sweep and wakes firstmate for any non-empty output.
# That seam gives "no queue noise" only if the review itself stays quiet, so
# everything below exists to keep it quiet. The gate is the product; the review
# is only what feeds it.
#
# Usage:
#   fm-standing-review.sh --home <fm-home> --id <review-id>
#   fm-standing-review.sh --home <fm-home> --id <review-id> --dry-run [--explain]
#   fm-standing-review.sh --home <fm-home> --id <review-id> --validate
#
# Options:
#   --home <path>   firstmate home holding config/standing-reviews/<id>.json and state/
#   --id <id>       review id; also names the check, spec, and durable records
#   --state <dir>   state directory holding this review's durable records
#   --config <dir>  config directory holding standing-reviews/<id>.json
#   --dry-run       evaluate and print, but write no durable record and ignore
#                   the cadence gate; the preview an operator runs by hand
#   --explain       report every rejected candidate and why, on stderr
#   --validate      check the spec and exit non-zero if it cannot be used;
#                   prints nothing on stdout, because stdout is the wake
#                   channel and nothing but a real finding may appear there
#   -h, --help      print this header
#
# --state and --config win over FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE, which
# in turn win over --home. An armed check always passes both explicitly, so the
# review it runs is decided entirely by its own registered bytes: a watcher
# launched from another home cannot redirect it through the environment.
# Never writes outside the resolved state directory, and never writes to, or
# executes anything from, a reviewed subject.
#
# THE EVIDENCE GATE. A candidate is emitted only when every condition holds.
# Each rejects a distinct way this check could become noise:
#   G1 cadence      the review body runs at most once per interval_seconds.
#                   Rejects: 288 reviews a day from a 5-minute watcher sweep.
#   G2 freshness    every source must exist and be younger than its
#                   max_age_seconds. Rejects: findings reasoned from rotten
#                   data. A stale source becomes the finding instead, so a
#                   review whose inputs stopped refreshing fails loudly.
#   G3 shape        subject, action, and evidence must be non-empty, single
#                   line, and free of control characters. Rejects: output that
#                   would corrupt the wake reason the watcher composes from it.
#   G4 quantified   evidence must carry at least one field whose value is a
#                   number. Rejects: "this venture looks quiet" - any finding
#                   whose whole content is a classification. A supervisor
#                   cannot act on an adjective, so an adjective is not evidence.
#   G5 dispatchable subject_root/<subject> must be an existing directory.
#                   Rejects: findings naming something no worker can be sent
#                   to - a misspelled name, a venture not on this machine, or
#                   an aggregate like "the portfolio". Dispatchable work has a
#                   place on disk; if it does not, this is a conversation with
#                   the captain rather than a wake.
#   G6 novelty      a finding identity already emitted inside the retention
#                   window is suppressed. Rejects: re-waking every sweep for as
#                   long as a standing condition stands.
#   G7 cooldown     a subject that woke inside subject_cooldown_seconds is
#                   suppressed, whatever the finding. Rejects: a rule that
#                   mints a fresh identity each run because one of its evidence
#                   values drifts (days_idle, cost_30d), which would defeat G6
#                   while looking like new information.
#   G8 one line     among survivors exactly one is emitted, ranked and then
#                   ordered deterministically. Rejects: a burst of findings
#                   becoming a multi-line wake reason.
#
# G4, G6, and G7 are what make it quiet, and G7 is the one that is easy to
# leave out: without it the check still wakes correctly and also wakes forever.
#
# WHAT THIS DELIBERATELY DOES NOT DECIDE. Firstmate ships no rules. Which
# conditions deserve a wake, and how they rank against each other, is a program
# decision belonging to whoever owns the reviewed surface; the spec is where
# they say so. This script owns only whether a stated finding is admissible.
#
# Structural findings - a missing or invalid spec, a missing or stale source -
# skip G5, because their subject is the review's own plumbing rather than a
# reviewed surface, and they outrank rule findings so a review reports its own
# blindness before reporting anything it saw while blind.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FM_STANDING_REVIEW_ROOT="$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

SPEC_VERSION = "fm-standing-review-v1"

DEFAULT_INTERVAL = 86400            # daily
DEFAULT_SUBJECT_COOLDOWN = 604800   # 7 days
DEFAULT_LATCH_RETENTION = 7776000   # 90 days
DEFAULT_SOURCE_MAX_AGE = 172800     # 2 days

# The watcher composes "check: <path>: <out>" into a wake reason that is read
# in a digest, so a long line costs more than it carries. The marker matches
# bin/fm-line-cap-lib.sh's so an agent recognizes one truncation marker.
LINE_CAP = 200
LINE_CAP_SUFFIX = " [truncated]"

SUBJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

SPEC_KEYS = {
    "version",
    "interval_seconds",
    "subject_cooldown_seconds",
    "latch_retention_seconds",
    "subject_root",
    "sources",
    "rules",
}
SOURCE_KEYS = {"name", "path", "records", "max_age_seconds"}
RULE_KEYS = {
    "name",
    "source",
    "subject_field",
    "when",
    "evidence_fields",
    "action",
    "rank",
}
PREDICATE_KEYS = {"field", "op", "value"}
NUMERIC_OPS = {"lt", "le", "gt", "ge"}
ANY_OPS = {"eq", "ne"}
UNARY_OPS = {"present", "absent"}


class SpecError(Exception):
    """The spec cannot be trusted to produce findings."""


def cap(line: str) -> str:
    if len(line) <= LINE_CAP:
        return line
    keep = LINE_CAP - len(LINE_CAP_SUFFIX)
    return line[:keep] + LINE_CAP_SUFFIX


def clean(value: str) -> str:
    """One line, no control characters, no runs of whitespace."""
    return " ".join(CONTROL_RE.sub(" ", str(value)).split())


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def fmt_number(value) -> str:
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def fmt_value(value) -> str:
    if is_number(value):
        return fmt_number(value)
    return clean(value)


# --- spec ------------------------------------------------------------------


def require_keys(obj, allowed, where):
    if not isinstance(obj, dict):
        raise SpecError(f"{where} must be an object")
    extra = sorted(set(obj) - allowed)
    if extra:
        raise SpecError(f"{where} has unknown keys: {', '.join(extra)}")


def positive_int(obj, key, default, where):
    if key not in obj:
        return default
    value = obj[key]
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise SpecError(f"{where}.{key} must be a positive integer")
    return value


def load_spec(path: Path) -> dict:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SpecError("spec file is missing") from None
    except (OSError, ValueError) as exc:
        raise SpecError(f"spec file is unreadable: {exc}") from None

    require_keys(raw, SPEC_KEYS, "spec")
    if raw.get("version") != SPEC_VERSION:
        raise SpecError(f"spec version must be {SPEC_VERSION}")

    subject_root = raw.get("subject_root")
    if not isinstance(subject_root, str) or not subject_root:
        raise SpecError("spec.subject_root must be a non-empty path")

    spec = {
        "interval": positive_int(raw, "interval_seconds", DEFAULT_INTERVAL, "spec"),
        "cooldown": positive_int(
            raw, "subject_cooldown_seconds", DEFAULT_SUBJECT_COOLDOWN, "spec"
        ),
        "retention": positive_int(
            raw, "latch_retention_seconds", DEFAULT_LATCH_RETENTION, "spec"
        ),
        "subject_root": Path(os.path.expanduser(subject_root)),
        "sources": {},
        "rules": [],
    }

    sources = raw.get("sources")
    if not isinstance(sources, list) or not sources:
        raise SpecError("spec.sources must be a non-empty array")
    for index, source in enumerate(sources):
        where = f"sources[{index}]"
        require_keys(source, SOURCE_KEYS, where)
        name = source.get("name")
        if not isinstance(name, str) or not SUBJECT_RE.match(name or ""):
            raise SpecError(f"{where}.name must be a plain identifier")
        if name in spec["sources"]:
            raise SpecError(f"{where}.name is a duplicate: {name}")
        path_value = source.get("path")
        if not isinstance(path_value, str) or not path_value:
            raise SpecError(f"{where}.path must be a non-empty path")
        records = source.get("records", "")
        if not isinstance(records, str):
            raise SpecError(f"{where}.records must be a dotted key path")
        spec["sources"][name] = {
            "name": name,
            "path": Path(os.path.expanduser(path_value)),
            "records": records,
            "max_age": positive_int(
                source, "max_age_seconds", DEFAULT_SOURCE_MAX_AGE, where
            ),
        }

    rules = raw.get("rules")
    if not isinstance(rules, list) or not rules:
        raise SpecError("spec.rules must be a non-empty array")
    seen = set()
    for index, rule in enumerate(rules):
        where = f"rules[{index}]"
        require_keys(rule, RULE_KEYS, where)
        name = rule.get("name")
        if not isinstance(name, str) or not SUBJECT_RE.match(name or ""):
            raise SpecError(f"{where}.name must be a plain identifier")
        if name in seen:
            raise SpecError(f"{where}.name is a duplicate: {name}")
        seen.add(name)
        source = rule.get("source")
        if source not in spec["sources"]:
            raise SpecError(f"{where}.source names no declared source: {source}")
        subject_field = rule.get("subject_field")
        if not isinstance(subject_field, str) or not subject_field:
            raise SpecError(f"{where}.subject_field must be a field name")
        action = rule.get("action")
        if not isinstance(action, str) or not clean(action):
            raise SpecError(f"{where}.action must be a non-empty instruction")
        evidence_fields = rule.get("evidence_fields")
        if (
            not isinstance(evidence_fields, list)
            or not evidence_fields
            or not all(isinstance(f, str) and f for f in evidence_fields)
        ):
            raise SpecError(f"{where}.evidence_fields must be a non-empty field list")
        rank = rule.get("rank", 0)
        if not isinstance(rank, int) or isinstance(rank, bool):
            raise SpecError(f"{where}.rank must be an integer")
        when = rule.get("when")
        if not isinstance(when, list) or not when:
            raise SpecError(f"{where}.when must be a non-empty predicate array")
        predicates = []
        for pindex, predicate in enumerate(when):
            pwhere = f"{where}.when[{pindex}]"
            require_keys(predicate, PREDICATE_KEYS, pwhere)
            field = predicate.get("field")
            if not isinstance(field, str) or not field:
                raise SpecError(f"{pwhere}.field must be a field name")
            op = predicate.get("op")
            if op in UNARY_OPS:
                predicates.append((field, op, None))
                continue
            if op not in NUMERIC_OPS and op not in ANY_OPS:
                raise SpecError(f"{pwhere}.op is not supported: {op}")
            if "value" not in predicate:
                raise SpecError(f"{pwhere}.value is required for op {op}")
            value = predicate["value"]
            if op in NUMERIC_OPS and not is_number(value):
                raise SpecError(f"{pwhere}.value must be a number for op {op}")
            predicates.append((field, op, value))
        spec["rules"].append(
            {
                "name": name,
                "source": source,
                "subject_field": subject_field,
                "when": predicates,
                "evidence_fields": evidence_fields,
                "action": clean(action),
                "rank": rank,
            }
        )
    return spec


def walk_records(payload, dotted: str):
    node = payload
    if dotted:
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
    return node if isinstance(node, list) else None


# --- durable records -------------------------------------------------------


class Latch:
    """Emitted finding identities and per-subject wake times.

    One append-only-in-spirit TSV rewritten atomically, holding both record
    kinds because they expire on the same retention clock and are always read
    together. Losing it re-opens G6 and G7 for one retention window, which is
    why it is written before the line is printed rather than after.
    """

    def __init__(self, path: Path, retention: int, now: int):
        self.path = path
        self.retention = retention
        self.now = now
        self.findings: dict[str, int] = {}
        self.subjects: dict[str, int] = {}
        self._load()

    def _load(self):
        try:
            text = self.path.read_text(encoding="utf-8")
        except (FileNotFoundError, OSError):
            return
        for line in text.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            stamp, kind, key = parts
            try:
                when = int(stamp)
            except ValueError:
                continue
            if self.now - when >= self.retention:
                continue
            if kind == "finding":
                self.findings[key] = when
            elif kind == "subject":
                self.subjects[key] = max(when, self.subjects.get(key, 0))

    def seen_finding(self, identity: str) -> bool:
        return identity in self.findings

    def subject_cooling(self, subject: str, cooldown: int) -> int:
        when = self.subjects.get(subject)
        if when is None:
            return 0
        remaining = cooldown - (self.now - when)
        return remaining if remaining > 0 else 0

    def record(self, identity: str, subject: str):
        self.findings[identity] = self.now
        self.subjects[subject] = self.now
        lines = [f"{when}\tfinding\t{key}" for key, when in sorted(self.findings.items())]
        lines += [f"{when}\tsubject\t{key}" for key, when in sorted(self.subjects.items())]
        body = "".join(f"{line}\n" for line in lines)
        directory = self.path.parent
        handle = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=str(directory), prefix=".fm-standing-review-latch.",
            delete=False,
        )
        try:
            with handle:
                handle.write(body)
            os.chmod(handle.name, 0o600)
            os.replace(handle.name, self.path)
        except OSError:
            try:
                os.unlink(handle.name)
            except OSError:
                pass
            raise


# --- candidates ------------------------------------------------------------


class Candidate:
    def __init__(self, kind, rule, subject, evidence, action, rank, structural=False):
        self.kind = kind
        self.rule = rule
        self.subject = subject
        self.evidence = evidence          # list of (field, formatted value, numeric?)
        self.action = action
        self.rank = rank
        self.structural = structural

    @property
    def evidence_text(self) -> str:
        return " ".join(f"{field}={value}" for field, value, _ in self.evidence)

    @property
    def has_number(self) -> bool:
        return any(numeric for _, _, numeric in self.evidence)

    @property
    def identity(self) -> str:
        payload = "\x1f".join([self.rule, self.subject, self.evidence_text])
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]

    def line(self, review_id: str) -> str:
        return cap(
            f"review {review_id}: {self.rule} {self.subject} "
            f"[{self.evidence_text}] -> {self.action}"
        )

    def sort_key(self):
        return (-self.rank, self.rule, self.subject)


def structural(code: str, subject: str, evidence, action: str) -> Candidate:
    return Candidate(
        kind="structural",
        rule=code,
        subject=subject,
        evidence=evidence,
        action=action,
        rank=1_000_000,
        structural=True,
    )


def rule_candidates(spec, rule, records, explain):
    out = []
    for record in records:
        if not isinstance(record, dict):
            continue
        if not predicates_hold(rule["when"], record):
            continue
        subject_value = record.get(rule["subject_field"])
        subject = clean(subject_value) if subject_value is not None else ""
        evidence = []
        for field in rule["evidence_fields"]:
            value = record.get(field)
            if value is None:
                continue
            evidence.append((field, fmt_value(value), is_number(value)))
        out.append(
            Candidate(
                kind="rule",
                rule=rule["name"],
                subject=subject,
                evidence=evidence,
                action=rule["action"],
                rank=rule["rank"],
            )
        )
    return out


def predicates_hold(predicates, record) -> bool:
    for field, op, value in predicates:
        actual = record.get(field)
        if op == "present":
            if actual is None:
                return False
            continue
        if op == "absent":
            if actual is not None:
                return False
            continue
        if actual is None:
            return False
        if op == "eq":
            if actual != value:
                return False
        elif op == "ne":
            if actual == value:
                return False
        else:
            if not is_number(actual):
                return False
            if op == "lt" and not actual < value:
                return False
            if op == "le" and not actual <= value:
                return False
            if op == "gt" and not actual > value:
                return False
            if op == "ge" and not actual >= value:
                return False
    return True


# --- gate ------------------------------------------------------------------


def admissible(candidate, spec, latch, explain):
    """Apply G3, G4, G5, G6, G7. Returns None when admitted, else a reason."""
    if not candidate.subject or not SUBJECT_RE.match(candidate.subject):
        return "G3 shape: subject is empty or not a plain name"
    if not candidate.action:
        return "G3 shape: action is empty"
    if not candidate.evidence:
        return "G3 shape: no evidence field resolved on the record"
    if not candidate.has_number:
        return (
            "G4 quantified: evidence carries no measurement, only a "
            f"classification ({candidate.evidence_text})"
        )
    if not candidate.structural:
        target = spec["subject_root"] / candidate.subject
        if not target.is_dir():
            return f"G5 dispatchable: no work location at {target}"
    if latch.seen_finding(candidate.identity):
        return "G6 novelty: this exact finding already woke firstmate"
    remaining = latch.subject_cooling(candidate.subject, spec["cooldown"])
    if remaining:
        return f"G7 cooldown: {candidate.subject} woke recently, {remaining}s left"
    return None


# --- main ------------------------------------------------------------------


def build_structural(spec_path, spec, state_dir, review_id, now):
    """Structural candidates, plus the sources that are safe to review."""
    if spec is None:
        return [], {}
    fresh = {}
    out = []
    for name, source in sorted(spec["sources"].items()):
        try:
            mtime = int(source["path"].stat().st_mtime)
        except OSError:
            out.append(
                structural(
                    "source-missing",
                    f"{review_id}.{name}",
                    [("missing", "1", True)],
                    f"evidence source '{name}' is unreadable - {source['path']}",
                )
            )
            continue
        age = max(now - mtime, 0)
        if age >= source["max_age"]:
            out.append(
                structural(
                    "source-stale",
                    f"{review_id}.{name}",
                    [("age_seconds", str(age), True),
                     ("max_age_seconds", str(source["max_age"]), True)],
                    f"evidence source '{name}' stopped refreshing - {source['path']}",
                )
            )
            continue
        fresh[name] = source
    return out, fresh


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--home")
    parser.add_argument("--id")
    parser.add_argument("--state")
    parser.add_argument("--config")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--explain", action="store_true")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args, unknown = parser.parse_known_args()

    if args.help or unknown or not args.home or not args.id:
        root = os.environ.get("FM_STANDING_REVIEW_ROOT", ".")
        script = Path(root) / "bin" / "fm-standing-review.sh"
        try:
            for line in script.read_text(encoding="utf-8").splitlines():
                if not line.startswith("#") and line != "#!/usr/bin/env bash":
                    break
                sys.stderr.write(line.lstrip("#").lstrip() + "\n")
        except OSError:
            pass
        return 0 if args.help else 2

    review_id = args.id
    if not SUBJECT_RE.match(review_id) or "/" in review_id:
        sys.stderr.write("error: review id must be a plain identifier\n")
        return 2

    home = Path(args.home)
    state_dir = Path(
        args.state or os.environ.get("FM_STATE_OVERRIDE") or home / "state"
    )
    config_dir = Path(
        args.config or os.environ.get("FM_CONFIG_OVERRIDE") or home / "config"
    )
    spec_path = config_dir / "standing-reviews" / f"{review_id}.json"

    if args.validate:
        try:
            spec = load_spec(spec_path)
        except SpecError as exc:
            sys.stderr.write(f"error: {spec_path}: {exc}\n")
            return 1
        sys.stderr.write(
            f"ok: {spec_path} declares {len(spec['sources'])} source(s) and "
            f"{len(spec['rules'])} rule(s), reviewed every {spec['interval']}s, "
            f"subjects under {spec['subject_root']}\n"
        )
        if not spec["subject_root"].is_dir():
            sys.stderr.write(
                f"error: subject_root is not a directory: {spec['subject_root']}\n"
            )
            return 1
        return 0

    if not state_dir.is_dir():
        sys.stderr.write(f"error: state directory is unavailable: {state_dir}\n")
        return 1

    now = int(time.time())
    cadence_path = state_dir / f"{review_id}.standing-review-last"
    latch_path = state_dir / f"{review_id}.standing-review-latch"

    # G1 cadence. Read the interval from the spec when it parses, so a spec can
    # slow itself down; a broken spec still reports on the default interval
    # rather than every sweep.
    spec = None
    spec_error = None
    try:
        spec = load_spec(spec_path)
    except SpecError as exc:
        spec_error = str(exc)

    interval = spec["interval"] if spec else DEFAULT_INTERVAL
    retention = spec["retention"] if spec else DEFAULT_LATCH_RETENTION
    cooldown = spec["cooldown"] if spec else DEFAULT_SUBJECT_COOLDOWN

    if not args.dry_run:
        try:
            since = now - int(cadence_path.stat().st_mtime)
        except OSError:
            since = interval
        if since < interval:
            if args.explain:
                sys.stderr.write(
                    f"skip G1 cadence: {interval - since}s until the next review\n"
                )
            return 0
        # Stamp before the work, so a review that dies partway does not repeat
        # every sweep until it succeeds.
        try:
            cadence_path.touch()
            os.chmod(cadence_path, 0o600)
        except OSError as exc:
            sys.stderr.write(f"error: cannot record the review cadence: {exc}\n")
            return 1

    latch = Latch(latch_path, retention, now)
    effective = spec or {
        "subject_root": Path("/"),
        "cooldown": cooldown,
        "sources": {},
        "rules": [],
    }

    candidates = []
    if spec_error is not None:
        candidates.append(
            structural(
                "spec-invalid",
                review_id,
                [("errors", "1", True)],
                f"{spec_error} - repair the review spec at {spec_path}",
            )
        )
    else:
        structural_found, fresh_sources = build_structural(
            spec_path, spec, state_dir, review_id, now
        )
        candidates.extend(structural_found)
        payloads = {}
        for name, source in fresh_sources.items():
            try:
                payloads[name] = json.loads(source["path"].read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                candidates.append(
                    structural(
                        "source-invalid",
                        f"{review_id}.{name}",
                        [("errors", "1", True)],
                        f"evidence source '{name}' is unparseable: {exc}",
                    )
                )
        for rule in spec["rules"]:
            if rule["source"] not in payloads:
                continue
            source = fresh_sources[rule["source"]]
            records = walk_records(payloads[rule["source"]], source["records"])
            if records is None:
                candidates.append(
                    structural(
                        "source-invalid",
                        f"{review_id}.{rule['source']}",
                        [("errors", "1", True)],
                        f"evidence source '{rule['source']}' has no record array at "
                        f"'{source['records'] or '<root>'}' - {source['path']}",
                    )
                )
                continue
            candidates.extend(rule_candidates(spec, rule, records, args.explain))

    # G8 one line: rank, then decide. Structural findings outrank rule findings
    # because a review must report its own blindness before what it saw blind.
    candidates.sort(key=lambda c: c.sort_key())
    chosen = None
    for candidate in candidates:
        reason = admissible(candidate, effective, latch, args.explain)
        if reason is None:
            chosen = candidate
            break
        if args.explain:
            sys.stderr.write(
                f"reject {candidate.rule}/{candidate.subject or '<no subject>'}: {reason}\n"
            )

    if chosen is None:
        if args.explain:
            sys.stderr.write(f"quiet: {len(candidates)} candidates, none admissible\n")
        return 0

    if not args.dry_run:
        try:
            latch.record(chosen.identity, chosen.subject)
        except OSError as exc:
            # Printing without latching would re-wake every sweep, which is the
            # one failure this check must not have. Stay quiet and say why.
            sys.stderr.write(f"error: cannot record the wake, staying quiet: {exc}\n")
            return 1

    sys.stdout.write(chosen.line(review_id) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
