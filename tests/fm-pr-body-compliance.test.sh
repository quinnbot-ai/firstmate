#!/usr/bin/env bash
# Behavioral regressions for the PR delivery-path compliance verdict owned by
# bin/fm-pr-body-compliance.sh and published by
# .github/workflows/no-mistakes-required.yml as `PR must be raised via no-mistakes`.
#
# Regression origin (quinnbot-ai/firstmate, 2026-08-20): the check accepted only
# the no-mistakes pipeline signature, so every `direct-PR` delivery failed it
# permanently and by construction. PR #152 merged with this check red twice and
# every other check green, and the merge gate in bin/fm-pr-verify-lib.sh had to
# refuse to adjudicate red at all because of it. A check that is red on correct
# work trains everyone to dismiss red.
#
# The properties pinned here are what make the check meaningful when red:
#   - correct work has a green path (pipeline, or a declared maintainer bypass);
#   - a bypass is never silent, so a maintainer alone is not enough;
#   - a bypass declaration is not self-grantable by a contributor;
#   - a miswired caller fails closed rather than granting the bypass to everyone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-body-compliance.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-compliance)

PIPELINE_SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
DECLARATION='no-mistakes-bypass: direct-PR - internal-only tooling change, shipped without the pipeline'

OUT=
ERR=
CODE=

# run_check <body> [extra args...] -> sets OUT (stdout), ERR (stderr), CODE.
run_check() {
  local body=$1
  shift
  printf '%s' "$body" > "$TMP_ROOT/body.txt"
  OUT=$("$CHECK" --body-file "$TMP_ROOT/body.txt" "$@" 2>"$TMP_ROOT/err.txt")
  CODE=$?
  ERR=$(cat "$TMP_ROOT/err.txt")
}

test_pipeline_signature_is_compliant() {
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR CONTRIBUTOR FIRST_TIME_CONTRIBUTOR NONE; do
    run_check "## Pipeline"$'\n\n'"$PIPELINE_SIGNATURE"$'\n' --author-association "$assoc"
    expect_code 0 "$CODE" "pipeline-raised PR rejected for author association $assoc"
    assert_contains "$OUT" 'raised through no-mistakes' \
      "pipeline-raised PR did not report the pipeline path for $assoc"
  done
  pass "a PR carrying the pipeline signature is compliant for every author association"
}

test_undeclared_bypass_still_fails_for_a_maintainer() {
  # The fix must NOT be "exempt maintainers". A delivery that skips the pipeline
  # has to say so, or the bypass goes unnoticed - the thing the check exists to
  # prevent.
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    run_check '## Summary'$'\n\n''Ordinary direct-PR body with nothing declared.'$'\n' \
      --author-association "$assoc" --author quinnbot-ai --pr 152
    expect_code 1 "$CODE" "an undeclared pipeline bypass passed for author association $assoc"
  done
  # Red has to be actionable: the failure names the exact line to add and says
  # who may add it, so the author can fix it instead of learning to ignore it.
  assert_contains "$ERR" 'no-mistakes-bypass: direct-PR - ' \
    "failure report omitted the declaration line the author must add"
  assert_contains "$ERR" 'MAINTAINERS ONLY' \
    "failure report did not say who may declare a bypass"
  pass "a maintainer skipping the pipeline without declaring it still fails"
}

test_declared_bypass_is_compliant_for_write_access() {
  local assoc
  for assoc in OWNER MEMBER COLLABORATOR; do
    run_check '## Summary'$'\n\n'"$DECLARATION"$'\n' --author-association "$assoc"
    expect_code 0 "$CODE" "declared bypass rejected for write-access association $assoc"
    assert_contains "$OUT" 'declared pipeline bypass, mode direct-PR' \
      "compliant bypass did not record the declared delivery mode for $assoc"
  done
  # The recorded reason is the whole point of declaring: it turns a bypass into
  # a reviewable fact on the run instead of a silent one.
  assert_contains "$OUT" 'internal-only tooling change, shipped without the pipeline' \
    "compliant bypass did not record the declared reason"
  pass "a declared direct-PR bypass by a write-access author is compliant and recorded"
}

test_declared_bypass_is_not_self_grantable() {
  # A body marker anyone can type would only move the gaming target. The gate is
  # GitHub's own computed author_association, which a PR author cannot assert
  # about themselves.
  local assoc
  for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE '' UNKNOWN_FUTURE_VALUE; do
    run_check '## Summary'$'\n\n'"$DECLARATION"$'\n' --author-association "$assoc" --author mallory
    expect_code 1 "$CODE" "a bypass declaration granted itself write access as '$assoc'"
    assert_contains "$ERR" 'available only to maintainers' \
      "refusal for '$assoc' did not explain that the declaration is maintainer-only"
    assert_contains "$ERR" 'git push no-mistakes' \
      "refusal for '$assoc' did not point at the pipeline as the way through"
  done
  pass "a bypass declaration cannot grant its own author write access"
}

test_missing_association_fails_closed() {
  # A caller that forgot to wire author_association through would otherwise
  # reach the bypass path with an empty value on every PR, quietly making the
  # check meaningless again. That is a usage error, not a pass.
  printf '%s' "$DECLARATION" > "$TMP_ROOT/body.txt"
  "$CHECK" --body-file "$TMP_ROOT/body.txt" >/dev/null 2>&1
  expect_code 2 "$?" "omitting --author-association was not a usage error"
  # An explicitly empty association is a real payload value, and must refuse.
  run_check "$DECLARATION" --author-association ''
  expect_code 1 "$CODE" "an empty author association granted the bypass"
  pass "a miswired or empty author association refuses the bypass"
}

test_github_crlf_bodies_are_handled() {
  # GitHub delivers PR bodies with CRLF line endings; a trailing carriage return
  # would otherwise make the declared mode read as 'direct-PR<CR>' and fail.
  run_check $'## Summary\r\n\r\n'"$DECLARATION"$'\r\nmore text\r\n' --author-association OWNER
  expect_code 0 "$CODE" "a CRLF PR body broke the declared bypass"
  assert_contains "$OUT" 'mode direct-PR' "CRLF body produced a malformed delivery mode"
  # The carriage return must not survive into the published verdict, which is
  # what the workflow writes into the run summary as the bypass record.
  case "$OUT" in
    *$'\r'*) fail "the published verdict carried a stray carriage return" ;;
  esac

  # The case where the carriage return actually decides the verdict: a CRLF
  # declaration with no reason must still be refused, not read as reason='\r'.
  run_check $'no-mistakes-bypass: direct-PR - \r\n' --author-association OWNER
  expect_code 1 "$CODE" "a CRLF-only bypass reason was accepted as a declared reason"
  pass "a CRLF PR body is read the same as an LF one"
}

test_malformed_declarations_are_refused_with_the_reason() {
  run_check 'no-mistakes-bypass: yolo - because I said so'$'\n' --author-association OWNER
  expect_code 1 "$CODE" "an unrecognized delivery mode was accepted as a bypass"
  assert_contains "$ERR" "'yolo'" "refusal did not name the unrecognized delivery mode"

  run_check 'no-mistakes-bypass: direct-PR'$'\n' --author-association OWNER
  expect_code 1 "$CODE" "a bypass declaration with no reason was accepted"
  assert_contains "$ERR" 'no reason' "refusal did not explain the missing reason"

  run_check 'no-mistakes-bypass: direct-PR -   '$'\n' --author-association OWNER
  expect_code 1 "$CODE" "a whitespace-only bypass reason was accepted"

  # A corrected declaration below a malformed attempt is what an author actually
  # produces when fixing the body; it must be accepted.
  run_check 'no-mistakes-bypass: yolo - bad first attempt'$'\n'"$DECLARATION"$'\n' \
    --author-association OWNER
  expect_code 0 "$CODE" "a corrected declaration below a malformed one was not accepted"
  pass "malformed declarations are refused and a corrected one is accepted"
}

test_empty_body_fails() {
  run_check '' --author-association OWNER
  expect_code 1 "$CODE" "an empty PR body was treated as compliant"
  pass "an empty PR body is not compliant"
}

test_pipeline_signature_is_compliant
test_undeclared_bypass_still_fails_for_a_maintainer
test_declared_bypass_is_compliant_for_write_access
test_declared_bypass_is_not_self_grantable
test_missing_association_fails_closed
test_github_crlf_bodies_are_handled
test_malformed_declarations_are_refused_with_the_reason
test_empty_body_fails
