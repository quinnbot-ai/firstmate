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

# gh-axi never forwards gh's raw stderr: it re-renders every failure as a TOON
# `error:`/`code:` pair drawn from its own fixed code set, so the code field is
# the only classification signal that survives its error mapping.
axi_code=$(printf '%s\n' "$result" | awk '/^code:[[:space:]]/ { sub(/^code:[[:space:]]*/, ""); print; exit }')
axi_message=$(printf '%s\n' "$result" | awk '/^error:[[:space:]]/ { sub(/^error:[[:space:]]*/, ""); print; exit }')
axi_message=${axi_message#\"}
axi_message=${axi_message%\"}

case "$axi_code" in
  VALIDATION_ERROR)
    # GitHub's HTTP 422 for the impossible base and head maps to
    # VALIDATION_ERROR, which proves the credentials were accepted for this
    # endpoint. gh-axi raises the same code for its own argument parsing before
    # any request leaves the machine, so an affirmative also requires GitHub's
    # validation wording and must not name gh-axi's own CLI surface.
    if printf '%s\n' "$axi_message" | grep -qi 'validation' &&
      ! printf '%s\n' "$axi_message" | grep -qi 'gh-axi'; then
      printf 'READY: GitHub credentials can create pull requests on %s/%s.\n' "$owner" "$repo"
      exit 0
    fi
    ;;
  FORBIDDEN)
    # The probe only ever posts to the create-pull-request endpoint, so every
    # authorization denial here - an admin-visible repository whose token is
    # refused for createPullRequest, or a token without repository write scope -
    # is a denial of pull-request creation specifically.
    printf 'BLOCKED: GitHub credentials lack "Pull requests: write" permission on %s/%s; GitHub denied the create-pull-request probe: %s.\n' \
      "$owner" "$repo" "${axi_message:-authorization denied}"
    exit 0
    ;;
esac

detail=$(printf '%s' "$result" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | cut -c1-240)
[ -n "$detail" ] || detail="gh-axi exited $status without diagnostic output"
warn "$detail"
