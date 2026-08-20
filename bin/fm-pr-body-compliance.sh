#!/usr/bin/env bash
# fm-pr-body-compliance.sh - single owner of the "was this pull request raised
# through a declared delivery path" verdict that
# .github/workflows/no-mistakes-required.yml publishes as the
# `PR must be raised via no-mistakes` check.
#
# WHY THIS EXISTS AS A SCRIPT RATHER THAN INLINE WORKFLOW BASH. The verdict is
# a safety contract, so it needs a portable regression that drives it through a
# real interface. Inline `run:` bash can only be tested by reading the YAML,
# which asserts implementation bytes instead of behavior. Keeping the decision
# here also gives the marker strings exactly one owner.
#
# WHAT WENT WRONG BEFORE (quinnbot-ai/firstmate, 2026-08-20). The check used to
# accept exactly one thing: the signature the no-mistakes pipeline writes into a
# PR body. Firstmate's own `direct-PR` delivery mode legitimately ships without
# that pipeline, so every single direct-PR pull request failed this check
# permanently and by construction - PR #152 merged with the check red twice and
# every other check green. A check that is red on correct work teaches everyone
# reading it to dismiss red, which is the exact habit that lets a real failure
# through, and it is what forced bin/fm-pr-verify-lib.sh's merge gate to answer
# only "is a check set present" rather than "is it green".
#
# THE RULE NOW. There are two ways to comply, and a red result means neither
# happened:
#
#   1. The pipeline raised it. The body carries no-mistakes' deterministic
#      signature.
#   2. A maintainer declared the bypass. The body carries a
#      `no-mistakes-bypass: <mode> - <reason>` line AND GitHub itself reports
#      the author as having write access to the repository.
#
# WHY THE AUTHOR ASSOCIATION IS THE GATE ON PATH 2. Any body marker is
# hand-writable, so a marker alone would just move the gaming target. GitHub
# computes `author_association` from repository membership; a pull request
# author cannot assert it about themselves. So an outside contributor who
# copies the bypass line still fails, and the only people who can take path 2
# are the people who are actually entitled to choose the delivery mode. The
# declaration then makes the bypass a recorded, reviewable fact instead of a
# silent one, which is what the original check was reaching for.
#
# RESIDUAL LIMITATION, STATED HONESTLY. A maintainer could still hand-write
# path 1's pipeline signature and misrepresent an unvalidated PR as pipeline
# raised. Nothing a body-content check can read would catch that, and pinning
# this script to the base ref would not help either, because `pull_request`
# workflows run from the PR's own merge ref and can be edited by the PR. What
# changed is that nobody needs to: path 2 is a legitimate, honest way to be
# green, so faking path 1 is now a deliberate misrepresentation rather than the
# only route past a check that could never pass.
#
# Usage:
#   fm-pr-body-compliance.sh --body-file <path|-> --author-association <assoc>
#                            [--author <login>] [--pr <number>]
#
#   --body-file            PR body to inspect; `-` reads STDIN.
#   --author-association   GitHub's computed author_association for the PR.
#                          Must be passed, may be empty; anything outside the
#                          write-access set below is treated as no write
#                          access, so an unexpected or missing payload value
#                          refuses the bypass rather than granting it.
#   --author / --pr        Identifiers echoed into the failure report only.
#
# Exit status: 0 compliant, 1 non-compliant, 2 usage error.
# Compliant runs print one verdict line to STDOUT; the caller may publish it.
# Non-compliant runs print the actionable guidance to STDERR.
#
# No side effects. set -u / set -e safe.

set -eu

# The deterministic signature `no-mistakes` writes into a PR body it raised.
# Fixed string, compared literally; CONTRIBUTING.md quotes it for contributors.
FM_PIPELINE_MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

# Line prefix a maintainer uses to declare a pipeline bypass.
FM_BYPASS_PREFIX='no-mistakes-bypass:'

# Delivery modes that legitimately reach a pull request without the pipeline.
# `local-only` never opens one and `no-mistakes` is path 1, so `direct-PR` is
# the whole list. An unrecognized mode is refused rather than waved through.
FM_BYPASS_MODES='direct-PR'

# GitHub author_association values that mean write access to this repository.
# GitHub computes these; a pull request author cannot claim one.
FM_WRITE_ASSOCIATIONS='OWNER MEMBER COLLABORATOR'

usage() {
  cat >&2 <<'USAGE'
usage: fm-pr-body-compliance.sh --body-file <path|-> --author-association <assoc>
                                [--author <login>] [--pr <number>]
USAGE
  exit 2
}

BODY_FILE=
AUTHOR_ASSOCIATION=
HAVE_ASSOCIATION=0
AUTHOR=
PR_NUMBER=

while [ $# -gt 0 ]; do
  case "$1" in
    --body-file)
      [ $# -ge 2 ] || usage
      BODY_FILE=$2
      shift 2
      ;;
    --author-association)
      [ $# -ge 2 ] || usage
      AUTHOR_ASSOCIATION=$2
      HAVE_ASSOCIATION=1
      shift 2
      ;;
    --author)
      [ $# -ge 2 ] || usage
      AUTHOR=$2
      shift 2
      ;;
    --pr)
      [ $# -ge 2 ] || usage
      PR_NUMBER=$2
      shift 2
      ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# No side effects/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      ;;
  esac
done

[ -n "$BODY_FILE" ] || usage
# Required rather than defaulted: a caller that forgot to wire the association
# through would otherwise reach the bypass path with an empty value on every
# pull request, which is the one mistake that would make this check meaningless
# again.
[ "$HAVE_ASSOCIATION" -eq 1 ] || {
  echo "error: --author-association is required (may be empty, but must be passed)" >&2
  usage
}

if [ "$BODY_FILE" = - ]; then
  BODY=$(cat) || BODY=
else
  [ -f "$BODY_FILE" ] || { echo "error: body file not found: $BODY_FILE" >&2; exit 2; }
  BODY=$(cat -- "$BODY_FILE") || BODY=
fi

fm_has_write_access() {
  local want=$1 assoc
  for assoc in $FM_WRITE_ASSOCIATIONS; do
    [ "$want" = "$assoc" ] && return 0
  done
  return 1
}

fm_is_bypass_mode() {
  local want=$1 mode
  for mode in $FM_BYPASS_MODES; do
    [ "$want" = "$mode" ] && return 0
  done
  return 1
}

# Normalizes one field of a declaration line. `[[:space:]]` is load-bearing
# beyond cosmetics: GitHub delivers PR bodies with CRLF endings, so this is what
# keeps a trailing carriage return out of the delivery mode, out of the reason's
# non-empty test, and out of the verdict this check publishes. Narrowing the
# class to space and tab would let `<mode> - \r` read as a declared reason.
fm_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# --- path 1: raised through the pipeline -------------------------------------

if printf '%s' "$BODY" | grep -qF -- "$FM_PIPELINE_MARKER"; then
  echo "Compliant: raised through no-mistakes (pipeline signature found in the PR body)."
  exit 0
fi

# --- path 2: maintainer-declared bypass --------------------------------------

# Scan every declaration line rather than only the first, so one malformed
# attempt above a corrected one does not fail the pull request.
BYPASS_SEEN=0
BYPASS_MODE=
BYPASS_REASON=
BYPASS_VALID=0
BAD_MODE=
while IFS= read -r line; do
  trimmed=$(fm_trim "$line")
  case "$trimmed" in
    "$FM_BYPASS_PREFIX"*) ;;
    *) continue ;;
  esac
  BYPASS_SEEN=1
  rest=$(fm_trim "${trimmed#"$FM_BYPASS_PREFIX"}")
  case "$rest" in
    *" - "*)
      mode=$(fm_trim "${rest%%" - "*}")
      reason=$(fm_trim "${rest#*" - "}")
      ;;
    *)
      mode=$(fm_trim "$rest")
      reason=
      ;;
  esac
  if ! fm_is_bypass_mode "$mode"; then
    [ -n "$BAD_MODE" ] || BAD_MODE=$mode
    continue
  fi
  [ -n "$reason" ] || continue
  BYPASS_MODE=$mode
  BYPASS_REASON=$reason
  BYPASS_VALID=1
  break
done <<EOF
$BODY
EOF

if [ "$BYPASS_VALID" -eq 1 ]; then
  if fm_has_write_access "$AUTHOR_ASSOCIATION"; then
    echo "Compliant: declared pipeline bypass, mode ${BYPASS_MODE}, by an author GitHub reports as ${AUTHOR_ASSOCIATION} of this repository."
    echo "Declared reason: ${BYPASS_REASON}"
    exit 0
  fi
  {
    echo "::error::A declared no-mistakes bypass is available only to maintainers of this repository."
    echo
    echo "This PR body declares '$FM_BYPASS_PREFIX $BYPASS_MODE', but GitHub reports the"
    echo "author's association with this repository as '${AUTHOR_ASSOCIATION:-<none>}', which does not carry"
    echo "write access. The declaration is not something a contributor can grant themselves."
    echo
    echo "Raise this PR through the pipeline instead:"
    echo
    echo "    git push no-mistakes"
    echo
    echo "See CONTRIBUTING.md for setup and the full workflow."
    echo
    [ -n "$AUTHOR" ] && echo "PR author: ${AUTHOR}"
    [ -n "$PR_NUMBER" ] && echo "PR number: ${PR_NUMBER}"
  } >&2
  exit 1
fi

# --- neither path satisfied ---------------------------------------------------

{
  echo "::error::This PR was neither raised through no-mistakes nor declared as a maintainer bypass."
  echo
  echo "Contributions to this repository must be submitted via 'git push no-mistakes'."
  echo "That pipeline runs the required review/test/lint/CI steps and writes a"
  echo "deterministic '## Pipeline' section into the PR body containing:"
  echo
  echo "    $FM_PIPELINE_MARKER"
  echo
  echo "See CONTRIBUTING.md for setup and the full workflow."
  if [ "$BYPASS_SEEN" -eq 1 ]; then
    echo
    if [ -n "$BAD_MODE" ]; then
      echo "This body carries a bypass declaration naming an unrecognized delivery mode"
      echo "'${BAD_MODE}'. Recognized modes: ${FM_BYPASS_MODES}."
    else
      echo "This body carries a bypass declaration with no reason after the ' - ' separator."
    fi
    echo "The declaration must read exactly:"
  else
    echo
    echo "MAINTAINERS ONLY: a delivery that legitimately bypasses the pipeline is"
    echo "declared in the PR body rather than left to fail this check. Add one line:"
  fi
  echo
  echo "    $FM_BYPASS_PREFIX direct-PR - <why this delivery bypassed the pipeline>"
  echo
  [ -n "$AUTHOR" ] && echo "PR author: ${AUTHOR}"
  [ -n "$PR_NUMBER" ] && echo "PR number: ${PR_NUMBER}"
} >&2
exit 1
