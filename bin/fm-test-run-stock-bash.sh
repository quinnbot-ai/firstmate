#!/usr/bin/env bash
# fm-test-run-stock-bash.sh - run the focused runner contract under stock
# macOS Bash 3.2, with an explicit local skip when that interpreter is absent.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x /bin/bash ]; then
  printf 'skip: stock Bash 3.2 unavailable (evidence: /bin/bash is missing)\n'
  exit 0
fi

version=$(/bin/bash -c 'printf "%s" "$BASH_VERSION"')
case "$version" in
  3.2.*) ;;
  *)
    printf 'skip: stock Bash 3.2 unavailable (evidence: /bin/bash reports %s)\n' "$version"
    exit 0
    ;;
esac

exec /bin/bash "$ROOT/tests/fm-test-run.test.sh" "$@"
