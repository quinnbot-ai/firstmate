#!/usr/bin/env bash
# fm-skill-trigger-lint.sh - advisory warnings about skill routing descriptions.
#
# A skill's frontmatter description is routing metadata: it is what an agent
# reads to decide whether to load the skill. This checker reads only SKILL.md
# frontmatter under the canonical skill roots, prints deterministic path-owned
# findings, and never edits a file.
#
# Findings are advisory. Warnings always exit 0, so no caller - including
# bin/fm-lint.sh - can fail a build on routing style. Only an unsafe or
# unreadable explicit root refuses, with exit 2.
#
# The bounded heuristics report malformed frontmatter, a description with no
# trigger wording, an instruction dump used as a description, and two or more
# distinctive trigger words shared by two skills under the same root.
#
# Usage:
#   fm-skill-trigger-lint.sh                 inspect .agents/skills and skills
#   fm-skill-trigger-lint.sh --root <path>   inspect explicit roots (repeatable)
#   fm-skill-trigger-lint.sh --help          print this usage
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-skill-trigger-lint.sh"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

fm_skill_usage() {
  sed -n '2,20{s/^# \{0,1\}//;p;}' "$SELF"
}

fm_skill_refuse() {
  printf 'fm-skill-trigger-lint.sh: refused: %s\n' "$1" >&2
  exit 2
}

ROOTS=()
EXPLICIT_ROOTS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fm_skill_refuse '--root requires a path'
      ROOTS+=("$2")
      EXPLICIT_ROOTS=1
      shift 2
      ;;
    --root=*)
      ROOTS+=("${1#*=}")
      EXPLICIT_ROOTS=1
      shift
      ;;
    --help|-h)
      fm_skill_usage
      exit 0
      ;;
    *)
      fm_skill_refuse "unknown argument: $1"
      ;;
  esac
done
[ "$EXPLICIT_ROOTS" -eq 1 ] || ROOTS=("$REPO_ROOT/.agents/skills" "$REPO_ROOT/skills")

# Parse one SKILL.md frontmatter block. Prints exactly one tab-separated record:
# "bad <line> <evidence>" for frontmatter this checker cannot route on, or
# "ok <line> <description>" with block scalars folded onto one line.
# shellcheck disable=SC2016 # single quotes are deliberate: awk expands its own field references.
PARSE_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flatten(s) { gsub(/\t/, " ", s); return s }
{ L[NR] = $0 }
END {
  if (NR == 0 || trim(L[1]) != "---") { print "bad\t1\tmissing opening ---"; exit }
  end = 0
  for (i = 2; i <= NR; i++) { if (trim(L[i]) == "---") { end = i; break } }
  if (end == 0) { print "bad\t1\tmissing closing ---"; exit }
  i = 2
  have = 0
  dline = 1
  desc = ""
  while (i < end) {
    if (L[i] ~ /^[A-Za-z][A-Za-z0-9_-]*:/) {
      key = L[i]
      sub(/:.*$/, "", key)
      value = L[i]
      sub(/^[A-Za-z][A-Za-z0-9_-]*:[ \t]*/, "", value)
      value = trim(value)
      if (key != "description") {
        i++
        while (i < end && (L[i] ~ /^[ \t]/ || trim(L[i]) == "")) { i++ }
        continue
      }
      if (have) { print "bad\t" i "\tduplicate description"; exit }
      have = 1
      dline = i
      if (value == ">" || value == ">-" || value == ">+" || value == "|" || value == "|-" || value == "|+") {
        i++
        block = ""
        while (i < end && (L[i] ~ /^[ \t]/ || trim(L[i]) == "")) {
          part = trim(L[i])
          if (part != "") { block = (block == "" ? part : block " " part) }
          i++
        }
        desc = block
        continue
      }
      quote = substr(value, 1, 1)
      if ((quote == "\047" || quote == "\"") && length(value) > 1 && substr(value, length(value), 1) == quote) {
        value = substr(value, 2, length(value) - 2)
      }
      desc = value
      i++
      continue
    }
    if (trim(L[i]) != "") { print "bad\t" i "\t" flatten(trim(L[i])); exit }
    i++
  }
  if (!have) { print "bad\t1\tdescription is missing"; exit }
  print "ok\t" dline "\t" flatten(desc)
}
'

# Turn parsed records into sortable findings. Each input record is
# "group <path> <kind> <line> <text>"; each finding is
# "path <padded-line> <reason> <evidence>".
# shellcheck disable=SC2016 # single quotes are deliberate: awk expands its own field references.
REPORT_AWK='
BEGIN {
  FS = "\t"
  OFS = "\t"
  TRIGGER_CLAUSE = "(^|[^a-z])(when|whenever|before|after|on) [a-z]"
  TRIGGER_ADDRESS = " (captain|user|users) (invokes|invoke|asks|ask|says|say) "
  INSTRUCTION = " (before|after|never|owns|contains|step|steps|must|should|ensure|confirm|read|run|pass|record) "
  INSTRUCTION_PAIR = " do not "
  STOP = " about agent agents captain current firstmate from load when with this that skill skills before after using reports report work procedure reference policy playbook operator operations handling handle task tasks project invokes invoke explicitly says asks request requests whenever actionable "
}
function normalize(s,   n) { n = tolower(s); gsub(/[^a-z0-9-]+/, " ", n); return " " n " " }
function evidence(s,   c) {
  c = s
  gsub(/[ \t]+/, " ", c)
  c = trim(c)
  if (length(c) > 160) { c = substr(c, 1, 157) "..." }
  return c
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function dots(s,   c, n) { c = s; n = gsub(/\./, ".", c); return n }
function has_trigger(s,   n) { n = normalize(s); return (tolower(s) ~ TRIGGER_CLAUSE) || (n ~ TRIGGER_ADDRESS) }
function trigger_words(s,   lc, clause, cut, parts, count, i, w, out) {
  lc = tolower(s)
  if (!match(lc, TRIGGER_CLAUSE)) { return "" }
  clause = substr(lc, RSTART)
  cut = index(clause, ".")
  if (cut > 0) { clause = substr(clause, 1, cut - 1) }
  gsub(/[^a-z0-9-]+/, " ", clause)
  count = split(clause, parts, " ")
  out = ""
  for (i = 1; i <= count; i++) {
    w = parts[i]
    if (length(w) < 5 || w !~ /^[a-z]/) { continue }
    if (index(STOP, " " w " ") > 0) { continue }
    if (index(" " out " ", " " w " ") > 0) { continue }
    out = (out == "" ? w : out " " w)
  }
  return out
}
function shared_words(a, b,   parts, count, i, hits, j, swap, out) {
  count = split(a, parts, " ")
  hits = 0
  for (i = 1; i <= count; i++) {
    if (index(" " b " ", " " parts[i] " ") > 0) { hits++; found[hits] = parts[i] }
  }
  for (i = 1; i <= hits; i++) {
    for (j = i + 1; j <= hits; j++) {
      if (found[j] < found[i]) { swap = found[i]; found[i] = found[j]; found[j] = swap }
    }
  }
  out = ""
  for (i = 1; i <= hits; i++) { out = (out == "" ? found[i] : out ", " found[i]) }
  shared_count = hits
  return out
}
function emit(path, line, reason, ev) { printf "%s\t%06d\t%s\t%s\n", path, line + 0, reason, ev }
{
  n++
  group[n] = $1
  path[n] = $2
  kind[n] = $3
  line[n] = $4
  text[n] = $5
}
END {
  for (i = 1; i <= n; i++) {
    if (kind[i] == "bad") {
      emit(path[i], line[i], "malformed frontmatter", evidence(text[i]))
      continue
    }
    norm = normalize(text[i])
    if (length(text[i]) > 360 || (dots(text[i]) >= 4 && (norm ~ INSTRUCTION || index(norm, INSTRUCTION_PAIR) > 0))) {
      emit(path[i], line[i], "instruction dump in frontmatter", evidence(text[i]))
    }
    if (!has_trigger(text[i])) {
      emit(path[i], line[i], "missing trigger wording", evidence(text[i]))
    }
    words[i] = trigger_words(text[i])
  }
  for (i = 1; i <= n; i++) {
    if (kind[i] != "ok" || words[i] == "") { continue }
    for (j = i + 1; j <= n; j++) {
      if (kind[j] != "ok" || words[j] == "" || group[i] != group[j]) { continue }
      list = shared_words(words[i], words[j])
      if (shared_count < 2) { continue }
      emit(path[i], line[i], "overlapping adjacent trigger words", "shared with " path[j] ": " list)
      emit(path[j], line[j], "overlapping adjacent trigger words", "shared with " path[i] ": " list)
    }
  }
}
'

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-trigger.XXXXXX") || exit 2
trap 'rm -rf "$TMP_ROOT"' EXIT
RECORDS="$TMP_ROOT/records"
: > "$RECORDS"

group=0
for root in "${ROOTS[@]}"; do
  group=$((group + 1))
  if [ ! -e "$root" ] || [ ! -d "$root" ] || [ -L "$root" ]; then
    [ "$EXPLICIT_ROOTS" -eq 1 ] || continue
    fm_skill_refuse "root is not a real directory: $root"
  fi
  escape=$(find "$root" -mindepth 1 -type l 2>/dev/null | LC_ALL=C sort | head -n 1)
  [ -z "$escape" ] || fm_skill_refuse "symlink inside root: $escape"
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    display=${skill#"$PWD"/}
    if [ ! -r "$skill" ]; then
      printf '%s\t%s\tbad\t1\tunreadable file\n' "$group" "$display" >> "$RECORDS"
      continue
    fi
    record=$(awk "$PARSE_AWK" "$skill" 2>/dev/null) || record=
    [ -n "$record" ] || record=$(printf 'bad\t1\tunreadable file')
    printf '%s\t%s\t%s\n' "$group" "$display" "$record" >> "$RECORDS"
  done < <(find "$root" -type f -name SKILL.md 2>/dev/null | LC_ALL=C sort)
done

awk "$REPORT_AWK" "$RECORDS" \
  | LC_ALL=C sort -u \
  | awk -F'\t' '{ printf "skill-trigger-warning: %s:%d: %s; evidence: %s\n", $1, $2 + 0, $3, $4 }'
exit 0
