#!/usr/bin/env bash
# Install, remove, or check the no-mistakes CI gh shim.
#
# Usage: fm-gh-shim-install.sh --check [--dir <directory>] [--path <PATH>]
#        fm-gh-shim-install.sh --install --dir <directory> [--path <PATH>]
#        fm-gh-shim-install.sh --uninstall --dir <directory>
#
# Nothing installs automatically. --install creates only a symlink named gh in
# an existing directory and refuses to replace any file or symlink it does not
# own. The directory must precede the real gh on the daemon's PATH; --check
# verifies that precedence against the supplied --path (or this shell's PATH).
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIM_SOURCE="$SCRIPT_DIR/fm-gh-shim.sh"
MODE=--check
DIRECTORY=
TARGET_PATH=$PATH

usage() {
  sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# //'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check|--install|--uninstall) MODE=$1; shift ;;
    --dir)
      [ "$#" -ge 2 ] || { echo "fm-gh-shim-install: --dir needs a value" >&2; exit 2; }
      DIRECTORY=$2
      shift 2
      ;;
    --path)
      [ "$#" -ge 2 ] || { echo "fm-gh-shim-install: --path needs a value" >&2; exit 2; }
      TARGET_PATH=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-gh-shim-install: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -x "$SHIM_SOURCE" ] || { echo "fm-gh-shim-install: shim source missing: $SHIM_SOURCE" >&2; exit 1; }

resolve_directory() {
  cd "$1" 2>/dev/null && pwd
}

first_gh() {
  local path_value=$1 skip=${2:-} entry candidate resolved
  local IFS=:
  for entry in $path_value; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/gh"
    [ -x "$candidate" ] && [ -f "$candidate" ] || continue
    resolved=$(resolve_directory "$entry") || continue
    [ "$resolved" = "$skip" ] && continue
    printf '%s/gh\n' "$resolved"
    return 0
  done
  return 1
}

owns_link() {
  [ -L "$1" ] && [ "$(readlink "$1")" = "$SHIM_SOURCE" ]
}

case "$MODE" in
  --install)
    [ -n "$DIRECTORY" ] || { echo "fm-gh-shim-install: --install needs --dir" >&2; exit 2; }
    directory_abs=$(resolve_directory "$DIRECTORY") || { echo "fm-gh-shim-install: --dir does not exist: $DIRECTORY" >&2; exit 1; }
    link="$directory_abs/gh"
    if { [ -e "$link" ] || [ -L "$link" ]; } && ! owns_link "$link"; then
      echo "fm-gh-shim-install: refusing to replace $link because this installer does not own it" >&2
      exit 1
    fi
    real_gh=$(first_gh "$TARGET_PATH" "$directory_abs") || { echo "fm-gh-shim-install: no real gh on PATH outside $directory_abs" >&2; exit 1; }
    ln -sf "$SHIM_SOURCE" "$link"
    printf 'installed: %s -> %s\n' "$link" "$SHIM_SOURCE"
    printf 'delegates to: %s\n' "$real_gh"
    ;;
  --uninstall)
    [ -n "$DIRECTORY" ] || { echo "fm-gh-shim-install: --uninstall needs --dir" >&2; exit 2; }
    directory_abs=$(resolve_directory "$DIRECTORY") || { echo "fm-gh-shim-install: --dir does not exist: $DIRECTORY" >&2; exit 1; }
    link="$directory_abs/gh"
    [ -L "$link" ] || { printf 'not installed: %s\n' "$link"; exit 0; }
    owns_link "$link" || { echo "fm-gh-shim-install: $link is not this shim; leaving it alone" >&2; exit 1; }
    rm -f "$link"
    printf 'removed: %s\n' "$link"
    ;;
  --check)
    status=0
    winner=$(first_gh "$TARGET_PATH") || winner=
    printf 'first gh on evaluated PATH: %s\n' "${winner:-none found}"
    if [ -n "$DIRECTORY" ]; then
      directory_abs=$(resolve_directory "$DIRECTORY") || { echo "fm-gh-shim-install: --dir does not exist: $DIRECTORY" >&2; exit 1; }
      link="$directory_abs/gh"
      owns_link "$link" || status=1
      if [ "$winner" = "$link" ]; then
        printf 'precedence: %s wins\n' "$directory_abs"
      else
        printf 'precedence: %s does NOT win\n' "$directory_abs"
        status=1
      fi
    fi
    exit "$status"
    ;;
esac
