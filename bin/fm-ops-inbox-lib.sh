#!/usr/bin/env bash
# Shared read-only operations-inbox discovery for the session-start digest and
# watcher.  The home directory is $FM_HOME/ops-inbox; an optional local
# config/ops-inbox-cmd supplies one prompt list-only command for a machine
# inbox.  Watcher fingerprints stat at most 64 entries from a 256-file
# early-cutoff scan, with both bounds configurable below.  This file
# owns the config seam and fingerprint mechanics.

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

fm_ops_inbox_home_marker_path() {
  printf '%s/.fm-ops-inbox.marker\n' "$(fm_ops_inbox_home_dir "$1")"
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
FM_OPS_INBOX_MARKER_LIMIT=${FM_OPS_INBOX_MARKER_LIMIT:-64}
case "$FM_OPS_INBOX_MARKER_LIMIT" in ''|*[!0-9]*|0) FM_OPS_INBOX_MARKER_LIMIT=64 ;; esac
FM_OPS_INBOX_MARKER_SCAN_LIMIT=${FM_OPS_INBOX_MARKER_SCAN_LIMIT:-256}
case "$FM_OPS_INBOX_MARKER_SCAN_LIMIT" in ''|*[!0-9]*|0) FM_OPS_INBOX_MARKER_SCAN_LIMIT=256 ;; esac
FM_OPS_INBOX_EVENT_SAMPLE_BYTES=${FM_OPS_INBOX_EVENT_SAMPLE_BYTES:-4096}
case "$FM_OPS_INBOX_EVENT_SAMPLE_BYTES" in ''|*[!0-9]*|0) FM_OPS_INBOX_EVENT_SAMPLE_BYTES=4096 ;; esac
FM_OPS_INBOX_SUPPRESSION_LIMIT=${FM_OPS_INBOX_SUPPRESSION_LIMIT:-10}
case "$FM_OPS_INBOX_SUPPRESSION_LIMIT" in ''|*[!0-9]*|0) FM_OPS_INBOX_SUPPRESSION_LIMIT=10 ;; esac
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
          if (!$capped) {
            kill "TERM", -$pid;
            $capped = 1;
            $kill_deadline = time + 0.2;
            $capture_deadline = $kill_deadline + 0.1;
          }
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
# Prints mtime-ordered path records from a bounded home-inbox scan.
# A final __FM_OPS_INBOX_OVERFLOW__ record means the scan limit was reached.
fm_ops_inbox_home_records() {
  local home=$1 limit=$2 dir marker path mtime count=0 overflow=0
  local -a records=()
  dir=$(fm_ops_inbox_home_dir "$home")
  marker=$(fm_ops_inbox_home_marker_path "$home")
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' path; do
    [ "$path" = "$marker" ] && continue
    if [ "$count" -ge "$limit" ]; then
      overflow=1
      break
    fi
    count=$((count + 1))
    mtime=$(fm_ops_inbox_stat_mtime "$path") || continue
    records+=("$mtime"$'\t'"$path")
  done < <(find "$dir" -mindepth 1 -maxdepth 2 -type f -print0 2>/dev/null)
  ((${#records[@]})) && printf '%s\n' "${records[@]}" | LC_ALL=C sort -rn
  [ "$overflow" -eq 0 ] || printf '%s\n' '__FM_OPS_INBOX_OVERFLOW__'
}

fm_ops_inbox_home_marker() {
  local home=$1 marker record path sig count=0 selected_overflow=0 scan_overflow=0
  marker=$(fm_ops_inbox_home_marker_path "$home")
  if [ -f "$marker" ]; then
    sig=$(fm_ops_inbox_stat_sig "$marker") || return 1
    printf '%s\t%s\n' "$sig" "$marker"
  fi
  while IFS= read -r record; do
    case "$record" in
      __FM_OPS_INBOX_OVERFLOW__)
        scan_overflow=1
        continue
        ;;
    esac
    if [ "$count" -ge "$FM_OPS_INBOX_MARKER_LIMIT" ]; then
      selected_overflow=1
      continue
    fi
    path=${record#*$'\t'}
    sig=$(fm_ops_inbox_stat_sig "$path") || continue
    printf '%s\t%s\n' "$sig" "$path"
    count=$((count + 1))
  done < <(fm_ops_inbox_home_records "$home" "$FM_OPS_INBOX_MARKER_SCAN_LIMIT")
  if [ "$selected_overflow" -ne 0 ] || [ "$scan_overflow" -ne 0 ]; then
    printf '%s\n' '__FM_OPS_INBOX_MARKER_OVERFLOW__'
  fi
}

# fm_ops_inbox_sample_is_routine <sample>
# Matches the routine declaration against a sample already in memory, so an
# event file is read once for both its classification and its identity and the
# two can never come from different bodies.
fm_ops_inbox_sample_is_routine() {
  local sample=$1 blank=$'[ \t\r]' pattern
  pattern=$'\n'"$blank"'*(classification|disposition):'"$blank"'*routine'"$blank"'*'$'\n'
  [[ $'\n'$sample$'\n' =~ $pattern ]]
}

fm_ops_inbox_event_signal() {
  local path=$1 sample
  if ! sample=$(dd if="$path" bs="$FM_OPS_INBOX_EVENT_SAMPLE_BYTES" count=1 2>/dev/null); then
    printf 'home:unreadable:%s\n' "$path"
    return 0
  fi
  fm_ops_inbox_sample_is_routine "$sample" && return 1
  printf 'home:'
  printf '%s' "$sample" | fm_ops_inbox_hash
}

# fm_ops_inbox_external_reading <config-dir>
# Runs the configured list command exactly once and prints the whole reading:
# a header line, then the command's raw output.  The header is `absent` when no
# command is configured, otherwise `configured\t<class>\t<count>\t<rc>\t<identity>`.
# The class is `ok` for a trustworthy zero count, `critical` for a trustworthy
# nonzero count, and `invalid` when the listing itself cannot be believed - a
# malformed listing, or reserved status 124 or 125.
# Those statuses represent Firstmate's timeout and output-cap kill, so they fail
# closed even when the configured command itself returns one.
# The identity is empty for the counted classes because their fingerprint depends
# on the caller's escalation watermark.  Every derived value - the cheap
# fingerprint segment, the genuineness decision, the escalation identity - is
# computed from one reading, so a supervision cycle can neither mix two
# readings of the same inbox nor pay for the command twice.
fm_ops_inbox_external_reading() {
  local config=$1 output rc class count identity=''
  fm_ops_inbox_external_command "$config" >/dev/null || { printf 'absent\n'; return 0; }
  output=$(fm_ops_inbox_external_output "$config")
  rc=$?
  count=$(printf '%s\n' "$output" | awk '/^unacked_criticals:[[:space:]]*[0-9]+$/ { sub(/^unacked_criticals:[[:space:]]*/, ""); print; exit }')
  case "$rc" in
    124|125) class=invalid; count=0; identity="external:unreachable:$rc" ;;
    *)
      case "$count" in
        ''|*[!0-9]*)
          class=invalid
          count=0
          identity="external:invalid:$rc:$(printf '%s' "$output" | fm_ops_inbox_hash)"
          ;;
        0) class=ok ;;
        *) class=critical ;;
      esac
      ;;
  esac
  printf 'configured\t%s\t%s\t%s\t%s\n%s\n' "$class" "$count" "$rc" "$identity" "$output"
}

# fm_ops_inbox_reading_output <reading>
# Prints the command output carried by a reading, empty when it has none.
fm_ops_inbox_reading_output() {
  case "$1" in
    *$'\n'*) printf '%s\n' "${1#*$'\n'}" ;;
    *) printf '\n' ;;
  esac
}

# fm_ops_inbox_critical_level <count> <watermark>
# Prints the escalation level of a critical count against the watermark the
# caller persisted.  A zero count closes the escalation window and clears the
# watermark; inside an open window only a count above the watermark raises the
# level.  A burst or a falling count therefore keeps one identity, while every
# rise still produces a new one.
fm_ops_inbox_critical_level() {
  local count=$1 watermark=$2
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$watermark" in ''|*[!0-9]*) watermark=0 ;; esac
  if [ "$count" -eq 0 ] || [ "$count" -gt "$watermark" ]; then
    printf '%s\n' "$count"
  else
    printf '%s\n' "$watermark"
  fi
}

# fm_ops_inbox_actionable_fingerprint <home> <config-dir> [critical-watermark] [reading]
# Prints `<genuine>\t<external-class>\t<critical-count>\t<critical-level>\t<hash>`
# from one reading of both sources, so a caller decides suppression, reports the
# count movement behind it, and persists the escalation watermark from a single
# consistent observation.  A genuine failure is exactly a non-empty actionable
# signal set: a home overflow, any retained home event that does not declare
# itself routine (including one whose sample cannot be read), or an external
# listing that is critical or untrustworthy.  The hash covers only those
# identities, so copied event records with the same sampled body collapse to
# one wake until the inbox clears.
# The external listing contributes its escalation level rather than its raw
# count: a burst or a falling count stays one identity, while a count above the
# watermark raises the level and wakes once for that escalation.
fm_ops_inbox_actionable_fingerprint() {
  local home=$1 config=$2 watermark=${3:-0} reading=${4:-}
  local record path signal header class='none' count=0 identity='' level=0
  local hash signals='' genuine=no
  [ -n "$reading" ] || reading=$(fm_ops_inbox_external_reading "$config")
  header=${reading%%$'\n'*}
  if [ "${header%%$'\t'*}" = configured ]; then
    record=${header#*$'\t'}
    class=${record%%$'\t'*}
    record=${record#*$'\t'}
    count=${record%%$'\t'*}
    record=${record#*$'\t'}
    identity=${record#*$'\t'}
    level=$(fm_ops_inbox_critical_level "$count" "$watermark")
    if [ "$class" = critical ]; then
      identity="external:critical:$level"
    fi
  fi
  signals=$(
    while IFS= read -r record; do
      if [ "$record" = '__FM_OPS_INBOX_OVERFLOW__' ]; then
        printf '%s\n' 'home:overflow'
        continue
      fi
      path=${record#*$'\t'}
      signal=$(fm_ops_inbox_event_signal "$path") || continue
      printf '%s\n' "$signal"
    done < <(fm_ops_inbox_home_records "$home" "$FM_OPS_INBOX_MARKER_SCAN_LIMIT")
    [ -n "$identity" ] && printf '%s\n' "$identity"
  )
  [ -n "$signals" ] && genuine=yes
  hash=$(printf '%s\n' "$signals" | LC_ALL=C sort -u | fm_ops_inbox_hash)
  printf '%s\t%s\t%s\t%s\t%s\n' "$genuine" "$class" "$count" "$level" "$hash"
}

# fm_ops_inbox_fingerprint <home> <config-dir> [reading]
# Hashes local directory markers plus the configured external list output.  The
# fingerprint is safe to persist in state/.hash-ops-inbox as the watcher's
# suppressor.  A caller that already holds this cycle's reading passes it in so
# the command is not run a second time.
fm_ops_inbox_fingerprint() {
  local home=$1 config=$2 reading=${3:-} command header record rc
  [ -n "$reading" ] || reading=$(fm_ops_inbox_external_reading "$config")
  header=${reading%%$'\n'*}
  {
    printf 'home\n'
    fm_ops_inbox_home_marker "$home"
    if [ "${header%%$'\t'*}" = configured ] && command=$(fm_ops_inbox_external_command "$config"); then
      record=${header#*$'\t'}
      record=${record#*$'\t'}
      record=${record#*$'\t'}
      rc=${record%%$'\t'*}
      printf 'external:configured:%s\n' "$command"
      printf 'external:exit:%s\n%s\n' "$rc" "$(fm_ops_inbox_reading_output "$reading")"
    else
      printf 'external:absent\n'
    fi
  } | fm_ops_inbox_hash
}
