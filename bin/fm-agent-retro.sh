#!/usr/bin/env bash
# fm-agent-retro.sh - bounded, read-only retrospective over recent task records.
#
# Output contract: `fm-agent-retro.v1` TOON on stdout. Read-only and local-only:
# it opens no network, takes no lock, writes no state, and never mutates,
# reclassifies, or tears down anything it reads.
#
# Sources are limited to the three records this home's own state/ owns for a
# task: state/<id>.meta (the spawn-written key=value block), state/<id>.status
# (the append-only wake-event log), and state/<id>.turn-ended. Nothing else is
# opened - not transcripts, prompts, worktrees, projects, config, or any path
# named inside metadata - so a record cannot steer this command at another file.
#
# The window is the most recently modified task metadata records, newest first
# with a task-id tie-break, so repeated runs over unchanged state print
# byte-identical output.
#
# Status lines are classified by leading verb through bin/fm-classify-lib.sh,
# which is the single owner of firstmate's status vocabulary; this command adds
# no second verb list and reads no status prose. Report values are counts plus
# the five metadata axes (kind, mode, harness, model, effort), each normalized
# to a short token from a conservative character set - anything else becomes
# "other" and an absent value becomes "unknown". No task id, path, command,
# token, URL, or status text can reach the output.
#
# usage: fm-agent-retro.sh [--window <1-100>] [--help]
#
# Every proposal in the report is a suggestion for a human to accept or reject.
# This command applies none of them.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DEFAULT_WINDOW=40
MAX_WINDOW=100
# Per-source read bounds. A record larger than these is read only up to the
# bound, so one oversized log cannot make this command unbounded.
MAX_META_BYTES=16384
MAX_STATUS_BYTES=65536
STATUS_TAIL_LINES=200
# Normalized value bounds.
MAX_VALUE_CHARS=32

usage() {
  cat <<'EOF'
usage: fm-agent-retro.sh [--window <1-100>]

Bounded, read-only retrospective over this home's recent task records.
Prints `fm-agent-retro.v1` TOON: source coverage, task mix, recorded outcome
categories with approval-gated proposals, confidence, and limitations.
Default window is the 40 most recently updated task records.
EOF
}

die() { # <message> [help] [exit-code]
  printf 'schema: "fm-agent-retro.v1"\nerror: "%s"\nhelp: "%s"\n' \
    "$1" "${2:-Run fm-agent-retro.sh --help for usage.}"
  exit "${3:-1}"
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
    *) die "unknown argument $1" 'Valid flags: --window <1-100>, --help.' 2 ;;
  esac
  shift
done

case "$WINDOW" in
  ''|*[!0-9]*) die '--window must be an integer from 1 to 100' 'Run fm-agent-retro.sh --window <1-100>.' 2 ;;
esac
[ "$WINDOW" -ge 1 ] && [ "$WINDOW" -le "$MAX_WINDOW" ] \
  || die '--window must be an integer from 1 to 100' 'Run fm-agent-retro.sh --window <1-100>.' 2

HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
  || die 'this firstmate home cannot be resolved' 'Set FM_HOME to an existing firstmate home.'
STATE="$HOME_REAL/state"
[ -d "$STATE" ] && [ ! -L "$STATE" ] \
  || die 'this home has no readable state directory' 'Run this from a firstmate home with a state/ directory.'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-agent-retro.XXXXXX") || die 'a bounded private workspace could not be created'
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT HUP INT TERM

# 0 when <path> is a plain, readable, non-symlink regular file, which is the
# only shape any source record is read from (bin/fm-classify-lib.sh's idiom).
safe_source() { # <path>
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ]
}

file_mtime() { # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f '%m' -- "$1" 2>/dev/null
  else
    stat -c '%Y' -- "$1" 2>/dev/null
  fi
}

# Value of <key> in a bounded read of a key=value metadata file, normalized to a
# short token: absent or empty becomes "unknown", a repeated key or any value
# outside the conservative set becomes "other". That normalization is what keeps
# every emitted value safe to print and makes leaking a path, command, or token
# through one impossible.
meta_value() { # <file> <key>
  local value
  value=$(head -c "$MAX_META_BYTES" -- "$1" 2>/dev/null | awk -v key="$2" -v max="$MAX_VALUE_CHARS" '
    index($0, key "=") == 1 {
      if (found++) { repeated = 1; next }
      v = substr($0, length(key) + 2)
    }
    END {
      if (repeated) { print "other"; exit }
      if (!found || v == "") { print "unknown"; exit }
      if (length(v) > max || v !~ /^[A-Za-z0-9._+-]+$/) { print "other"; exit }
      print v
    }
  ')
  printf '%s\n' "${value:-unknown}"
}

UNREADABLE=0

: > "$TMP/candidates"
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  # A record whose own name is not a plain task id is never opened: its name is
  # about to become a field in this command's internal tables.
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      UNREADABLE=$((UNREADABLE + 1))
      continue
      ;;
  esac
  if ! safe_source "$meta"; then
    UNREADABLE=$((UNREADABLE + 1))
    continue
  fi
  mtime=$(file_mtime "$meta")
  case "$mtime" in
    ''|*[!0-9]*)
      UNREADABLE=$((UNREADABLE + 1))
      continue
      ;;
  esac
  printf '%s\t%s\n' "$mtime" "$id" >> "$TMP/candidates"
done

TASKS_TOTAL=$(LC_ALL=C wc -l < "$TMP/candidates" | tr -d ' ')
LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 "$TMP/candidates" | head -n "$WINDOW" > "$TMP/selected"
TASKS_SAMPLED=$(LC_ALL=C wc -l < "$TMP/selected" | tr -d ' ')

STATUS_LOGS=0
STATUS_EVENTS=0
TURN_ENDS=0
TERMINAL_OUTCOMES=0
FAILURE_EVENTS=0
FAILURE_TASKS=0
GATE_EVENTS=0
GATE_TASKS=0

: > "$TMP/mix"
while IFS="$(printf '\t')" read -r _ id; do
  [ -n "$id" ] || continue
  meta="$STATE/$id.meta"
  if ! safe_source "$meta"; then
    UNREADABLE=$((UNREADABLE + 1))
    continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(meta_value "$meta" kind)" "$(meta_value "$meta" mode)" \
    "$(meta_value "$meta" harness)" "$(meta_value "$meta" model)" \
    "$(meta_value "$meta" effort)" >> "$TMP/mix"

  status="$STATE/$id.status"
  if [ -e "$status" ] || [ -L "$status" ]; then
    if safe_source "$status"; then
      STATUS_LOGS=$((STATUS_LOGS + 1))
      task_failures=0
      task_gates=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        STATUS_EVENTS=$((STATUS_EVENTS + 1))
        case "$(status_line_verb "$line")" in
          done)
            TERMINAL_OUTCOMES=$((TERMINAL_OUTCOMES + 1))
            ;;
          failed)
            TERMINAL_OUTCOMES=$((TERMINAL_OUTCOMES + 1))
            FAILURE_EVENTS=$((FAILURE_EVENTS + 1))
            task_failures=1
            ;;
          needs-decision|blocked)
            GATE_EVENTS=$((GATE_EVENTS + 1))
            task_gates=1
            ;;
        esac
      done < <(tail -c "$MAX_STATUS_BYTES" -- "$status" 2>/dev/null | tail -n "$STATUS_TAIL_LINES")
      FAILURE_TASKS=$((FAILURE_TASKS + task_failures))
      GATE_TASKS=$((GATE_TASKS + task_gates))
    else
      UNREADABLE=$((UNREADABLE + 1))
    fi
  fi

  turn="$STATE/$id.turn-ended"
  if [ -e "$turn" ] || [ -L "$turn" ]; then
    if safe_source "$turn"; then
      TURN_ENDS=$((TURN_ENDS + 1))
    else
      UNREADABLE=$((UNREADABLE + 1))
    fi
  fi
done < "$TMP/selected"

# --- TOON renderer (output boundary) ----------------------------------------
#
# Every string in the model is either a fixed sentence written here or a
# normalized metadata token, so each is emitted quoted and none can contain a
# quote, backslash, control character, or newline. Counts are plain integers.

if [ "$TASKS_SAMPLED" -eq 0 ]; then
  printf 'schema: "fm-agent-retro.v1"\nstate: "empty"\n'
else
  printf 'schema: "fm-agent-retro.v1"\nstate: "ok"\n'
fi
printf 'window: %s\n' "$WINDOW"
printf 'tasks:\n'
printf '  sampled: %s\n' "$TASKS_SAMPLED"
printf '  total: %s\n' "$TASKS_TOTAL"
printf 'source_coverage:\n'
printf '  status_logs: %s\n' "$STATUS_LOGS"
printf '  status_events: %s\n' "$STATUS_EVENTS"
printf '  turn_end_markers: %s\n' "$TURN_ENDS"
printf '  terminal_outcomes: %s\n' "$TERMINAL_OUTCOMES"
printf '  unreadable_sources: %s\n' "$UNREADABLE"

LC_ALL=C sort "$TMP/mix" | LC_ALL=C uniq -c | LC_ALL=C sort -k1,1nr -k2 > "$TMP/mix-rows"
MIX_ROWS=$(LC_ALL=C wc -l < "$TMP/mix-rows" | tr -d ' ')
if [ "$MIX_ROWS" -eq 0 ]; then
  printf 'task_mix: []\n'
else
  printf 'task_mix[%s]{kind,mode,harness,model,effort,tasks}:\n' "$MIX_ROWS"
  while read -r count rest; do
    [ -n "$count" ] || continue
    IFS="$(printf '\t')" read -r kind mode harness model effort <<EOF
$rest
EOF
    printf '  "%s","%s","%s","%s","%s",%s\n' "$kind" "$mode" "$harness" "$model" "$effort" "$count"
  done < "$TMP/mix-rows"
fi

: > "$TMP/categories"
if [ "$FAILURE_EVENTS" -gt 0 ]; then
  printf '%s\t%s\t%s\t%s\n' "$FAILURE_EVENTS" recorded_failure "$FAILURE_TASKS" \
    'Name the verification that was missing before the next attempt on this kind of work.' >> "$TMP/categories"
fi
if [ "$GATE_EVENTS" -gt 0 ]; then
  printf '%s\t%s\t%s\t%s\n' "$GATE_EVENTS" supervisor_gate "$GATE_TASKS" \
    'State the one authority or prerequisite the instructions should settle up front.' >> "$TMP/categories"
fi
CATEGORY_ROWS=$(LC_ALL=C wc -l < "$TMP/categories" | tr -d ' ')
if [ "$CATEGORY_ROWS" -eq 0 ]; then
  printf 'outcome_categories: []\n'
else
  printf 'outcome_categories[%s]{rank,category,events,tasks,proposal}:\n' "$CATEGORY_ROWS"
  rank=0
  LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 "$TMP/categories" > "$TMP/category-rows"
  while IFS="$(printf '\t')" read -r events category tasks proposal; do
    [ -n "$events" ] || continue
    rank=$((rank + 1))
    printf '  %s,"%s",%s,%s,"Proposal only - human approval required: %s"\n' \
      "$rank" "$category" "$events" "$tasks" "$proposal"
  done < "$TMP/category-rows"
fi

if [ "$TASKS_SAMPLED" -ge 20 ] && [ "$TERMINAL_OUTCOMES" -ge 10 ]; then
  printf 'confidence: "moderate"\n'
else
  printf 'confidence: "low"\n'
fi
printf 'limitations[4]:\n'
printf '  - "Status logs are bounded event histories, not current state."\n'
printf '  - "Only the most recent status events of each sampled task are counted."\n'
printf '  - "Categories come from recorded status verbs alone: no cause is attributed and no harness, model, or worker is ranked."\n'
printf '  - "Every proposal needs human approval and is never applied by this command."\n'
