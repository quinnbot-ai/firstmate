#!/usr/bin/env bash
# Preserve no-mistakes' `gh pr checks` contract when GitHub forbids the
# check-runs read but still permits workflow-runs reads.
#
# Usage: fm-gh-ci-fallback.sh <real-gh> pr checks <pr-number-or-url> --repo <owner/repo> --json <fields>
#
# Token routing is deliberately least-privilege. The original check-runs call,
# the pull-request head lookup, and the exact-head workflow-runs lookup all use
# the caller's ambient GH_TOKEN/GITHUB_TOKEN unchanged. This script never calls
# fm-gh.sh, never injects config/gh-credential's broader PR-capable credential,
# and never prints a token. It falls back only after the original command reports
# a 403-style authorization failure; every other result is replayed unchanged.
#
# The fallback is intentionally limited to the two JSON field sets used by the
# supported no-mistakes CI monitor. Other `gh pr checks` invocations keep the real
# gh result, so installing the PATH-wide shim does not silently change an
# interactive command's output format.
#
# A fallback verdict is tied to the PR's exact current head SHA. The PR number
# and owner/repository are strictly validated, the head is read from
# repos/<owner>/<repo>/pulls/<number>, and Actions is queried through
# repos/<owner>/<repo>/actions/runs?head_sha=<exact-sha>. No branch name or local
# HEAD can certify green. All exact-head workflow runs are paginated, then mapped
# into the JSON check shape no-mistakes already consumes. An empty run list stays
# empty and therefore pending; it is never synthesized into green.
# This evidence covers GitHub Actions only; it cannot reconstruct third-party
# check providers hidden behind the forbidden check-runs API.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

[ "$#" -ge 4 ] || {
  echo "fm-gh-ci-fallback: invalid invocation" >&2
  exit 2
}
REAL_GH=$1
shift

ORIGINAL_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-out.XXXXXX")
ORIGINAL_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-err.XXXXXX")
FALLBACK_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-fallback-out.XXXXXX")
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  rm -f -- "$ORIGINAL_OUT" "$ORIGINAL_ERR" "$FALLBACK_OUT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ORIGINAL_STATUS=0
"$REAL_GH" "$@" > "$ORIGINAL_OUT" 2> "$ORIGINAL_ERR" || ORIGINAL_STATUS=$?
if [ "$ORIGINAL_STATUS" -eq 0 ]; then
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit 0
fi

replay_original() {
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit "$ORIGINAL_STATUS"
}

# The command itself is already constrained to `pr checks` by fm-gh-shim.sh.
# Requiring the permission marker here keeps a changed gh failure from being
# reinterpreted as CI state.
if ! grep -Eiq '(^|[^0-9])403([^0-9]|$)|Resource not accessible by personal access token' \
  "$ORIGINAL_OUT" "$ORIGINAL_ERR"; then
  replay_original
fi

[ "${1:-}" = pr ] && [ "${2:-}" = checks ] || replay_original
SELECTOR=${3:-}
shift 3

REPO=
JSON_FIELDS=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R)
      [ "$#" -ge 2 ] || replay_original
      REPO=$2
      shift 2
      ;;
    --repo=*|-R=*)
      REPO=${1#*=}
      shift
      ;;
    --json)
      [ "$#" -ge 2 ] || replay_original
      JSON_FIELDS=$2
      shift 2
      ;;
    --json=*)
      JSON_FIELDS=${1#*=}
      shift
      ;;
    *)
      replay_original
      ;;
  esac
done

case "$JSON_FIELDS" in
  name,state,bucket,completedAt|name,state,bucket,completedAt,link) ;;
  *) replay_original ;;
esac

case "$SELECTOR" in
  https://github.com/*)
    fm_pr_url_parse "$SELECTOR" || replay_original
    [ "$FM_PR_PROVIDER" = github ] || replay_original
    [ -z "$REPO" ] || [ "$REPO" = "$FM_PR_PATH" ] || replay_original
    REPO=$FM_PR_PATH
    NUMBER=$FM_PR_NUMBER
    ;;
  *)
    case "$SELECTOR" in
      ''|0|*[!0-9]*) replay_original ;;
    esac
    fm_pr_url_parse "https://github.com/$REPO/pull/$SELECTOR" || replay_original
    [ "$FM_PR_PROVIDER" = github ] || replay_original
    REPO=$FM_PR_PATH
    NUMBER=$FM_PR_NUMBER
    ;;
esac

PR_HEAD=
if ! PR_HEAD=$("$REAL_GH" api -X GET "repos/$REPO/pulls/$NUMBER" --jq .head.sha 2>/dev/null); then
  echo "fm-gh-ci-fallback: exact PR head lookup failed; preserving the original gh pr checks failure" >&2
  replay_original
fi
PR_HEAD=${PR_HEAD//$'\r'/}
PR_HEAD=${PR_HEAD//$'\n'/}
fm_pr_head_valid "$PR_HEAD" || {
  echo "fm-gh-ci-fallback: exact PR head lookup returned an invalid SHA; preserving the original gh pr checks failure" >&2
  replay_original
}

# gh's built-in jq evaluator applies this after --paginate --slurp has wrapped
# every Actions response page in one outer array. Producing one object per
# workflow run lets the existing no-mistakes classifier reach green, red,
# cancelled, skipped, and pending verdicts without any upstream patch.
# shellcheck disable=SC2016 # This is a literal jq program; its $ names belong to jq.
RUNS_JQ='[
  .[].workflow_runs[]
  | .status as $status
  | .conclusion as $conclusion
  | {
      name: (.name // "GitHub Actions workflow"),
      state: (if $status != "completed" then ($status // "pending") else ($conclusion // "pending") end),
      bucket: (
        if $status != "completed" or $conclusion == null then "pending"
        elif $conclusion == "success" then "pass"
        elif $conclusion == "cancelled" then "cancel"
        elif ($conclusion == "skipped" or $conclusion == "neutral" or $conclusion == "stale") then "skipping"
        elif ($conclusion == "failure" or $conclusion == "timed_out" or $conclusion == "action_required" or $conclusion == "startup_failure") then "fail"
        else "pending"
        end
      ),
      completedAt: (if $status == "completed" then (.updated_at // "") else "" end),
      link: (.html_url // "")
    }
]'

RUNS_ENDPOINT="repos/$REPO/actions/runs?head_sha=$PR_HEAD&per_page=100"
if "$REAL_GH" api -X GET "$RUNS_ENDPOINT" --paginate --slurp --jq "$RUNS_JQ" \
  > "$FALLBACK_OUT" 2>/dev/null; then
  cat "$FALLBACK_OUT"
  exit 0
fi

echo "fm-gh-ci-fallback: exact-head workflow-runs lookup failed; preserving the original gh pr checks failure" >&2
replay_original
