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
# fm_claude_crew_profile_ready <profile-dir> returns 0 only when the
# directory exists and `claude auth status --json`, run with CLAUDE_CONFIG_DIR
# pointed at it, reports a logged-in account. That mirrors the check a human
# would run and stays correct across CLI credential-storage changes, instead
# of parsing the profile's internal file format. It fails closed (returns 1,
# no diagnostic) on any missing dependency, non-zero exit, or unparseable
# output: an absent or credential-less profile is simply "not ready", the same
# state as a project with no profile directory at all - never a hard error
# that could block dispatch or spawn.
# FM_CLAUDE_CREW_CLI overrides the claude binary (tests only).

fm_claude_crew_profile_dir() {
  printf '%s/claude-crewmate/profile' "$1"
}

fm_claude_crew_profile_ready() {
  local profile=$1 cli=${FM_CLAUDE_CREW_CLI:-claude} status
  [ -n "$profile" ] && [ -d "$profile" ] || return 1
  command -v "$cli" >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  status=$(CLAUDE_CONFIG_DIR="$profile" "$cli" auth status --json 2>/dev/null) || return 1
  printf '%s\n' "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1
}
