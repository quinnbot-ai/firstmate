#!/usr/bin/env bash
# Who owns a recorded task copy RIGHT NOW, including copies that carry no
# ownership binding at all.
#
# THE FAILURE THIS EXISTS FOR. bin/fm-worktree-binding-lib.sh stamps the current
# owner inside a freshly assigned copy's private Git directory, and teardown
# reads it before touching anything. That protects every copy assigned after the
# binding existed. It deliberately does nothing for the collisions that already
# exist: a lane recorded before the binding, pointing at a copy that also
# predates it, has no binding to read, so teardown behaves exactly as it did
# before and the stale pointer stays both unrefused and unretirable.
#
# Those collisions are not a backlog that drains. A lane that is preserved
# instead of torn down - a captain-gated long-term pause - keeps its recorded
# pointer for as long as it stays preserved, the pool hands the slot to someone
# else, and nothing refuses. The count of stale pointers in a home therefore
# grows with the number of protected lanes, and every protected lane is by
# construction one that will never be cleaned up on its own.
#
# THE SECOND PROOF. When no binding can be read, ownership is still legible from
# the copy itself: the branch it actually has checked out. bin/fm-brief.sh gives
# every task the single branch name `fm/<task-id>`, so a copy sitting on
# `fm/<other>` is announcing that it is now <other>'s. That is exactly the check
# a supervisor runs by hand before an unbound teardown, and it reads the copy
# rather than the record, which is the whole point: a recorded path is an
# allocation, never proof of ownership.
#
# THREE CONDITIONS KEEP IT QUIET. A wrong "this copy was reassigned" verdict is
# as damaging as the missing one, because it retires a live pointer and refuses
# a legitimate cleanup, so the branch proof fires only when all three hold:
#
#   1. The binding wins whenever it is readable. The branch is consulted ONLY
#      after fm_worktree_binding_read has failed. A worker that checks out some
#      other branch inside its own copy must never look reassigned.
#   2. The branch must name a task THIS home records, whose own record points
#      back at this same path. One-sided evidence ("some fm/* branch is checked
#      out here") proves nothing; the copy and the claimant's record have to
#      agree before the reassignment is called proven.
#   3. Callers compare the resolved owner against the task they are asking
#      about. A copy that is still its own lane's resolves to that lane and is
#      reported as owned, not reassigned.
#
# Usage: . bin/fm-worktree-owner-lib.sh   (after bin/fm-worktree-binding-lib.sh)
#
# Public entry points:
#   fm_worktree_owner_resolve <worktree> <state-dir>
#     Sets FM_WORKTREE_OWNER_TASK_ID / _METHOD (binding|branch) / _BRANCH and
#     returns 0 when the copy's current owner is proven. Returns non-zero with
#     FM_WORKTREE_OWNER_DETAIL when it is not; unprovable is never a verdict.
#   fm_worktree_owner_retire_pointer <meta-file> <owner-task-id>
#     Writes the durable `worktree_retired=<owner>` line into one task record and
#     KEEPS the stale `worktree=` value as history. Callers own the meta lock;
#     this function does not take one.

# shellcheck disable=SC2034 # Read by callers (fm-teardown.sh, fm-reconcile-worktree-pointers.sh), not this lib.
FM_WORKTREE_OWNER_TASK_ID=
# shellcheck disable=SC2034 # Read by callers, not this lib.
FM_WORKTREE_OWNER_METHOD=
# shellcheck disable=SC2034 # Read by callers, not this lib.
FM_WORKTREE_OWNER_BRANCH=
# shellcheck disable=SC2034 # Read by callers, not this lib.
FM_WORKTREE_OWNER_DETAIL=

# The one place that knows bin/fm-brief.sh's `fm/<task-id>` branch convention.
fm_worktree_owner_branch_task_id() {  # <branch> -> task id on stdout
  local branch=${1-} id
  case "$branch" in
    fm/?*) id=${branch#fm/} ;;
    *) return 1 ;;
  esac
  fm_worktree_binding_task_id_valid "$id" || return 1
  printf '%s\n' "$id"
}

# Condition 2: the claimant named by the branch must be a task this home records,
# and that record must point back at this exact copy.
fm_worktree_owner_record_confirms() {  # <state-dir> <task-id> <worktree>
  local state=${1-} id=${2-} worktree=${3-} meta recorded
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  recorded=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
  [ -n "$recorded" ] && [ "$recorded" = "$worktree" ]
}

fm_worktree_owner_resolve() {  # <worktree> <state-dir>
  local worktree=${1-} state=${2-} branch candidate
  FM_WORKTREE_OWNER_TASK_ID=
  FM_WORKTREE_OWNER_METHOD=
  FM_WORKTREE_OWNER_BRANCH=
  FM_WORKTREE_OWNER_DETAIL=
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    FM_WORKTREE_OWNER_DETAIL="no copy at ${worktree:-<empty>} to read current ownership from"
    return 1
  fi
  # Condition 1: an authoritative binding ends the question here.
  if fm_worktree_binding_read "$worktree"; then
    FM_WORKTREE_OWNER_TASK_ID=$FM_WORKTREE_BINDING_TASK_ID
    FM_WORKTREE_OWNER_METHOD=binding
    FM_WORKTREE_OWNER_BRANCH=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    return 0
  fi
  branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  FM_WORKTREE_OWNER_BRANCH=$branch
  if [ -z "$branch" ]; then
    FM_WORKTREE_OWNER_DETAIL="the copy at $worktree names no owner and its checked-out branch is unreadable"
    return 1
  fi
  if ! candidate=$(fm_worktree_owner_branch_task_id "$branch"); then
    FM_WORKTREE_OWNER_DETAIL="the copy at $worktree names no owner and its branch '$branch' is not a task branch"
    return 1
  fi
  if ! fm_worktree_owner_record_confirms "$state" "$candidate" "$worktree"; then
    FM_WORKTREE_OWNER_DETAIL="the copy at $worktree has branch '$branch' checked out, but this home has no record of task $candidate holding that copy"
    return 1
  fi
  FM_WORKTREE_OWNER_TASK_ID=$candidate
  FM_WORKTREE_OWNER_METHOD=branch
  return 0
}

# Retire one stale pointer, record-only. The stale worktree= value is KEPT: it is
# the honest history of what the lane was allocated, and bin/fm-backend.sh's
# endpoint validation needs it, so deleting it would make the record permanently
# un-tearable. The added line names the task proven to own the path instead, and
# it is durable, so a failed later step is re-run idempotently.
fm_worktree_owner_retire_pointer() {  # <meta-file> <owner-task-id>
  local meta=${1-} owner=${2-} tmp
  [ -f "$meta" ] || {
    echo "error: no task record at ${meta:-<empty>} to retire a copy pointer in" >&2
    return 1
  }
  fm_worktree_binding_task_id_valid "$owner" || {
    echo "error: refusing to retire a copy pointer to an invalid owning task id" >&2
    return 1
  }
  tmp="$meta.forget.$$"
  if ! { cat "$meta" && printf 'worktree_retired=%s\n' "$owner"; } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error: could not rewrite $meta to retire its stale copy pointer" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$meta"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "error: could not publish the retired copy pointer to $meta" >&2
    return 1
  fi
  return 0
}
