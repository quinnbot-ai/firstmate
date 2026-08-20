#!/usr/bin/env bash
# Intercept no-mistakes' bounded `gh pr checks` CI monitor invocation.
#
# Install this script as a symlink named `gh` in a directory that precedes the
# real gh binary on the no-mistakes daemon's PATH. It delegates every command
# unchanged except the exact JSON `gh pr checks` argument shapes that
# bin/fm-gh-ci-fallback.sh declares supported. That helper first invokes the
# real gh with the ambient token, and only translates the known
# statusCheckRollup permission denial into an exact-current-head Actions API
# verdict. See bin/fm-gh-ci-fallback.sh for the verification contract.
#
# This script is intentionally a PATH wrapper rather than a task-worktree
# wrapper: no-mistakes executes the CI command in its own daemon environment.
set -eu

SHIM_PATH=${BASH_SOURCE[0]}
SHIM_DIR=$(cd "$(dirname "$SHIM_PATH")" && pwd)

resolve_path() {
  local target=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null || printf '%s\n' "$target"
    return 0
  fi
  local directory base link
  directory=$(cd "$(dirname "$target")" 2>/dev/null && pwd) || {
    printf '%s\n' "$target"
    return 0
  }
  base=$(basename "$target")
  while [ -L "$directory/$base" ]; do
    link=$(readlink "$directory/$base") || break
    case "$link" in
      /*) directory=$(cd "$(dirname "$link")" && pwd) ;;
      *) directory=$(cd "$directory/$(dirname "$link")" && pwd) ;;
    esac
    base=$(basename "$link")
  done
  printf '%s/%s\n' "$directory" "$base"
}

SHIM_REAL=$(resolve_path "$SHIM_PATH")
SHIM_SOURCE_DIR=$(cd "$(dirname "$SHIM_REAL")" && pwd)

find_real_gh() {
  local entry candidate
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/gh"
    [ -x "$candidate" ] && [ -f "$candidate" ] || continue
    [ "$(cd "$entry" 2>/dev/null && pwd)" = "$SHIM_DIR" ] && continue
    [ "$(resolve_path "$candidate")" = "$SHIM_REAL" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

REAL_GH=$(find_real_gh) || {
  echo "fm-gh-shim: no real gh found on PATH beyond the shim directory ($SHIM_DIR)" >&2
  exit 127
}

CI_FALLBACK="$SHIM_SOURCE_DIR/fm-gh-ci-fallback.sh"
if [ "${1:-}" = pr ] && [ "${2:-}" = checks ] && [ -x "$CI_FALLBACK" ] && \
  "$CI_FALLBACK" --supports "$@"; then
  exec "${FM_GH_SHIM_CI_FALLBACK:-$CI_FALLBACK}" "$REAL_GH" "$@"
fi

exec "$REAL_GH" "$@"
