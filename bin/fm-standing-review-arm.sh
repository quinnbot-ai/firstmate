#!/usr/bin/env bash
# fm-standing-review-arm.sh - arm, list, or disarm a standing review as a watcher check.
#
# A standing review is an ordinary registered custom check (AGENTS.md section 7).
# This script owns only the arming path: it validates the spec, writes the
# byte-static shim the watcher will run, and binds those bytes through
# bin/fm-check-register.sh. bin/fm-standing-review.sh owns the review itself and
# the evidence gate; read its header before writing a spec.
#
# Usage:
#   fm-standing-review-arm.sh --id <review-id> [--home <fm-home>]
#   fm-standing-review-arm.sh --list [--home <fm-home>]
#   fm-standing-review-arm.sh --disarm --id <review-id> [--home <fm-home>] [--purge]
#
# Options:
#   --id <id>     review id; names the spec, the check, and the durable records
#   --home <path> firstmate home to arm in (default: FM_HOME, else this repo)
#   --purge       with --disarm, also delete the review's durable records, so a
#                 later re-arm may wake for findings it already reported
#   --list        print the armed standing reviews in this home
#   -h, --help    print this header
#
# THIS SCRIPT ARMS NO SCHEDULER. It registers a check the existing watcher
# already sweeps; it creates no cron entry, LaunchAgent, or routine, and it does
# not refresh the review's evidence sources. Whatever keeps those sources
# current is a separate trigger owned outside this home. Nothing here goes
# quiet if that trigger is missing: the review's freshness condition turns a
# source that stopped refreshing into the finding it reports.
#
# The generated shim carries absolute paths because a custom check inherits no
# guaranteed firstmate environment - the watcher exports FM_HOME only for its
# own Relay shim, so a review that resolved its home from the environment would
# resolve it against whatever launched the watcher.
#
# Arming refuses to touch a check it did not generate, and refuses an id that
# already names a task, because task ids and check ids share one namespace and
# a task's cleanup removes its check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-standing-review-arm.sh" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

canonical_directory() {
  [ -d "$1" ] || return 1
  ( CDPATH= cd -- "$1" && pwd -P )
}

ID=
MODE=arm
PURGE=0
DISARM_REQUESTED=0
LIST_REQUESTED=0
TMP=
PRIOR_CHECK=
PRIOR_TRUST=
REPLACEMENT_PENDING=0
TASK_SET_LOCK=
TASK_SET_LOCK_HELD=0
CHECK_LIFECYCLE_LOCK=
CHECK_LIFECYCLE_LOCK_HELD=0

release_check_lifecycle_lock() {
  [ "$CHECK_LIFECYCLE_LOCK_HELD" -eq 1 ] || return 0
  CHECK_LIFECYCLE_LOCK_HELD=0
  fm_lock_release "$CHECK_LIFECYCLE_LOCK"
}

rollback_replacement() {
  [ "$REPLACEMENT_PENDING" -eq 1 ] || return 0
  if [ -n "$PRIOR_CHECK" ] && [ -n "$PRIOR_TRUST" ]; then
    mv -f -- "$PRIOR_TRUST" "$TRUST" || return 1
    PRIOR_TRUST=
    mv -f -- "$PRIOR_CHECK" "$CHECK" || return 1
    PRIOR_CHECK=
  else
    rm -f -- "$CHECK" "$TRUST" || return 1
  fi
  REPLACEMENT_PENDING=0
}

cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP"
  if ! rollback_replacement; then
    printf 'error: could not restore the prior standing review registration\n' >&2
    status=1
  fi
  if [ "$REPLACEMENT_PENDING" -eq 0 ]; then
    [ -z "$PRIOR_CHECK" ] || rm -f -- "$PRIOR_CHECK"
    [ -z "$PRIOR_TRUST" ] || rm -f -- "$PRIOR_TRUST"
  fi
  if [ "$CHECK_LIFECYCLE_LOCK_HELD" -eq 1 ]; then
    release_check_lifecycle_lock || status=1
  fi
  if [ "$TASK_SET_LOCK_HELD" -eq 1 ]; then
    TASK_SET_LOCK_HELD=0
    fm_lock_release "$TASK_SET_LOCK"
  fi
  return "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) [ "$#" -ge 2 ] || die "--id needs a value" 2; ID=$2; shift 2 ;;
    --home) [ "$#" -ge 2 ] || die "--home needs a value" 2; FM_HOME=$2; shift 2 ;;
    --disarm) DISARM_REQUESTED=1; shift ;;
    --list) LIST_REQUESTED=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ "$DISARM_REQUESTED" -eq 0 ] || [ "$LIST_REQUESTED" -eq 0 ] \
  || die "--disarm and --list cannot be combined" 2
if [ "$DISARM_REQUESTED" -eq 1 ]; then
  MODE=disarm
elif [ "$LIST_REQUESTED" -eq 1 ]; then
  MODE=list
fi
[ "$PURGE" -eq 0 ] || [ "$MODE" = disarm ] || die "--purge requires --disarm" 2
[ "$MODE" != list ] || [ -z "$ID" ] || die "--id cannot be used with --list" 2

HOME_INPUT=$FM_HOME
FM_HOME=$(canonical_directory "$HOME_INPUT") || die "home directory is unavailable: $HOME_INPUT"
STATE_INPUT="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_INPUT="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ ! -L "$STATE_INPUT" ] || die "state directory is unavailable: $STATE_INPUT"
STATE=$(canonical_directory "$STATE_INPUT") || die "state directory is unavailable: $STATE_INPUT"
CONFIG=$(canonical_directory "$CONFIG_INPUT") || die "config directory is unavailable: $CONFIG_INPUT"

is_review_shim() {  # <path>
  fm_standing_review_check_owned "$1"
}

if [ "$MODE" = list ]; then
  checks=()
  TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") \
    || die "cannot resolve the task-set lock for $STATE"
  fm_lock_acquire_wait "$TASK_SET_LOCK" \
    || die "cannot acquire the task-set lock for $STATE"
  TASK_SET_LOCK_HELD=1
  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || continue
    checks+=("$check")
  done
  if [ "${#checks[@]}" -eq 0 ]; then
    printf 'no standing reviews armed in %s\n' "$FM_HOME"
    exit 0
  fi
  TASK_SET_LOCK_HELD=0
  fm_lock_release "$TASK_SET_LOCK" \
    || die "cannot release the task-set lock for $STATE"
  found=0
  for check in "${checks[@]}"; do
    id=$(basename "$check" .check.sh)
    fm_pr_task_id_valid "$id" || continue
    CHECK_LIFECYCLE_LOCK=$(fm_custom_check_lifecycle_lock_path "$STATE" "$id") \
      || die "cannot resolve the check lifecycle lock for $id"
    fm_lock_acquire_wait "$CHECK_LIFECYCLE_LOCK" \
      || die "cannot acquire the check lifecycle lock for $id"
    CHECK_LIFECYCLE_LOCK_HELD=1
    if { [ -e "$check" ] || [ -L "$check" ]; } && is_review_shim "$check"; then
      if fm_custom_check_registered "$STATE" "$id" 2>/dev/null; then
        state=registered
      else
        state=UNREGISTERED
      fi
      printf '%s\t%s\t%s\n' "$id" "$state" "$CONFIG/standing-reviews/$id.json"
      found=1
    fi
    release_check_lifecycle_lock || die "cannot release the check lifecycle lock for $id"
  done
  [ "$found" -eq 1 ] || printf 'no standing reviews armed in %s\n' "$FM_HOME"
  exit 0
fi

[ -n "$ID" ] || die "--id is required" 2
fm_pr_task_id_valid "$ID" || die "review id is not a safe identifier: $ID" 2
case "$ID" in */*) die "review id must not contain a path separator" 2 ;; esac
fm_standing_review_id_reserved "$ID" \
  && die "review id is reserved by a system check: $ID" 2

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"

acquire_review_locks() {
  TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") \
    || die "cannot resolve the task-set lock for $STATE"
  fm_lock_try_acquire "$TASK_SET_LOCK" \
    || die "this home's task set is locked by another operation; refusing to $MODE review $ID"
  TASK_SET_LOCK_HELD=1
  CHECK_LIFECYCLE_LOCK=$(fm_custom_check_lifecycle_lock_path "$STATE" "$ID") \
    || die "cannot resolve the check lifecycle lock for $ID"
  fm_lock_acquire_wait "$CHECK_LIFECYCLE_LOCK" \
    || die "cannot acquire the check lifecycle lock for $ID"
  CHECK_LIFECYCLE_LOCK_HELD=1
}

review_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

review_artifact_preflight_remove() {
  local path=$1
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    die "review artifact is a directory; refusing to remove it: $path"
  fi
}

review_artifact_remove() {
  local path=$1
  review_artifact_present "$path" || return 0
  rm -f -- "$path" || die "could not remove review artifact: $path"
  ! review_artifact_present "$path" || die "review artifact remains after removal: $path"
}

if [ "$MODE" = disarm ]; then
  acquire_review_locks
  if review_artifact_present "$CHECK" && ! is_review_shim "$CHECK"; then
    die "state/$ID.check.sh is not a standing review shim; refusing to remove it"
  fi
  review_artifact_preflight_remove "$CHECK"
  review_artifact_preflight_remove "$TRUST"
  if [ "$PURGE" -eq 1 ]; then
    review_artifact_preflight_remove "$STATE/$ID.standing-review-latch"
    review_artifact_preflight_remove "$STATE/$ID.standing-review-last"
  fi
  review_artifact_remove "$CHECK"
  review_artifact_remove "$TRUST"
  if [ "$PURGE" -eq 1 ]; then
    review_artifact_remove "$STATE/$ID.standing-review-latch"
    review_artifact_remove "$STATE/$ID.standing-review-last"
    printf 'disarmed: %s (durable records purged)\n' "$ID"
  else
    printf 'disarmed: %s\n' "$ID"
  fi
  exit 0
fi

SCAN="$FM_ROOT/bin/fm-standing-review.sh"
[ -x "$SCAN" ] || die "review scanner is not executable: $SCAN"

# Validate before arming: an unusable spec must be a refusal here, not a wake
# every interval once the watcher owns it.
"$SCAN" --home "$FM_HOME" --state "$STATE" --config "$CONFIG" \
  --id "$ID" --validate || exit 1

acquire_review_locks

[ -e "$STATE/$ID.meta" ] && die "$ID already names a task in this home; choose another review id"
if [ -e "$CHECK" ] && ! is_review_shim "$CHECK"; then
  die "state/$ID.check.sh already exists and was not generated here; refusing to overwrite it"
fi

umask 077
STATE_DEVICE=$(fm_pr_file_device "$STATE") || die "cannot inspect the state directory"
if fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  && fm_pr_private_file_valid "$TRUST" 600 "$STATE_DEVICE"; then
  PRIOR_CHECK=$(mktemp "$STATE/.fm-standing-review-prior-check.XXXXXX") \
    || die "cannot preserve the current check shim"
  cp -p -- "$CHECK" "$PRIOR_CHECK" || die "cannot preserve the current check shim"
  PRIOR_TRUST=$(mktemp "$STATE/.fm-standing-review-prior-trust.XXXXXX") \
    || die "cannot preserve the current check registration"
  cp -p -- "$TRUST" "$PRIOR_TRUST" || die "cannot preserve the current check registration"
fi
TMP=$(mktemp "$STATE/.fm-standing-review-shim.XXXXXX") || die "cannot stage the check shim"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$FM_STANDING_REVIEW_CHECK_MARKER"
  printf '# Prints one line only when the review has an admissible finding.\n'
  printf 'exec %s --home %s --state %s --config %s --id %s\n' \
    "$(printf '%q' "$SCAN")" "$(printf '%q' "$FM_HOME")" \
    "$(printf '%q' "$STATE")" "$(printf '%q' "$CONFIG")" "$(printf '%q' "$ID")"
} > "$TMP" || die "cannot write the check shim"
chmod 0700 "$TMP" || die "cannot set the check shim mode"
bash -n "$TMP" || die "generated check shim does not parse"
REPLACEMENT_PENDING=1
mv -f -- "$TMP" "$CHECK" || die "cannot install the check shim"
TMP=

if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-check-register.sh" "$ID"; then
  rollback_replacement \
    || die "check registration failed for $ID and the prior review could not be restored"
  die "check registration failed for $ID"
fi
REPLACEMENT_PENDING=0
[ -z "$PRIOR_CHECK" ] || rm -f -- "$PRIOR_CHECK"
[ -z "$PRIOR_TRUST" ] || rm -f -- "$PRIOR_TRUST"
PRIOR_CHECK=
PRIOR_TRUST=
printf 'armed: standing review %s\n' "$ID"
