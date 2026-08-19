#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
# Resolved once at source time: fm_pid_identity and fm_path_mtime run inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost on
# the platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

# Which stat(1) dialect this host answers with, seeded from the cached uname and
# then corrected by the first successful read. The seed is a preference, never a
# verdict: probing both dialects is what keeps a single failed uname from pinning
# every later read to the wrong one. That failure mode is not hypothetical - a
# uname fork can fail on a loaded machine, and the old Darwin-or-GNU branch then
# ran "stat -c" on macOS, so every mtime read in that process failed and reported
# a perfectly fresh liveness beacon as ancient.
_FM_STAT_MTIME_DIALECT=gnu
[ "$_FM_UNAME" = Darwin ] && _FM_STAT_MTIME_DIALECT=bsd

_fm_stat_mtime_try() {
  local dialect=$1 path=$2 out
  case "$dialect" in
    bsd) out=$(stat -f %m "$path" 2>/dev/null) || return 1 ;;
    *) out=$(stat -c %Y "$path" 2>/dev/null) || return 1 ;;
  esac
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# fm_path_mtime <path>
# Print <path>'s mtime in epoch seconds, or return 1 when it cannot be read.
# Never prints a fabricated value: an unreadable path is the caller's problem to
# report honestly.
fm_path_mtime() {
  local path=$1 other out
  if out=$(_fm_stat_mtime_try "$_FM_STAT_MTIME_DIALECT" "$path"); then
    printf '%s\n' "$out"
    return 0
  fi
  other=bsd
  [ "$_FM_STAT_MTIME_DIALECT" = bsd ] && other=gnu
  if out=$(_fm_stat_mtime_try "$other" "$path"); then
    # The seed was wrong for this host; remember what actually answers so the
    # rest of this process reads the beacon on the first try.
    _FM_STAT_MTIME_DIALECT=$other
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# fm_path_age_measure <path>
# Set FM_PATH_AGE to <path>'s age in seconds and return 0, or return 1 with
# FM_PATH_AGE_MEASURED=false when the mtime cannot be read. Callers that must
# distinguish "this file is old" from "this age could not be measured" use this
# instead of fm_path_age, whose printed sentinel cannot carry that difference.
FM_PATH_AGE=
FM_PATH_AGE_MEASURED=false
fm_path_age_measure() {
  local path=$1 m
  FM_PATH_AGE=
  FM_PATH_AGE_MEASURED=false
  m=$(fm_path_mtime "$path") || return 1
  FM_PATH_AGE=$(( $(date +%s) - m ))
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_PATH_AGE_MEASURED=true
  return 0
}

# fm_path_age <path>
# Print the age in seconds, or the 999999 sentinel when it cannot be measured.
# Kept for callers that only log or compare an age; anything that decides whether
# supervision is present must use fm_path_age_measure instead, because "could not
# measure" and "very old" are different findings and only one of them is a lapse.
fm_path_age() {
  local path=$1
  if fm_path_age_measure "$path"; then
    printf '%s\n' "$FM_PATH_AGE"
  else
    printf '999999\n'
  fi
}

# fm_watcher_lock_unheld <state>
# True when the watcher lock or its symlinked owner directory is absent, or when
# the existing lock records no pid at all. Any non-empty pid remains held here;
# its syntax, liveness, ownership metadata, and identity are health concerns.
fm_watcher_lock_unheld() {
  local state=$1 lockdir pid
  lockdir="$state/.watch.lock"
  [ ! -e "$lockdir" ] && return 0
  [ ! -e "$lockdir/pid" ] && return 0
  pid=$(cat "$lockdir/pid" 2>/dev/null) || return 1
  [ -z "$pid" ]
}

FM_WATCHER_MATCHED_IDENTITY=
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  FM_WATCHER_MATCHED_IDENTITY=
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ] || return 1
  FM_WATCHER_MATCHED_IDENTITY=$lock_identity
}

# fm_watcher_healthy publishes WHICH of its ordered conditions failed, because a
# caller that reports one hardcoded cause for every failure will eventually print
# a self-contradictory line - "no watcher has a fresh beacon (last beat: 41s ago,
# grace 300s)" when the beacon was never the problem. FM_WATCHER_HEALTHY_REASON
# is one of:
#   ok                 a live, identity-matched holder with a fresh beacon
#   no-lock-holder     the lock records no pid at all
#   dead-lock-holder   the recorded pid is not running
#   lock-mismatch      a live pid holds the lock but it is not this home's watcher
#   no-beacon          no beacon file exists at all (no watcher has ever beat)
#   beacon-unreadable  a beacon exists but its age could not be measured; that is
#                      a failure to observe, never evidence that it is old
#   stale-beacon       the holder is live and matched, the beacon is past grace
# FM_WATCHER_HEALTHY_LOCK_PID and FM_WATCHER_HEALTHY_BEACON_AGE carry whatever
# evidence was actually established, and are empty where nothing was measured.
FM_WATCHER_HEALTHY_PID=
FM_WATCHER_HEALTHY_IDENTITY=
FM_WATCHER_HEALTHY_REASON=
FM_WATCHER_HEALTHY_LOCK_PID=
FM_WATCHER_HEALTHY_BEACON_AGE=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid identity
  FM_WATCHER_HEALTHY_PID=
  FM_WATCHER_HEALTHY_IDENTITY=
  FM_WATCHER_HEALTHY_REASON=
  FM_WATCHER_HEALTHY_LOCK_PID=
  FM_WATCHER_HEALTHY_BEACON_AGE=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  FM_WATCHER_HEALTHY_LOCK_PID=$pid
  case "$pid" in
    ''|*[!0-9]*) FM_WATCHER_HEALTHY_REASON='no-lock-holder'; return 1 ;;
  esac
  if ! fm_pid_alive "$pid"; then
    FM_WATCHER_HEALTHY_REASON='dead-lock-holder'
    return 1
  fi
  if ! fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home"; then
    FM_WATCHER_HEALTHY_REASON='lock-mismatch'
    return 1
  fi
  identity=$FM_WATCHER_MATCHED_IDENTITY
  if [ ! -e "$beat" ]; then
    FM_WATCHER_HEALTHY_REASON='no-beacon'
    return 1
  fi
  if ! fm_path_age_measure "$beat"; then
    FM_WATCHER_HEALTHY_REASON='beacon-unreadable'
    return 1
  fi
  FM_WATCHER_HEALTHY_BEACON_AGE=$FM_PATH_AGE
  if [ "$FM_PATH_AGE" -ge "$grace" ]; then
    FM_WATCHER_HEALTHY_REASON='stale-beacon'
    return 1
  fi
  FM_WATCHER_HEALTHY_REASON=ok
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_IDENTITY=$identity
  return 0
}

# In-cycle progress record (state/.watch-progress), written by bin/fm-watch.sh at
# each phase boundary of a supervision cycle. The liveness beacon only advances
# at the TOP of a cycle, so a cycle whose body genuinely takes longer than grace -
# a serial check sweep, a signal-grace linger, and a fleet heartbeat scan on a
# loaded machine - is indistinguishable from an absent watcher by beacon age
# alone. The progress record is what separates them: it advances inside the body.
# Format is one line, "pid=<n> cycle=<n> phase=<name>"; the record's own mtime is
# the authoritative age, so a stopped clock or a torn write cannot age it.
fm_watcher_progress_path() {
  printf '%s/.watch-progress\n' "$1"
}

# fm_watcher_progress_write <state> <pid> <cycle> <phase>
# Best-effort: an observability write must never stall a healthy cycle.
fm_watcher_progress_write() {
  local state=$1 pid=$2 cycle=$3 phase=$4 path
  path=$(fm_watcher_progress_path "$state")
  printf 'pid=%s cycle=%s phase=%s\n' "$pid" "$cycle" "$phase" > "$path" 2>/dev/null || true
}

# fm_watcher_progress_read <state>
# Set FM_WATCHER_PROGRESS_PID/CYCLE/PHASE/AGE and return 0, or return 1 when the
# record is absent, unreadable, or does not name a pid.
FM_WATCHER_PROGRESS_PID=
FM_WATCHER_PROGRESS_CYCLE=
FM_WATCHER_PROGRESS_PHASE=
FM_WATCHER_PROGRESS_AGE=
fm_watcher_progress_read() {
  local state=$1 path line field
  FM_WATCHER_PROGRESS_PID=
  FM_WATCHER_PROGRESS_CYCLE=
  FM_WATCHER_PROGRESS_PHASE=
  FM_WATCHER_PROGRESS_AGE=
  path=$(fm_watcher_progress_path "$state")
  [ -f "$path" ] || return 1
  fm_path_age_measure "$path" || return 1
  FM_WATCHER_PROGRESS_AGE=$FM_PATH_AGE
  line=$(sed -n '1p' "$path" 2>/dev/null) || return 1
  # shellcheck disable=SC2034 # FM_WATCHER_PROGRESS_PHASE is read by callers.
  for field in $line; do
    case "$field" in
      pid=*) FM_WATCHER_PROGRESS_PID=${field#pid=} ;;
      cycle=*) FM_WATCHER_PROGRESS_CYCLE=${field#cycle=} ;;
      phase=*) FM_WATCHER_PROGRESS_PHASE=${field#phase=} ;;
    esac
  done
  case "$FM_WATCHER_PROGRESS_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# How far past grace a demonstrably live and demonstrably progressing watcher may
# fall behind on its beacon before it is treated as down anyway. This is a
# ceiling, not a new grace: nothing below it is tolerated without independent
# proof of both liveness and forward progress.
FM_WATCHER_LATE_MULTIPLIER=${FM_WATCHER_LATE_MULTIPLIER:-3}
case "$FM_WATCHER_LATE_MULTIPLIER" in
  ''|*[!0-9]*|0|1) FM_WATCHER_LATE_MULTIPLIER=3 ;;
esac

# fm_watcher_presence <state> <watch-path> [grace] [home]
# The single owner of "is a watcher process actually there right now", for
# callers that must not mistake a slow cycle for an absent one. Sets:
#   FM_WATCHER_PRESENCE         healthy | late | down
#   FM_WATCHER_PRESENCE_REASON  the fm_watcher_healthy vocabulary above
#   FM_WATCHER_PRESENCE_PID / _IDENTITY / _BEACON_AGE / _PROGRESS_AGE / _CYCLE
# Returns 0 for healthy or late, 1 for down.
#
# "late" requires ALL THREE, and each one independently rules out the failure it
# is there to catch:
#   1. the lock names a LIVE, identity-matched process for this home and this
#      watcher path - an absent, dead, or foreign holder can never be late;
#   2. that same process wrote a progress record within grace - a live but WEDGED
#      watcher stops advancing and is therefore never late, only down;
#   3. the beacon is still inside grace * FM_WATCHER_LATE_MULTIPLIER - an absolute
#      ceiling, so tolerance cannot grow without bound.
fm_watcher_presence() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local ceiling
  FM_WATCHER_PRESENCE=down
  FM_WATCHER_PRESENCE_REASON=
  FM_WATCHER_PRESENCE_PID=
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_WATCHER_PRESENCE_IDENTITY=
  FM_WATCHER_PRESENCE_BEACON_AGE=
  FM_WATCHER_PRESENCE_PROGRESS_AGE=
  FM_WATCHER_PRESENCE_CYCLE=
  if fm_watcher_healthy "$state" "$watch_path" "$grace" "$home"; then
    FM_WATCHER_PRESENCE=healthy
    FM_WATCHER_PRESENCE_REASON=ok
    FM_WATCHER_PRESENCE_PID=$FM_WATCHER_HEALTHY_PID
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_PRESENCE_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
    FM_WATCHER_PRESENCE_BEACON_AGE=$FM_WATCHER_HEALTHY_BEACON_AGE
    return 0
  fi
  FM_WATCHER_PRESENCE_REASON=$FM_WATCHER_HEALTHY_REASON
  FM_WATCHER_PRESENCE_PID=$FM_WATCHER_HEALTHY_LOCK_PID
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_WATCHER_PRESENCE_BEACON_AGE=$FM_WATCHER_HEALTHY_BEACON_AGE
  # Only a stale beacon can be lateness: every other reason means the health
  # check stopped before it ever established a live, identity-matched holder.
  [ "$FM_WATCHER_HEALTHY_REASON" = stale-beacon ] || return 1
  ceiling=$(( grace * FM_WATCHER_LATE_MULTIPLIER ))
  [ "$FM_WATCHER_HEALTHY_BEACON_AGE" -lt "$ceiling" ] || return 1
  fm_watcher_progress_read "$state" || return 1
  FM_WATCHER_PRESENCE_PROGRESS_AGE=$FM_WATCHER_PROGRESS_AGE
  FM_WATCHER_PRESENCE_CYCLE=$FM_WATCHER_PROGRESS_CYCLE
  [ "$FM_WATCHER_PROGRESS_PID" = "$FM_WATCHER_HEALTHY_LOCK_PID" ] || return 1
  [ "$FM_WATCHER_PROGRESS_AGE" -lt "$grace" ] || return 1
  # The identity match above is what established this holder, so reuse it rather
  # than re-reading the lock and risking a different answer.
  # shellcheck disable=SC2034 # Read by callers after the function returns.
  FM_WATCHER_PRESENCE_IDENTITY=$FM_WATCHER_MATCHED_IDENTITY
  FM_WATCHER_PRESENCE=late
  return 0
}

# fm_watcher_healthy is the strictest primitive: true only when a live,
# identity-matched watcher PROCESS holds this home's lock with a beacon inside
# grace. fm_watcher_presence above builds on it for every caller that must decide
# whether a real watcher process is THERE - the arm layer (bin/fm-watch-arm.sh,
# bin/fm-claude-stop-autoarm.sh) and both turn-end guards, which start, attach to,
# replace, or block on a real process, so a leftover beacon must never satisfy
# them and a slow cycle must never be mistaken for an absent one. The pull warning
# (bin/fm-guard.sh) fires mid-turn, where the auto-arm model runs no watcher at
# all, so it wants a different, model-aware question:

# fm_supervision_model
# Print the supervision model of this home's PRIMARY harness:
#   autoarm     Claude's Stop-hook auto-arm and Cursor's stop-hook park: the
#               watcher is armed at each turn end and exits on its wake, so it
#               runs only BETWEEN turns. Mid-turn a fresh beacon with no live
#               watcher process is the healthy state.
#   extension   Pi (and pi-signed): .pi/extensions/fm-primary-pi-watch.ts owns
#               continuity. It tears the watcher down on every actionable wake and
#               spawns the replacement itself, so a genuinely unheld singleton lock
#               is healthy during that hand-off only with extension ownership and a
#               fresh beacon. Any held but unhealthy lock remains down.
#   persistent  every other harness (codex foreground checkpoint, opencode/grok
#               background arm, tmux, unknown): the watcher runs as a tracked live
#               process, so a live identity-matched pid is the real liveness signal.
# FM_SUPERVISION_MODEL overrides detection (tests, and callers that already know
# the harness). Otherwise bin/fm-harness.sh is the single detection owner, so this
# stays consistent with the harness-specific repair line the guards already emit.
fm_supervision_model() {
  local harness
  case "${FM_SUPERVISION_MODEL:-}" in
    autoarm|extension|persistent) printf '%s\n' "$FM_SUPERVISION_MODEL"; return 0 ;;
  esac
  harness=$("$FM_WAKE_LIB_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  case "$harness" in
    claude|cursor) printf 'autoarm\n' ;;
    pi|pi-signed) printf 'extension\n' ;;
    *) printf 'persistent\n' ;;
  esac
}

# Pi primary supervision evidence. The Pi extensions record, in their state
# markers, the exact build they loaded and the session process that loaded it, so
# "a live Pi session owns supervision" is provable from durable state without a
# watcher process and without reading any vendor-rendered surface.
#
# fm_pi_extension_version <file>
# Print the marker version string the Pi extensions record for <file>. Must stay
# byte-identical to the "sha256:<hex>" digest .pi/extensions/fm-primary-pi-watch.ts
# and .pi/extensions/fm-primary-turnend-guard.ts compute for themselves; a host
# with no SHA-256 tool falls back to a form no marker can match, which keeps every
# consumer loud rather than silently satisfied.
fm_pi_extension_version() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

# fm_pi_extension_loaded <marker> <expected-version> <session-lock>
# True when <marker> records <expected-version> and names the session process in
# <session-lock>, i.e. the session holding this home loaded exactly this build.
fm_pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

# fm_pi_extension_owns_supervision <state> <root>
# True when a LIVE Pi session owns supervision continuity for this home: both
# primary extensions are loaded at their current on-disk builds by the process
# recorded in this home's session lock, and that process is still alive.
# Requiring the turn-end guard extension too is deliberate - it is the structural
# backstop that catches a cycle the watch extension failed to restore, so a home
# missing it has no benign hand-off to tolerate.
fm_pi_extension_owns_supervision() {
  local state=$1 root=$2 lock session_pid pair source marker version
  lock="$state/.lock"
  for pair in \
    "fm-primary-pi-watch.ts:.pi-watch-extension-loaded" \
    "fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded"; do
    source=${pair%%:*}
    marker=${pair#*:}
    version=$(fm_pi_extension_version "$root/.pi/extensions/$source") || return 1
    fm_pi_extension_loaded "$state/$marker" "$version" "$lock" || return 1
  done
  session_pid=$(sed -n '1p' "$lock" 2>/dev/null)
  fm_pid_alive "$session_pid"
}

# fm_watcher_supervision_verdict <state> <watch-path> [grace] [home] [root]
# Model-aware "is supervision healthy right now" verdict for the pull warning
# guard (bin/fm-guard.sh), NOT the arm layer or the turn-end guard. Sets:
#   FM_WATCHER_VERDICT_OK      true when supervision is healthy for this model
#   FM_WATCHER_VERDICT_REASON  when not ok, the coarse failing condition:
#                              no-watcher   - a live watcher process is the real
#                                             signal for this model but none holds
#                                             the lock (the beacon is still fresh)
#                              stale-beacon - the beacon is stale beyond grace or
#                                             absent (a genuine supervision lapse)
#   FM_WATCHER_VERDICT_CAUSE   the specific fm_watcher_healthy reason behind it
#                              (no-lock-holder, dead-lock-holder, lock-mismatch,
#                              no-beacon, beacon-unreadable, stale-beacon), so a
#                              banner can name what actually failed, rather than
#                              blaming one hardcoded condition for all of them
#   FM_WATCHER_VERDICT_LATE    true when supervision is present but running a slow
#                              cycle (fm_watcher_presence "late"): degraded, not
#                              off, and never an alarm
#   FM_WATCHER_VERDICT_PID / _BEACON_AGE / _PROGRESS_AGE / _CYCLE
#                              the evidence behind the verdict, empty where the
#                              check stopped before establishing it
# autoarm: a fresh beacon within grace is healthy even with no live watcher,
# because the watcher only runs between turns; only a stale beacon is a lapse.
# extension: a live identity-matched watcher is the ordinary healthy state, but a
# genuinely unheld lock is also healthy while the beacon is fresh AND a live Pi
# session provably owns continuity (fm_pi_extension_owns_supervision) - that is the
# extension's own tear-down-and-respawn hand-off, which it retries and escalates
# itself. A lock with any recorded pid remains down if the strict health check fails.
# Without ownership proof an unheld lock is down exactly as before, so an unloaded,
# version-drifted, or exited Pi session still alarms immediately, and a cycle the
# extension never restores still alarms once the beacon passes grace.
# persistent: require a live identity-matched watcher with a fresh beacon
# (fm_watcher_healthy); a fresh leftover beacon with no live watcher is still down.
# Under every model a "late" presence - a live, identity-matched, still-advancing
# watcher whose beacon slipped past grace inside the bounded ceiling - is degraded
# rather than off, so it never raises the watcher-down alarm.
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_OK=false
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_REASON='stale-beacon'
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_CAUSE=
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_LATE=false
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_PID=
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_BEACON_AGE=
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_PROGRESS_AGE=
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_CYCLE=
fm_watcher_supervision_verdict() {
  local state=$1 watch=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local root=${5:-$FM_ROOT}
  local beat fresh=false measured=false model
  FM_WATCHER_VERDICT_OK=false
  FM_WATCHER_VERDICT_REASON='stale-beacon'
  FM_WATCHER_VERDICT_CAUSE=
  FM_WATCHER_VERDICT_LATE=false
  FM_WATCHER_VERDICT_PID=
  FM_WATCHER_VERDICT_BEACON_AGE=
  FM_WATCHER_VERDICT_PROGRESS_AGE=
  FM_WATCHER_VERDICT_CYCLE=
  beat="$state/.last-watcher-beat"
  if fm_path_age_measure "$beat"; then
    measured=true
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_BEACON_AGE=$FM_PATH_AGE
    [ "$FM_PATH_AGE" -lt "$grace" ] && fresh=true
  fi
  model=$(fm_supervision_model)
  # An unmeasurable beacon is a measurement failure, not evidence of age. Say so
  # rather than reporting a stale beacon nobody actually read; an absent beacon
  # stays its own separate finding.
  if [ "$measured" != true ]; then
    if [ -e "$beat" ]; then
      FM_WATCHER_VERDICT_CAUSE='beacon-unreadable'
    else
      FM_WATCHER_VERDICT_CAUSE='no-beacon'
    fi
  fi
  if [ "$model" = autoarm ]; then
    if [ "$fresh" = true ]; then
      FM_WATCHER_VERDICT_OK=true
      return 0
    fi
    # No live watcher is expected mid-turn under this model, so the beacon is the
    # only signal and the beacon condition stays the reported cause - never the
    # absent lock holder, which is the healthy mid-turn state here. The one
    # exception is a between-turns watcher that is still there and still
    # advancing, just running a cycle longer than grace.
    if fm_watcher_presence "$state" "$watch" "$grace" "$home" \
      && [ "$FM_WATCHER_PRESENCE" = late ]; then
      FM_WATCHER_VERDICT_OK=true
      FM_WATCHER_VERDICT_LATE=true
      FM_WATCHER_VERDICT_PID=$FM_WATCHER_PRESENCE_PID
      FM_WATCHER_VERDICT_PROGRESS_AGE=$FM_WATCHER_PRESENCE_PROGRESS_AGE
      FM_WATCHER_VERDICT_CYCLE=$FM_WATCHER_PRESENCE_CYCLE
      return 0
    fi
    [ "$measured" = true ] && FM_WATCHER_VERDICT_CAUSE='stale-beacon'
    return 0
  fi
  if fm_watcher_presence "$state" "$watch" "$grace" "$home"; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_OK=true
    FM_WATCHER_VERDICT_PID=$FM_WATCHER_PRESENCE_PID
    if [ "$FM_WATCHER_PRESENCE" = late ]; then
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_LATE=true
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_PROGRESS_AGE=$FM_WATCHER_PRESENCE_PROGRESS_AGE
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_CYCLE=$FM_WATCHER_PRESENCE_CYCLE
    fi
    return 0
  fi
  # Which cause is DECISIVE depends on the beacon. A beacon that is not fresh is
  # a lapse under every model on its own, so the beacon condition is what to
  # report. A beacon that IS fresh cannot be the reason anything failed, so the
  # cause must be lock-side - reporting the beacon there is exactly the
  # self-contradicting banner this attribution exists to prevent.
  if [ "$fresh" = true ]; then
    FM_WATCHER_VERDICT_CAUSE=$FM_WATCHER_PRESENCE_REASON
    FM_WATCHER_VERDICT_PID=$FM_WATCHER_PRESENCE_PID
    if [ "$model" = extension ] && fm_watcher_lock_unheld "$state" \
      && fm_pi_extension_owns_supervision "$state" "$root"; then
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_OK=true
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_CAUSE=
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_PID=
    else
      # shellcheck disable=SC2034 # Read by callers after the function returns.
      FM_WATCHER_VERDICT_REASON='no-watcher'
    fi
  elif [ "$measured" = true ]; then
    FM_WATCHER_VERDICT_CAUSE='stale-beacon'
  fi
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/role" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_set_role() {
  local lockdir=$1 role=$2 current pid back
  case "$role" in
    autoarm|terminal-check) : ;;
    *) return 1 ;;
  esac
  current=${BASHPID:-$$}
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 1
  printf '%s\n' "$role" > "$lockdir/role" 2>/dev/null || return 1
  back=$(cat "$lockdir/role" 2>/dev/null || true)
  [ "$back" = "$role" ]
}

fm_lock_role() {
  cat "$1/role" 2>/dev/null
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

FM_RECOVERY_MARKER_TOKEN=
FM_RECOVERY_MARKER_ACTION='none'

fm_recovery_marker_read() {
  local marker=$1 line count
  FM_RECOVERY_MARKER_TOKEN=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  count=$(wc -l < "$marker" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$count" = 1 ] || return 1
  IFS= read -r line < "$marker" || return 1
  case "$line" in
    pending:handling:*|pending:downtime:*|acked:handling:*|acked:downtime:*) ;;
    *) return 1 ;;
  esac
  case "${line##*:}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_RECOVERY_MARKER_TOKEN=$line
}

_fm_atomic_replace() {
  mv -f -- "$1" "$2"
}

_fm_recovery_marker_write_locked() {
  local marker=$1 kind=$2 generation=${3:-} tmp
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || return 1
  [ -n "$generation" ] || generation="$(fm_current_pid).$(date +%s).${tmp##*.}"
  if ! printf 'pending:%s:%s\n' "$kind" "$generation" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Preserve a pending episode's generation across downtime republication so its
# outstanding acknowledgement remains usable; docs/watcher-continuity.md owns
# the recovery contract and sequence-safety rationale.
_fm_recovery_marker_publish() {
  local marker=$1 kind=${2:-downtime} lock saved_token generation=''
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    fm_lock_release "$lock"
    return 1
  fi
  if [ "$kind" = downtime ]; then
    # Read inline rather than in a command substitution: this runs inside the
    # marker-lock critical section, so it must not add a subshell fork there.
    # The token is restored because publishing owns no snapshot of its own.
    saved_token=$FM_RECOVERY_MARKER_TOKEN
    if fm_recovery_marker_read "$marker"; then
      case "$FM_RECOVERY_MARKER_TOKEN" in
        pending:handling:*|pending:downtime:*) generation=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      esac
    fi
    FM_RECOVERY_MARKER_TOKEN=$saved_token
  fi
  if ! _fm_recovery_marker_write_locked "$marker" "$kind" "$generation"; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

_fm_recovery_marker_begin_handling() {
  local marker=$1 expected_generation=${2:-} lock line generation
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker"; then
    fm_lock_release "$lock"
    return 1
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  generation=${line##*:}
  if [ -n "$expected_generation" ] && [ "$generation" != "$expected_generation" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  case "$line" in
    pending:handling:*) ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation"; then
        fm_lock_release "$lock"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="pending:handling:$generation"
      ;;
    *) fm_lock_release "$lock"; return 1 ;;
  esac
  fm_lock_release "$lock"
}

fm_recovery_marker_snapshot() {
  local marker=$1 lock
  FM_RECOVERY_MARKER_TOKEN=
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_recovery_marker_read "$marker" || true
  fm_lock_release "$lock"
}

_fm_recovery_marker_ack() {
  local marker=$1 expected_generation=$2 lock tmp line
  [ -n "$expected_generation" ] || return 2
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker" \
    || [ "${FM_RECOVERY_MARKER_TOKEN##*:}" != "$expected_generation" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:*) line="acked:${line#pending:}" ;;
    acked:*) fm_lock_release "$lock"; return 0 ;;
  esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! printf '%s\n' "$line" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

_fm_recovery_marker_arm_check() {
  local marker=$1 lock line quarantine
  FM_RECOVERY_MARKER_ACTION='none'
  lock="${marker}.lock"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! fm_lock_acquire_wait "$lock"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if [ -s "$FM_WAKE_QUEUE" ]; then
      if ! _fm_recovery_marker_write_locked "$marker" downtime; then
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_ACTION='recover'
    fi
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_recovery_marker_read "$marker"; then
    quarantine=$(mktemp -d "${marker}.invalid.XXXXXX") \
      || {
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      }
    if ! mv -- "$marker" "$quarantine/marker" \
      || ! _fm_recovery_marker_write_locked "$marker" downtime; then
      rmdir "$quarantine" 2>/dev/null || true
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    fi
    FM_RECOVERY_MARKER_ACTION='recover'
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:handling:*)
      FM_RECOVERY_MARKER_ACTION='wait'
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
      ;;
    pending:downtime:*) FM_RECOVERY_MARKER_ACTION='recover' ;;
    acked:*)
      if [ -s "$FM_WAKE_QUEUE" ]; then
        if ! _fm_recovery_marker_write_locked "$marker" downtime; then
          fm_lock_release "$lock"
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          return 1
        fi
        # shellcheck disable=SC2034 # Output read by callers after this function returns.
        FM_RECOVERY_MARKER_ACTION='recover'
      fi
      ;;
  esac
  fm_lock_release "$lock"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_recovery_transition() {
  local marker=$1 action=$2 target=${3:-} value=${4:-}
  case "$action" in
    publish)
      _fm_recovery_marker_publish "$marker" "${target:-downtime}"
      ;;
    acknowledge)
      _fm_recovery_marker_ack "$marker" "$target"
      ;;
    arm-check)
      _fm_recovery_marker_arm_check "$marker"
      ;;
    release-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_release "$target"
      ;;
    release-lock-existing)
      [ -n "$target" ] || return 1
      local lock="${marker}.lock"
      fm_lock_acquire_wait "$lock" || return 1
      if ! fm_recovery_marker_read "$marker"; then
        fm_lock_release "$lock"
        return 1
      fi
      fm_lock_release "$target"
      fm_lock_release "$lock"
      ;;
    clear-stale-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_remove_path "$target"
      ;;
    *) return 2 ;;
  esac
}

fm_recovery_marker_publish() {
  fm_recovery_transition "$1" publish "${2:-downtime}"
}

fm_recovery_marker_ack() {
  fm_recovery_transition "$1" acknowledge "$2"
}

fm_recovery_marker_begin_handling() {
  _fm_recovery_marker_begin_handling "$1" "${2:-}"
}

fm_recovery_marker_arm_check() {
  fm_recovery_transition "$1" arm-check
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=
  FM_LOCK_RECOVERED_PID=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  # Compare against ${BASHPID:-$$} inline, never via a command substitution:
  # $() forks a subshell whose BASHPID is not this frame's pid.
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && [ "$pid" = "${BASHPID:-$$}" ]; then
    # The recorded holder is THIS very process. Single-threaded bash can only
    # observe that when an interrupting trap abandoned the frame that held the
    # lock mid-critical-section (e.g. TERM inside a recovery-marker section,
    # with the EXIT path then re-acquiring the same lock), and every
    # lock-taking trap path in this repo exits rather than resuming the
    # interrupted frame. Spinning here deadlocks the exit path against itself
    # - the hang reproduced by the self-held reclaim regression in
    # tests/fm-wake-queue.test.sh - so reclaim the abandoned hold instead.
    fm_lock_remove_path "$lockdir" || true
    if fm_lock_try_create "$lockdir"; then
      return 0
    fi
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    return 1
  fi
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  if [ "$lockdir" = "$STATE/.watch.lock" ] \
    && ! _fm_recovery_marker_publish "$STATE/.watcher-down" downtime; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
    # shellcheck disable=SC2034 # Read by sourcing callers after lock acquisition.
    FM_LOCK_RECOVERED_PID=$cur
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_meta_lock_path() {
  local meta=$1 dir base id
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  case "$base" in
    *.meta) id=${base%.meta} ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/.meta-%s.lock\n' "$dir" "$id"
}

# fm_task_set_lock_path: the per-home lock guarding WHICH tasks exist in a home,
# as opposed to fm_meta_lock_path, which guards one task's record.
#
# A per-task lock cannot protect a task that does not exist yet. Forced
# secondmate teardown enumerates a home's task set, locks what it found, and
# then re-enumerates while removing; a fresh spawn publishing a record inside
# that window is invisible to the first enumeration and visible to the second,
# so it gets destructively processed while never lifecycle-locked (reproduced
# with real agents: a record published 0.249s after teardown began was removed
# and its worktree returned to the pool, with both commands reporting success).
# Holding this lock from enumeration through cleanup makes the two operations
# serialize: either the spawn publishes first and the teardown's preflight
# covers it, or the teardown owns the set and the spawn refuses. Both directions
# fail closed.
fm_task_set_lock_path() {  # <state-dir>
  local state=$1
  [ -n "$state" ] || return 1
  case "$state" in *[$'\n\r\t']*) return 1 ;; esac
  printf '%s/.task-set.lock\n' "$state"
}

fm_failure_episode_reset() {
  local state=$1 mode=${2:-acquire} lock current pid acquired=0 path
  lock="$state/.turnend-claude-blocks.lock"
  case "$mode" in
    acquire)
      fm_lock_try_acquire "$lock" || return 1
      acquired=1
      ;;
    held)
      current=${BASHPID:-$$}
      pid=$(cat "$lock/pid" 2>/dev/null || true)
      [ "$pid" = "$current" ] || return 1
      ;;
    *) return 1 ;;
  esac
  for path in \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed"
  do
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
      return 1
    fi
  done
  if ! rm -f \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed" \
    2>/dev/null; then
    [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
    return 1
  fi
  [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
  return 0
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  local recovery_marker
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  recovery_marker="$STATE/.watcher-down"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  _fm_recovery_marker_publish "$recovery_marker" downtime || status=$?
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$seq_file" 2>/dev/null || echo 0)
    case "$seq" in
      ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$seq_file" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# fm_wake_queued_keys <kind>
# Print the distinct keys currently queued for <kind>, oldest first. Read under
# the append lock so a concurrent append is never observed half-written. The
# durable queue stays the authority: a key appears here exactly while a record
# for it is queued and unacknowledged, and disappears only after post-handling
# acknowledgement consumes it.
fm_wake_queued_keys() {
  local kind=$1
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_queued_keys: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_wake_queued_keys_locked "$kind"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_wake_queued_keys_locked() {
  local kind=$1
  awk -F '\t' -v kind="$kind" 'NF >= 5 && $3 == kind && !seen[$4]++ { print $4 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || true
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# --- signal announcement signatures -----------------------------------------
#
# The watcher's per-file signal scan (bin/fm-watch.sh scan_signals) detects a
# status or turn-ended change by comparing a size:mtime signature against a
# persisted state/.seen-* marker, and advances that marker only after the change
# has been surfaced to firstmate or deliberately absorbed by the signal triage.
# These three helpers plus the guarded append below are the ONE owner of that
# signature and marker format, shared by the scan itself, by the drain-time
# historical-annotation staleness check, and by this home's own bookkeeping
# writers.

fm_wake_signal_sig() {  # <file> -> "size:mtime"
  if [ "$_FM_UNAME" = Darwin ]; then
    stat -f '%z:%Fm' "$1" 2>/dev/null
  else
    stat -c '%s:%Y' "$1" 2>/dev/null
  fi
}

fm_wake_signal_seen_path() {  # <state> <file>
  printf '%s/.seen-%s' "$1" "$(basename "$2" | tr '.' '_')"
}

# 0 when <file>'s current signature exactly matches its recorded seen marker,
# meaning every byte in it was already surfaced or deliberately absorbed.
# A missing marker or unreadable signature is NOT a match, so uncertainty reads
# as "unannounced bytes present".
fm_wake_signal_seen_current() {  # <state> <file>
  local sig
  sig=$(fm_wake_signal_sig "$2") || return 1
  [ -n "$sig" ] || return 1
  [ "$(cat "$(fm_wake_signal_seen_path "$1" "$2")" 2>/dev/null)" = "$sig" ]
}

# Guarded self-announced status append - the one dedup primitive for a status
# line THIS home's own machinery writes as bookkeeping it has already presented
# in the very turn or tick that writes it (an answerer-closes resolved line, a
# pending-reply escalation close, a captain-held transfer). Such a close must
# not wake the session that wrote it, so this appends the line and then
# advances the watcher's seen marker to cover exactly the appended bytes and
# nothing else. The advance is provenance-gated and fails toward waking:
#   - the marker advances ONLY when the file's pre-append signature matched the
#     recorded seen marker (every earlier byte was already announced or
#     deliberately absorbed), AND the post-append size equals the pre-append
#     size plus exactly the appended bytes (no foreign write interleaved);
#   - on ANY other condition - missing marker, pending foreign bytes, an
#     interleaved writer, an unreadable signature - the line is still appended
#     but the marker is left alone, so the watcher surfaces the file normally.
# A later, different line from any other writer grows the size past the marker
# and wakes as before: task identity alone can never suppress new content.
# Returns 0 appended and self-announced, 1 appended but left for the watcher
# (the safe direction), 2 the append itself failed.
fm_wake_status_append_self_announced() {  # <state> <status-file> <line>
  local state=$1 file=$2 line=$3 marker pre_sig='' post_sig pre_size post_size
  local LC_ALL=C
  marker=$(fm_wake_signal_seen_path "$state" "$file")
  if [ -e "$file" ]; then
    pre_sig=$(fm_wake_signal_sig "$file") || pre_sig=''
  fi
  printf '%s\n' "$line" >> "$file" || return 2
  [ -n "$pre_sig" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$pre_sig" ] || return 1
  post_sig=$(fm_wake_signal_sig "$file") || return 1
  [ -n "$post_sig" ] || return 1
  pre_size=${pre_sig%%:*}
  post_size=${post_sig%%:*}
  case "$pre_size$post_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$post_size" -eq $((pre_size + ${#line} + 1)) ] || return 1
  printf '%s' "$post_sig" > "$marker" 2>/dev/null || return 1
  return 0
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

FM_WAKE_EVENT_LINE=
FM_WAKE_UNREAD_LINES=
fm_wake_status_cursor_offset() {  # <validated-status-path> -> already-presented byte offset
  local path=$1 offset
  command -v status_presentation_cursor_offset >/dev/null 2>&1 || return 1
  offset=$(status_presentation_cursor_offset "$path" 2>/dev/null) || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$offset"
}

# O_NOFOLLOW read of every still-unread status byte. min-offset is the
# already-presented cursor from classify-lib. Lines whose bytes begin before
# that offset are not replayed. Prints nothing and returns 1 when no unread
# non-blank line exists.
fm_wake_unread_events() {  # <validated-status-path> <unused-tail-byte-cap> <min-offset> [<end-offset>]
  local path=$1 min_offset=$3 end_offset=${4:-} result size chunk chunk_start
  local LC_ALL=C
  FM_WAKE_EVENT_LINE=
  FM_WAKE_UNREAD_LINES=
  case "$min_offset" in ''|*[!0-9]*) min_offset=0 ;; esac
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $end) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/ && $start =~ /\A\d+\z/ && $start <= $size;
    $end = $size unless length $end;
    exit 1 unless $end =~ /\A\d+\z/ && $start <= $end && $end <= $size;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $end or exit 1;
    my $remaining = $end - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$min_offset" "$end_offset" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  [ "$min_offset" -lt "$size" ] || return 1
  chunk_start=$min_offset
  FM_WAKE_UNREAD_LINES=$(printf '%s' "$chunk" | LC_ALL=C awk -v start="$chunk_start" -v min="$min_offset" '
    BEGIN { pos = start + 0 }
    {
      line_start = pos
      pos += length($0) + 1
      if ($0 ~ /[^[:space:]]/ && line_start >= min) print $0
    }
  ') || return 1
  [ -n "$FM_WAKE_UNREAD_LINES" ] || return 1
  FM_WAKE_EVENT_LINE=$(printf '%s\n' "$FM_WAKE_UNREAD_LINES" | tail -1)
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
}

fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  fm_wake_unread_events "$1" "$2" 0
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock.
fm_wake_print_annotations() {  # <deduped-raw-rows> [<presentation-snapshot>]
  local rows=$1 snapshot=${2:-} manifest status_key mode path prefix line task endpoint
  local snapshot_task snapshot_endpoint _snapshot_ident offset last_event event_line
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    path="$STATE/$status_key"
    # A turn-ended-only (historical) row's annotation would show unread status
    # lines even when those bytes are fully covered by the seen marker - already
    # surfaced to firstmate or deliberately absorbed by the signal triage.
    # Presenting such an already-announced line again makes a bare turn-end look
    # like fresh progress, so skip the annotation when the status file's
    # signature still matches its marker (a proven replay). Any uncertainty -
    # missing marker, unreadable signature - keeps the annotation with its
    # existing historical caveat. A direct status row is annotated for every
    # still-unread line since the last drain presentation; already-presented
    # bytes are not replayed.
    if [ "$mode" = historical ] && fm_wake_signal_seen_current "$STATE" "$path"; then
      continue
    fi
    offset=$(fm_wake_status_cursor_offset "$path") || return 1
    endpoint=
    if [ -n "$snapshot" ]; then
      task=${status_key%.status}
      while IFS=$(printf '\t') read -r snapshot_task snapshot_endpoint _snapshot_ident; do
        if [ "$snapshot_task" = "$task" ]; then endpoint=$snapshot_endpoint; break; fi
      done <<EOF
$snapshot
EOF
      [ -n "$endpoint" ] || continue
    fi
    if [ -n "$endpoint" ] && [ "$offset" -ge "$endpoint" ]; then continue; fi
    if ! fm_wake_unread_events "$path" 0 "$offset" "$endpoint"; then
      # Annotation enrichment is supplemental to the already-printed durable
      # wake rows. A file that disappears, rotates, or becomes unreadable after
      # the snapshot must not suppress annotations for other status files; the
      # presentation commit will reject a changed snapshot identity.
      continue
    fi
    last_event=$FM_WAKE_EVENT_LINE
    while IFS= read -r event_line || [ -n "$event_line" ]; do
      [ -n "$event_line" ] || continue
      event_line=$(printf '%s' "$event_line" | LC_ALL=C tr '\t\r' '  ')
      prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
      if [ "$event_line" != "$last_event" ]; then
        prefix="wake annotation: unread wake-EVENT since last drain, not current state"
      fi
      if [ "$mode" = historical ]; then
        prefix="$prefix; historical / not necessarily the triggering event"
      fi
      line="$prefix: $status_key: $event_line"
      printf '%s\n' "$line" || return 1
    done <<EOF
$FM_WAKE_UNREAD_LINES
EOF
  done <<EOF
$manifest
EOF

  return 0
}
