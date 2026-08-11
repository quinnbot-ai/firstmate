#!/usr/bin/env bash
# fm-agent-retro.sh - bounded, read-only retrospective of recent agent work.
#
# Output contract: `fm-agent-retro.v1` TOON on stdout.
#
# This command reads only this home's state/<id>.meta, state/<id>.status, and
# state/<id>.turn-ended records. It never reads transcripts, prompts, project
# files, credentials, hooks, or arbitrary paths from task metadata. The bounded
# task window is selected by metadata mtime and stable task-id tie-breaker. It
# validates every selected source as a single-link, non-symlink regular file,
# refuses malformed records, holds the internal model as JSON, and renders TOON
# only at the output boundary. Examples are numbered task samples, never ids,
# paths, commands, tokens, or status text.
#
# usage: fm-agent-retro.sh [--window <1-100>] [--help]
#
# Default output is local-only and read-only. Every suggested instruction or
# test change is a proposal requiring human approval.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DEFAULT_WINDOW=${FM_AGENT_RETRO_WINDOW:-40}
STATUS_LINES=${FM_AGENT_RETRO_STATUS_LINES:-64}
MAX_META_BYTES=16384
MAX_STATUS_BYTES=16384
MAX_TURN_BYTES=1024
MAX_WINDOW=100

usage() {
  cat <<'EOF'
usage: fm-agent-retro.sh [--window <1-100>]

Read-only, local-only retrospective over bounded Firstmate task records.
Prints compact TOON with redacted examples and approval-gated proposals.
Run fm-agent-retro.sh --window 40 for the default safe recent sample.
EOF
}

toon_error() { # <message> [help]
  local message=$1 help=${2:-'Run fm-agent-retro.sh --help for safe usage.'}
  command -v jq >/dev/null 2>&1 || {
    printf 'schema: "fm-agent-retro.v1"\nerror: %s\nhelp: %s\n' "$message" "$help"
    return
  }
  jq -rn --arg message "$message" --arg help "$help" \
    '"schema: \"fm-agent-retro.v1\"", "error: \($message|@json)", "help: \($help|@json)"'
}

die() { toon_error "$1" "${2:-Run fm-agent-retro.sh --help for safe usage.}"; exit "${3:-1}"; }

positive_bound() { # <value> <maximum>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le "$2" ]
}

WINDOW=$DEFAULT_WINDOW
while [ "$#" -gt 0 ]; do
  case "$1" in
    --window)
      [ "$#" -ge 2 ] || die '--window requires a value' 'Run fm-agent-retro.sh --window <1-100>.' 2
      WINDOW=$2
      shift
      ;;
    --window=*) WINDOW=${1#--window=} ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown flag $1" 'Valid flags: --window <1-100>, --help.' 2 ;;
    *) die "unknown argument $1" 'Valid flags: --window <1-100>, --help.' 2 ;;
  esac
  shift
done

positive_bound "$WINDOW" "$MAX_WINDOW" || die '--window must be an integer from 1 to 100' 'Run fm-agent-retro.sh --window <1-100>.' 2
positive_bound "$STATUS_LINES" 256 || die 'FM_AGENT_RETRO_STATUS_LINES must be an integer from 1 to 256' '' 2
command -v jq >/dev/null 2>&1 || die 'jq is required to render the retrospective safely' 'Install jq, then rerun fm-agent-retro.sh.'

HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die 'FM_HOME is unavailable or unsafe'
[ -d "$HOME_REAL/state" ] && [ ! -L "$HOME_REAL/state" ] || die 'state directory is missing, not a directory, or symlinked'
STATE=$(CDPATH='' cd -- "$HOME_REAL/state" 2>/dev/null && pwd -P) || die 'state directory is unavailable or unsafe'
[ "$STATE" = "$HOME_REAL/state" ] || die 'state directory escapes this Firstmate home'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-retro.XXXXXX") || die 'could not create bounded private analysis workspace'
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT HUP INT TERM

file_links() { # <file>
  if [ "$(uname)" = Darwin ]; then
    stat -f '%l' -- "$1" 2>/dev/null
  else
    stat -c '%h' -- "$1" 2>/dev/null
  fi
}

file_mtime() { # <file>
  if [ "$(uname)" = Darwin ]; then
    stat -f '%m' -- "$1" 2>/dev/null
  else
    stat -c '%Y' -- "$1" 2>/dev/null
  fi
}

safe_file() { # <file> <max-bytes> <label>
  local file=$1 max=$2 label=$3 bytes links
  [ -f "$file" ] && [ ! -L "$file" ] || die "$label is not a non-symlink regular file"
  links=$(file_links "$file") || die "$label link count cannot be verified"
  [ "$links" = 1 ] || die "$label is not a single-link source record"
  bytes=$(LC_ALL=C wc -c < "$file" | tr -d ' ') || die "$label size cannot be read"
  case "$bytes" in ''|*[!0-9]*) die "$label size is invalid" ;; esac
  [ "$bytes" -le "$max" ] || die "$label exceeds the bounded source size"
}

safe_id() { # <id>
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*|*..) return 1 ;; esac
  return 0
}

validate_meta() { # <file> <label>
  awk '
    length($0) > 512 { exit 1 }
    $0 !~ /^[A-Za-z][A-Za-z0-9_]*=[ -~]*$/ { exit 1 }
  ' "$1" || die "$2 is malformed"
}

meta_value() { # <file> <key>
  awk -v key="$2" '
    index($0, key "=") == 1 {
      if (found++) exit 2
      value=substr($0, length(key) + 2)
    }
    END { if (found == 1) print value; else if (found > 1) exit 2 }
  ' "$1"
}

safe_meta_value() { # <value>
  case "$1" in ''|unknown) printf 'unknown\n' ;; *[!A-Za-z0-9._+/-]*) return 1 ;; *) printf '%s\n' "$1" ;; esac
}

validate_status_tail() { # <file> <label>
  tail -n "$STATUS_LINES" -- "$1" | awk '
    length($0) > 512 { exit 1 }
    $0 != "" && $0 !~ /^[a-z][a-z-]*: [ -~]*$/ { exit 1 }
  ' || die "$2 is malformed"
}

: > "$TMP/candidates"
# Reject unsafe metadata before choosing the bounded window. This never reads an
# unselected file's content, but it prevents a hidden symlink from being ignored.
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  safe_id "$id" || die 'task metadata filename is unsafe'
  safe_file "$meta" "$MAX_META_BYTES" "metadata for task $id"
  mtime=$(file_mtime "$meta") || die "metadata mtime cannot be read for task $id"
  case "$mtime" in ''|*[!0-9]*) die "metadata mtime is invalid for task $id" ;; esac
  printf '%s\t%s\n' "$mtime" "$id" >> "$TMP/candidates"
done

if [ -s "$TMP/candidates" ]; then
  LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 "$TMP/candidates" | head -n "$WINDOW" > "$TMP/selected"
else
  : > "$TMP/selected"
fi

TASKS_TOTAL=$(LC_ALL=C wc -l < "$TMP/candidates" 2>/dev/null | tr -d ' ' || printf '0')
TASKS_SAMPLED=$(LC_ALL=C wc -l < "$TMP/selected" | tr -d ' ')
STATUS_LOGS=0
STATUS_EVENTS=0
TURN_ENDS=0
TERMINAL_OUTCOMES=0
CI_REVIEW_CLASSES=0
TERMINAL_FAILURES=0
GATE_FAILURES=0

: > "$TMP/tasks.jsonl"
while IFS="$(printf '\t')" read -r _mtime id; do
  [ -n "$id" ] || continue
  meta="$STATE/$id.meta"
  validate_meta "$meta" "metadata for task $id"
  harness=$(meta_value "$meta" harness) || die "metadata harness is ambiguous for task $id"
  model=$(meta_value "$meta" model) || die "metadata model is ambiguous for task $id"
  effort=$(meta_value "$meta" effort) || die "metadata effort is ambiguous for task $id"
  kind=$(meta_value "$meta" kind) || die "metadata kind is ambiguous for task $id"
  mode=$(meta_value "$meta" mode) || die "metadata mode is ambiguous for task $id"
  harness=$(safe_meta_value "$harness") || die "metadata harness is unsafe for task $id"
  model=$(safe_meta_value "$model") || die "metadata model is unsafe for task $id"
  effort=$(safe_meta_value "$effort") || die "metadata effort is unsafe for task $id"
  kind=$(safe_meta_value "$kind") || die "metadata kind is unsafe for task $id"
  mode=$(safe_meta_value "$mode") || die "metadata mode is unsafe for task $id"

  terminal=0
  terminal_failed=0
  status="$STATE/$id.status"
  if [ -e "$status" ] || [ -L "$status" ]; then
    safe_file "$status" "$MAX_STATUS_BYTES" "status log for task $id"
    validate_status_tail "$status" "status log for task $id"
    STATUS_LOGS=$((STATUS_LOGS + 1))
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      STATUS_EVENTS=$((STATUS_EVENTS + 1))
      verb=${line%%:*}
      body=${line#*: }
      case "$verb" in
        done)
          terminal=1
          TERMINAL_OUTCOMES=$((TERMINAL_OUTCOMES + 1))
          case "$body" in *'checks green'*) CI_REVIEW_CLASSES=$((CI_REVIEW_CLASSES + 1)) ;; esac
          ;;
        failed)
          terminal=1
          terminal_failed=1
          TERMINAL_OUTCOMES=$((TERMINAL_OUTCOMES + 1))
          lower=$(printf '%s' "$body" | LC_ALL=C tr '[:upper:]' '[:lower:]')
          case "$lower" in
            *'ci failed'*|*'checks failed'*|*'review failed'*) GATE_FAILURES=$((GATE_FAILURES + 1)); CI_REVIEW_CLASSES=$((CI_REVIEW_CLASSES + 1)) ;;
            *) TERMINAL_FAILURES=$((TERMINAL_FAILURES + 1)) ;;
          esac
          ;;
        blocked|needs-decision) GATE_FAILURES=$((GATE_FAILURES + 1)) ;;
      esac
    done <<EOF
$(tail -n "$STATUS_LINES" -- "$status")
EOF
  fi

  turn="$STATE/$id.turn-ended"
  if [ -e "$turn" ] || [ -L "$turn" ]; then
    safe_file "$turn" "$MAX_TURN_BYTES" "turn-end marker for task $id"
    TURN_ENDS=$((TURN_ENDS + 1))
  fi
  jq -cn --arg kind "$kind" --arg mode "$mode" --arg harness "$harness" --arg model "$model" --arg effort "$effort" \
    --argjson terminal "$terminal" --argjson terminal_failed "$terminal_failed" \
    '{kind:$kind, mode:$mode, harness:$harness, model:$model, effort:$effort, terminal:$terminal, terminal_failed:$terminal_failed}' >> "$TMP/tasks.jsonl"
done < "$TMP/selected"

MODEL=$(jq -s \
  --argjson window "$WINDOW" --argjson tasks_total "$TASKS_TOTAL" --argjson tasks_sampled "$TASKS_SAMPLED" \
  --argjson status_logs "$STATUS_LOGS" --argjson status_events "$STATUS_EVENTS" --argjson turn_ends "$TURN_ENDS" \
  --argjson terminal_outcomes "$TERMINAL_OUTCOMES" --argjson ci_review_classes "$CI_REVIEW_CLASSES" \
  --argjson terminal_failures "$TERMINAL_FAILURES" --argjson gate_failures "$GATE_FAILURES" '
  def task_mix:
    sort_by(.kind, .mode, .harness, .model, .effort)
    | group_by([.kind, .mode, .harness, .model, .effort])
    | map({kind:.[0].kind, mode:.[0].mode, harness:.[0].harness, model:.[0].model, effort:.[0].effort, tasks:length});
  def model_comparisons:
    [ sort_by(.kind, .mode, .harness, .effort, .model)
      | group_by([.kind, .mode, .harness, .effort])[]
      | [sort_by(.model) | group_by(.model)[] | select(length >= 20)] as $models
      | select(($models | length) >= 2)
      | $models[]
      | {kind:.[0].kind, mode:.[0].mode, harness:.[0].harness, effort:.[0].effort,
         model:.[0].model, tasks:length, terminal_failures:(map(select(.terminal_failed == 1)) | length),
         failure_rate: ((map(select(.terminal_failed == 1)) | length) / length)}
    ] | sort_by(.kind, .mode, .harness, .effort, .failure_rate, .model);
  . as $tasks
  | ([
      if $terminal_failures > 0 then
        {category:"terminal_failure", count:$terminal_failures, examples:([$terminal_failures, 3] | min), proposal:"Record the failing verification class before retrying."}
      else empty end,
      if $gate_failures > 0 then
        {category:"workflow_gate", count:$gate_failures, examples:([$gate_failures, 3] | min), proposal:"State the one missing authority or prerequisite before pausing work."}
      else empty end
    ] | sort_by(-.count, .category) | to_entries | map(.value + {rank:(.key + 1)})) as $failures
  | (model_comparisons) as $comparisons
  | {schema:"fm-agent-retro.v1", state:(if $tasks_sampled == 0 then "empty" else "ok" end), window:$window,
     tasks:{sampled:$tasks_sampled,total:$tasks_total},
     source_coverage:{metadata_tasks:$tasks_sampled,status_logs:$status_logs,status_events:$status_events,turn_end_markers:$turn_ends,terminal_outcomes:$terminal_outcomes,ci_review_classes:$ci_review_classes},
     task_mix:($tasks | task_mix), failure_categories:$failures,
     model_comparisons:$comparisons,
     model_quality:(if ($comparisons|length) > 0 then "bounded descriptive comparison: each controlled kind/mode/harness/effort group has at least 20 terminal tasks per model; not a causal verdict" else "suppressed: no controlled kind/mode/harness/effort group has at least two models with 20 terminal tasks each" end),
     confidence:(if $tasks_sampled >= 20 and $terminal_outcomes >= 10 then "moderate" else "low" end),
     limitations:["Status logs are bounded event histories, not current-state truth.", "Review and CI coverage is limited to normalized terminal status classes already recorded by Firstmate.", "All proposed follow-ups require human approval and are not applied by this command."]}
' "$TMP/tasks.jsonl") || die 'internal retrospective model could not be constructed safely'

printf '%s\n' "$MODEL" | jq -r '
  def q: @json;
  "schema: \(.schema|q)",
  "state: \(.state|q)",
  "window: \(.window)",
  "tasks: \(.tasks.sampled) sampled of \(.tasks.total) safe metadata records",
  "source_coverage:",
  "  metadata_tasks: \(.source_coverage.metadata_tasks)",
  "  status_logs: \(.source_coverage.status_logs)",
  "  status_events: \(.source_coverage.status_events)",
  "  turn_end_markers: \(.source_coverage.turn_end_markers)",
  "  terminal_outcomes: \(.source_coverage.terminal_outcomes)",
  "  ci_review_classes: \(.source_coverage.ci_review_classes)",
  (if (.task_mix|length) == 0 then "task_mix: []" else
    "task_mix[\(.task_mix|length)]{kind,mode,harness,model,effort,tasks}:" ,
    (.task_mix[] | [.kind,.mode,.harness,.model,.effort,.tasks] | map(q) | join(",")) end),
  (if (.failure_categories|length) == 0 then "failure_categories: []" else
    "failure_categories[\(.failure_categories|length)]{rank,category,count,examples,proposal}:" ,
    (.failure_categories[] | [.rank,.category,.count,("redacted task samples: " + (.examples|tostring)),("Proposal only - human approval required: " + .proposal)] | map(q) | join(",")) end),
  (if (.model_comparisons|length) == 0 then "model_comparisons: []" else
    "model_comparisons[\(.model_comparisons|length)]{kind,mode,harness,effort,model,tasks,terminal_failures,failure_rate}:" ,
    (.model_comparisons[] | [.kind,.mode,.harness,.effort,.model,.tasks,.terminal_failures,(.failure_rate|tostring)] | map(q) | join(",")) end),
  "model_quality: \(.model_quality|q)",
  "confidence: \(.confidence|q)",
  "limitations[\(.limitations|length)]:",
  (.limitations[] | "  - \(.|q)")
' || die 'TOON rendering failed'
