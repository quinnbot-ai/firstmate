#!/usr/bin/env bash
# fm-pr-verify-lib.sh - single owner of the "was this pull request tested at
# all" verdict that bin/fm-pr-merge.sh's merge gate depends on.
#
# THE HAZARD (quinnbot-ai/firstmate PR #148, 2026-08-20). A pull request whose
# head conflicts with its base has no refs/pull/<number>/merge, because GitHub
# cannot build the merge commit. GitHub Actions schedules `pull_request`
# workflows against exactly that merge ref, so a conflicted PR records ZERO
# workflow runs - not a failure, not a queued check, nothing. Reopening it and
# pushing new commits to it change nothing, because neither resolves the
# conflict. The PR then presents as "no CI checks configured", which reads as
# benign and is easily mistaken for green. It is not green: it was never tested.
# Waking the CI on the sibling PR #147, which was stuck the same way, exposed
# four genuine failures that a zero-checks-reads-as-fine merge would have landed
# on the default branch. docs/verification/pr-check-set-gate.md holds the dated
# evidence for both halves.
#
# THE RULE (captain-ruled 2026-08-20, carried in AGENTS.md section 7): an absent
# check set is UNVERIFIED, never green. It blocks a merge and is reported as
# unverified rather than passing quietly.
#
# WHAT THIS LIB DECIDES, AND WHAT IT DELIBERATELY DOES NOT. It answers only
# "does the head commit carry a check set at all". It does NOT adjudicate red
# versus green, because a red check set is a DIFFERENT state that is already
# visible to whoever is merging, and because a repository can legitimately carry
# a permanently failing advisory check - this one does: "PR must be raised via
# no-mistakes" fails by design on every direct-PR task. Refusing red here would
# block every such merge. AGENTS.md section 7's "never merge a red PR" rule
# keeps owning that judgement; this lib owns only the state nothing else could
# see.
#
# FAIL CLOSED ON AN UNREADABLE ANSWER. gh-axi renders a scalar sometimes bare
# and sometimes wrapped in an `api_response:`/`body:` envelope, and it reports
# API errors as `error:`/`code:` lines on STDOUT rather than stderr (verified
# 2026-08-20: a bad commit SHA prints `error: Validation error` to stdout with
# empty stderr and exit 2). So the error text can arrive on the same stream as a
# value, and this reads three independent signals rather than trusting any one:
# the exit status, the `error:`/`code:` shape, and - authoritatively - the shape
# of the value itself, a valid commit SHA or a bare decimal count. Anything else
# becomes `unreadable`, which the gate treats exactly like `unverified`. A check
# set that cannot be read has not been read green.
#
# The head SHA is re-read from the pull request itself rather than trusted from
# a caller, so a verdict always describes the commit that is actually about to
# merge.
#
# No side effects on source. set -u / set -e safe.

# Exit status bin/fm-pr-merge.sh uses for this refusal, distinct from its usage
# error (2) and its ordinary failure (1) so a caller or test can recognize
# "the CI verification gate fired" rather than a malformed request.
# shellcheck disable=SC2034 # Read by bin/fm-pr-merge.sh, which sources this lib.
FM_PR_VERIFY_REFUSE_EXIT=4

# fm_pr_head_valid is the repo's one owner of the commit-SHA shape check.
if ! declare -f fm_pr_head_valid >/dev/null 2>&1; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
fi

# fm_pr_verify_scalar: echo one scalar from gh-axi output, tolerating both the
# bare rendering and the `api_response:`/`body:` envelope, with surrounding
# quotes and whitespace removed. Echoes nothing when the output carries an
# `error:`/`code:` diagnostic instead of a value.
fm_pr_verify_scalar() {
  local raw=$1 line value=
  while IFS= read -r line; do
    case "$line" in
      api_response:*|*truncated:*) continue ;;
      error:*|code:*) return 1 ;;
    esac
    case "$line" in
      *body:*) value=${line#*body:} ;;
      *) value=$line ;;
    esac
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value#\"}
    value=${value%\"}
    [ -n "$value" ] && break
  done <<EOF
$raw
EOF
  printf '%s' "$value"
}

# fm_pr_verify_api: read one scalar field from the GitHub API through gh-axi.
# Returns 1 when the call fails or renders anything but a value.
fm_pr_verify_api() {  # <api-path> <jq-expression>
  local path=$1 expr=$2 out
  # stdout only: gh-axi puts its diagnostics there too, so folding stderr in
  # would add nothing and would let an unrelated warning corrupt a good value.
  out=$(gh-axi api "$path" --jq "$expr") || return 1
  fm_pr_verify_scalar "$out"
}

# fm_pr_verify_count: succeed only for a bare decimal count.
fm_pr_verify_count() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

# fm_pr_check_set_verdict: decide whether a pull request's current head carries
# any check set. Sets, and never leaves stale:
#   FM_PR_VERIFY_VERDICT  verified | unverified | unreadable
#   FM_PR_VERIFY_DETAIL   one plain-language line naming what was found and,
#                         for an absent set, the cause when it is knowable
#   FM_PR_VERIFY_HEAD     the head SHA the verdict describes, when it was read
# Returns 0 for `verified` and 1 otherwise, so a caller may branch on either the
# status or the verdict.
fm_pr_check_set_verdict() {  # <owner> <repo> <pr-number>
  local owner=$1 repo=$2 number=$3 head runs statuses mergeable
  # shellcheck disable=SC2034 # All three are read by this lib's callers.
  FM_PR_VERIFY_VERDICT=unreadable
  FM_PR_VERIFY_DETAIL='the check set could not be read'
  FM_PR_VERIFY_HEAD=

  head=$(fm_pr_verify_api "/repos/$owner/$repo/pulls/$number" '.head.sha') || head=
  if ! fm_pr_head_valid "$head"; then
    FM_PR_VERIFY_DETAIL='the head commit of the pull request could not be read'
    return 1
  fi
  # shellcheck disable=SC2034 # Read by this lib's callers.
  FM_PR_VERIFY_HEAD=$head

  runs=$(fm_pr_verify_api "/repos/$owner/$repo/commits/$head/check-runs" '.total_count') || runs=
  statuses=$(fm_pr_verify_api "/repos/$owner/$repo/commits/$head/status" '.total_count') || statuses=
  # Both counts are validated separately: an empty answer concatenated with a
  # valid one would otherwise read as a single valid decimal.
  if ! fm_pr_verify_count "$runs" || ! fm_pr_verify_count "$statuses"; then
    FM_PR_VERIFY_DETAIL="the check set on head $head could not be read"
    return 1
  fi

  if [ "$runs" -gt 0 ] || [ "$statuses" -gt 0 ]; then
    FM_PR_VERIFY_VERDICT=verified
    FM_PR_VERIFY_DETAIL="head $head reports $runs check run(s) and $statuses commit status(es)"
    return 0
  fi

  # shellcheck disable=SC2034 # Read by this lib's callers.
  FM_PR_VERIFY_VERDICT=unverified
  FM_PR_VERIFY_DETAIL="head $head reports no check runs and no commit statuses, so nothing has tested this pull request"
  # A conflicted pull request is the cause this gate was built for, and it is
  # the one an operator can act on immediately, so name it when it applies.
  mergeable=$(fm_pr_verify_api "/repos/$owner/$repo/pulls/$number" '.mergeable_state') || mergeable=
  if [ "$mergeable" = dirty ]; then
    FM_PR_VERIFY_DETAIL="$FM_PR_VERIFY_DETAIL; the branch conflicts with its base, so GitHub cannot build the merge commit that pull_request workflows run against and will never schedule them until the conflict is resolved"
  fi
  return 1
}
