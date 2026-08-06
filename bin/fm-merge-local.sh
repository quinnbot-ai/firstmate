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

safe_git() {
  env \
    -u GIT_DIR \
    -u GIT_COMMON_DIR \
    -u GIT_WORK_TREE \
    -u GIT_IMPLICIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    -u GIT_NAMESPACE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_QUARANTINE_PATH \
    -u GIT_SHALLOW_FILE \
    -u GIT_REPLACE_REF_BASE \
    -u GIT_CONFIG \
    -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_CONFIG_NOSYSTEM \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_COUNT \
    -u GIT_EXEC_PATH \
    GIT_NO_REPLACE_OBJECTS=1 \
    git --no-replace-objects "$@"
}

PROJ=$(meta_single_value project) || exit 1
MODE=$(meta_single_value mode) || exit 1
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
RECORDED_WORKTREE=$(meta_single_value worktree) || exit 1

PROJECT_ROOT=$(safe_git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "error: task $ID project is not a Git checkout: $PROJ" >&2; exit 1; }
PROJECT_ROOT=$(canonical_dir "$PROJECT_ROOT") \
  || { echo "error: cannot canonicalize project checkout for task $ID" >&2; exit 1; }
PROJECT_COMMON=$(safe_git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir) \
  || { echo "error: cannot identify project repository for task $ID" >&2; exit 1; }
PROJECT_COMMON=$(canonical_dir "$PROJECT_COMMON") \
  || { echo "error: cannot canonicalize project repository for task $ID" >&2; exit 1; }
TASK_WORKTREE=$(canonical_dir "$RECORDED_WORKTREE") \
  || { echo "error: recorded worktree for task $ID does not exist: $RECORDED_WORKTREE" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(safe_git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if safe_git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
CANDIDATE=
VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-local.XXXXXX") \
  || { echo "error: cannot create verification workspace for task $ID" >&2; exit 1; }
trap 'rm -rf -- "$VERIFY_DIR"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
VERIFY_SEQUENCE=0

tracked_state_matches() {
  local checkout=$1 expected=$2 actual_entries actual_link entry expected_blob expected_entries
  local full_path metadata mode object_id permissions stage tracked_path
  VERIFY_SEQUENCE=$((VERIFY_SEQUENCE + 1))
  expected_entries=$VERIFY_DIR/expected-$VERIFY_SEQUENCE
  actual_entries=$VERIFY_DIR/actual-$VERIFY_SEQUENCE
  expected_blob=$VERIFY_DIR/blob-$VERIFY_SEQUENCE
  actual_link=$VERIFY_DIR/link-$VERIFY_SEQUENCE

  safe_git -C "$checkout" ls-tree -r -z --full-tree \
    --format='%(objectmode) %(objectname) 0%x09%(path)' "$expected" >"$expected_entries" \
    || return 1
  safe_git -C "$checkout" ls-files -z \
    --format='%(objectmode) %(objectname) %(stage)%x09%(path)' >"$actual_entries" \
    || return 1
  cmp -s "$expected_entries" "$actual_entries" \
    || return 1

  while IFS= read -r -d '' entry; do
    metadata=${entry%%$'\t'*}
    tracked_path=${entry#*$'\t'}
    mode=${metadata%% *}
    metadata=${metadata#* }
    object_id=${metadata%% *}
    stage=${metadata##* }
    [ "$stage" = 0 ] || return 1
    full_path=$checkout/$tracked_path
    case "$mode" in
      100644 | 100755)
        [ -f "$full_path" ] && [ ! -L "$full_path" ] || return 1
        if permissions=$(stat -c %a "$full_path" 2>/dev/null); then
          :
        elif permissions=$(stat -f %Lp "$full_path" 2>/dev/null); then
          :
        else
          return 1
        fi
        case "$mode:$permissions" in
          100755:*[1357][0-7][0-7] | 100644:*[0246][0-7][0-7]) ;;
          *) return 1 ;;
        esac
        safe_git -C "$checkout" cat-file blob "$object_id" >"$expected_blob" \
          || return 1
        cmp -s "$expected_blob" "$full_path" \
          || return 1
        ;;
      120000)
        [ -L "$full_path" ] || return 1
        safe_git -C "$checkout" cat-file blob "$object_id" >"$expected_blob" \
          || return 1
        readlink -n "$full_path" >"$actual_link" \
          || return 1
        cmp -s "$expected_blob" "$actual_link" \
          || return 1
        ;;
      160000)
        [ -d "$full_path" ] || return 1
        [ "$(safe_git -C "$full_path" rev-parse --verify HEAD^{commit} 2>/dev/null)" = "$object_id" ] \
          || return 1
        tracked_state_matches "$full_path" "$object_id" \
          || return 1
        ;;
      *) return 1 ;;
    esac
  done <"$actual_entries"
}

checkout_has_untracked() {
  local checkout=$1 entries entry full_path metadata mode tracked_path untracked
  VERIFY_SEQUENCE=$((VERIFY_SEQUENCE + 1))
  entries=$VERIFY_DIR/untracked-entries-$VERIFY_SEQUENCE
  untracked=$VERIFY_DIR/untracked-$VERIFY_SEQUENCE
  safe_git -C "$checkout" ls-files --others --exclude-standard -z >"$untracked" \
    || return 0
  [ ! -s "$untracked" ] || return 0
  safe_git -C "$checkout" ls-files -z \
    --format='%(objectmode) %(objectname) %(stage)%x09%(path)' >"$entries" \
    || return 0
  while IFS= read -r -d '' entry; do
    metadata=${entry%%$'\t'*}
    tracked_path=${entry#*$'\t'}
    mode=${metadata%% *}
    [ "$mode" = 160000 ] || continue
    full_path=$checkout/$tracked_path
    [ -d "$full_path" ] || continue
    checkout_has_untracked "$full_path" && return 0
  done <"$entries"
  return 1
}

checkout_has_in_progress_operation() {
  local checkout=$1 marker marker_path
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-apply rebase-merge sequencer; do
    marker_path=$(safe_git -C "$checkout" rev-parse --path-format=absolute --git-path "$marker") || return 0
    [ ! -e "$marker_path" ] || return 0
  done
  safe_git -C "$checkout" ls-files -u | grep -q . && return 0
  return 1
}

validate_task_custody() {
  local worker_root worker_common worker_branch worker_head candidate_now
  worker_root=$(safe_git -C "$TASK_WORKTREE" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: recorded worktree for task $ID is not a Git checkout" >&2; return 1; }
  worker_root=$(canonical_dir "$worker_root") \
    || { echo "error: cannot canonicalize recorded worktree for task $ID" >&2; return 1; }
  [ "$worker_root" = "$TASK_WORKTREE" ] \
    || { echo "error: recorded worktree for task $ID must name its checkout root" >&2; return 1; }
  worker_common=$(safe_git -C "$TASK_WORKTREE" rev-parse --path-format=absolute --git-common-dir) \
    || { echo "error: cannot identify recorded worktree repository for task $ID" >&2; return 1; }
  worker_common=$(canonical_dir "$worker_common") \
    || { echo "error: cannot canonicalize recorded worktree repository for task $ID" >&2; return 1; }
  [ "$worker_common" = "$PROJECT_COMMON" ] \
    || { echo "error: recorded worktree for task $ID belongs to a different repository" >&2; return 1; }
  worker_branch=$(safe_git -C "$TASK_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$worker_branch" = "$BRANCH" ] \
    || { echo "error: recorded worktree for task $ID is on '${worker_branch:-detached}', expected $BRANCH" >&2; return 1; }
  candidate_now=$(safe_git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}") \
    || { echo "error: branch $BRANCH does not exist in $PROJECT_ROOT" >&2; return 1; }
  if [ -z "$CANDIDATE" ]; then
    CANDIDATE=$candidate_now
  elif [ "$candidate_now" != "$CANDIDATE" ]; then
    echo "error: branch $BRANCH moved after custody verification; refusing to merge" >&2
    return 1
  fi
  worker_head=$(safe_git -C "$TASK_WORKTREE" rev-parse HEAD) \
    || { echo "error: cannot read recorded worktree HEAD for task $ID" >&2; return 1; }
  [ "$worker_head" = "$CANDIDATE" ] \
    || { echo "error: recorded worktree HEAD for task $ID is stale versus $BRANCH" >&2; return 1; }
  if checkout_has_in_progress_operation "$TASK_WORKTREE"; then
    echo "error: recorded worktree for task $ID has an unmerged index or operation in progress" >&2
    return 1
  fi
  tracked_state_matches "$TASK_WORKTREE" "$CANDIDATE" \
    || { echo "error: recorded worktree for task $ID is not clean; refusing to land unlanded work" >&2; return 1; }
  ! checkout_has_untracked "$TASK_WORKTREE" \
    || { echo "error: recorded worktree for task $ID is not clean; refusing to land unlanded work" >&2; return 1; }
}

validate_task_custody || exit 1

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

validate_target_state() {
  local cur
  cur=$(safe_git -C "$PROJECT_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
  [ "$cur" = "$DEFAULT" ] \
    || { echo "error: $PROJECT_ROOT is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; return 1; }
  if checkout_has_in_progress_operation "$PROJECT_ROOT"; then
    echo "error: $PROJECT_ROOT has an unmerged index or operation in progress; refusing to merge" >&2
    return 1
  fi
  if ! tracked_state_matches "$PROJECT_ROOT" HEAD \
    && ! tracked_state_matches "$PROJECT_ROOT" "$CANDIDATE"; then
    echo "error: $PROJECT_ROOT has tracked dirt that does not exactly match $BRANCH; refusing to merge" >&2
    return 1
  fi
}

# The project's main checkout must be on its default branch so the fast-forward
# lands predictably. Tracked dirt is allowed only when it already matches the
# custody-verified candidate (firstmate never reconciles it manually).
validate_target_state || exit 1

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! safe_git -C "$PROJECT_ROOT" merge-base --is-ancestor "$DEFAULT" "$CANDIDATE"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

validate_task_custody || exit 1
before=$(safe_git -C "$PROJECT_ROOT" rev-parse --short "$DEFAULT")
validate_target_state || exit 1
safe_git -C "$PROJECT_ROOT" merge --ff-only "$CANDIDATE" >/dev/null
after=$(safe_git -C "$PROJECT_ROOT" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJECT_ROOT"
