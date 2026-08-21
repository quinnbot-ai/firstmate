#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# CI VERIFICATION GATE. Before merging, the PR's current head must carry a check
# set. A head with no check runs and no commit statuses has not passed - it has
# not been tested at all - so this refuses the merge with exit
# FM_PR_VERIFY_REFUSE_EXIT and names the cause. bin/fm-pr-verify-lib.sh owns that
# verdict, the reason the state exists, and why the gate deliberately does not
# adjudicate red versus green. The refusal happens after pr= is recorded and the
# merge poll is armed, so an unverified PR stays monitored rather than forgotten.
#
# --allow-unverified merges anyway, for the genuine case of a repository with no
# PR CI at all. It is an explicit decision that prints what it is overriding; it
# is never a default, and it never suppresses a failure to read the check set
# into silence.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-unverified]
#                       [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-verify-lib.sh
. "$SCRIPT_DIR/fm-pr-verify-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
ALLOW_UNVERIFIED=0
if [ "${1:-}" = "--allow-unverified" ]; then
  ALLOW_UNVERIFIED=1
  shift
fi
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# An absent check set is UNVERIFIED, never green (AGENTS.md section 7). Refuse
# here exactly as a red check would be refused, and say what is unverified.
if ! fm_pr_check_set_verdict "$PR_OWNER" "$PR_REPO" "$PR_NUMBER"; then
  if [ "$ALLOW_UNVERIFIED" = 1 ]; then
    echo "warning: merging $URL without CI verification: $FM_PR_VERIFY_DETAIL" >&2
  else
    echo "error: refusing to merge $URL - CI is unverified, not green: $FM_PR_VERIFY_DETAIL" >&2
    echo "hint: this pull request has not been tested; get its checks to run, or pass --allow-unverified to merge an untested pull request deliberately" >&2
    exit "$FM_PR_VERIFY_REFUSE_EXIT"
  fi
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
