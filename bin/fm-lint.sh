#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, file set, and config live here and ONLY here, so the gates
# cannot drift apart: both invoke this script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. The installer pins one exact
# version, and this script asserts the resolved `shellcheck` matches it, so CI
# and local run the identical rule set. This is not a CI relaxation: it
# adopts one upstream release consistently; the only difference from the old
# floating CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket exclude of checks - every still-supported
# finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --required-version print the installer-owned ShellCheck version
#                                  (CI reads this to install the exact same one)
#
# Exit status is ShellCheck's own on a lint run, so a caller (CI or the gate)
# fails exactly when ShellCheck reports a finding; a version mismatch or a
# missing ShellCheck fails before linting with a distinct message.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Expose the installer-owned version without needing ShellCheck installed, so CI
# can read it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  exec "$ROOT/bin/fm-install-shellcheck.sh" --required-version
fi

# Prefer the exact binary installed by CI's installer. RUNNER_TEMP is the
# install root in CI, and TMPDIR keeps the same destination discoverable for
# local installs that follow the installer convention.
REQUIRED_SHELLCHECK=$("$ROOT/bin/fm-install-shellcheck.sh" --required-version)
PINNED_BIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bin/shellcheck"
if [ -x "$PINNED_BIN" ]; then
  shellcheck_bin=$PINNED_BIN
else
  printf "fm-lint.sh: pinned ShellCheck is absent; falling back to PATH. Install it with bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\".\n" >&2
  if ! shellcheck_bin=$(command -v shellcheck); then
    printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
      "$REQUIRED_SHELLCHECK" >&2
    exit 127
  fi
fi
unset SHELLCHECK_OPTS
resolved=$("$shellcheck_bin" --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  exec "$shellcheck_bin" --norc "$@"
fi

# Canonical file set: the ONE authoritative definition. Callers reference this
# script; they never re-spell these globs.
exec "$shellcheck_bin" --norc bin/*.sh bin/backends/*.sh tests/*.sh
