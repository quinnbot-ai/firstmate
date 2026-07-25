#!/usr/bin/env bash
# Behavior tests for profile-local Claude account attestation and the
# ambient-auth-scrubbed verified exec boundary.
# Every account and credential is synthetic, and no test touches Keychain.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-claude-auth.py"
TMP_ROOT=$(fm_test_tmproot fm-claude-auth-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-} ${2:-}" = "auth login" ]; then
  {
    printf 'config=%s\n' "${CLAUDE_CONFIG_DIR:-}"
    printf 'identity=%s\n' "${ANTHROPIC_IDENTITY_TOKEN:-}"
    printf 'session=%s\n' "${CLAUDE_CODE_SESSION_ACCESS_TOKEN:-}"
    printf 'host_creds=%s\n' "${CLAUDE_CODE_HOST_CREDS_FILE:-}"
    printf 'ccr_token=%s\n' "${CCR_OAUTH_TOKEN_FILE:-}"
    printf 'profile=%s\n' "${ANTHROPIC_PROFILE:-}"
    printf 'provider=%s\n' "${CLAUDE_CODE_USE_BEDROCK:-}"
    printf 'gateway=%s\n' "${CLAUDE_CODE_USE_GATEWAY:-}"
    printf 'program=%s\n' "$0"
    printf 'cwd=%s\n' "$PWD"
  } > "${FM_FAKE_LOGIN_RESULT:?}"
  exit 0
fi
if [ "${1:-} ${2:-} ${3:-}" != "auth status --json" ]; then
  exit 2
fi
if [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_IDENTITY_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}${CLAUDE_CODE_SESSION_ACCESS_TOKEN:-}${CLAUDE_CODE_HOST_CREDS_FILE:-}${CCR_OAUTH_TOKEN_FILE:-}${ANTHROPIC_PROFILE:-}${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_GATEWAY:-}" ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"ambient@example.invalid","orgId":"org-ambient"}'
  exit 0
fi
case "$(cat "${CLAUDE_CONFIG_DIR:-}/.fake-account" 2>/dev/null)" in
  intended)
    printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"crew@example.invalid","orgId":"org-test"}'
    ;;
  wrong)
    printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"other@example.invalid","orgId":"org-other"}'
    ;;
  incomplete)
    printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"crew@example.invalid"}'
    ;;
  *)
    printf '%s\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
    exit 1
    ;;
esac
SH

cat > "$FAKEBIN/worker" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'config=%s\n' "${CLAUDE_CONFIG_DIR:-}"
  printf 'api_key=%s\n' "${ANTHROPIC_API_KEY:-}"
  printf 'auth_token=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
  printf 'oauth_token=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  printf 'identity=%s\n' "${ANTHROPIC_IDENTITY_TOKEN:-}"
  printf 'session=%s\n' "${CLAUDE_CODE_SESSION_ACCESS_TOKEN:-}"
  printf 'host_creds=%s\n' "${CLAUDE_CODE_HOST_CREDS_FILE:-}"
  printf 'ccr_token=%s\n' "${CCR_OAUTH_TOKEN_FILE:-}"
  printf 'profile=%s\n' "${ANTHROPIC_PROFILE:-}"
  printf 'provider=%s\n' "${CLAUDE_CODE_USE_BEDROCK:-}"
  printf 'gateway=%s\n' "${CLAUDE_CODE_USE_GATEWAY:-}"
  printf 'program=%s\n' "$0"
  printf 'cwd=%s\n' "$PWD"
} > "${FM_FAKE_WORKER_RESULT:?}"
SH
# The helper execs the path it resolved from PATH, and that resolution
# collapses the duplicate slash TMPDIR leaves in TMP_ROOT.
FAKEBIN_EXEC=$(printf '%s' "$FAKEBIN" | sed 's://*:/:g')
NOISYBIN="$TMP_ROOT/noisybin"
LIARBIN="$TMP_ROOT/liarbin"
mkdir -p "$NOISYBIN" "$LIARBIN"

cat > "$NOISYBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-} ${2:-} ${3:-}" = "auth status --json" ]; then
  head -c 200000 /dev/zero | tr '\0' x
  exit 0
fi
exit 2
SH

cat > "$LIARBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"crew@example.invalid","orgId":"org-test"}'
exit 0
SH
chmod 700 "$FAKEBIN/claude" "$FAKEBIN/worker" "$NOISYBIN/claude" "$LIARBIN/claude"

attest() {
  PATH="$FAKEBIN:$PATH" python3 "$HELPER" \
    --attest --profile "$1" --worktree "$2"
}

verify() {
  PATH="$FAKEBIN:$PATH" python3 "$HELPER" \
    --verify --profile "$1" --home "$2" --worktree "$3"
}

test_login_pins_profile_and_scrubs_ambient_auth() {
  local case_dir profile result real_profile real_case out status
  case_dir="$TMP_ROOT/login"
  profile="$case_dir/profile"
  result="$case_dir/login.env"
  mkdir -p "$profile"
  real_profile=$(cd "$profile" && pwd -P)
  real_case=$(cd "$case_dir" && pwd -P)

  out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_LOGIN_RESULT="$result" \
    ANTHROPIC_IDENTITY_TOKEN=ambient-identity \
    CLAUDE_CODE_SESSION_ACCESS_TOKEN=ambient-session \
    CLAUDE_CODE_HOST_CREDS_FILE=/tmp/ambient-host-creds \
    CCR_OAUTH_TOKEN_FILE=/tmp/ambient-ccr-token \
    ANTHROPIC_PROFILE=personal CLAUDE_CODE_USE_BEDROCK=1 \
    CLAUDE_CODE_USE_GATEWAY=1 \
    python3 "$HELPER" --login --profile "$profile" --worktree "$case_dir" 2>&1)
  status=$?
  expect_code 0 "$status" "profile login helper should start the synthetic login"
  [ -z "$out" ] || fail "profile login helper relayed unexpected output"
  assert_grep "config=$real_profile" "$result" "login did not pin the managed profile"
  grep -Fx 'identity=' "$result" >/dev/null || fail "login inherited an identity token"
  grep -Fx 'session=' "$result" >/dev/null || fail "login inherited a session token"
  grep -Fx 'host_creds=' "$result" >/dev/null || fail "login inherited a host credential file"
  grep -Fx 'ccr_token=' "$result" >/dev/null || fail "login inherited a CCR token file"
  grep -Fx 'profile=' "$result" >/dev/null || fail "login inherited an alternate profile"
  grep -Fx 'provider=' "$result" >/dev/null || fail "login inherited an alternate provider"
  grep -Fx 'gateway=' "$result" >/dev/null || fail "login inherited gateway mode"
  assert_grep "program=$FAKEBIN_EXEC/claude" "$result" \
    "login did not exec the exact Claude program resolved from PATH"
  assert_grep "cwd=$real_case" "$result" "login did not pin the Firstmate worktree"
  pass "profile login pins the managed path and scrubs ambient authentication"
}

test_intended_account_attests_and_verifies_without_identity_output() {
  local case_dir profile home out status manifest
  case_dir="$TMP_ROOT/intended"
  profile="$case_dir/profile"
  home="$case_dir/home"
  mkdir -p "$profile" "$home"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' intended > "$home/.fake-account"

  out=$(attest "$profile" "$case_dir" 2>&1)
  status=$?
  expect_code 0 "$status" "intended account attestation should succeed"
  assert_not_contains "$out" "@example.invalid" "attestation printed private account identity"
  assert_not_contains "$out" "org-test" "attestation printed private organization identity"
  manifest="$profile/.firstmate-account.json"
  assert_present "$manifest" "attestation did not create the profile-local manifest"
  assert_not_contains "$(cat "$manifest")" "@example.invalid" "manifest stored raw account identity"
  assert_not_contains "$(cat "$manifest")" "org-test" "manifest stored raw organization identity"

  printf '%s\n' wrong > "$profile/.fake-account"
  out=$(attest "$profile" "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "attestation must not silently switch accounts"
  assert_contains "$out" "refusing to replace its attestation" \
    "account-switch refusal was not actionable"
  printf '%s\n' intended > "$profile/.fake-account"

  out=$(ANTHROPIC_API_KEY=ambient-key ANTHROPIC_AUTH_TOKEN=ambient-token \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-oauth ANTHROPIC_PROFILE=personal \
    CLAUDE_CODE_USE_BEDROCK=1 verify "$profile" "$home" "$case_dir" 2>&1)
  status=$?
  expect_code 0 "$status" "verified home should ignore ambient personal auth"
  [ -z "$out" ] || fail "successful verification should print nothing"
  pass "intended account attestation is private and ambient auth cannot override it"
}

test_missing_auth_and_wrong_account_are_rejected() {
  local case_dir profile missing wrong out status
  case_dir="$TMP_ROOT/rejections"
  profile="$case_dir/profile"
  missing="$case_dir/missing"
  wrong="$case_dir/wrong"
  mkdir -p "$profile" "$missing" "$wrong"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' wrong > "$wrong/.fake-account"
  attest "$profile" "$case_dir" >/dev/null

  out=$(verify "$profile" "$missing" "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "missing task-home auth must be rejected"
  assert_contains "$out" "could not be attested" "missing auth refusal was not actionable"
  assert_not_contains "$out" "@example.invalid" "missing auth refusal leaked account identity"

  out=$(verify "$profile" "$wrong" "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "wrong-account fallback must be rejected"
  assert_contains "$out" "different account" "wrong-account refusal was not actionable"
  assert_not_contains "$out" "@example.invalid" "wrong-account refusal leaked account identity"
  pass "missing auth and wrong-account fallback both fail closed"
}

test_unavailable_attestation_is_rejected() {
  local case_dir profile home incomplete out status
  case_dir="$TMP_ROOT/unavailable"
  profile="$case_dir/profile"
  home="$case_dir/home"
  incomplete="$case_dir/incomplete"
  mkdir -p "$profile" "$home" "$incomplete"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' intended > "$home/.fake-account"
  printf '%s\n' incomplete > "$incomplete/.fake-account"

  out=$(verify "$profile" "$home" "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "verification without a profile attestation must fail"
  assert_contains "$out" "no usable account attestation" \
    "missing profile-local attestation refusal was not actionable"

  out=$(attest "$incomplete" "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "an account without organization identity cannot be attested"
  assert_contains "$out" "could not be attested" \
    "unavailable identity fields did not produce a clear refusal"
  assert_absent "$incomplete/.firstmate-account.json" \
    "failed attestation wrote an unusable manifest"
  pass "unavailable identity attestation blocks provisioning and verification"
}

test_verified_exec_rechecks_and_scrubs_worker_environment() {
  local case_dir profile home real_home real_case result out status
  case_dir="$TMP_ROOT/exec"
  profile="$case_dir/profile"
  home="$case_dir/home"
  result="$case_dir/worker.env"
  mkdir -p "$profile" "$home"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' intended > "$home/.fake-account"
  attest "$profile" "$case_dir" >/dev/null
  real_home=$(cd "$home" && pwd -P)
  real_case=$(cd "$case_dir" && pwd -P)

  out=$(FM_FAKE_WORKER_RESULT="$result" \
    ANTHROPIC_API_KEY=ambient-key ANTHROPIC_AUTH_TOKEN=ambient-token \
    ANTHROPIC_IDENTITY_TOKEN=ambient-identity \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-oauth \
    CLAUDE_CODE_SESSION_ACCESS_TOKEN=ambient-session ANTHROPIC_PROFILE=personal \
    CLAUDE_CODE_HOST_CREDS_FILE=/tmp/ambient-host-creds \
    CCR_OAUTH_TOKEN_FILE=/tmp/ambient-ccr-token \
    CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_GATEWAY=1 PATH="$FAKEBIN:$PATH" \
    python3 "$HELPER" --verify-exec --profile "$profile" --home "$home" \
      --worktree "$case_dir" -- worker 2>&1)
  status=$?
  expect_code 0 "$status" "verified exec should start the synthetic worker"
  [ -z "$out" ] || fail "verified exec relayed status output"
  assert_grep "config=$real_home" "$result" "worker did not receive the exact task-private home"
  grep -Fx 'api_key=' "$result" >/dev/null || fail "worker inherited ANTHROPIC_API_KEY"
  grep -Fx 'auth_token=' "$result" >/dev/null || fail "worker inherited ANTHROPIC_AUTH_TOKEN"
  grep -Fx 'oauth_token=' "$result" >/dev/null || fail "worker inherited CLAUDE_CODE_OAUTH_TOKEN"
  grep -Fx 'identity=' "$result" >/dev/null || fail "worker inherited ANTHROPIC_IDENTITY_TOKEN"
  grep -Fx 'session=' "$result" >/dev/null || fail "worker inherited CLAUDE_CODE_SESSION_ACCESS_TOKEN"
  grep -Fx 'host_creds=' "$result" >/dev/null || fail "worker inherited CLAUDE_CODE_HOST_CREDS_FILE"
  grep -Fx 'ccr_token=' "$result" >/dev/null || fail "worker inherited CCR_OAUTH_TOKEN_FILE"
  grep -Fx 'profile=' "$result" >/dev/null || fail "worker inherited ANTHROPIC_PROFILE"
  grep -Fx 'provider=' "$result" >/dev/null || fail "worker inherited an alternate provider"
  grep -Fx 'gateway=' "$result" >/dev/null || fail "worker inherited gateway mode"
  assert_grep "program=$FAKEBIN_EXEC/worker" "$result" \
    "verified exec did not start the exact program it resolved"
  assert_grep "cwd=$real_case" "$result" "verified exec did not pin the task worktree"
  pass "verified exec rechecks identity and scrubs ambient auth before the worker"
}

test_environment_cannot_redirect_the_attested_cli() {
  local case_dir profile logged_out out status
  case_dir="$TMP_ROOT/redirect"
  profile="$case_dir/profile"
  logged_out="$case_dir/logged-out"
  mkdir -p "$profile" "$logged_out"
  printf '%s\n' intended > "$profile/.fake-account"
  attest "$profile" "$case_dir" >/dev/null

  out=$(PATH="$LIARBIN:$PATH" python3 "$HELPER" --verify --profile "$profile" \
    --home "$logged_out" --worktree "$case_dir" 2>&1)
  status=$?
  expect_code 0 "$status" \
    "the always-attesting fixture must be able to satisfy verification from PATH"

  out=$(PATH="$FAKEBIN:$PATH" FM_CLAUDE_CREW_CLI="$LIARBIN/claude" \
    FM_CLAUDE_CREW_FAKE_CLI=1 CLAUDE_CLI="$LIARBIN/claude" \
    python3 "$HELPER" --verify --profile "$profile" --home "$logged_out" \
    --worktree "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" \
    "no environment variable may point account attestation at another program"
  assert_contains "$out" "could not be attested" \
    "redirected-attestation refusal was not actionable"
  pass "account attestation always runs the claude program on the launching PATH"
}

test_oversized_status_output_is_rejected() {
  local case_dir profile home out status
  case_dir="$TMP_ROOT/noisy"
  profile="$case_dir/profile"
  home="$case_dir/home"
  mkdir -p "$profile" "$home"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' intended > "$home/.fake-account"
  attest "$profile" "$case_dir" >/dev/null

  out=$(PATH="$NOISYBIN:$PATH" python3 "$HELPER" \
    --verify --profile "$profile" --home "$home" --worktree "$case_dir" 2>&1)
  status=$?
  expect_code 1 "$status" "unbounded status output must fail closed"
  assert_contains "$out" "could not be attested" \
    "oversized status refusal was not actionable"
  pass "status output beyond the in-memory cap fails closed"
}

test_verified_exec_bounds_environment_assignments_and_pins_the_cli() {
  local case_dir profile home result out status
  case_dir="$TMP_ROOT/exec-pinning"
  profile="$case_dir/profile"
  home="$case_dir/home"
  result="$case_dir/worker.env"
  mkdir -p "$profile" "$home"
  printf '%s\n' intended > "$profile/.fake-account"
  printf '%s\n' intended > "$home/.fake-account"
  attest "$profile" "$case_dir" >/dev/null

  out=$(PATH="$FAKEBIN:$PATH" \
    python3 "$HELPER" --verify-exec --profile "$profile" --home "$home" \
    --worktree "$case_dir" -- ANTHROPIC_API_KEY=injected \
    FM_FAKE_WORKER_RESULT="$result" worker 2>&1)
  status=$?
  expect_code 1 "$status" "a command assignment must not restore scrubbed authentication"
  assert_contains "$out" "cannot set authentication variables" \
    "authentication-assignment refusal was not actionable"
  assert_absent "$result" "a rejected assignment still started a worker"

  out=$(PATH="$FAKEBIN:$PATH" \
    python3 "$HELPER" --verify-exec --profile "$profile" --home "$home" \
    --worktree "$case_dir" -- FM_FAKE_WORKER_RESULT="$result" worker 2>&1)
  status=$?
  expect_code 0 "$status" "verified exec should apply a safe leading assignment itself"
  assert_present "$result" "verified exec did not apply the command's own assignment"

  out=$(FM_FAKE_WORKER_RESULT="$case_dir/pinned.env" \
    PATH="$FAKEBIN:$PATH" python3 "$HELPER" --verify-exec --require-verified-cli \
    --profile "$profile" --home "$home" --worktree "$case_dir" -- worker 2>&1)
  status=$?
  expect_code 1 "$status" "a pinned exec must refuse a program other than the attested CLI"
  assert_contains "$out" "not the attested Claude CLI" \
    "unattested exec-target refusal was not actionable"
  assert_absent "$case_dir/pinned.env" "unattested exec target still started"

  out=$(FM_FAKE_LOGIN_RESULT="$case_dir/pinned.env" \
    PATH="$FAKEBIN:$PATH" python3 "$HELPER" --verify-exec --require-verified-cli \
    --profile "$profile" --home "$home" --worktree "$case_dir" -- claude auth login 2>&1)
  status=$?
  expect_code 0 "$status" "a pinned exec should start the exact attested CLI"
  assert_present "$case_dir/pinned.env" "pinned exec did not start the attested CLI"
  pass "verified exec bounds its own assignments and can pin the attested Claude binary"
}

test_login_pins_profile_and_scrubs_ambient_auth
test_intended_account_attests_and_verifies_without_identity_output
test_missing_auth_and_wrong_account_are_rejected
test_unavailable_attestation_is_rejected
test_verified_exec_rechecks_and_scrubs_worker_environment
test_environment_cannot_redirect_the_attested_cli
test_oversized_status_output_is_rejected
test_verified_exec_bounds_environment_assignments_and_pins_the_cli

echo "# all fm-claude-auth tests passed"
