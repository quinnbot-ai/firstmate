#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# --- lock-holder classification ---------------------------------------------
#
# fm_harness_pid_alive above answers "is this pid a process I can RECOGNIZE as a
# harness?". That is a name-pattern question, and a name pattern can only ever
# produce evidence FOR a match. Its no-match result is ambiguous: the pid may be
# dead, or it may be a perfectly live session this table cannot name - launched
# through a generated wrapper script, renamed by its installer, or running a
# harness that has not been added to FM_HARNESS_RE yet. Treating that ambiguity
# as "dead" is what lets one session reclaim a live session's lock and put two
# writers on the same home.
#
# The reclaim decision therefore does not use the name pattern as its authority.
# It asks four questions in order of strength - is the pid gone, is it a
# recognized harness, is it too young to have written this lock, is it our own
# lineage - and only the strongest available answer decides. When none of them
# settles the question, the holder is left alone.

# Elapsed seconds for <pid>, or return 1 when it cannot be read.
#
# ps etime is used rather than lstart because its [[dd-]hh:]mm:ss form is
# locale-invariant on both macOS and procps, while lstart's date string is not:
# an identity written under one locale and re-read under another (ko_KR, say)
# mismatches and would reject a live holder. Elapsed time answers the only
# question asked of it below - "did this process exist before that file was
# written?" - without any date parsing at all.
fm_process_elapsed_seconds() {  # <pid>
  local pid=$1 raw days=0 hours=0 mins=0 secs=0 rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  raw=$(LC_ALL=C ps -p "$pid" -o etime= 2>/dev/null) || return 1
  raw=${raw//[[:space:]]/}
  [ -n "$raw" ] || return 1
  case "$raw" in
    *-*) days=${raw%%-*}; rest=${raw#*-} ;;
    *) rest=$raw ;;
  esac
  case "$rest" in
    *:*:*) hours=${rest%%:*}; rest=${rest#*:}; mins=${rest%%:*}; secs=${rest##*:} ;;
    *:*) mins=${rest%%:*}; secs=${rest##*:} ;;
    *) return 1 ;;
  esac
  # Strip leading zeros so 08 is not read as an invalid octal literal.
  days=$((10#${days:-0})); hours=$((10#${hours:-0}))
  mins=$((10#${mins:-0})); secs=$((10#${secs:-0}))
  printf '%s\n' "$(( days * 86400 + hours * 3600 + mins * 60 + secs ))"
}

# True when <pid> is too YOUNG to have written the file <path>: it started after
# that file was last written, so whatever wrote the file was some other process
# and this pid is a recycled number.
#
# This is the signal that keeps an unrecognized-but-live holder from wedging the
# home forever. A recycled pid is necessarily younger than the lock, because the
# process that wrote the lock had to die before its number could be reissued.
# Unreadable inputs return 1, which keeps the holder protected rather than
# reclaimed.
fm_pid_started_after_file() {  # <pid> <path>
  local pid=$1 path=$2 elapsed now mtime lock_age
  elapsed=$(fm_process_elapsed_seconds "$pid") || return 1
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$path" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$path" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  lock_age=$(( now - mtime ))
  # Both clocks are whole seconds, so require a clear margin rather than a bare
  # inequality: a process that started in the same second the lock was written
  # stays protected.
  [ "$lock_age" -gt "$(( elapsed + 1 ))" ]
}

# True when <pid> appears anywhere in THIS process's parent chain.
#
# Unlike fm_harness_ancestry_pids this walk does not stop at the first
# non-harness hop, because the question is plain lineage, not harness identity:
# a lock naming an inner shell of our own session must be recognized as ours.
# A competing session can never satisfy this - if it were our ancestor it would
# be the session that launched us.
fm_pid_is_own_ancestor() {  # <pid>
  local target=$1 walk=$$ hops=0
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$hops" -lt 32 ]; do
    [ "$walk" != "$target" ] || return 0
    walk=$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d '[:space:]')
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    [ "$walk" -gt 1 ] || return 1
    hops=$((hops + 1))
  done
  return 1
}

# Classify the holder recorded in lock file <path>. Prints exactly one of:
#
#   free          no lock file, or it records no pid at all
#   malformed     the lock file exists but does not record a plain pid
#   live          the pid is alive AND identifiable as a verified harness
#   unidentified  the pid is ALIVE but no name pattern recognizes it, and it
#                 belongs to no session we can account for; it may be a live
#                 session this table cannot name, so it is NOT reclaimable
#   self-inner    the pid is ALIVE and unrecognized, but it is THIS process's own
#                 ancestor - an inner shell of our own session that wrote the
#                 lock under its own pid. Reclaimable: re-pointing the lock at the
#                 real harness pid is a correction, not a takeover.
#   stale         the pid is gone, or it is a recycled number too young to have
#                 written this lock; safe to reclaim
#
# `unidentified` is the whole point of this function: it is the case the old
# single boolean folded into "dead", and it is reported separately so callers
# refuse and say why, instead of silently taking a live session's home.
fm_session_lock_holder_state() {  # <lock-path>
  local lock=$1 pid
  [ -f "$lock" ] || { printf 'free\n'; return 0; }
  pid=$(cat "$lock" 2>/dev/null) || { printf 'malformed\n'; return 0; }
  pid=${pid//[[:space:]]/}
  [ -n "$pid" ] || { printf 'free\n'; return 0; }
  case "$pid" in *[!0-9]*) printf 'malformed\n'; return 0 ;; esac
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'stale\n'
    return 0
  fi
  if fm_harness_pid_alive "$pid"; then
    printf 'live\n'
    return 0
  fi
  # Alive, but unrecognized. Only strictly stronger evidence than the name may
  # downgrade this to something reclaimable.
  if fm_pid_started_after_file "$pid" "$lock"; then
    printf 'stale\n'
  elif fm_pid_is_own_ancestor "$pid"; then
    printf 'self-inner\n'
  else
    printf 'unidentified\n'
  fi
}

# True when the classifier's verdict permits this session to claim the lock.
# Reclaiming our own session's inner pid is a correction; taking a lock from a
# process we cannot account for is not.
fm_session_lock_state_permits_claim() {  # <state>
  case "$1" in
    stale|self-inner) return 0 ;;
    *) return 1 ;;
  esac
}
