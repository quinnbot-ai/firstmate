#!/usr/bin/env bash
# fm-claude-crew-lib.sh - shared helpers for the isolated Claude crewmate
# profile (data/claude-crewmate/). Sourced by fm-spawn.sh and
# fm-dispatch-select.sh so the profile path and the "does it hold usable
# credentials" readiness check have exactly one owner.
#
# fm_claude_crew_profile_dir <data-dir> echoes the persistent, captain-owned
# profile directory: <data-dir>/claude-crewmate/profile. The captain populates
# it with an explicit login, then bin/fm-claude-auth.py records a profile-local
# digest attestation without writing account identity or credential material.
# Task-private copies live as sibling directories, created and removed by
# bin/fm-claude-home.py.
#
# fm_claude_crew_profile_ready <profile-dir> <data-dir> <state-dir> returns 0
# only when both the persistent profile and a freshly provisioned private copy
# resolve to the attested Claude.ai account. The copy is immediately removed,
# including its managed macOS Keychain entry, before this function returns.
# That tests the exact credential surface a crew pane will receive rather than
# assuming that a profile-path probe proves a copied path can authenticate.
# It fails closed on any missing dependency, unsafe cleanup, non-zero exit,
# missing identity, or account mismatch. An absent profile is simply not ready;
# a present profile that fails this check is an invalid Claude crew
# configuration that fm-spawn.sh refuses.
# fm_claude_crew_home_ready <profile-dir> <home-dir> <worktree> verifies the
# actual task home after creation and before its launch command is constructed.
# Both probe the `claude` program on PATH through bin/fm-claude-auth.py, which
# accepts no environment override for it; tests supply a fake by prepending
# their own directory to PATH.

fm_claude_crew_profile_dir() {
  printf '%s/claude-crewmate/profile' "$1"
}

fm_claude_crew_profile_ready() {
  local profile=${1:-} data=${2:-} state=${3:-} probe probe_id cleanup_status script_dir
  [ -n "$profile" ] && [ -n "$data" ] && [ -n "$state" ] && [ -d "$profile" ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  probe_id="claude-readiness-${RANDOM}${RANDOM}"
  probe=$(python3 "$script_dir/fm-claude-home.py" \
    --data "$data" --source "$profile" --task-id "$probe_id" --create) || return 1
  readiness_status=0
  python3 "$script_dir/fm-claude-auth.py" \
    --verify --profile "$profile" --home "$probe" --worktree "$PWD" >/dev/null 2>&1 \
    || readiness_status=$?
  cleanup_status=0
  python3 "$script_dir/fm-claude-home.py" \
    --data "$data" --state "$state" --task-id "$probe_id" --home "$probe" --remove >/dev/null 2>&1 \
    || cleanup_status=1
  [ "$cleanup_status" -eq 0 ] || return 1
  [ "$readiness_status" -eq 0 ]
}

fm_claude_crew_home_ready() {
  local profile=${1:-} home=${2:-} worktree=${3:-} script_dir
  [ -n "$profile" ] && [ -n "$home" ] && [ -n "$worktree" ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  python3 "$script_dir/fm-claude-auth.py" \
    --verify --profile "$profile" --home "$home" --worktree "$worktree" >/dev/null 2>&1
}
