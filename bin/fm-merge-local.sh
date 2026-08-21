#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# The checkout must be clean, with one proven exception: dirt the fast-forward
# would produce anyway. A path whose working-tree content and mode already equal
# the target tip's holds no work the merge could destroy, so it is staged and
# landed with the merge instead of blocking it (a self-writing generator that
# reproduces its own committed output is the case this exists for). Identity is
# proved against the tip by content, per path - one differing byte, a staged
# version that is neither HEAD's nor the tip's, or a path the tip does not carry
# as a file all refuse exactly as before.
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

CHECK_TMP=""
cleanup_check_tmp() {
  if [ -n "$CHECK_TMP" ]; then
    rm -rf "$CHECK_TMP"
  fi
}
trap cleanup_check_tmp EXIT

# Decide whether a dirty checkout still qualifies for the fast-forward, and if
# so write the NUL-separated paths to stage to $1. Returns non-zero the moment
# any dirty path is not provably the target tip's own content, which keeps every
# other dirty checkout refused.
branch_identical_dirt() {
  local out=$1 index dirty path entry mode
  : > "$out"
  index="$CHECK_TMP/tip.index"
  dirty="$CHECK_TMP/dirty"
  # Every path git calls dirty: unstaged, staged, untracked. Collected as three
  # plain path lists rather than status records so a rename is judged as its two
  # ordinary paths, with no status code to decode.
  {
    git -C "$PROJ" diff-files --name-only -z &&
      git -C "$PROJ" diff-index --cached --name-only -z HEAD -- &&
      git -C "$PROJ" ls-files --others --exclude-standard -z
  } > "$dirty" || return 1
  # A throwaway index seeded from the tip lets git itself answer "is the working
  # tree already exactly this commit here", including mode, content filters, and
  # symlinks, without touching the project's real index. The refresh is what
  # turns stale stat data into a real content comparison.
  GIT_INDEX_FILE="$index" git -C "$PROJ" read-tree "$BRANCH" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE="$index" git -C "$PROJ" update-index -q --refresh >/dev/null 2>&1 || true
  while IFS= read -r -d "" path; do
    # The tip must carry this path as a file. A submodule pointer is excluded on
    # purpose: matching gitlinks say nothing about the dirt inside the submodule.
    entry=$(git -C "$PROJ" ls-tree "$BRANCH" -- "$path" || true)
    mode=${entry%% *}
    case "$mode" in
      100644|100755|120000) : ;;
      *) return 1 ;;
    esac
    # Content and mode on disk must already be the tip's.
    GIT_INDEX_FILE="$index" git -C "$PROJ" diff-files --quiet -- "$path" || return 1
    # Staging must lose nothing: the index either carries no change of its own,
    # or already carries exactly what the tip will land.
    if ! git -C "$PROJ" diff-index --cached --quiet HEAD -- "$path" &&
      ! git -C "$PROJ" diff-index --cached --quiet "$BRANCH" -- "$path"; then
      return 1
    fi
    printf '%s\0' "$path" >> "$out"
  done < "$dirty"
  return 0
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
STAGE_LIST=""
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  CHECK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-local.XXXXXX")
  if branch_identical_dirt "$CHECK_TMP/paths"; then
    STAGE_LIST="$CHECK_TMP/paths"
  else
    echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
    exit 1
  fi
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Only now, past every refusal, adopt the proven-identical dirt into the index so
# the fast-forward sees a consistent tree. Nothing here changes a byte on disk.
if [ -n "$STAGE_LIST" ]; then
  echo "note: dirty paths in $PROJ already match $BRANCH; landing them with the fast-forward" >&2
  while IFS= read -r -d "" stage_path; do
    git -C "$PROJ" add -- "$stage_path"
  done < "$STAGE_LIST"
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
