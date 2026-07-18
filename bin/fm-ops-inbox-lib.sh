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
  command -v perl >/dev/null 2>&1 || return 124
  fm_ops_inbox_external_run "$command"
}

FM_OPS_INBOX_TIMEOUT=${FM_OPS_INBOX_TIMEOUT:-10}
case "$FM_OPS_INBOX_TIMEOUT" in ''|*[!0-9]*|0) FM_OPS_INBOX_TIMEOUT=10 ;; esac
FM_OPS_INBOX_OUTPUT_MAX_BYTES=${FM_OPS_INBOX_OUTPUT_MAX_BYTES:-32768}
case "$FM_OPS_INBOX_OUTPUT_MAX_BYTES" in ''|*[!0-9]*|0) FM_OPS_INBOX_OUTPUT_MAX_BYTES=32768 ;; esac
FM_OPS_INBOX_MARKER_LIMIT=${FM_OPS_INBOX_MARKER_LIMIT:-256}
case "$FM_OPS_INBOX_MARKER_LIMIT" in ''|*[!0-9]*|0) FM_OPS_INBOX_MARKER_LIMIT=256 ;; esac

fm_ops_inbox_external_run() {
  local command=$1
  perl -e '
    use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
    use IO::Select;
    use POSIX qw(WNOHANG);
    use Time::HiRes qw(time);

    my ($timeout, $max, $command) = @ARGV;
    pipe(my $reader, my $writer) or exit 124;
    my $pid = fork;
    exit 124 unless defined $pid;
    if (!$pid) {
      close $reader;
      setpgrp(0, 0) or exit 124;
      open STDOUT, ">&", $writer or exit 124;
      open STDERR, ">&", $writer or exit 124;
      close $writer;
      exec "bash", "-c", $command;
      exit 127;
    }

    close $writer;
    my $flags = fcntl($reader, F_GETFL, 0);
    fcntl($reader, F_SETFL, $flags | O_NONBLOCK) or exit 124;
    my $selector = IO::Select->new($reader);
    my $deadline = time + $timeout;
    my $kill_deadline;
    my $capture_deadline;
    my $eof = 0;
    my $shell_done = 0;
    my $shell_status = 124;
    my $timed_out = 0;
    my $capped = 0;
    my $killed = 0;
    my $written = 0;

    while (!$eof || !$shell_done) {
      my $now = time;
      if (!$timed_out && !$capped && $now >= $deadline) {
        kill "TERM", -$pid;
        $timed_out = 1;
        $kill_deadline = $now + 0.2;
        $capture_deadline = $kill_deadline + 0.1;
      }
      if (($timed_out || $capped) && !$killed && $now >= $kill_deadline) {
        kill "KILL", -$pid;
        $killed = 1;
      }
      if (defined $capture_deadline && $now >= $capture_deadline) {
        $selector->remove($reader);
        close $reader;
        $eof = 1;
        last;
      }

      my $next = $deadline;
      $next = $kill_deadline if defined $kill_deadline && $kill_deadline < $next;
      $next = $capture_deadline if defined $capture_deadline && $capture_deadline < $next;
      my $wait = $next - time;
      $wait = 0 if $wait < 0;
      $wait = 0.05 if $wait > 0.05;
      for my $fh ($selector->can_read($wait)) {
        my $read = sysread($fh, my $chunk, 8192);
        if (!defined $read) {
          next;
        }
        if ($read == 0) {
          $selector->remove($fh);
          close $fh;
          $eof = 1;
          next;
        }
        my $remaining = $max - $written;
        if ($read > $remaining) {
          print substr($chunk, 0, $remaining) if $remaining > 0;
          $written += $remaining;
          kill "TERM", -$pid;
          $capped = 1;
          $kill_deadline = time + 0.2;
          $capture_deadline = $kill_deadline + 0.1;
          next;
        }
        print $chunk;
        $written += $read;
      }

      if (!$shell_done && waitpid($pid, WNOHANG) == $pid) {
        $shell_status = $?;
        $shell_done = 1;
      }
    }

    exit 125 if $capped;
    exit 124 if $timed_out;
    exit(128 + ($shell_status & 127)) if $shell_status & 127;
    exit($shell_status >> 8);
  ' "$FM_OPS_INBOX_TIMEOUT" "$FM_OPS_INBOX_OUTPUT_MAX_BYTES" "$command"
}

# fm_ops_inbox_home_records <home> <scan-limit>
# Prints newest-first mtime/path records from a bounded home-inbox scan.
# A final __FM_OPS_INBOX_OVERFLOW__ record means the scan limit was reached.
fm_ops_inbox_home_records() {
  local home=$1 limit=$2 dir path mtime count=0 overflow=0
  local -a records=()
  dir=$(fm_ops_inbox_home_dir "$home")
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' path; do
    if [ "$count" -ge "$limit" ]; then
      overflow=1
      break
    fi
    mtime=$(fm_ops_inbox_stat_mtime "$path") || continue
    records+=("$mtime"$'\t'"$path")
    count=$((count + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 2 -type f -print0 2>/dev/null)
  ((${#records[@]})) && printf '%s\n' "${records[@]}" | LC_ALL=C sort -rn
  [ "$overflow" -eq 0 ] || printf '%s\n' '__FM_OPS_INBOX_OVERFLOW__'
}

fm_ops_inbox_home_marker() {
  local home=$1 dir path sig count=0 overflow=0
  dir=$(fm_ops_inbox_home_dir "$home")
  [ -d "$dir" ] || return 0
  {
    while IFS= read -r -d '' path; do
      if [ "$count" -ge "$FM_OPS_INBOX_MARKER_LIMIT" ]; then
        overflow=1
        break
      fi
      sig=$(fm_ops_inbox_stat_sig "$path") || continue
      printf '%s\t%s\n' "$sig" "$path"
      count=$((count + 1))
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    [ "$overflow" -eq 0 ] || printf '__FM_OPS_INBOX_MARKER_OVERFLOW__:%s\n' "$FM_OPS_INBOX_MARKER_LIMIT"
  } | LC_ALL=C sort
}

fm_ops_inbox_home_has_events() {
  local home=$1 dir
  dir=$(fm_ops_inbox_home_dir "$home")
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -mindepth 1 -maxdepth 2 -type f -print -quit 2>/dev/null)" ]
}

# fm_ops_inbox_has_events <home> <config-dir>
# The configured list-command contract starts with `unacked_criticals: <n>`.
# A malformed or failed configured command is treated as an event so its one
# durable wake cannot be hidden by a bad local seam.
fm_ops_inbox_has_events() {
  local home=$1 config=$2 output rc count
  fm_ops_inbox_home_has_events "$home" && return 0
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
# Hashes local directory markers plus the configured external list output.  The
# fingerprint is safe to persist in state/.hash-ops-inbox as the watcher's
# suppressor.
fm_ops_inbox_fingerprint() {
  local home=$1 config=$2 command output rc
  {
    printf 'home\n'
    fm_ops_inbox_home_marker "$home"
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
