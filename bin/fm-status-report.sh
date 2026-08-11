#!/usr/bin/env bash
# fm-status-report.sh - append one crewmate material-phase status event safely.
#
# Usage:
#   fm-status-report.sh <absolute-state/<task>.status> <one-line-status-event>
#
# This is the sole writer for status events produced by generated crewmate and
# secondmate-reporting commands.
# A keyed declared-pause event is appended once per identical line per task and
# home during a one-hour window.
# A changed pause reason, or any keyed non-pause transition, appends immediately.
# The durable per-phase receipt lives under state/.status-report/ and is updated
# atomically while the task's status-report lock is held.
# Status history is append-only: receipts never rewrite or compact *.status.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf '%s\n' "Usage: fm-status-report.sh <absolute-state/<task>.status> <one-line-status-event>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
STATUS_FILE=$1
LINE=$2

case "$STATUS_FILE" in
  /*/state/*.status) ;;
  *)
    printf 'fm-status-report: status file must be an absolute state/<task>.status path\n' >&2
    exit 2
    ;;
esac
case "$LINE" in
  ''|*$'\n'*|*$'\r'*)
    printf 'fm-status-report: status event must be one non-empty line\n' >&2
    exit 2
    ;;
esac

STATE_DIR=$(cd "$(dirname "$STATUS_FILE")" 2>/dev/null && pwd -P) || {
  printf 'fm-status-report: cannot resolve status directory for %s\n' "$STATUS_FILE" >&2
  exit 1
}
TASK=$(basename "$STATUS_FILE")
TASK=${TASK%.status}
case "$TASK" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'fm-status-report: invalid task id in status file %s\n' "$STATUS_FILE" >&2
    exit 2
    ;;
esac

# fm-wake-lib's portable owner-directory locks serialize the event append and
# phase receipt for this task without relying on flock or a process-global lock.
export FM_STATE_OVERRIDE="$STATE_DIR"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

LOCK_DIR="$STATE_DIR/.status-report-locks/$TASK.lock"
mkdir -p "$(dirname "$LOCK_DIR")" || exit 1
fm_lock_acquire_wait "$LOCK_DIR"
trap 'fm_lock_release "$LOCK_DIR"' EXIT HUP INT TERM

append_event() {
  mkdir -p "$STATE_DIR" || return 1
  printf '%s\n' "$LINE" >> "$STATUS_FILE"
}

PREFIX=${LINE%%:*}
KEY=
if case "$PREFIX" in *\[key=*\]*) true ;; *) false ;; esac; then
  KEY=$(_fm_decision_key "$LINE") || {
    printf 'fm-status-report: invalid stable phase key\n' >&2
    exit 2
  }
fi
VERB=$(status_line_verb "$LINE")
PAUSE_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

if [ -z "$KEY" ]; then
  append_event || exit 1
  printf '%s\n' appended
  exit 0
fi

PHASE_DIR="$STATE_DIR/.status-report/$TASK"
RECEIPT="$PHASE_DIR/$KEY"

if [ "$VERB" != "$PAUSE_VERB" ]; then
  append_event || exit 1
  rm -f "$RECEIPT"
  printf '%s\n' appended
  exit 0
fi

now=$(date +%s)
previous_epoch=
previous_line=
if [ -r "$RECEIPT" ]; then
  IFS= read -r previous_epoch < "$RECEIPT" || previous_epoch=
  previous_line=$(sed -n '2p' "$RECEIPT" 2>/dev/null || true)
fi

if [ "$previous_line" = "$LINE" ] \
  && case "$previous_epoch" in *[!0-9]*|'') false ;; *) true ;; esac \
  && [ $(( now - previous_epoch )) -lt 3600 ]; then
  printf '%s\n' suppressed
  exit 0
fi

append_event || exit 1
old_umask=$(umask)
umask 077
mkdir -p "$PHASE_DIR" || exit 1
receipt_tmp=$(mktemp "$PHASE_DIR/.${KEY}.tmp.XXXXXX") || exit 1
umask "$old_umask"
if ! { printf '%s\n%s\n' "$now" "$LINE" > "$receipt_tmp" && mv -f "$receipt_tmp" "$RECEIPT"; }; then
  rm -f "$receipt_tmp"
  exit 1
fi
printf '%s\n' appended
