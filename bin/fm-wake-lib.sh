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
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

# A watch-arm lease binds the harness-tracked relay to the exact watcher it is
# waiting for.  The lock's pid is the arm pid; the extra fields deliberately
# make a recycled pid, a sibling home, or a successor watcher fail closed.
FM_ARM_LEASE_OWNER=
FM_ARM_LEASE_HEALTHY_PID=
fm_arm_lease_owner() {  # <state>
  local lease="$1/.watch-arm.lease"
  if [ -L "$lease" ]; then
    fm_lock_link_owner "$lease"
    return
  fi
  [ -d "$lease" ] && printf '%s\n' "$lease"
}

fm_arm_lease_bind_watcher() {  # <state> <watch-path> <watcher-pid> <home> <watcher-identity>
  local state=$1 watch_path=$2 watcher_pid=$3 home=$4 watcher_identity=$5 bound tmp
  bound="$state/.watch-arm.bound"
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$watcher_pid" "$home" || return 1
  tmp=$(umask 077; mktemp "$state/.watch-arm.bound.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n%s\n%s\n%s\n' "$home" "$watch_path" "$watcher_pid" "$watcher_identity" > "$tmp" \
    || ! mv -f "$tmp" "$bound"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_arm_lease_watcher_bound() {  # <state> <watch-path> <watcher-pid> <home>
  local state=$1 watch_path=$2 watcher_pid=$3 home=$4 bound bound_home bound_path bound_pid bound_identity current
  bound="$state/.watch-arm.bound"
  [ -f "$bound" ] && [ ! -L "$bound" ] || return 1
  {
    IFS= read -r bound_home
    IFS= read -r bound_path
    IFS= read -r bound_pid
    IFS= read -r bound_identity
  } < "$bound" || return 1
  [ "$bound_home" = "$home" ] && [ "$bound_path" = "$watch_path" ] && [ "$bound_pid" = "$watcher_pid" ] || return 1
  current=$(fm_pid_identity "$watcher_pid") || return 1
  [ -n "$bound_identity" ] && [ "$current" = "$bound_identity" ] || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$watcher_pid" "$home"
}

fm_arm_lease_healthy() {  # <state> <watch-path> <watcher-pid> <home> [grace]
  local state=$1 watch_path=$2 watcher_pid=$3 home=$4 grace=${5:-${FM_ARM_LEASE_GRACE:-45}}
  local owner arm_pid arm_identity watcher_identity current_arm current_watcher lease_home lease_path
  FM_ARM_LEASE_HEALTHY_PID=
  owner=$(fm_arm_lease_owner "$state" 2>/dev/null || true)
  [ -n "$owner" ] || return 1
  arm_pid=$(cat "$owner/pid" 2>/dev/null || true)
  arm_identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  lease_home=$(cat "$owner/fm-home" 2>/dev/null || true)
  lease_path=$(cat "$owner/watcher-path" 2>/dev/null || true)
  watcher_identity=$(cat "$owner/watcher-identity" 2>/dev/null || true)
  [ "$lease_home" = "$home" ] && [ "$lease_path" = "$watch_path" ] || return 1
  [ "$(cat "$owner/watcher-pid" 2>/dev/null || true)" = "$watcher_pid" ] || return 1
  [ -n "$arm_identity" ] && [ -n "$watcher_identity" ] || return 1
  current_arm=$(fm_pid_identity "$arm_pid") || return 1
  current_watcher=$(fm_pid_identity "$watcher_pid") || return 1
  [ "$current_arm" = "$arm_identity" ] && [ "$current_watcher" = "$watcher_identity" ] || return 1
  [ "$(fm_path_age "$owner/heartbeat")" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_arm_lease_healthy returns.
  FM_ARM_LEASE_HEALTHY_PID=$arm_pid
}

fm_arm_lease_remove_stale() {  # <state> <watch-path> <watcher-pid> <home> [grace]
  local state=$1 watch_path=$2 watcher_pid=$3 home=$4 grace=${5:-${FM_ARM_LEASE_GRACE:-45}}
  local lease owner pid identity current watcher_pid_bound watcher_identity_bound watcher_current snapshot
  lease="$state/.watch-arm.lease"
  owner=$(fm_arm_lease_owner "$state" 2>/dev/null || true)
  [ -n "$owner" ] || return 1
  snapshot=$(cat "$owner/pid" "$owner/pid-identity" "$owner/fm-home" "$owner/watcher-path" "$owner/watcher-pid" "$owner/watcher-identity" 2>/dev/null || true)
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  watcher_pid_bound=$(cat "$owner/watcher-pid" 2>/dev/null || true)
  watcher_identity_bound=$(cat "$owner/watcher-identity" 2>/dev/null || true)
  watcher_current=$(fm_pid_identity "$watcher_pid_bound" 2>/dev/null || true)
  # A live relay gets a short publication grace, but a stale heartbeat is a
  # failed relay even if its pid still exists and may be wedged.
  if [ "$current" = "$identity" ] \
    && [ "$watcher_current" = "$watcher_identity_bound" ] \
    && [ "$(fm_path_age "$owner/heartbeat")" -lt "$grace" ]; then
    return 1
  fi
  [ "$(cat "$owner/pid" "$owner/pid-identity" "$owner/fm-home" "$owner/watcher-path" "$owner/watcher-pid" "$owner/watcher-identity" 2>/dev/null || true)" = "$snapshot" ] || return 1
  if [ -L "$lease" ]; then
    fm_lock_points_to_owner "$lease" "$owner" || return 1
    rm -f "$lease" 2>/dev/null || return 1
  elif [ "$lease" != "$owner" ]; then
    return 1
  fi
  rm -f "$owner/heartbeat" "$owner/watcher-pid" "$owner/watcher-identity" 2>/dev/null || true
  fm_lock_clean_known_files "$owner"
  rmdir "$owner" 2>/dev/null || true
}

fm_arm_lease_claim() {  # <state> <watch-path> <watcher-pid> <home>
  local state=$1 watch_path=$2 watcher_pid=$3 home=$4 lease owner arm_pid arm_identity watcher_identity
  lease="$state/.watch-arm.lease"
  FM_ARM_LEASE_OWNER=
  # Do not use fm_current_pid through command substitution here: that would
  # identify the short-lived substitution subshell instead of this relay.
  arm_pid=${BASHPID:-$$}
  arm_identity=$(fm_pid_identity "$arm_pid") || return 1
  watcher_identity=$(fm_pid_identity "$watcher_pid") || return 1
  FM_ARM_LEASE_PUBLISH_IDENTITY=$arm_identity
  FM_ARM_LEASE_PUBLISH_HOME=$home
  FM_ARM_LEASE_PUBLISH_WATCH_PATH=$watch_path
  FM_ARM_LEASE_PUBLISH_WATCHER_PID=$watcher_pid
  FM_ARM_LEASE_PUBLISH_WATCHER_IDENTITY=$watcher_identity
  if ! fm_lock_try_acquire "$lease" fm_arm_lease_publish_owner; then
    if fm_arm_lease_healthy "$state" "$watch_path" "$watcher_pid" "$home"; then
      return 2
    fi
    fm_arm_lease_remove_stale "$state" "$watch_path" "$watcher_pid" "$home" || return 1
    fm_lock_try_acquire "$lease" fm_arm_lease_publish_owner || return 1
  fi
  owner=${FM_LOCK_OWNER_DIR:-}
  [ -n "$owner" ] || return 1
  fm_arm_lease_bind_watcher "$state" "$watch_path" "$watcher_pid" "$home" "$watcher_identity" || {
    fm_arm_lease_release "$state" "$owner"
    return 1
  }
  # shellcheck disable=SC2034 # Read by callers after fm_arm_lease_claim returns.
  FM_ARM_LEASE_OWNER=$owner
}

fm_arm_lease_publish_owner() {  # <owner>
  local owner=$1
  printf '%s\n' "$FM_ARM_LEASE_PUBLISH_IDENTITY" > "$owner/pid-identity" \
    && printf '%s\n' "$FM_ARM_LEASE_PUBLISH_HOME" > "$owner/fm-home" \
    && printf '%s\n' "$FM_ARM_LEASE_PUBLISH_WATCH_PATH" > "$owner/watcher-path" \
    && printf '%s\n' "$FM_ARM_LEASE_PUBLISH_WATCHER_PID" > "$owner/watcher-pid" \
    && printf '%s\n' "$FM_ARM_LEASE_PUBLISH_WATCHER_IDENTITY" > "$owner/watcher-identity" \
    && touch "$owner/heartbeat"
}

fm_arm_lease_heartbeat() {  # <state> <owner>
  local state=$1 owner=$2 current stored
  [ "$(fm_arm_lease_owner "$state" 2>/dev/null || true)" = "$owner" ] || return 1
  stored=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$(cat "$owner/pid" 2>/dev/null || true)") || return 1
  [ -n "$stored" ] && [ "$current" = "$stored" ] || return 1
  touch "$owner/heartbeat"
}

fm_arm_lease_release() {  # <state> <owner>
  local state=$1 owner=$2 lease current stored
  lease="$state/.watch-arm.lease"
  [ "$(fm_arm_lease_owner "$state" 2>/dev/null || true)" = "$owner" ] || return 0
  stored=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$(cat "$owner/pid" 2>/dev/null || true)") || return 0
  [ -n "$stored" ] && [ "$current" = "$stored" ] || return 0
  fm_lock_release "$lease"
  rm -f "$owner/heartbeat" "$owner/watcher-pid" "$owner/watcher-identity" 2>/dev/null || true
  fm_lock_clean_known_files "$owner"
  rmdir "$owner" 2>/dev/null || true
}

fm_daemon_lease_publish() {  # <state> <daemon-path> <home> <lock> <owner>
  local state=$1 daemon_path=$2 home=$3 lock=$4 owner=$5 pid stored current
  [ -n "$owner" ] || return 1
  fm_lock_points_to_owner "$lock" "$owner" || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  stored=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$pid") || return 1
  [ -n "$stored" ] && [ "$current" = "$stored" ] || return 1
  printf '%s\n' "$home" > "$owner/fm-home"
  printf '%s\n' "$daemon_path" > "$owner/daemon-path"
  touch "$owner/heartbeat"
}

fm_daemon_lease_healthy() {  # <state> <daemon-path> <home> [grace]
  local state=$1 daemon_path=$2 home=$3 grace=${4:-${FM_DAEMON_LEASE_GRACE:-45}}
  local lock owner pid stored current
  lock="$state/.supervise-daemon.lock"
  owner=$(fm_lock_link_owner "$lock" 2>/dev/null || true)
  [ -n "$owner" ] || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  stored=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$pid") || return 1
  [ -n "$stored" ] && [ "$current" = "$stored" ] || return 1
  [ "$(cat "$owner/fm-home" 2>/dev/null || true)" = "$home" ] || return 1
  [ "$(cat "$owner/daemon-path" 2>/dev/null || true)" = "$daemon_path" ] || return 1
  [ "$(fm_path_age "$owner/heartbeat")" -lt "$grace" ]
}

fm_daemon_lease_heartbeat() {  # <lock> <owner> <identity>
  local lock=$1 owner=$2 identity=$3 pid stored current
  [ -n "$owner" ] && [ -n "$identity" ] || return 1
  fm_lock_points_to_owner "$lock" "$owner" || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  stored=$(cat "$owner/pid-identity" 2>/dev/null || true)
  current=$(fm_pid_identity "$pid") || return 1
  [ "$stored" = "$identity" ] && [ "$current" = "$identity" ] || return 1
  touch "$owner/heartbeat"
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    "$lockdir/watcher-pid" \
    "$lockdir/watcher-identity" \
    "$lockdir/daemon-path" \
    "$lockdir/heartbeat" \
    2>/dev/null || true
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
  local lockdir=$1 allowed_steal_owner=${2:-} owner_prepare=${3:-} ownerdir
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
  if [ -n "$owner_prepare" ] && ! "$owner_prepare" "$ownerdir"; then
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

fm_lock_try_acquire() {
  local lockdir=$1 owner_prepare=${2:-} pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir" '' "$owner_prepare"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
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

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner" "$owner_prepare"; then
    rc=0
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

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
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
FM_WAKE_EVENT_TRUNCATED=false
fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  local path=$1 tail_bytes=$2 result size chunk record line_number
  FM_WAKE_EVENT_LINE=
  FM_WAKE_EVENT_TRUNCATED=false
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $limit) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/;
    my $start = $size > $limit ? $size - $limit : 0;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $size or exit 1;
    my $remaining = $size - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$tail_bytes" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  record=$(printf '%s' "$chunk" | LC_ALL=C awk '
    /[^[:space:]]/ { line = $0; line_number = NR }
    END { if (line_number) printf "%d\t%s", line_number, line }
  ') || return 1
  [ -n "$record" ] || return 1
  line_number=${record%%	*}
  FM_WAKE_EVENT_LINE=${record#*	}
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
  if [ "$size" -gt "$tail_bytes" ] && [ "$line_number" -eq 1 ]; then
    FM_WAKE_EVENT_TRUNCATED=true
  fi
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock. The limits are constants,
# so status-file volume cannot turn a drain into an unbounded context read.
fm_wake_print_annotations() {  # <deduped-raw-rows>
  local rows=$1 manifest status_key mode path prefix line suffix keep bytes
  local output='' used=0 omitted=0 read_omitted=0 annotation_marker marker_reserve=192
  local tail_bytes=8192 item_bytes=2048 global_bytes=8192 read_cap=8 reads=0
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
    if [ "$reads" -ge "$read_cap" ]; then
      read_omitted=$((read_omitted + 1))
      continue
    fi
    reads=$((reads + 1))
    path="$STATE/$status_key"
    fm_wake_latest_event "$path" "$tail_bytes" || continue
    prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
    if [ "$mode" = historical ]; then
      prefix="$prefix; historical / not necessarily the triggering event"
    fi
    line="$prefix: $status_key: $FM_WAKE_EVENT_LINE"
    suffix=''
    [ "$FM_WAKE_EVENT_TRUNCATED" = false ] || suffix=' [truncated]'
    line="$line$suffix"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes + marker_reserve)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
  done <<EOF
$manifest
EOF

  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $omitted annotations omitted (global enrichment byte cap)"
    printf '%s\n' "$annotation_marker"
  fi
  if [ "$read_omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $read_omitted annotations omitted (enrichment read cap)"
    printf '%s\n' "$annotation_marker"
  fi
  return 0
}
