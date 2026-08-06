#!/usr/bin/env bash
# Execute a task merge through one shared exact-candidate boundary.
#
# Usage: fm-merge-execute.sh local <task-id>
#        fm-merge-execute.sh github <task-id> <pr-url> [-- <merge-args>]
#
# Both sanctioned merge entry points delegate here.
# The boundary validates task metadata, repository identity, clean exact
# candidate and base commits, and literal-source inventory receipts before the
# merge itself.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MERGE_EXECUTE_ARGS=("$@")

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

meta_value() {
  local key=$1 values count
  values=$(sed -n "s/^${key}=//p" "$META")
  count=$(printf '%s\n' "$values" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || die "task metadata must contain exactly one nonempty ${key}= value"
  printf '%s\n' "$values"
}

git_top() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || return 1; }

git_common() {
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) (cd "$common" 2>/dev/null && pwd -P) ;;
    *) (cd "$root/$common" 2>/dev/null && pwd -P) ;;
  esac
}

require_clean() {
  local root=$1 label=$2 status
  status=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || die "cannot inspect $label state"
  [ -z "$status" ] || die "$label is dirty; refusing merge execution"
}

require_repository_state() {
  local worktree_top project_top worktree_common project_common
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die "task worktree is unavailable"
  [ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] || die "task project checkout is unavailable"
  worktree_top=$(git_top "$WORKTREE") || die "task worktree is not a git checkout"
  project_top=$(git_top "$PROJECT") || die "task project is not a git checkout"
  [ "$(cd "$WORKTREE" && pwd -P)" = "$(cd "$worktree_top" && pwd -P)" ] || die "task worktree path does not match its git top-level"
  [ "$(cd "$PROJECT" && pwd -P)" = "$(cd "$project_top" && pwd -P)" ] || die "task project path does not match its git top-level"
  worktree_common=$(git_common "$WORKTREE") || die "cannot resolve task worktree repository"
  project_common=$(git_common "$PROJECT") || die "cannot resolve task project repository"
  [ "$worktree_common" = "$project_common" ] || die "task worktree and project metadata name different repositories"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
}

ensure_repository_lock() {
  local common lock_path
  common=$(git_common "$PROJECT") || die "cannot resolve repository lock path"
  lock_path="$common/firstmate-merge.lock"
  if [ -n "${FM_MERGE_LOCK_FD:-}" ]; then
    python3 - "$FM_MERGE_LOCK_FD" "$lock_path" <<'PY' || die "repository merge lock is invalid"
import fcntl
import os
import pathlib
import sys

fd = int(sys.argv[1])
path = pathlib.Path(sys.argv[2])
held = os.fstat(fd)
current = path.stat()
if (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
    raise SystemExit(1)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
    return
  fi
  python3 - "$lock_path" "$SCRIPT_DIR/fm-merge-execute.sh" "${MERGE_EXECUTE_ARGS[@]}" <<'PY'
import fcntl
import os
import subprocess
import sys

lock_path, script, *args = sys.argv[1:]
fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
environment = os.environ.copy()
environment["FM_MERGE_LOCK_FD"] = str(fd)
result = subprocess.run([script, *args], env=environment, pass_fds=(fd,))
raise SystemExit(result.returncode)
PY
  exit $?
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$branch"; then printf '%s\n' "$branch"; return 0; fi
  done
  return 1
}

api_value() {
  local key=$1 payload=$2 value count
  value=$(printf '%s\n' "$payload" | sed -n "s/^[[:space:]]*${key}: //p")
  count=$(printf '%s\n' "$value" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || die "GitHub response did not contain exactly one ${key} value"
  printf '%s\n' "$value"
}

urlencode_ref() { python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

parse_merge_args() {
  local arg
  MERGE_METHOD=squash
  DELETE_BRANCH=0
  METHOD_SEEN=0
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --squash) arg=squash ;;
      --merge) arg=merge ;;
      --rebase) arg=rebase ;;
      --method) [ "$#" -gt 0 ] || die "--method requires squash, merge, or rebase"; arg=$1; shift ;;
      --method=*) arg=${arg#--method=} ;;
      --delete-branch) DELETE_BRANCH=1; continue ;;
      --auto|--disable-auto|--admin) die "$arg is a non-immediate or protection-bypassing merge mode" ;;
      --repo|--repo=*|-R|-R?*) die "extra merge arguments must not override the repository" ;;
      *) die "unsupported merge argument at the atomic merge boundary: $arg" ;;
    esac
    case "$arg" in squash|merge|rebase) ;; *) die "merge method must be squash, merge, or rebase" ;; esac
    if [ "$METHOD_SEEN" -eq 1 ] && [ "$MERGE_METHOD" != "$arg" ]; then die "conflicting merge methods are not allowed"; fi
    MERGE_METHOD=$arg
    METHOD_SEEN=1
  done
}

execute_local() {
  local branch current candidate base before after
  [ "$MODE" = local-only ] || die "task $ID is mode=$MODE, not local-only"
  [ "$KIND" = ship ] || die "task $ID is kind=$KIND, not ship"
  require_repository_state
  branch="fm/$ID"
  git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || die "branch $branch does not exist in $PROJECT"
  current=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$branch" ] || die "task worktree is on '$current', expected '$branch'"
  candidate=$(git -C "$WORKTREE" rev-parse HEAD)
  [ "$(git -C "$PROJECT" rev-parse "refs/heads/$branch")" = "$candidate" ] || die "task worktree HEAD does not match its branch ref"
  DEFAULT=$(default_branch) || die "cannot determine default branch for $PROJECT"
  current=$(git -C "$PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$DEFAULT" ] || die "$PROJECT is on '$current', expected default branch '$DEFAULT'"
  base=$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")
  git -C "$PROJECT" merge-base --is-ancestor "$base" "$candidate" || die "$branch is not a fast-forward of $DEFAULT"
  "$SCRIPT_DIR/fm-test-inventory.sh" merge-check "$WORKTREE" "$candidate" "$base"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$candidate" ] || die "task worktree HEAD changed during merge verification"
  [ "$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")" = "$base" ] || die "local merge base changed during merge verification"
  before=${base:0:12}
  git -C "$PROJECT" merge --ff-only "$candidate" >/dev/null || die "local checkout changed before the exact candidate could land"
  after=$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")
  [ "$after" = "$candidate" ] || die "local merge did not land the verified candidate SHA"
  echo "merged $branch into local $DEFAULT ($before -> ${after:0:12}) in $PROJECT"
}

execute_github() {
  local query payload head base base_ref state draft merged strict admin_enforced recorded_pr recorded_head merge_output head_repo head_ref encoded_ref
  [ "$MODE" = no-mistakes ] || [ "$MODE" = direct-PR ] || die "task $ID is mode=$MODE, not a PR merge mode"
  [ "$KIND" = ship ] || die "task $ID is kind=$KIND, not ship"
  require_repository_state
  parse_merge_args "$@"
  recorded_pr=$(meta_value pr)
  recorded_head=$(meta_value pr_head)
  [ "$recorded_pr" = "$URL" ] || die "task PR metadata does not match the requested PR"
  query="{repository(owner:\"$PR_OWNER\",name:\"$PR_REPO\"){pullRequest(number:$PR_NUMBER){headRefOid baseRefOid baseRefName headRefName state isDraft merged headRepository{nameWithOwner} baseRef{branchProtectionRule{requiresStrictStatusChecks isAdminEnforced}}}}}"
  payload=$(gh-axi api POST /graphql --field "query=$query") || die "cannot read the exact GitHub merge candidate"
  head=$(api_value headRefOid "$payload"); base=$(api_value baseRefOid "$payload"); base_ref=$(api_value baseRefName "$payload")
  head_ref=$(api_value headRefName "$payload"); head_repo=$(api_value nameWithOwner "$payload"); state=$(api_value state "$payload")
  draft=$(api_value isDraft "$payload"); merged=$(api_value merged "$payload"); strict=$(api_value requiresStrictStatusChecks "$payload"); admin_enforced=$(api_value isAdminEnforced "$payload")
  [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$merged" = false ] || die "GitHub pull request is not an open, mergeable candidate"
  [ "$recorded_head" = "$head" ] || die "task PR head metadata does not match the current GitHub head"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD does not match the current GitHub PR head"
  git -C "$WORKTREE" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$WORKTREE" fetch --quiet "https://github.com/$PR_OWNER/$PR_REPO.git" "$base"
  git -C "$WORKTREE" merge-base --is-ancestor "$base" "$head" || die "GitHub PR head does not contain the current base; update the branch and retry"
  [ "$strict" = true ] && [ "$admin_enforced" = true ] || die "exact GitHub merge execution requires strict, admin-enforced base branch protection"
  "$SCRIPT_DIR/fm-test-inventory.sh" merge-check "$WORKTREE" "$head" "$base"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD changed during merge verification"
  merge_output=$(gh-axi api PUT "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" --field "sha=$head" --field "merge_method=$MERGE_METHOD") || die "GitHub rejected the exact conditional merge"
  [ "$(api_value merged "$merge_output")" = true ] || die "GitHub did not merge the verified candidate"
  if [ "$DELETE_BRANCH" -eq 1 ]; then
    [ "$head_repo" = "$PR_OWNER/$PR_REPO" ] || die "PR merged, but cross-repository head deletion is unsupported"
    encoded_ref=$(urlencode_ref "$head_ref")
    gh-axi api DELETE "/repos/$PR_OWNER/$PR_REPO/git/refs/heads/$encoded_ref" >/dev/null || die "PR merged, but deleting the head branch failed"
  fi
  echo "merged exact GitHub candidate $head into $base_ref at base $base"
}

ENTRY=${1:-}
ID=${2:-}
case "$ENTRY" in
  local) [ "$#" -eq 2 ] || { echo "usage: fm-merge-execute.sh local <task-id>" >&2; exit 2; }; fm_pr_task_id_valid "$ID" || die "invalid task ID" ;;
  github)
    [ "$#" -ge 3 ] || { echo "usage: fm-merge-execute.sh github <task-id> <pr-url> [-- <merge-args>]" >&2; exit 2; }
    RAW_URL=$3
    fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || die "invalid GitHub merge request"
    URL=$FM_PR_URL; PR_OWNER=$FM_PR_OWNER; PR_REPO=$FM_PR_REPO; PR_NUMBER=$FM_PR_NUMBER
    shift 3; [ "${1:-}" != -- ] || shift; GITHUB_ARGS=("$@")
    ;;
  *) echo "usage: fm-merge-execute.sh <local|github> ..." >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "task metadata is unavailable"
WORKTREE=$(meta_value worktree); PROJECT=$(meta_value project); KIND=$(meta_value kind); MODE=$(meta_value mode)
ensure_repository_lock
case "$ENTRY" in local) execute_local ;; github) execute_github "${GITHUB_ARGS[@]+"${GITHUB_ARGS[@]}"}" ;; esac
