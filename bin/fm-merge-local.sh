#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a fast-forward whose changed paths have no dirty
# overlap. It preserves unrelated runtime-artifact drift, refuses a diverged
# branch, and tells you to have the crewmate rebase. See AGENTS.md prime
# directives, project management, and task lifecycle.
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

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

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
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch.
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }

# Fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Query each dirty path against the exact fast-forward range. Porcelain -z keeps
# unusual path bytes unambiguous; --untracked-files=all expands untracked
# directories so an untracked file that the branch would add cannot hide behind
# its parent directory. Rename and copy records carry a second path, and both
# sides can intersect the fast-forward.
path_if_changed_by_fast_forward() {
  local path=$1 rc
  if GIT_LITERAL_PATHSPECS=1 git -C "$PROJ" diff --quiet "$DEFAULT..$BRANCH" -- "$path" </dev/null; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || return "$rc"
  printf '  %q\n' "$path"
}

dirty_paths_changed_by_fast_forward() {
  local entry status path
  git -C "$PROJ" status --porcelain=v1 -z --untracked-files=all \
    | while IFS= read -r -d '' entry; do
        [ "${#entry}" -ge 4 ] || return 2
        status=${entry:0:2}
        path=${entry:3}
        path_if_changed_by_fast_forward "$path" || return 2
        case "$status" in
          R?|C?|?R|?C)
            IFS= read -r -d '' path || return 2
            path_if_changed_by_fast_forward "$path" || return 2
            ;;
        esac
      done
}

set -o pipefail
if ! DIRTY_OVERLAP=$(dirty_paths_changed_by_fast_forward); then
  echo "REFUSED: cannot compare dirty paths in $PROJ with the $DEFAULT..$BRANCH fast-forward; refusing to merge." >&2
  exit 1
fi
if [ -n "$DIRTY_OVERLAP" ]; then
  echo "REFUSED: dirty paths in $PROJ intersect paths changed by the $DEFAULT..$BRANCH fast-forward:" >&2
  printf '%s\n' "$DIRTY_OVERLAP" >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
