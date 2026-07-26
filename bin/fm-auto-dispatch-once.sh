#!/usr/bin/env bash
# Run one bounded report-only auto-dispatch refill pass.
#
# An absent or disabled config claims nothing and reports nothing.
# The helper acquires one per-home lock, verifies session and watcher ownership,
# obtains authoritative machine-readable ready work, atomically claims and
# reopens each selected task, and reports what it would dispatch.
# It never calls fm-spawn.sh and never starts another daemon.
# Usage: fm-auto-dispatch-once.sh [--force]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# A home with no config and no leftover episode marker is an immediate no-op.
# When a marker survives the config's removal, the pass still runs so it can
# retire that marker, and an absent config makes it do nothing else.
if [ ! -f "$CONFIG/auto-dispatch.json" ] \
  && [ ! -f "$STATE/.auto-dispatch-episode.json" ]; then
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

LOCK="$STATE/.auto-dispatch.lock"
if ! fm_lock_try_acquire "$LOCK"; then
  exit 0
fi
cleanup() {
  fm_lock_release "$LOCK"
}
trap cleanup EXIT HUP INT TERM

node "$SCRIPT_DIR/fm-auto-dispatch.mjs" once "$@"
