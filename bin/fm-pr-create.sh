#!/usr/bin/env bash
# Create a direct-PR pull request with either an explicitly supplied body or
# Firstmate's generated concise narrative.
#
# Usage: fm-pr-create.sh <task-id> --repo <owner/name> --title <text>
#          --problem <one-line sentence> --outcome <one-line sentence> --tests <text>
#          [--base <branch>] [--head <branch>] [--draft]
#        fm-pr-create.sh <task-id> --repo <owner/name> --title <text>
#          (--body <text> | --body-file <path>) [--base <branch>] [--head <branch>] [--draft]
#
# The generated narrative contract lives here, rather than in the brief: its body
# opens with one one-line Problem sentence, one one-line Outcome sentence, and a
# Tests section in that order. A Worker provenance section is optional and is
# derived only from one well-formed recorded state/<task-id>.meta file. It never
# accepts worker prose or a caller-provided provenance value. Missing, malformed,
# incomplete, or untrusted metadata omits provenance without blocking PR creation.
#
# An explicit --body or --body-file is user-authored content. This script passes it
# to gh-axi unchanged and does not generate, append, or overwrite its narrative.
# All GitHub mutation calls run through fm-gh.sh and require an explicit --repo.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "error: $*" >&2
  exit 2
}

repo_valid() {
  local repo=$1 owner name
  case "$repo" in
    */*) owner=${repo%%/*}; name=${repo#*/} ;;
    *) return 1 ;;
  esac
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  case "$name" in */*) return 1 ;; esac
  case "$owner" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}

one_line_text() {
  local text=$1
  [ -n "$text" ] || return 1
  [ "${#text}" -le 240 ] || return 1
  case "$text" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
}

reserved_provenance_heading() {
  local text=$1 line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      '## Worker provenance'*|'# Worker provenance'*|'Worker provenance'*) return 0 ;;
    esac
  done <<EOF
$text
EOF
  return 1
}

meta_provenance() {  # <state/meta path> -> stdout, or nothing
  local meta=$1 line harness='' model='' effort='' kind='' mode=''
  local harness_count=0 model_count=0 effort_count=0 kind_count=0 mode_count=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      harness=*)
        harness_count=$((harness_count + 1))
        harness=${line#harness=}
        ;;
      model=*)
        model_count=$((model_count + 1))
        model=${line#model=}
        ;;
      effort=*)
        effort_count=$((effort_count + 1))
        effort=${line#effort=}
        ;;
      kind=*)
        kind_count=$((kind_count + 1))
        kind=${line#kind=}
        ;;
      mode=*)
        mode_count=$((mode_count + 1))
        mode=${line#mode=}
        ;;
    esac
  done < "$meta"
  [ "$harness_count" -eq 1 ] && [ "$model_count" -eq 1 ] && [ "$effort_count" -eq 1 ] \
    && [ "$kind_count" -eq 1 ] && [ "$mode_count" -eq 1 ] || return 0
  [ "$kind" = ship ] && [ "$mode" = direct-PR ] || return 0
  case "$harness" in claude|codex|opencode|pi|pi-signed|grok|kimi) ;; *) return 0 ;; esac
  case "$model" in ''|*[!A-Za-z0-9._:+/-]*) return 0 ;; esac
  case "$effort" in low|medium|high|xhigh|max|default) ;; *) return 0 ;; esac
  printf '%s\n' "$harness|$model|$effort"
}

ID=
REPO=
TITLE=
PROBLEM=
OUTCOME=
TESTS=
CUSTOM_BODY=
CUSTOM_BODY_FILE=
CUSTOM_BODY_SET=0
CUSTOM_BODY_FILE_SET=0
BASE=
HEAD=
DRAFT=0
want_value=
POS=()

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

while [ "$#" -gt 0 ]; do
  arg=$1
  shift
  if [ -n "$want_value" ]; then
    case "$arg" in --*) die "--$want_value requires a value" ;; esac
    case "$want_value" in
      repo) REPO=$arg ;;
      title) TITLE=$arg ;;
      problem) PROBLEM=$arg ;;
      outcome) OUTCOME=$arg ;;
      tests) TESTS=$arg ;;
      body) CUSTOM_BODY=$arg; CUSTOM_BODY_SET=1 ;;
      body-file) CUSTOM_BODY_FILE=$arg; CUSTOM_BODY_FILE_SET=1 ;;
      base) BASE=$arg ;;
      head) HEAD=$arg ;;
    esac
    want_value=
    continue
  fi
  case "$arg" in
    --repo|--title|--problem|--outcome|--tests|--body|--body-file|--base|--head)
      want_value=${arg#--}
      ;;
    --repo=*) REPO=${arg#--repo=} ;;
    --title=*) TITLE=${arg#--title=} ;;
    --problem=*) PROBLEM=${arg#--problem=} ;;
    --outcome=*) OUTCOME=${arg#--outcome=} ;;
    --tests=*) TESTS=${arg#--tests=} ;;
    --body=*) CUSTOM_BODY=${arg#--body=}; CUSTOM_BODY_SET=1 ;;
    --body-file=*) CUSTOM_BODY_FILE=${arg#--body-file=}; CUSTOM_BODY_FILE_SET=1 ;;
    --base=*) BASE=${arg#--base=} ;;
    --head=*) HEAD=${arg#--head=} ;;
    --draft) DRAFT=1 ;;
    --*) die "unknown option: $arg" ;;
    *) POS+=("$arg") ;;
  esac
done

[ -z "$want_value" ] || die "--$want_value requires a value"
[ "${#POS[@]}" -eq 1 ] || die "usage: fm-pr-create.sh <task-id> ..."
ID=${POS[0]}
fm_task_id_creation_valid "$ID" || die "invalid task id: $ID"
repo_valid "$REPO" || die "--repo must be one explicit owner/name target"
[ -n "$TITLE" ] || die "--title is required"
if [ "$CUSTOM_BODY_SET" -eq 1 ] && [ "$CUSTOM_BODY_FILE_SET" -eq 1 ]; then
  die "--body and --body-file are mutually exclusive"
fi
if [ "$CUSTOM_BODY_SET" -eq 1 ] || [ "$CUSTOM_BODY_FILE_SET" -eq 1 ]; then
  [ -z "$PROBLEM$OUTCOME$TESTS" ] || die "custom PR bodies cannot be mixed with generated narrative inputs"
  args=(pr create --repo "$REPO" --title "$TITLE")
  [ -z "$BASE" ] || args+=(--base "$BASE")
  [ -z "$HEAD" ] || args+=(--head "$HEAD")
  [ "$DRAFT" -eq 0 ] || args+=(--draft)
  if [ "$CUSTOM_BODY_FILE_SET" -eq 1 ]; then
    args+=(--body-file "$CUSTOM_BODY_FILE")
  else
    args+=(--body "$CUSTOM_BODY")
  fi
  exec "$SCRIPT_DIR/fm-gh.sh" gh "${args[@]}"
fi

one_line_text "$PROBLEM" || die "--problem must be one non-empty line of at most 240 characters"
one_line_text "$OUTCOME" || die "--outcome must be one non-empty line of at most 240 characters"
[ -n "$TESTS" ] || die "--tests is required for generated narratives"
if reserved_provenance_heading "$PROBLEM" || reserved_provenance_heading "$OUTCOME" || reserved_provenance_heading "$TESTS"; then
  die "generated narrative text must not add a Worker provenance heading"
fi

body_file=$(mktemp "${TMPDIR:-/tmp}/fm-pr-body.XXXXXX") || exit 1
trap 'rm -f -- "$body_file"' EXIT HUP INT TERM
{
  printf '## Problem\n%s\n\n## Outcome\n%s\n\n## Tests\n%s\n' "$PROBLEM" "$OUTCOME" "$TESTS"
  provenance=$(meta_provenance "$STATE/$ID.meta")
  if [ -n "$provenance" ]; then
    IFS='|' read -r meta_harness meta_model meta_effort <<EOF
$provenance
EOF
    printf '\n## Worker provenance\n- harness: %s\n- model: %s\n- effort: %s\n' \
      "$meta_harness" "$meta_model" "$meta_effort"
  fi
} > "$body_file"

args=(pr create --repo "$REPO" --title "$TITLE" --body-file "$body_file")
[ -z "$BASE" ] || args+=(--base "$BASE")
[ -z "$HEAD" ] || args+=(--head "$HEAD")
[ "$DRAFT" -eq 0 ] || args+=(--draft)
"$SCRIPT_DIR/fm-gh.sh" gh "${args[@]}"
