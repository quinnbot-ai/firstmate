#!/usr/bin/env bash
# Shared read-only operations-inbox discovery for the session-start digest and
# watcher.  The home directory is $FM_HOME/ops-inbox; an optional local
# config/ops-inbox-cmd supplies one prompt list-only command for a machine
# inbox.  This file owns the config seam and fingerprint mechanics.

fm_ops_inbox_stat_sig() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%y' "$1" 2>/dev/null
  fi
}

fm_ops_inbox_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_ops_inbox_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print "sha256:" $1}'
  else
    cksum | awk '{print "cksum:" $1 ":" $2}'
  fi
}

fm_ops_inbox_home_dir() {
  printf '%s/ops-inbox\n' "$1"
}

# fm_ops_inbox_external_command <config-dir>
# Prints the first non-empty, non-comment config line.  That line is an
# operator-owned list-only shell command, intentionally generic so tracked
# firstmate code does not know any machine-specific inbox location.
fm_ops_inbox_external_command() {
  local config=$1 line path
  path="$config/ops-inbox-cmd"
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$path"
  return 1
}

# fm_ops_inbox_external_output <config-dir>
# Prints the configured command's combined output and returns its exit status.
# A command may use a non-zero exit to signal unacknowledged criticals, so
# callers must inspect the output as well as this status.
fm_ops_inbox_external_output() {
  local config=$1 command
  command=$(fm_ops_inbox_external_command "$config") || return 127
  fm_ops_inbox_external_run "$command" 2>&1 | LC_ALL=C head -c "$FM_OPS_INBOX_OUTPUT_MAX_BYTES"
  return "${PIPESTATUS[0]}"
}

FM_OPS_INBOX_TIMEOUT=${FM_OPS_INBOX_TIMEOUT:-10}
case "$FM_OPS_INBOX_TIMEOUT" in ''|*[!0-9]*|0) FM_OPS_INBOX_TIMEOUT=10 ;; esac
FM_OPS_INBOX_OUTPUT_MAX_BYTES=${FM_OPS_INBOX_OUTPUT_MAX_BYTES:-32768}
case "$FM_OPS_INBOX_OUTPUT_MAX_BYTES" in ''|*[!0-9]*|0) FM_OPS_INBOX_OUTPUT_MAX_BYTES=32768 ;; esac

fm_ops_inbox_external_run() {
  local command=$1
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed\n" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec failed: $!\n" } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_OPS_INBOX_TIMEOUT" /bin/sh -c "$command"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$FM_OPS_INBOX_TIMEOUT" /bin/sh -c "$command"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$FM_OPS_INBOX_TIMEOUT" /bin/sh -c "$command"
  else
    return 124
  fi
}

# fm_ops_inbox_home_records <home>
# Prints deterministic size/mtime/path records for every home inbox event.
fm_ops_inbox_home_records() {
  local home=$1 dir path sig
  dir=$(fm_ops_inbox_home_dir "$home")
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' path; do
    sig=$(fm_ops_inbox_stat_sig "$path") || continue
    printf '%s\t%s\n' "$sig" "$path"
  done < <(find "$dir" -type f -print0 2>/dev/null) | LC_ALL=C sort
}

# fm_ops_inbox_home_newest <home> <limit>
# Prints newest event files as epoch/path records, bounded by <limit>.
fm_ops_inbox_home_newest() {
  local home=$1 limit=$2 dir path mtime
  dir=$(fm_ops_inbox_home_dir "$home")
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' path; do
    mtime=$(fm_ops_inbox_stat_mtime "$path") || continue
    printf '%s\t%s\n' "$mtime" "$path"
  done < <(find "$dir" -type f -print0 2>/dev/null) | LC_ALL=C sort -rn | head -n "$limit"
}

# fm_ops_inbox_has_events <home> <config-dir>
# The configured list-command contract starts with `unacked_criticals: <n>`.
# A malformed or failed configured command is treated as an event so its one
# durable wake cannot be hidden by a bad local seam.
fm_ops_inbox_has_events() {
  local home=$1 config=$2 records output rc count
  records=$(fm_ops_inbox_home_records "$home")
  [ -z "$records" ] || return 0
  fm_ops_inbox_external_command "$config" >/dev/null || return 1
  output=$(fm_ops_inbox_external_output "$config")
  rc=$?
  count=$(printf '%s\n' "$output" | awk '/^unacked_criticals:[[:space:]]*[0-9]+$/ { sub(/^unacked_criticals:[[:space:]]*/, ""); print; exit }')
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    0) [ "$rc" -eq 0 ] && return 1; return 0 ;;
    *) return 0 ;;
  esac
}

# fm_ops_inbox_fingerprint <home> <config-dir>
# Hashes local event metadata plus the configured external list output.  The
# fingerprint changes once per inbox state transition and is safe to persist in
# state/.hash-ops-inbox as the watcher's suppressor.
fm_ops_inbox_fingerprint() {
  local home=$1 config=$2 dir command output rc
  dir=$(fm_ops_inbox_home_dir "$home")
  {
    printf 'home\n'
    if [ -d "$dir" ]; then
      fm_ops_inbox_home_records "$home"
    fi
    if command=$(fm_ops_inbox_external_command "$config"); then
      printf 'external:configured:%s\n' "$command"
      output=$(fm_ops_inbox_external_output "$config")
      rc=$?
      printf 'external:exit:%s\n%s\n' "$rc" "$output"
    else
      printf 'external:absent\n'
    fi
  } | fm_ops_inbox_hash
}
