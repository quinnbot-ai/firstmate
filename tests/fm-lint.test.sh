#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. The installer owns one exact version and
# fm-lint.sh prefers its installed binary, so command, file set, config, AND
# version all match.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run.
CANON='bin/*.sh bin/backends/*.sh tests/*.sh'
# The pinned version, read from the installer owner.
REQUIRED=$("$LINT" --required-version)
# The pinned archive checksum for THIS host platform, mirroring the installer's
# per-platform table so the fake sha256sum below satisfies the real check.
case "$(uname -s).$(uname -m)" in
  Darwin.arm64) PINNED_SHA=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
  *) PINNED_SHA=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
esac

# True only when the shellcheck fm-lint.sh itself resolves is exactly the
# pinned version, so the lint-running tests below match what CI enforces
# instead of a runner default. Probing through the one owner keeps this guard
# on the script's own selection order (pinned binary first, then PATH).
pinned_ready() {
  local tmp probe
  tmp=$(fm_test_tmproot fm-lint-ready)
  mkdir -p "$tmp"
  probe="$tmp/probe.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$probe"
  "$LINT" "$probe" >/dev/null 2>&1
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  local invocation="\"\$shellcheck_bin\" --norc"
  [ "$(grep -Fc "$invocation" "$LINT")" -eq 2 ] || fail "both lint modes must ignore ambient ShellCheck configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The installer-owned pin adopts ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  assert_grep 'VERSION=0.11.0' "$INSTALLER" "installer must own the ShellCheck pin"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep 'VERSION=0.11.0' "$INSTALLER" "installer must use its owned ShellCheck pin"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 4 ] || fail "lint and all three portable behavior jobs must use the shared ShellCheck installer"
  assert_grep "SHA256=$PINNED_SHA" "$INSTALLER" "installer must pin this platform's ShellCheck archive checksum"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-shellcheck-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt 1 ] || exit 35
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    : > "$2"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sha256sum" <<SH
#!/usr/bin/env bash
printf '%s  %s\n' "$PINNED_SHA" "\$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    mkdir -p "$2/shellcheck-v0.11.0"
    cat > "$2/shellcheck-v0.11.0/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
EOF
    chmod +x "$2/shellcheck-v0.11.0/shellcheck"
    exit 0
  fi
  shift
done
exit 2
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/sleep"

  out=$(CURL_COUNT="$tmp/curl-count" PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 2 ] || fail "installer did not retry exactly once after recovery"
  assert_contains "$out" "download attempt 1 failed; retrying" "installer did not disclose its retry"
  [ -x "$destination/shellcheck" ] || fail "installer did not install ShellCheck after retrying"
  pass "ShellCheck installer retries a transient download failure"
}

make_fake_shellcheck() {
  local path=$1 version=$2 marker=$3
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\\nversion: $version\\nlicense: x\\nwebsite: y\\n'
  exit 0
fi
printf '%s\\n' "$path" > "$marker"
exit 0
SH
  chmod +x "$path"
}

test_pinned_binary_wins_over_path() {
  local tmp fakebin runner_temp fixture marker out
  tmp=$(fm_test_tmproot fm-lint-pinned)
  fakebin=$(fm_fakebin "$tmp")
  runner_temp="$tmp/runner"
  marker="$tmp/selected"
  fixture="$tmp/fixture.sh"
  : > "$fixture"
  mkdir -p "$runner_temp/bin"
  make_fake_shellcheck "$runner_temp/bin/shellcheck" "$REQUIRED" "$marker"
  make_fake_shellcheck "$fakebin/shellcheck" 0.9.9 "$tmp/path-selected"
  out=$(RUNNER_TEMP="$runner_temp" PATH="$fakebin:$PATH" "$LINT" "$fixture" 2>&1) \
    || fail "fm-lint.sh rejected the pinned binary"$'\n'"$out"
  [ "$(cat "$marker")" = "$runner_temp/bin/shellcheck" ] \
    || fail "fm-lint.sh did not select the installer binary"
  assert_contains "$out" "ShellCheck $REQUIRED" "fm-lint.sh did not report the pinned binary"
  pass "fm-lint.sh selects the pinned binary before PATH"
}

test_local_pin_resolves_to_user_cache() {
  # Outside CI (no RUNNER_TEMP) the pinned binary must live under the
  # user-owned XDG cache, never a world-writable /tmp path.
  local tmp fakebin cache marker fixture out
  tmp=$(fm_test_tmproot fm-lint-xdg)
  fakebin=$(fm_fakebin "$tmp")
  cache="$tmp/cache"
  marker="$tmp/selected"
  fixture="$tmp/fixture.sh"
  : > "$fixture"
  mkdir -p "$cache/fm-shellcheck/bin"
  make_fake_shellcheck "$cache/fm-shellcheck/bin/shellcheck" "$REQUIRED" "$marker"
  make_fake_shellcheck "$fakebin/shellcheck" 0.9.9 "$tmp/path-selected"
  out=$(RUNNER_TEMP='' XDG_CACHE_HOME="$cache" PATH="$fakebin:$PATH" "$LINT" "$fixture" 2>&1) \
    || fail "fm-lint.sh rejected the user-cache pinned binary"$'\n'"$out"
  [ "$(cat "$marker")" = "$cache/fm-shellcheck/bin/shellcheck" ] \
    || fail "fm-lint.sh did not select the user-cache installer binary"
  pass "fm-lint.sh resolves the local pin under the user cache, not /tmp"
}

test_falls_back_to_path_with_warning() {
  local tmp fakebin runner_temp fixture marker out
  tmp=$(fm_test_tmproot fm-lint-fallback)
  fakebin=$(fm_fakebin "$tmp")
  runner_temp="$tmp/runner"
  marker="$tmp/selected"
  fixture="$tmp/fixture.sh"
  : > "$fixture"
  make_fake_shellcheck "$fakebin/shellcheck" "$REQUIRED" "$marker"
  out=$(RUNNER_TEMP="$runner_temp" PATH="$fakebin:$PATH" "$LINT" "$fixture" 2>&1) \
    || fail "fm-lint.sh rejected the matching PATH fallback"$'\n'"$out"
  [ "$(cat "$marker")" = "$fakebin/shellcheck" ] \
    || fail "fm-lint.sh did not fall back to PATH"
  assert_contains "$out" 'pinned ShellCheck is absent; falling back to PATH' \
    "fm-lint.sh did not warn about the missing pinned binary"
  assert_contains "$out" "bin/fm-install-shellcheck.sh \"$runner_temp/bin\"" \
    "fm-lint.sh warning did not name the resolved installer destination"
  pass "fm-lint.sh warns and falls back to PATH when the pin is absent"
}

test_rejects_wrong_shellcheck_version() {
  # A PATH shellcheck reporting a different version must be refused before any
  # lint, proving local and CI cannot silently diverge when the pin is absent.
  local tmp fakebin runner_temp out rc
  tmp=$(fm_test_tmproot fm-lint-mismatch)
  fakebin=$(fm_fakebin "$tmp")
  runner_temp="$tmp/runner"
  make_fake_shellcheck "$fakebin/shellcheck" 0.9.9 "$tmp/path-selected"
  rc=0
  out=$(RUNNER_TEMP="$runner_temp" PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_installer_retries_transient_download_failure
test_pinned_binary_wins_over_path
test_local_pin_resolves_to_user_cache
test_falls_back_to_path_with_warning
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
