#!/usr/bin/env bash
# fm-claude-crew-lib.sh - shared helpers for the isolated Claude crewmate
# profile (data/claude-crewmate/). Sourced by fm-spawn.sh and
# fm-dispatch-select.sh so the profile path and the "does it hold usable
# credentials" readiness check have exactly one owner.
#
# fm_claude_crew_profile_dir <data-dir> echoes the persistent, captain-owned
# profile directory: <data-dir>/claude-crewmate/profile. Nothing in this repo
# writes there - it is populated only by the captain's own one-time
# `CLAUDE_CONFIG_DIR=<that path> claude auth login` (docs/configuration.md).
# Task-private copies live as sibling directories, created and removed by
# bin/fm-claude-home.py.
#
# fm_claude_crew_profile_ready <profile-dir> <data-dir> <state-dir> returns 0
# only when both the persistent profile and a freshly provisioned private copy
# report a logged-in account. The copy is immediately removed, including its
# managed macOS Keychain entry, before this function returns. That tests the
# exact credential surface a crew pane will receive rather than assuming that
# a profile-path probe proves a copied path can authenticate. It fails closed
# on any missing dependency, unsafe cleanup, non-zero exit, or unparseable
# output. An absent profile is simply not ready; a present profile that fails
# this check is an invalid Claude crew configuration that fm-spawn.sh refuses.
# FM_CLAUDE_CREW_CLI overrides the claude binary (tests only).

fm_claude_crew_profile_dir() {
  printf '%s/claude-crewmate/profile' "$1"
}

fm_claude_crew_profile_ready() {
  local profile=${1:-} data=${2:-} state=${3:-} cli=${FM_CLAUDE_CREW_CLI:-claude} status probe probe_id cleanup_status
  [ -n "$profile" ] && [ -n "$data" ] && [ -n "$state" ] && [ -d "$profile" ] || return 1
  command -v "$cli" >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  status=$(CLAUDE_CONFIG_DIR="$profile" "$cli" auth status --json 2>/dev/null) || return 1
  printf '%s\n' "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1 || return 1
  probe_id="claude-readiness-${RANDOM}${RANDOM}"
  probe=$(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-home.py" \
    --data "$data" --source "$profile" --task-id "$probe_id" --create) || return 1
  status=$(CLAUDE_CONFIG_DIR="$probe" "$cli" auth status --json 2>/dev/null)
  cleanup_status=0
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-home.py" \
    --data "$data" --state "$state" --task-id "$probe_id" --home "$probe" --remove >/dev/null 2>&1 \
    || cleanup_status=1
  [ "$cleanup_status" -eq 0 ] || return 1
  [ -n "$status" ] && printf '%s\n' "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1
}
