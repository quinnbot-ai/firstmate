#!/usr/bin/env bash
# fm-condition-hold.sh - typed, inspectable condition holds for backlog items.
#
# A backlog hold whose release condition is a STATE condition rather than a date
# had no evaluable representation: it was recorded as an ordinary future hold with
# no hold date, so nothing ever decided whether it could be released and
# `tasks-axi ready` could never surface it. The work stayed parked until a person
# re-read the hold prose and compared it against reality. That silence is what
# this contract removes.
#
# This is NOT a second backlog engine and NOT a second scheduler. The backlog
# entry stays an ordinary tasks-axi hold in this home's data/backlog.md, and the
# recheck rides the watcher's existing registered-custom-check sweep. This script
# owns only the typed condition state that tasks-axi has no representation for.
#
# Captain holds and ordinary date holds are untouched: they are already correct.
# `hold` refuses a task already held by another kind, and every backlog mutation
# here goes through tasks-axi, so a condition hold is a third kind layered on top
# of the existing two rather than a reinterpretation of either.
#
# Usage:
#   fm-condition-hold.sh hold <task-id> --reason <text> --evaluator <path>
#     --cadence <n>[s|m|h|d] [--first-recheck YYYY-MM-DD]
#     [--evidence-max-age <n>[s|m|h|d]] [--max-rechecks <n>]
#   fm-condition-hold.sh arm <task-id>
#   fm-condition-hold.sh disarm <task-id>
#   fm-condition-hold.sh evaluate <task-id> [--force]
#   fm-condition-hold.sh show <task-id>
#   fm-condition-hold.sh list
#   fm-condition-hold.sh release <task-id>
#
# A bare number in a duration is days, because a recheck cadence is a
# calendar-scale concern; the explicit suffixes exist so a fast-moving condition
# stays exact.
#
# EVALUATOR IDENTITY. `--evaluator` is an executable file, recorded by absolute
# path AND by the SHA-256 of its bytes. A missing evaluator, an unreadable or
# non-executable one, and one whose bytes changed since registration are each a
# distinct loud failure, never a silent skip: the whole point of the contract is
# that a condition nobody can evaluate says so.
#
# EVALUATOR OUTPUT CONTRACT. The evaluator receives the task id as its one
# argument, prints typed lines on stdout, and exits 0:
#   result: satisfied|unsatisfied
#   observed: <epoch-seconds>|<YYYY-MM-DDTHH:MM:SSZ>
#   evidence: <one line of why>          (optional)
# `observed` is when the evaluator actually looked, so evidence older than
# --evidence-max-age is refused as stale rather than acted on, and evidence dated
# more than 300 seconds in the future is refused the same way. A nonzero exit, a
# missing or unparseable field, or an unknown result value is malformed state and
# is reported as such.
#
# EXACTLY ONCE PER FALSE-TO-TRUE TRANSITION. The durable record carries a
# transition sequence and the sequence already released. A transition commits the
# incremented sequence BEFORE it clears the hold, so a process that dies mid
# transition resumes that same sequence on its next evaluation and releases once;
# the release itself is an idempotent `tasks-axi unhold`. A condition that stays
# satisfied is not re-released, and a condition that falls back to unsatisfied and
# rises again is a new transition.
#
# RELEASE IS THE RESURFACING; THE PRINTED LINE IS THE NOTIFICATION. The release
# and its announcement commit together, so an announcement is emitted at most once
# per episode. If this process dies between that commit and the print, the task is
# still genuinely unheld and `tasks-axi ready` surfaces it, which is the
# end-user-visible behavior this contract exists to guarantee.
#
# UNSATISFIED ADVANCES BOOKKEEPING ONLY. An unsatisfied condition leaves the hold
# in place and moves only the recheck counter and the next recheck time. The
# recheck itself stays bounded: --cadence spaces it, --first-recheck can defer the
# first one, and --max-rechecks bounds how many times a condition may answer "not
# yet" before the hold is reported as exhausted and stops rechecking. A condition
# hold therefore either releases, reports a failure, or reports exhaustion; it
# never parks forever in silence.
#
# ANNOUNCEMENTS ARE PER EPISODE, NOT PER TICK. Release, exhaustion, retirement,
# and each distinct failure are announced once on stdout, so a registered watcher
# check turns them into exactly one wake instead of one per sweep. Full detail
# always goes to stderr, and `show` prints the durable record.
#
# ARMING. `arm` writes state/<task-id>.check.sh as a one-line call back into this
# script and registers it with bin/fm-check-register.sh, the existing trust
# binding for an intentional custom watcher check. No watcher change is needed and
# no new daemon exists. `disarm` removes both, and a hold that reaches a terminal
# state - released, exhausted, or retired - disarms itself so no poll outlives the
# condition it was watching.
#
# STATE. state/<task-id>.condition-hold is a private mode-0600 key=value record
# written atomically. Its `version` line is the compatibility gate: an unknown
# version is refused rather than guessed at.
#
# PATH SAFETY. Every command validates its task id at argument-parse time and
# refuses an empty, dotted, or otherwise unsafe one, and every path this script
# removes is rebuilt from that validated id and a non-empty state directory
# immediately before the removal. No removal can run against a path assembled
# from an unset or empty variable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

RECORD_VERSION=fm-condition-hold-v1
FUTURE_SKEW_SECS=300
RECORD_SOFT=0
EVAL_LOCK=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-condition-hold: %s\n' "$*" >&2
  exit 1
}

now_epoch() {
  local override=${FM_CONDITION_HOLD_NOW:-}
  case "$override" in
    '') date +%s ;;
    *[!0-9]*) return 1 ;;
    *) printf '%s\n' "$override" ;;
  esac
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

duration_secs() {  # <label> <value>; prints whole seconds
  local label=$1 value=$2 number unit
  case "$value" in
    ''|*[!0-9smhd]*) fail "$label must be <n>[s|m|h|d]: $value" ;;
  esac
  case "$value" in
    *s) number=${value%s}; unit=1 ;;
    *m) number=${value%m}; unit=60 ;;
    *h) number=${value%h}; unit=3600 ;;
    *d) number=${value%d}; unit=86400 ;;
    *) number=$value; unit=86400 ;;
  esac
  case "$number" in
    ''|*[!0-9]*) fail "$label must be <n>[s|m|h|d]: $value" ;;
  esac
  [ "$number" -gt 0 ] || fail "$label must be greater than zero: $value"
  printf '%s\n' "$((number * unit))"
}

# Portable UTC instant parsing. An unparseable value fails rather than falling
# back to "now", because guessing an observation time is exactly how stale
# evidence would slip past the staleness gate.
parse_instant() {  # <value>; prints epoch seconds
  local value=$1 epoch
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null) \
    || epoch=$(date -u -d "$value" +%s 2>/dev/null) \
    || return 1
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

parse_date_start() {  # <YYYY-MM-DD>; prints epoch seconds of that UTC midnight
  local value=$1
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  parse_instant "${value}T00:00:00Z"
}

render_instant() {  # <epoch>
  local at=$1
  case "$at" in
    ''|0|*[!0-9]*) printf '%s\n' '-'; return 0 ;;
  esac
  date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s\n' "$at"
}

# --- validated identities and paths -------------------------------------------

# THE one place a task id becomes trusted. Every command calls this before it
# builds a path, and every removal re-checks the same two invariants.
require_task_id() {  # <task-id>
  local id=${1-}
  [ -n "$id" ] || fail "a task id is required"
  fm_pr_task_id_valid "$id" || fail "task id must be a privacy-safe slug: $id"
}

require_state_dir() {
  [ -n "$STATE" ] || fail "state directory is unset"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable: $STATE"
}

record_path() {  # <task-id>
  require_task_id "${1-}"
  [ -n "$STATE" ] || fail "state directory is unset"
  printf '%s\n' "$STATE/$1.condition-hold"
}

check_path() {  # <task-id>
  require_task_id "${1-}"
  [ -n "$STATE" ] || fail "state directory is unset"
  printf '%s\n' "$STATE/$1.check.sh"
}

trust_path() {  # <task-id>
  require_task_id "${1-}"
  [ -n "$STATE" ] || fail "state directory is unset"
  printf '%s\n' "$STATE/$1.check-trust"
}

# Removal guard: both invariants are re-checked here, so a caller that forgot to
# validate cannot reach `rm` with a path built from an empty variable.
remove_owned_file() {  # <task-id> <absolute-path>
  local id=${1-} path=${2-}
  require_task_id "$id"
  [ -n "$STATE" ] || fail "state directory is unset"
  [ -n "$path" ] || fail "refusing to remove an empty path"
  case "$path" in
    "$STATE/$id."*) ;;
    *) fail "refusing to remove a path outside this task's state: $path" ;;
  esac
  rm -f -- "$path"
}

# A condition hold that reached a terminal state has nothing left to evaluate, so
# it takes its own watcher check back out rather than leaving a poll that can
# never wake anything. Safe from inside the check itself: the watcher executes a
# private snapshot, not this file.
disarm_quietly() {  # <task-id>
  local id=$1
  [ -e "$(check_path "$id")" ] || [ -e "$(trust_path "$id")" ] || return 0
  remove_owned_file "$id" "$(check_path "$id")"
  remove_owned_file "$id" "$(trust_path "$id")"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
}

task_show() {  # <task-id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

check_armed() {  # <task-id>
  [ -f "$(check_path "$1")" ] && [ -f "$(trust_path "$1")" ]
}

# --- durable record -----------------------------------------------------------

REC_TASK=; REC_REASON=; REC_EVALUATOR=; REC_EVALUATOR_DIGEST=
REC_CADENCE_SECS=; REC_EVIDENCE_MAX_AGE_SECS=; REC_MAX_RECHECKS=
REC_RECHECK_AFTER=; REC_RECHECK_COUNT=; REC_LAST_EVALUATED=
REC_LAST_RESULT=; REC_LAST_EVIDENCE=; REC_LAST_ERROR=
REC_TRANSITION_SEQ=; REC_RELEASED_SEQ=; REC_ANNOUNCED=; REC_STATE=

record_reset() {
  REC_TASK=; REC_REASON=; REC_EVALUATOR=; REC_EVALUATOR_DIGEST=
  REC_CADENCE_SECS=; REC_EVIDENCE_MAX_AGE_SECS=; REC_MAX_RECHECKS=
  REC_RECHECK_AFTER=0; REC_RECHECK_COUNT=0; REC_LAST_EVALUATED=0
  REC_LAST_RESULT=unknown; REC_LAST_EVIDENCE=; REC_LAST_ERROR=
  REC_TRANSITION_SEQ=0; REC_RELEASED_SEQ=0; REC_ANNOUNCED=; REC_STATE=active
}

# Malformed durable state is loud by default. `list` sets RECORD_SOFT=1 so one
# bad record is reported as a row instead of hiding every other condition hold.
record_problem() {  # <message>
  if [ "$RECORD_SOFT" = 1 ]; then
    printf 'fm-condition-hold: %s\n' "$*" >&2
    return 1
  fi
  fail "$@"
}

record_number_ok() {  # <task-id> <field> <value>
  case "${3-}" in
    ''|*[!0-9]*) record_problem "condition-hold record for $1 has a malformed $2: ${3-}" || return 1 ;;
  esac
}

record_load() {  # <task-id>
  local id=$1 file line key value version=
  file=$(record_path "$id")
  record_reset
  [ -f "$file" ] && [ ! -L "$file" ] \
    || { record_problem "no condition hold is recorded for $id" || return 1; }
  [ "$(fm_pr_file_link_count "$file")" = 1 ] \
    || { record_problem "condition-hold record for $id is not a private single-link file" || return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *) record_problem "condition-hold record for $id is malformed: $line" || return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version) version=$value ;;
      task) REC_TASK=$value ;;
      reason) REC_REASON=$value ;;
      evaluator) REC_EVALUATOR=$value ;;
      evaluator_digest) REC_EVALUATOR_DIGEST=$value ;;
      cadence_secs) REC_CADENCE_SECS=$value ;;
      evidence_max_age_secs) REC_EVIDENCE_MAX_AGE_SECS=$value ;;
      max_rechecks) REC_MAX_RECHECKS=$value ;;
      recheck_after) REC_RECHECK_AFTER=$value ;;
      recheck_count) REC_RECHECK_COUNT=$value ;;
      last_evaluated) REC_LAST_EVALUATED=$value ;;
      last_result) REC_LAST_RESULT=$value ;;
      last_evidence) REC_LAST_EVIDENCE=$value ;;
      last_error) REC_LAST_ERROR=$value ;;
      transition_seq) REC_TRANSITION_SEQ=$value ;;
      released_seq) REC_RELEASED_SEQ=$value ;;
      announced) REC_ANNOUNCED=$value ;;
      state) REC_STATE=$value ;;
      *) record_problem "condition-hold record for $id has an unknown field: $key" || return 1 ;;
    esac
  done < "$file"
  [ "$version" = "$RECORD_VERSION" ] \
    || { record_problem "condition-hold record for $id has version '$version', not $RECORD_VERSION" || return 1; }
  [ "$REC_TASK" = "$id" ] \
    || { record_problem "condition-hold record for $id names task '$REC_TASK'" || return 1; }
  record_number_ok "$id" cadence_secs "$REC_CADENCE_SECS" || return 1
  record_number_ok "$id" evidence_max_age_secs "$REC_EVIDENCE_MAX_AGE_SECS" || return 1
  record_number_ok "$id" max_rechecks "$REC_MAX_RECHECKS" || return 1
  record_number_ok "$id" recheck_after "$REC_RECHECK_AFTER" || return 1
  record_number_ok "$id" recheck_count "$REC_RECHECK_COUNT" || return 1
  record_number_ok "$id" last_evaluated "$REC_LAST_EVALUATED" || return 1
  record_number_ok "$id" transition_seq "$REC_TRANSITION_SEQ" || return 1
  record_number_ok "$id" released_seq "$REC_RELEASED_SEQ" || return 1
  [ -n "$REC_EVALUATOR" ] \
    || { record_problem "condition-hold record for $id names no evaluator" || return 1; }
  case "$REC_EVALUATOR_DIGEST" in
    [0-9a-f][0-9a-f]*)
      [ "${#REC_EVALUATOR_DIGEST}" -eq 64 ] \
        || { record_problem "condition-hold record for $id has a malformed evaluator digest" || return 1; } ;;
    *) record_problem "condition-hold record for $id has a malformed evaluator digest" || return 1 ;;
  esac
  case "$REC_STATE" in
    active|released|exhausted|retired) ;;
    *) record_problem "condition-hold record for $id has an unknown state: $REC_STATE" || return 1 ;;
  esac
  case "$REC_LAST_RESULT" in
    unknown|satisfied|unsatisfied|error) ;;
    *) record_problem "condition-hold record for $id has an unknown result: $REC_LAST_RESULT" || return 1 ;;
  esac
}

record_store() {  # <task-id>
  local id=$1 file tmp state_device
  require_state_dir
  file=$(record_path "$id")
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable: $STATE"
  fm_pr_regular_destination_on_device_or_absent "$file" "$state_device" \
    || fail "condition-hold record path is unavailable: $file"
  umask 077
  tmp=$(mktemp "$STATE/.fm-condition-hold.XXXXXX") || fail "could not stage the condition-hold record"
  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'task=%s\n' "$REC_TASK"
    printf 'reason=%s\n' "$REC_REASON"
    printf 'evaluator=%s\n' "$REC_EVALUATOR"
    printf 'evaluator_digest=%s\n' "$REC_EVALUATOR_DIGEST"
    printf 'cadence_secs=%s\n' "$REC_CADENCE_SECS"
    printf 'evidence_max_age_secs=%s\n' "$REC_EVIDENCE_MAX_AGE_SECS"
    printf 'max_rechecks=%s\n' "$REC_MAX_RECHECKS"
    printf 'recheck_after=%s\n' "$REC_RECHECK_AFTER"
    printf 'recheck_count=%s\n' "$REC_RECHECK_COUNT"
    printf 'last_evaluated=%s\n' "$REC_LAST_EVALUATED"
    printf 'last_result=%s\n' "$REC_LAST_RESULT"
    printf 'last_evidence=%s\n' "$REC_LAST_EVIDENCE"
    printf 'last_error=%s\n' "$REC_LAST_ERROR"
    printf 'transition_seq=%s\n' "$REC_TRANSITION_SEQ"
    printf 'released_seq=%s\n' "$REC_RELEASED_SEQ"
    printf 'announced=%s\n' "$REC_ANNOUNCED"
    printf 'state=%s\n' "$REC_STATE"
  } > "$tmp" || { rm -f -- "$tmp"; fail "could not write the condition-hold record"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; fail "could not secure the condition-hold record"; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; fail "could not commit the condition-hold record"; }
}

# --- announcements ------------------------------------------------------------

# One announcement per episode, and the single commit point for every outcome:
# the episode key is committed with the record BEFORE the line is printed, so a
# repeated evaluation can never re-announce an episode it already announced.
announce() {  # <task-id> <episode-key> <line>
  local id=$1 key=$2 line=$3 fresh=0
  [ "$REC_ANNOUNCED" = "$key" ] || fresh=1
  REC_ANNOUNCED=$key
  record_store "$id"
  [ "$fresh" -eq 1 ] || return 0
  printf 'condition-hold %s: %s\n' "$id" "$line"
}

report_error() {  # <task-id> <reason>
  local id=$1 reason=$2 key now
  now=$(now_epoch) || now=$REC_LAST_EVALUATED
  REC_LAST_RESULT=error
  REC_LAST_ERROR=$reason
  REC_LAST_EVALUATED=$now
  REC_RECHECK_AFTER=$((now + REC_CADENCE_SECS))
  key=error:$(sha256_text "$reason" 2>/dev/null || printf '%s' "$reason")
  announce "$id" "$key" "error: $reason"
  printf 'fm-condition-hold: %s: %s\n' "$id" "$reason" >&2
  exit 1
}

retire() {  # <task-id> <reason>
  local id=$1 reason=$2
  REC_STATE=retired
  REC_LAST_ERROR=$reason
  announce "$id" "retired:$reason" "retired: $reason"
  disarm_quietly "$id"
  exit 0
}

# --- evaluation ---------------------------------------------------------------

EVAL_RESULT=
EVAL_OBSERVED=
EVAL_EVIDENCE=

run_evaluator() {  # <task-id>; sets EVAL_*, or reports a loud failure
  local id=$1 digest output status line key value
  EVAL_RESULT=; EVAL_OBSERVED=; EVAL_EVIDENCE=
  [ -e "$REC_EVALUATOR" ] || report_error "$id" "evaluator is missing: $REC_EVALUATOR"
  [ -f "$REC_EVALUATOR" ] && [ ! -L "$REC_EVALUATOR" ] \
    || report_error "$id" "evaluator is not an ordinary file: $REC_EVALUATOR"
  [ -x "$REC_EVALUATOR" ] || report_error "$id" "evaluator is not executable: $REC_EVALUATOR"
  digest=$(sha256_file "$REC_EVALUATOR") \
    || report_error "$id" "evaluator digest could not be computed: $REC_EVALUATOR"
  [ "$digest" = "$REC_EVALUATOR_DIGEST" ] \
    || report_error "$id" "evaluator changed since registration: $REC_EVALUATOR"
  status=0
  output=$("$REC_EVALUATOR" "$id" 2>/dev/null) || status=$?
  [ "$status" -eq 0 ] || report_error "$id" "evaluator exited $status"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *:*) ;;
      *) continue ;;
    esac
    key=${line%%:*}
    value=${line#*:}
    value=${value# }
    case "$key" in
      result) EVAL_RESULT=$value ;;
      observed) EVAL_OBSERVED=$value ;;
      evidence) EVAL_EVIDENCE=$value ;;
    esac
  done <<EOF
$output
EOF
  case "$EVAL_RESULT" in
    satisfied|unsatisfied) ;;
    '') report_error "$id" "evaluator printed no result line" ;;
    *) report_error "$id" "evaluator printed an unknown result: $EVAL_RESULT" ;;
  esac
  [ -n "$EVAL_OBSERVED" ] || report_error "$id" "evaluator printed no observed line"
  EVAL_OBSERVED=$(parse_instant "$EVAL_OBSERVED") \
    || report_error "$id" "evaluator printed an unparseable observed time"
}

check_evidence_fresh() {  # <task-id> <now>
  local id=$1 now=$2 age
  age=$((now - EVAL_OBSERVED))
  if [ "$age" -lt "-$FUTURE_SKEW_SECS" ]; then
    report_error "$id" "evaluator evidence is dated $((0 - age))s in the future"
  fi
  if [ "$age" -gt "$REC_EVIDENCE_MAX_AGE_SECS" ]; then
    report_error "$id" \
      "evaluator evidence is stale: observed ${age}s ago, limit ${REC_EVIDENCE_MAX_AGE_SECS}s"
  fi
}

# The release half of a transition. Idempotent by construction: the tasks-axi
# unhold is idempotent and the committed released sequence stops it repeating.
complete_transition() {  # <task-id>
  local id=$1 seq=$REC_TRANSITION_SEQ evidence
  tasks_axi unhold "$id" >/dev/null 2>&1 \
    || report_error "$id" "could not clear the backlog hold"
  REC_RELEASED_SEQ=$seq
  REC_STATE=released
  REC_LAST_RESULT=satisfied
  evidence=${REC_LAST_EVIDENCE:-condition satisfied}
  announce "$id" "satisfied:$seq" "released: $evidence"
  disarm_quietly "$id"
  exit 0
}

# --- commands -----------------------------------------------------------------

cmd_hold() {  # <task-id> <flags...>
  local id=${1-} reason='' evaluator='' cadence='' first_recheck='' evidence_max_age='' max_rechecks=60
  local show held kind digest now first_epoch file
  require_task_id "$id"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || fail "--reason needs a value"; reason=$2; shift 2 ;;
      --evaluator) [ "$#" -ge 2 ] || fail "--evaluator needs a value"; evaluator=$2; shift 2 ;;
      --cadence) [ "$#" -ge 2 ] || fail "--cadence needs a value"; cadence=$2; shift 2 ;;
      --first-recheck) [ "$#" -ge 2 ] || fail "--first-recheck needs a value"; first_recheck=$2; shift 2 ;;
      --evidence-max-age) [ "$#" -ge 2 ] || fail "--evidence-max-age needs a value"; evidence_max_age=$2; shift 2 ;;
      --max-rechecks) [ "$#" -ge 2 ] || fail "--max-rechecks needs a value"; max_rechecks=$2; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  validate_one_line --reason "$reason"
  [ -n "$evaluator" ] || fail "--evaluator is required"
  [ -n "$cadence" ] || fail "--cadence is required"
  case "$max_rechecks" in
    ''|*[!0-9]*) fail "--max-rechecks must be a whole number: $max_rechecks" ;;
  esac
  [ "$max_rechecks" -gt 0 ] || fail "--max-rechecks must be greater than zero"
  case "$evaluator" in
    /*) ;;
    *) evaluator=$(cd "$(dirname "$evaluator")" 2>/dev/null && pwd)/$(basename "$evaluator") \
      || fail "--evaluator path could not be resolved: $evaluator" ;;
  esac
  [ -f "$evaluator" ] && [ ! -L "$evaluator" ] || fail "evaluator is not an ordinary file: $evaluator"
  [ -x "$evaluator" ] || fail "evaluator is not executable: $evaluator"
  digest=$(sha256_file "$evaluator") || fail "evaluator digest could not be computed"

  require_state_dir
  require_tasks_axi
  show=$(task_show "$id") || fail "backlog item $id does not exist in this home"
  held=$(show_field "$show" held)
  if [ "$held" = yes ]; then
    kind=$(show_field "$show" hold_kind)
    case "$kind" in
      future|'-'|'') ;;
      *) fail "backlog item $id already carries a $kind hold; condition holds never reinterpret one" ;;
    esac
  fi
  file=$(record_path "$id")
  [ ! -e "$file" ] || fail "a condition hold is already recorded for $id; release it first"

  now=$(now_epoch) || fail "FM_CONDITION_HOLD_NOW must be epoch seconds"
  first_epoch=$now
  if [ -n "$first_recheck" ]; then
    first_epoch=$(parse_date_start "$first_recheck") \
      || fail "--first-recheck must be YYYY-MM-DD: $first_recheck"
  fi

  record_reset
  REC_TASK=$id
  REC_REASON=$reason
  REC_EVALUATOR=$evaluator
  REC_EVALUATOR_DIGEST=$digest
  REC_CADENCE_SECS=$(duration_secs --cadence "$cadence") || exit 1
  if [ -n "$evidence_max_age" ]; then
    REC_EVIDENCE_MAX_AGE_SECS=$(duration_secs --evidence-max-age "$evidence_max_age") || exit 1
  else
    REC_EVIDENCE_MAX_AGE_SECS=$REC_CADENCE_SECS
  fi
  REC_MAX_RECHECKS=$max_rechecks
  REC_RECHECK_AFTER=$first_epoch

  record_store "$id"
  if ! tasks_axi hold "$id" --reason "$reason [condition: $(basename "$evaluator")]" --kind future >/dev/null 2>&1; then
    remove_owned_file "$id" "$file"
    fail "could not record the backlog hold for $id"
  fi
  printf 'held: %s (condition, recheck from %s, cadence %ss)\n' \
    "$id" "$(render_instant "$REC_RECHECK_AFTER")" "$REC_CADENCE_SECS"
}

cmd_arm() {  # <task-id>
  local id=${1-} check state_device
  require_task_id "$id"
  require_state_dir
  record_load "$id"
  check=$(check_path "$id")
  [ ! -e "$check" ] || fail "state/$id.check.sh already exists; disarm or remove it first"
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable: $STATE"
  fm_pr_regular_destination_on_device_or_absent "$check" "$state_device" \
    || fail "check path is unavailable: $check"
  umask 077
  # The shim pins the home it was armed in. One code root serves several homes,
  # so a check that inherited whatever FM_HOME the watcher happened to export
  # could evaluate one home's condition against another home's backlog.
  cat > "$check" <<EOF || fail "could not write the condition-hold check"
#!/usr/bin/env bash
export FM_HOME="$FM_HOME"
export FM_STATE_OVERRIDE="$STATE"
exec "$SCRIPT_DIR/fm-condition-hold.sh" evaluate "$id"
EOF
  chmod 0700 "$check" || fail "could not secure the condition-hold check"
  if ! "$SCRIPT_DIR/fm-check-register.sh" "$id" >/dev/null; then
    remove_owned_file "$id" "$check"
    fail "could not register the condition-hold check"
  fi
  printf 'armed: state/%s.check.sh\n' "$id"
}

cmd_disarm() {  # <task-id>
  local id=${1-}
  require_task_id "$id"
  require_state_dir
  remove_owned_file "$id" "$(check_path "$id")"
  remove_owned_file "$id" "$(trust_path "$id")"
  printf 'disarmed: %s\n' "$id"
}

cmd_release() {  # <task-id>
  local id=${1-}
  require_task_id "$id"
  require_state_dir
  record_load "$id"
  remove_owned_file "$id" "$(record_path "$id")"
  remove_owned_file "$id" "$(check_path "$id")"
  remove_owned_file "$id" "$(trust_path "$id")"
  printf 'released: %s\n' "$id"
}

cmd_show() {  # <task-id>
  local id=${1-} armed=no
  require_task_id "$id"
  record_load "$id"
  check_armed "$id" && armed=yes
  printf 'condition-hold:\n'
  printf '  task: %s\n' "$REC_TASK"
  printf '  state: %s\n' "$REC_STATE"
  printf '  reason: %s\n' "$REC_REASON"
  printf '  evaluator: %s\n' "$REC_EVALUATOR"
  printf '  evaluator_digest: %s\n' "$REC_EVALUATOR_DIGEST"
  printf '  cadence_secs: %s\n' "$REC_CADENCE_SECS"
  printf '  evidence_max_age_secs: %s\n' "$REC_EVIDENCE_MAX_AGE_SECS"
  printf '  recheck_after: %s\n' "$(render_instant "$REC_RECHECK_AFTER")"
  printf '  rechecks: %s of %s\n' "$REC_RECHECK_COUNT" "$REC_MAX_RECHECKS"
  printf '  last_evaluated: %s\n' "$(render_instant "$REC_LAST_EVALUATED")"
  printf '  last_result: %s\n' "$REC_LAST_RESULT"
  printf '  last_evidence: %s\n' "${REC_LAST_EVIDENCE:--}"
  printf '  last_error: %s\n' "${REC_LAST_ERROR:--}"
  printf '  transition_seq: %s\n' "$REC_TRANSITION_SEQ"
  printf '  released_seq: %s\n' "$REC_RELEASED_SEQ"
  printf '  armed: %s\n' "$armed"
}

cmd_list() {
  local file id found=0
  require_state_dir
  RECORD_SOFT=1
  for file in "$STATE"/*.condition-hold; do
    [ -e "$file" ] || continue
    id=$(basename "$file" .condition-hold)
    found=$((found + 1))
    if ! fm_pr_task_id_valid "$id" || ! record_load "$id"; then
      printf '%s\tmalformed\t-\t-\t-\n' "$id"
      continue
    fi
    printf '%s\t%s\t%s\trecheck_after=%s\trechecks=%s/%s\n' \
      "$id" "$REC_STATE" "$REC_LAST_RESULT" \
      "$(render_instant "$REC_RECHECK_AFTER")" "$REC_RECHECK_COUNT" "$REC_MAX_RECHECKS"
  done
  RECORD_SOFT=0
  [ "$found" -gt 0 ] || printf 'no condition holds recorded\n'
}

evaluate_cleanup() {
  [ -z "$EVAL_LOCK" ] || fm_lock_release "$EVAL_LOCK" || true
}

cmd_evaluate() {  # <task-id> [--force]
  local id=${1-} force=0 now show held acquired=0 tries=0
  require_task_id "$id"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  require_state_dir
  EVAL_LOCK="$STATE/.$id.condition-hold.lock"
  trap evaluate_cleanup EXIT
  while [ "$tries" -lt 50 ]; do
    if fm_lock_try_acquire "$EVAL_LOCK"; then acquired=1; break; fi
    tries=$((tries + 1))
    sleep 0.1
  done
  if [ "$acquired" -ne 1 ]; then
    EVAL_LOCK=
    printf 'fm-condition-hold: %s: another evaluation holds the record\n' "$id" >&2
    exit 0
  fi

  record_load "$id"
  require_tasks_axi
  now=$(now_epoch) || fail "FM_CONDITION_HOLD_NOW must be epoch seconds"

  # Restart safety first: a transition committed but not released resumes here
  # before any other bookkeeping can move past it.
  if [ "$REC_RELEASED_SEQ" -lt "$REC_TRANSITION_SEQ" ]; then
    complete_transition "$id"
  fi

  case "$REC_STATE" in
    released|retired|exhausted) exit 0 ;;
  esac

  show=$(task_show "$id") || retire "$id" "backlog item is gone"
  held=$(show_field "$show" held)
  [ "$held" = yes ] || retire "$id" "backlog hold was cleared outside this contract"

  if [ "$force" -eq 0 ] && [ "$now" -lt "$REC_RECHECK_AFTER" ]; then
    exit 0
  fi

  run_evaluator "$id"
  check_evidence_fresh "$id" "$now"

  REC_LAST_EVALUATED=$now
  REC_LAST_ERROR=
  REC_LAST_EVIDENCE=$EVAL_EVIDENCE
  REC_RECHECK_AFTER=$((now + REC_CADENCE_SECS))
  if [ "$EVAL_RESULT" = satisfied ]; then
    if [ "$REC_LAST_RESULT" = satisfied ]; then
      record_store "$id"
      exit 0
    fi
    REC_TRANSITION_SEQ=$((REC_TRANSITION_SEQ + 1))
    record_store "$id"
    complete_transition "$id"
  fi

  REC_LAST_RESULT=unsatisfied
  REC_RECHECK_COUNT=$((REC_RECHECK_COUNT + 1))
  if [ "$REC_RECHECK_COUNT" -ge "$REC_MAX_RECHECKS" ]; then
    REC_STATE=exhausted
    announce "$id" "exhausted:$REC_RECHECK_COUNT" \
      "exhausted: still unsatisfied after $REC_RECHECK_COUNT rechecks; the hold needs a decision"
    disarm_quietly "$id"
    exit 0
  fi
  record_store "$id"
  exit 0
}

COMMAND=${1-}
[ "$#" -eq 0 ] || shift
case "$COMMAND" in
  hold) cmd_hold "$@" ;;
  arm) cmd_arm "$@" ;;
  disarm) cmd_disarm "$@" ;;
  evaluate) cmd_evaluate "$@" ;;
  show) cmd_show "$@" ;;
  list) cmd_list "$@" ;;
  release) cmd_release "$@" ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
