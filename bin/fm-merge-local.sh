#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a fast-forward - it refuses a diverged branch and
# tells you to have the crewmate rebase. Before merging, it proves that the
# recorded task worktree is the clean, checked-out fm/<id> candidate branch.
# A dirty target checkout is accepted only when its tracked index and working
# tree already exactly equal that candidate. Git remains the final collision
# check for untracked content. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

meta_single_value() {
  local key=$1 count=0 line value=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*)
        count=$((count + 1))
        value=${line#*=}
        ;;
    esac
  done < "$META"
  if [ "$count" -ne 1 ] || [ -z "$value" ]; then
    echo "error: task $ID metadata must contain exactly one nonempty $key= value" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

canonical_dir() {
  (cd -P -- "$1" && pwd -P)
}

PROJ=$(meta_single_value project) || exit 1
MODE=$(meta_single_value mode) || exit 1
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
RECORDED_WORKTREE=$(meta_single_value worktree) || exit 1

PROJECT_ROOT=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: task $ID project is not a Git checkout: $PROJ" >&2; exit 1; }
PROJECT_ROOT=$(canonical_dir "$PROJECT_ROOT") \
  || { echo "error: cannot canonicalize project checkout for task $ID" >&2; exit 1; }
PROJECT_COMMON=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir) \
  || { echo "error: cannot identify project repository for task $ID" >&2; exit 1; }
PROJECT_COMMON=$(canonical_dir "$PROJECT_COMMON") \
  || { echo "error: cannot canonicalize project repository for task $ID" >&2; exit 1; }
TASK_WORKTREE=$(canonical_dir "$RECORDED_WORKTREE") \
  || { echo "error: recorded worktree for task $ID does not exist: $RECORDED_WORKTREE" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"

validate_task_custody() {
  local worker_root worker_common worker_branch worker_head candidate worker_status
  worker_root=$(git -C "$TASK_WORKTREE" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: recorded worktree for task $ID is not a Git checkout" >&2; return 1; }
  worker_root=$(canonical_dir "$worker_root") \
    || { echo "error: cannot canonicalize recorded worktree for task $ID" >&2; return 1; }
  [ "$worker_root" = "$TASK_WORKTREE" ] \
    || { echo "error: recorded worktree for task $ID must name its checkout root" >&2; return 1; }
  worker_common=$(git -C "$TASK_WORKTREE" rev-parse --path-format=absolute --git-common-dir) \
    || { echo "error: cannot identify recorded worktree repository for task $ID" >&2; return 1; }
  worker_common=$(canonical_dir "$worker_common") \
    || { echo "error: cannot canonicalize recorded worktree repository for task $ID" >&2; return 1; }
  [ "$worker_common" = "$PROJECT_COMMON" ] \
    || { echo "error: recorded worktree for task $ID belongs to a different repository" >&2; return 1; }
  worker_branch=$(git -C "$TASK_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$worker_branch" = "$BRANCH" ] \
    || { echo "error: recorded worktree for task $ID is on '${worker_branch:-detached}', expected $BRANCH" >&2; return 1; }
  candidate=$(git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/heads/$BRANCH") \
    || { echo "error: branch $BRANCH does not exist in $PROJECT_ROOT" >&2; return 1; }
  worker_head=$(git -C "$TASK_WORKTREE" rev-parse HEAD) \
    || { echo "error: cannot read recorded worktree HEAD for task $ID" >&2; return 1; }
  [ "$worker_head" = "$candidate" ] \
    || { echo "error: recorded worktree HEAD for task $ID is stale versus $BRANCH" >&2; return 1; }
  worker_status=$(git -C "$TASK_WORKTREE" status --porcelain=v1 --untracked-files=all) \
    || { echo "error: cannot inspect recorded worktree state for task $ID" >&2; return 1; }
  [ -z "$worker_status" ] \
    || { echo "error: recorded worktree for task $ID is not clean; refusing to land unlanded work" >&2; return 1; }
}

target_has_in_progress_operation() {
  local marker
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-apply rebase-merge sequencer; do
    marker=$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-path "$marker") || return 0
    [ ! -e "$marker" ] || return 0
  done
  git -C "$PROJECT_ROOT" ls-files -u | grep -q . && return 0
  return 1
}

validate_task_custody || exit 1

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch so the fast-forward
# lands predictably. Tracked dirt is allowed only when it already matches the
# custody-verified candidate (firstmate never reconciles it manually).
cur=$(git -C "$PROJECT_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJECT_ROOT is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if target_has_in_progress_operation; then
  echo "error: $PROJECT_ROOT has an unmerged index or operation in progress; refusing to merge" >&2
  exit 1
fi
if ! git -C "$PROJECT_ROOT" diff --quiet -- \
  || ! git -C "$PROJECT_ROOT" diff --cached --quiet --; then
  if ! git -C "$PROJECT_ROOT" diff --quiet "$BRANCH" -- \
    || ! git -C "$PROJECT_ROOT" diff --cached --quiet "$BRANCH" --; then
    echo "error: $PROJECT_ROOT has tracked dirt that does not exactly match $BRANCH; refusing to merge" >&2
    exit 1
  fi
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJECT_ROOT" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

validate_task_custody || exit 1
before=$(git -C "$PROJECT_ROOT" rev-parse --short "$DEFAULT")
git -C "$PROJECT_ROOT" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJECT_ROOT" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJECT_ROOT"
