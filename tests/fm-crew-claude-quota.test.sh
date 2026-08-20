#!/usr/bin/env bash
# Behavior tests for fm-crew-claude-quota.sh's isolated, redacted crew result.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-crew-claude-quota)
SCRIPT="$ROOT/bin/fm-crew-claude-quota.sh"

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${CLAUDE_CONFIG_DIR:-}" "${XDG_CACHE_HOME:-}" "$*" >> "$FM_FAKE_QUOTA_LOG"
case "${FM_FAKE_QUOTA_MODE:-healthy}" in
  healthy)
    printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":73}]},"account":{"opaque":"'"${FM_FAKE_REDACTION_SENTINEL:-}"'"}}]}'
    ;;
  exhausted)
    printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]}}]}'
    ;;
  absent)
    printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"auth_required"},"account":{"opaque":"'"${FM_FAKE_REDACTION_SENTINEL:-}"'"}}]}'
    exit 1
    ;;
  stale)
    printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"stale"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]},"account":{"opaque":"'"${FM_FAKE_REDACTION_SENTINEL:-}"'"}}]}'
    ;;
  malformed) printf 'not json\n' ;;
esac
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# run_probe <case> <mode> [profile=present|missing]
RUN_OUTPUT=
RUN_RC=0
RUN_LOG=
RUN_PROFILE=
RUN_SEAT_PROFILE=
run_probe() {
  local case_name=$1 mode=$2 profile_state=${3:-present}
  local case_dir home config fakebin
  case_dir="$TMP_ROOT/$case_name"
  home="$case_dir/home"
  config="$home/config"
  fakebin=$(make_fakebin "$case_dir")
  RUN_LOG="$case_dir/quota.log"
  RUN_PROFILE="$case_dir/crew-profile"
  RUN_SEAT_PROFILE="$case_dir/seat-profile"
  mkdir -p "$config" "$RUN_SEAT_PROFILE"
  if [ "$profile_state" = present ]; then
    mkdir -p "$RUN_PROFILE"
    printf '%s\n' "$RUN_PROFILE" > "$config/crew-claude-profile"
  fi
  : > "$RUN_LOG"
  RUN_OUTPUT=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    CLAUDE_CONFIG_DIR="$RUN_SEAT_PROFILE" FM_FAKE_QUOTA_LOG="$RUN_LOG" \
    FM_FAKE_QUOTA_MODE="$mode" FM_FAKE_REDACTION_SENTINEL='redaction-sentinel' \
    "$SCRIPT" 2>"$case_dir/stderr") || RUN_RC=$?
}

test_healthy_profile_is_measured_without_using_seat_profile() {
  local log
  run_probe healthy healthy
  expect_code 0 "$RUN_RC" "healthy result should not be an exit-status failure"
  [ "$RUN_OUTPUT" = 'status=healthy headroom_percent=73' ] \
    || fail "healthy result was not the sanitized crew headroom: $RUN_OUTPUT"
  log=$(cat "$RUN_LOG")
  assert_contains "$log" "$RUN_PROFILE|" "quota probe did not select the configured crew profile"
  assert_not_contains "$log" "$RUN_SEAT_PROFILE" "quota probe used the seat profile"
  assert_contains "$log" '|--provider claude --json --allow-keychain-prompt' "quota probe argv lost its fixed Claude measurement shape"
  pass "healthy crew headroom uses only the configured crew profile"
}

test_absent_profile_authentication_is_named() {
  run_probe absent absent
  expect_code 0 "$RUN_RC" "absent authentication should be a reported result"
  [ "$RUN_OUTPUT" = 'status=absent' ] || fail "absent authentication was not named: $RUN_OUTPUT"
  pass "missing crew sign-in is distinct from quota exhaustion"
}

test_stale_or_malformed_results_are_unmeasurable_not_zero() {
  local mode
  for mode in stale malformed; do
    run_probe "unmeasurable-$mode" "$mode"
    expect_code 0 "$RUN_RC" "$mode result should be reported"
    [ "$RUN_OUTPUT" = 'status=unmeasurable' ] \
      || fail "$mode result was not explicitly unmeasurable: $RUN_OUTPUT"
  done
  pass "stale and malformed results are unmeasurable rather than exhausted"
}

test_fresh_zero_is_exhausted_not_unmeasurable() {
  run_probe exhausted exhausted
  expect_code 0 "$RUN_RC" "fresh zero should be a reported result"
  [ "$RUN_OUTPUT" = 'status=exhausted headroom_percent=0' ] \
    || fail "fresh zero was not distinct from unmeasurable: $RUN_OUTPUT"
  pass "fresh zero remains a measurable exhausted result"
}

test_missing_configured_profile_is_cleanly_absent_without_quota_call() {
  run_probe missing-profile healthy missing
  expect_code 0 "$RUN_RC" "missing profile should be a reported result"
  [ "$RUN_OUTPUT" = 'status=absent' ] || fail "missing profile was not absent: $RUN_OUTPUT"
  [ ! -s "$RUN_LOG" ] || fail "missing profile unexpectedly invoked quota-axi"
  pass "missing configured profile is absent without a seat fallback"
}

test_raw_account_data_never_reaches_output_or_stderr() {
  local stderr_file
  run_probe redaction healthy
  stderr_file="$TMP_ROOT/redaction/stderr"
  assert_not_contains "$RUN_OUTPUT" 'redaction-sentinel' "raw account data leaked to stdout"
  assert_not_contains "$(cat "$stderr_file")" 'redaction-sentinel' "raw account data leaked to stderr"
  assert_not_contains "$RUN_OUTPUT" "$RUN_PROFILE" "profile path leaked to stdout"
  pass "raw quota account fields and profile paths are redacted"
}

test_healthy_profile_is_measured_without_using_seat_profile
test_absent_profile_authentication_is_named
test_stale_or_malformed_results_are_unmeasurable_not_zero
test_fresh_zero_is_exhausted_not_unmeasurable
test_missing_configured_profile_is_cleanly_absent_without_quota_call
test_raw_account_data_never_reaches_output_or_stderr

echo "# all fm-crew-claude-quota tests passed"
