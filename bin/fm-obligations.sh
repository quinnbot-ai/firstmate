#!/usr/bin/env bash
# fm-obligations.sh - durable, checkable reporting obligations for one task.
#
# THE FAILURE THIS EXISTS FOR. A brief can state an explicit reporting
# requirement ("run the regression on the unfixed base AND at your head, then
# report the pair") and a worker can deliver excellent work while silently
# omitting that report. Nothing notices, because the only thing that remembers
# what was asked is the supervisor's memory of the brief it wrote. An obligation
# recorded here survives that memory: teardown refuses to clean the task up
# while the obligation is neither reported nor explicitly waived, so a silent
# omission becomes a visible refusal instead of a quiet gap.
#
# This script decides nothing about the CONTENT of a report. It cannot judge
# whether "the pair" was actually run; it only enforces that the worker put a
# statement under the obligation's key into the durable status log, where the
# supervisor reads it and can judge it. Making the omission visible is the whole
# job - fabricated evidence is a different problem and is not addressed here.
#
# Usage:
#   fm-obligations.sh record <task-id> <key> --text <text>
#   fm-obligations.sh list <task-id>
#   fm-obligations.sh verify <task-id>
#   fm-obligations.sh waive <task-id> <key> --reason <reason>
#
# `record` appends one obligation. bin/fm-brief.sh calls it for every --report
# passed at scaffold time; call it by hand when an obligation is added later by
# a steer, so a mid-task requirement is as durable as a scaffolded one. Recording
# the same key twice with the same text is idempotent; a DIFFERENT text for a key
# already recorded is refused, because silently rewriting a stated requirement is
# the class of change this script exists to prevent.
#
# `list` prints "<key>\t<state>\t<text>" for every obligation, where <state> is
# reported, waived, or unmet. `verify` is the gate: it exits 0 when every
# obligation is reported or waived, and exits 1 naming each unmet one. Both are
# pure reads.
#
# `waive` records an explicit, reasoned decision that this obligation will not be
# reported by the worker - typically because the supervisor produced the evidence
# itself. A waiver is durable and attributable; it is not a way to make an
# inconvenient requirement disappear quietly, which is exactly what teardown
# --force already is when the captain has authorized a discard.
#
# SATISFACTION IS ONE EXACT SHAPE. An obligation is reported when the task's
# status log contains a line whose leading verb is `note` and whose stated
# `[key=<slug>]` equals the obligation key:
#
#   note [key=base-vs-head]: base FAILS (1 failure), head PASSES (0 failures)
#
# `note` is deliberate. bin/fm-classify-lib.sh already treats a `note:` line as
# an unread surface line, so the wake drain prints it verbatim and unbounded
# until it has been presented - the report reaches the supervisor by the ordinary
# status path with no new vocabulary. `note` also takes no part in the open/
# resolved decision fold, so an obligation report never masquerades as an open
# decision. Any other verb (a `done:` line that buries the evidence in its prose,
# for instance) does NOT satisfy the obligation: the gate is only worth having if
# it means one checkable thing, and the brief hands the worker the exact command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

CMD=$1; shift

# A task id reaches the filesystem as a path component, so it is held to the same
# slug charset as a decision key rather than trusted.
require_task_id() {  # <task-id>
  [ -n "${1:-}" ] || die "task id is required"
  _fm_decision_slug_ok "$1" || die "task id must be a slug (A-Za-z0-9._-): '$1'"
}

require_key() {  # <key>
  [ -n "${1:-}" ] || die "obligation key is required"
  _fm_decision_slug_ok "$1" \
    || die "obligation key must be a slug (A-Za-z0-9._-): '$1'"
}

# Obligation text is one field of a single TAB-separated record, so a literal
# tab or newline would corrupt that record and silently truncate the stated
# requirement - the exact class of loss this script exists to prevent.
require_text() {  # <label> <text>
  local label=$1 text=$2
  [ -n "$text" ] || die "$label must not be empty"
  case "$text" in
    *$'\t'*) die "$label must not contain a tab" ;;
    *$'\n'*) die "$label must not contain a newline" ;;
  esac
}

RECORD_FILE=
WAIVER_FILE=
STATUS_FILE=
set_task_paths() {  # <task-id>
  RECORD_FILE="$DATA/$1/obligations.tsv"
  WAIVER_FILE="$DATA/$1/obligations.waived"
  STATUS_FILE="$STATE/$1.status"
}

# 0 when the status log carries a `note` line stating exactly <key>.
obligation_is_reported() {  # <key>
  local key=$1 line verb line_key
  [ -f "$STATUS_FILE" ] && [ -r "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(status_line_verb "$line")
    [ "$verb" = note ] || continue
    line_key=$(_fm_decision_key "$line") || continue
    [ "$line_key" = "$key" ] || continue
    return 0
  done < "$STATUS_FILE"
  return 1
}

obligation_is_waived() {  # <key>
  local key=$1
  [ -f "$WAIVER_FILE" ] || return 1
  cut -f1 < "$WAIVER_FILE" | grep -Fxq -- "$key"
}

# Print "<key>\t<state>\t<text>" for each recorded obligation, in record order.
each_obligation_state() {
  local key text state
  [ -f "$RECORD_FILE" ] || return 0
  while IFS=$(printf '\t') read -r key text || [ -n "$key" ]; do
    [ -n "$key" ] || continue
    if obligation_is_reported "$key"; then
      state=reported
    elif obligation_is_waived "$key"; then
      state=waived
    else
      state=unmet
    fi
    printf '%s\t%s\t%s\n' "$key" "$state" "$text"
  done < "$RECORD_FILE"
}

case "$CMD" in
  record)
    ID=${1:-}; KEY=${2:-}; shift 2 2>/dev/null || true
    require_task_id "$ID"
    require_key "$KEY"
    TEXT=
    while [ $# -gt 0 ]; do
      case "$1" in
        --text) [ $# -ge 2 ] || die "--text requires a value"; TEXT=$2; shift 2 ;;
        --text=*) TEXT=${1#--text=}; shift ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    require_text "obligation text" "$TEXT"
    set_task_paths "$ID"
    mkdir -p "$DATA/$ID"
    if [ -f "$RECORD_FILE" ]; then
      EXISTING=$(awk -F'\t' -v k="$KEY" '$1 == k { print $2; exit }' "$RECORD_FILE")
      if [ -n "$EXISTING" ]; then
        [ "$EXISTING" = "$TEXT" ] \
          || die "obligation '$KEY' is already recorded with different text; a stated requirement is never silently rewritten (recorded: $EXISTING)"
        echo "recorded: $KEY (unchanged)"
        exit 0
      fi
    fi
    printf '%s\t%s\n' "$KEY" "$TEXT" >> "$RECORD_FILE"
    echo "recorded: $KEY"
    ;;
  list)
    ID=${1:-}
    require_task_id "$ID"
    set_task_paths "$ID"
    each_obligation_state
    ;;
  verify)
    ID=${1:-}
    require_task_id "$ID"
    set_task_paths "$ID"
    UNMET=0
    while IFS=$(printf '\t') read -r key state text || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      [ "$state" = unmet ] || continue
      UNMET=$((UNMET + 1))
      printf 'unmet: [key=%s] %s\n' "$key" "$text" >&2
    done <<EOF
$(each_obligation_state)
EOF
    if [ "$UNMET" -gt 0 ]; then
      echo "Have the worker append 'note [key=<key>]: <evidence>' to $STATUS_FILE, or waive it with bin/fm-obligations.sh waive $ID <key> --reason '<why>'." >&2
      exit 1
    fi
    ;;
  waive)
    ID=${1:-}; KEY=${2:-}; shift 2 2>/dev/null || true
    require_task_id "$ID"
    require_key "$KEY"
    REASON=
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) [ $# -ge 2 ] || die "--reason requires a value"; REASON=$2; shift 2 ;;
        --reason=*) REASON=${1#--reason=}; shift ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    require_text "waiver reason" "$REASON"
    set_task_paths "$ID"
    [ -f "$RECORD_FILE" ] || die "task $ID has no recorded obligations"
    awk -F'\t' -v k="$KEY" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "$RECORD_FILE" \
      || die "task $ID has no obligation '$KEY'"
    if obligation_is_waived "$KEY"; then
      echo "waived: $KEY (already waived)"
      exit 0
    fi
    printf '%s\t%s\n' "$KEY" "$REASON" >> "$WAIVER_FILE"
    echo "waived: $KEY"
    ;;
  *)
    die "unknown command: $CMD (see --help)"
    ;;
esac
