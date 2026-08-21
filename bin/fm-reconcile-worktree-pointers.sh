#!/usr/bin/env bash
# fm-reconcile-worktree-pointers.sh - retire the stale recorded-copy pointers a
# home has already accumulated, without touching a single copy or lane.
#
# THE FAILURE THIS EXISTS FOR. bin/fm-teardown.sh's current-owner check refuses a
# teardown aimed at a copy that now belongs to somebody else, and its
# --forget-worktree path retires such a pointer. Both fire at teardown time, on
# collisions discovered one at a time, and --forget-worktree then goes on to
# clean up the lane's records - which is precisely wrong for the lanes that
# actually hold these pointers. Every stale claimant found in this fleet so far
# was a deliberately preserved, captain-gated paused lane: it was never torn
# down because it must not be, which is exactly why its pointer went stale and
# exactly why teardown is the wrong instrument for repairing it.
#
# So this script separates the two things --forget-worktree fuses together. It
# retires the stale POINTER and stops. The lane keeps its record, its status log,
# its endpoint, its branch and its preserved work; the copy keeps its live
# owner's processes and files. Afterwards bin/fm-teardown.sh honours the durable
# worktree_retired= line on its own, so whenever that lane IS eventually cleaned
# up, it cleans up records only instead of reaching into a live task's copy.
#
# WHAT IT WILL NOT DO. It never writes to a status log. Any append re-declares a
# lane's current state and un-throttles a declared long-term pause, so recording
# a repair by appending to the lanes being repaired would wake every one of them
# - the repair announcing itself as an incident. The durable record of what
# happened is the worktree_retired= line in the task record and this script's own
# output.
#
# Usage: fm-reconcile-worktree-pointers.sh [--apply]
#
# Reports by default and changes nothing; --apply retires the pointers it
# reports. Re-runnable: an already-retired pointer is counted and skipped, so the
# accumulation this fixes can be drained again later rather than needing to be
# caught in one pass.
#
# Ownership is resolved by bin/fm-worktree-owner-lib.sh, from the copy itself -
# its ownership binding when it has one, otherwise the branch it actually has
# checked out cross-confirmed against the claimant's own record. A copy whose
# owner cannot be proven is reported as unresolved and left completely alone:
# "cannot tell" is never treated as "reassigned".
#
# Output lines, one per task record:
#   STALE:      <id> copy <path> is owned by <owner> (branch <branch>, via <method>)
#   RETIRED:    <id> ... (with --apply)
#   UNRESOLVED: <id> <detail>
# followed by a one-line summary. Exit 0 on a clean run, 1 if a retirement failed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worktree-binding-lib.sh
. "$SCRIPT_DIR/fm-worktree-binding-lib.sh"
# shellcheck source=bin/fm-worktree-owner-lib.sh
. "$SCRIPT_DIR/fm-worktree-owner-lib.sh"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ -d "$STATE" ] || { echo "error: no state directory at $STATE" >&2; exit 2; }

meta_field() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

stale=0
retired_now=0
already=0
unresolved=0
failed=0

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  fm_worktree_binding_task_id_valid "$id" || continue
  # A secondmate home is a persistent home, not a pooled slot; its own removal
  # validation owns it and it is never recycled underneath its record.
  kind=$(meta_field "$meta" kind)
  [ "$kind" != secondmate ] || continue
  if [ -n "$(meta_field "$meta" worktree_retired)" ]; then
    already=$((already + 1))
    continue
  fi
  wt=$(meta_field "$meta" worktree)
  # No pointer, or a pointer to something that no longer exists: there is no live
  # copy here to misidentify, and nothing to retire.
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  if ! fm_worktree_owner_resolve "$wt" "$STATE"; then
    unresolved=$((unresolved + 1))
    printf 'UNRESOLVED: %s %s\n' "$id" "$FM_WORKTREE_OWNER_DETAIL"
    continue
  fi
  # Condition 3: the copy still being this lane's own is the healthy case.
  [ "$FM_WORKTREE_OWNER_TASK_ID" != "$id" ] || continue
  stale=$((stale + 1))
  owner=$FM_WORKTREE_OWNER_TASK_ID
  branch=${FM_WORKTREE_OWNER_BRANCH:-<unreadable>}
  if [ "$APPLY" != 1 ]; then
    printf 'STALE: %s copy %s is owned by %s (branch %s, via %s)\n' \
      "$id" "$wt" "$owner" "$branch" "$FM_WORKTREE_OWNER_METHOD"
    continue
  fi
  lock=$(fm_meta_lock_path "$meta") || { failed=$((failed + 1)); continue; }
  fm_lock_acquire_wait "$lock"
  if fm_worktree_owner_retire_pointer "$meta" "$owner"; then
    retired_now=$((retired_now + 1))
    printf 'RETIRED: %s copy %s is owned by %s (branch %s, via %s)\n' \
      "$id" "$wt" "$owner" "$branch" "$FM_WORKTREE_OWNER_METHOD"
  else
    failed=$((failed + 1))
  fi
  fm_lock_release "$lock" || true
done

if [ "$APPLY" = 1 ]; then
  printf 'summary: %d stale pointer(s), %d retired, %d already retired, %d unresolved, %d failed\n' \
    "$stale" "$retired_now" "$already" "$unresolved" "$failed"
else
  printf 'summary: %d stale pointer(s) to retire, %d already retired, %d unresolved (re-run with --apply to retire)\n' \
    "$stale" "$already" "$unresolved"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
