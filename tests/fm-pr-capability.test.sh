#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-capability.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-capability)

make_worktree() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/acme/widget.git
}

write_fake_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "${FM_PR_CAPABILITY_ARGS:?}"
case "${FM_PR_CAPABILITY_RESULT:-}" in
  validation)
    printf '%s\n' 'error: Validation error' 'code: VALIDATION_ERROR'
    exit 1
    ;;
  denied)
    printf '%s\n' 'error: Resource not accessible by personal access token' 'code: AUTHORIZATION_ERROR'
    exit 1
    ;;
  unavailable)
    printf '%s\n' 'error: temporary network failure' 'code: NETWORK_ERROR'
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
}

test_validation_response_confirms_create_capability() {
  local dir fakebin args out rc
  dir="$TMP_ROOT/validation"
  make_worktree "$dir"
  fakebin=$(fm_fakebin "$dir")
  write_fake_gh_axi "$fakebin"
  args="$dir/args"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_PR_CAPABILITY_ARGS="$args" FM_PR_CAPABILITY_RESULT=validation \
    "$ROOT/bin/fm-pr-capability.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "validation response should not fail the probe"
  assert_contains "$out" 'READY: GitHub credentials can create pull requests on acme/widget.' \
    "validation response did not confirm PR creation capability"
  assert_grep 'POST /repos/acme/widget/pulls' "$args" \
    "probe did not target GitHub's create-pull-request endpoint"
  assert_grep 'head=__fm_pr_capability_probe_head_' "$args" \
    "probe did not use an intentionally absent head branch"
  assert_grep 'base=__fm_pr_capability_probe_base_' "$args" \
    "probe did not use an intentionally absent base branch"
  pass "fm-pr-capability: validation response confirms safe create capability"
}

test_admin_visible_but_create_denied_is_an_early_blocker() {
  local dir fakebin args out rc
  dir="$TMP_ROOT/denied"
  make_worktree "$dir"
  fakebin=$(fm_fakebin "$dir")
  write_fake_gh_axi "$fakebin"
  args="$dir/args"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_PR_CAPABILITY_ARGS="$args" FM_PR_CAPABILITY_RESULT=denied \
    "$ROOT/bin/fm-pr-capability.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "known permission denial should report, not crash"
  assert_contains "$out" 'BLOCKED: GitHub credentials lack "Pull requests: write" permission on acme/widget' \
    "admin-visible but create-denied token was not surfaced as the required blocker"
  assert_no_grep 'READY:' <(printf '%s\n' "$out") \
    "permission denial must not be mistaken for an auth-only success"
  pass "fm-pr-capability: create denial overrides repository-admin appearance"
}

test_unrelated_probe_failure_is_warning_only() {
  local dir fakebin args out rc
  dir="$TMP_ROOT/unavailable"
  make_worktree "$dir"
  fakebin=$(fm_fakebin "$dir")
  write_fake_gh_axi "$fakebin"
  args="$dir/args"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_PR_CAPABILITY_ARGS="$args" FM_PR_CAPABILITY_RESULT=unavailable \
    "$ROOT/bin/fm-pr-capability.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "unrelated probe failure must remain warning-only"
  assert_contains "$out" 'WARNING: could not verify GitHub pull-request creation capability' \
    "unrelated probe failure was not labeled as a warning"
  assert_contains "$out" 'continue the task and retry delivery later.' \
    "warning did not preserve task progress"
  assert_no_grep 'BLOCKED:' <(printf '%s\n' "$out") \
    "unrelated probe failure incorrectly stranded the task"
  pass "fm-pr-capability: unrelated failures do not create a new delivery gate"
}

test_validation_response_confirms_create_capability
test_admin_visible_but_create_denied_is_an_early_blocker
test_unrelated_probe_failure_is_warning_only
