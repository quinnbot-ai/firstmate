#!/usr/bin/env bash
# Check whether the credentials visible in the current worktree can create a
# pull request on origin without creating one.
#
# The probe submits an intentionally impossible pull request to GitHub's REST
# create-pull-request endpoint. A validation response means GitHub accepted the
# credentials far enough to evaluate the request, while an authorization denial
# means the token lacks the required "Pull requests: write" capability. Any
# unrelated probe failure is a warning, so this helper never becomes a delivery
# gate by itself.
#
# Usage: fm-pr-capability.sh
# Output: READY: capability confirmed
#         BLOCKED: known missing pull-request creation permission
#         WARNING: probe could not determine capability; continue the task
set -u

warn() {
  printf 'WARNING: could not verify GitHub pull-request creation capability: %s; continue the task and retry delivery later.\n' "$1"
}

if ! command -v gh-axi >/dev/null 2>&1; then
  warn "gh-axi is unavailable"
  exit 0
fi

if ! remote=$(git remote get-url origin 2>/dev/null); then
  warn "origin remote is unavailable"
  exit 0
fi

host=
path=
case "$remote" in
  http://*|https://*)
    rest=${remote#*://}
    host=${rest%%/*}
    path=${rest#*/}
    ;;
  ssh://*)
    rest=${remote#ssh://}
    rest=${rest#*@}
    host=${rest%%/*}
    path=${rest#*/}
    ;;
  *@*:* )
    host=${remote%%:*}
    host=${host#*@}
    path=${remote#*:}
    ;;
  *)
    warn "origin URL is not a supported GitHub remote: $remote"
    exit 0
    ;;
esac

path=${path%.git}
case "$path" in
  */*)
    owner=${path%%/*}
    repo=${path#*/}
    ;;
  *)
    warn "origin URL does not name an owner and repository: $remote"
    exit 0
    ;;
esac

case "$repo" in
  */*|"")
    warn "origin URL does not name exactly one repository: $remote"
    exit 0
    ;;
esac

# Both names are unique and deliberately absent, so GitHub cannot create a PR.
probe_base="__fm_pr_capability_probe_base_$$"
probe_head="__fm_pr_capability_probe_head_$$"
probe_title="Firstmate PR capability probe - intentionally invalid"
result=
status=0
if result=$(GH_HOST="$host" gh-axi api POST "/repos/$owner/$repo/pulls" \
  --field "title=$probe_title" \
  --field "head=$probe_head" \
  --field "base=$probe_base" 2>&1); then
  status=0
else
  status=$?
fi

# gh-axi labels the deliberately invalid request VALIDATION_ERROR only after
# GitHub has accepted the caller for this endpoint. It is the safe affirmative
# signal because the random base and head cannot result in a real pull request.
if printf '%s\n' "$result" | grep -qi 'VALIDATION_ERROR'; then
  printf 'READY: GitHub credentials can create pull requests on %s/%s.\n' "$owner" "$repo"
  exit 0
fi

# This is the real failure shape observed with an admin-visible repository and
# a token that GraphQL still refuses for createPullRequest.
if printf '%s\n' "$result" | grep -qiE 'resource not accessible|authorization[_ -]?error|pull requests?: write'; then
  printf 'BLOCKED: GitHub credentials lack "Pull requests: write" permission on %s/%s; GitHub denied the create-pull-request probe.\n' "$owner" "$repo"
  exit 0
fi

detail=$(printf '%s' "$result" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | cut -c1-240)
[ -n "$detail" ] || detail="gh-axi exited $status without diagnostic output"
warn "$detail"
