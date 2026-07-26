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

fm_ops_inbox_event_is_routine() {
  local path=$1
  dd if="$path" bs="$FM_OPS_INBOX_EVENT_SAMPLE_BYTES" count=1 2>/dev/null \
    | awk '
        /^[[:space:]]*(classification|disposition):[[:space:]]*routine[[:space:]]*$/ { found=1; exit }
        END { exit !found }
      '
}

fm_ops_inbox_event_signal() {
  local path=$1 sample
  fm_ops_inbox_event_is_routine "$path" && return 1
  if ! sample=$(dd if="$path" bs="$FM_OPS_INBOX_EVENT_SAMPLE_BYTES" count=1 2>/dev/null); then
    printf 'home:unreadable:%s\n' "$path"
    return 0
  fi
  printf 'home:'
  printf '%s' "$sample" | fm_ops_inbox_hash
}

# fm_ops_inbox_external_state <config-dir>
# Prints one `<class>\t<count>\t<identity>` record for the configured list
# command and returns 1 when no command is configured.  The class is `ok` for a
# trustworthy zero count, `critical` for a trustworthy nonzero count, and
# `invalid` when the listing itself cannot be believed - a malformed listing,
# or a firstmate-internal timeout (124) or output-cap kill (125) rather than
# the command's own routine nonzero convention.  Every reader of the
# `unacked_criticals: <n>` contract goes through here so the classifiers cannot
# drift.  The identity field is empty for the counted classes because their
# fingerprint identity depends on the caller's escalation watermark.
fm_ops_inbox_external_state() {
  local config=$1 output rc count
  fm_ops_inbox_external_command "$config" >/dev/null || return 1
  output=$(fm_ops_inbox_external_output "$config")
  rc=$?
  case "$rc" in
    124|125) printf 'invalid\t0\texternal:unreachable:%s\n' "$rc"; return 0 ;;
  esac
  count=$(printf '%s\n' "$output" | awk '/^unacked_criticals:[[:space:]]*[0-9]+$/ { sub(/^unacked_criticals:[[:space:]]*/, ""); print; exit }')
  case "$count" in
    ''|*[!0-9]*) printf 'invalid\t0\texternal:invalid:%s:%s\n' "$rc" "$(printf '%s' "$output" | fm_ops_inbox_hash)" ;;
    0) printf 'ok\t0\t\n' ;;
    *) printf 'critical\t%s\t\n' "$count" ;;
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

# fm_ops_inbox_has_genuine_failures <home> <config-dir>
# Routine home events declare `classification: routine` or `disposition:
# routine` within their first sample. The configured list-command contract
# starts with `unacked_criticals: <n>`; its status is not a failure signal when
# the count is zero. A malformed or unreachable list result still surfaces
# because the local failure-reporting seam is no longer trustworthy.
fm_ops_inbox_has_genuine_failures() {
  local home=$1 config=$2 record path state
  while IFS= read -r record; do
    [ "$record" = '__FM_OPS_INBOX_OVERFLOW__' ] && return 0
    path=${record#*$'\t'}
    fm_ops_inbox_event_is_routine "$path" || return 0
  done < <(fm_ops_inbox_home_records "$home" "$FM_OPS_INBOX_MARKER_SCAN_LIMIT")

  state=$(fm_ops_inbox_external_state "$config") || return 1
  [ "${state%%$'\t'*}" = ok ] && return 1
  return 0
}

# fm_ops_inbox_actionable_fingerprint <home> <config-dir> [critical-watermark]
# Prints `<external-class>\t<critical-count>\t<critical-level>\t<hash>` from a
# single external-command invocation, so a caller can both compare the hash and
# report the count movement behind it without running the command twice.  The
# hash covers only genuine failure identities, so copied event records with the
# same body collapse to one wake until the inbox clears, and an event that
# cannot be read keeps a stable path identity instead of vanishing from the
# hash.  The external listing contributes its escalation level rather than its
# raw count: a burst or a falling count stays one identity, while a count above
# the watermark raises the level and wakes once for that escalation.
fm_ops_inbox_actionable_fingerprint() {
  local home=$1 config=$2 watermark=${3:-0}
  local record path signal state class='none' count=0 identity='' level=0 hash
  if state=$(fm_ops_inbox_external_state "$config"); then
    class=${state%%$'\t'*}
    count=${state#*$'\t'}
    count=${count%%$'\t'*}
    identity=${state##*$'\t'}
    level=$(fm_ops_inbox_critical_level "$count" "$watermark")
    if [ "$class" = critical ]; then
      identity="external:critical:$level"
    fi
  fi
  hash=$(
    {
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
    } | LC_ALL=C sort -u | fm_ops_inbox_hash
  )
  printf '%s\t%s\t%s\t%s\n' "$class" "$count" "$level" "$hash"
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
