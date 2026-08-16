#!/usr/bin/env bash
# Read-only no-mistakes reviewer/fixer liveness observation for fm-watch.sh.
#
# Why this exists: an active no-mistakes run-step proves custody, not progress.
# A reviewer or fixer can retain an active `running`/`fixing` status while its
# process has stopped producing review output.  This helper persists one
# home-scoped observation per task and returns `stalled` only when the same
# attributed active run, structural status, and active-step log tail have all
# remained unchanged for FM_NOMISTAKES_STALL_SECS (default 1200).  It never
# controls no-mistakes, its daemon, the worker, or the worktree.
#
# The watcher calls this at FM_NOMISTAKES_LIVENESS_INTERVAL (default 60) while
# not in away mode.  A changing status or log tail resets the clock, so slow
# but active reviewers remain untouched.  A parked gate, terminal run,
# unattributed run, absent active step, or unavailable read clears the receipt
# rather than reporting a stall.  The state file is private volatile state:
#   state/.nomistakes-liveness-<task>
# with one line each for run_id, fingerprint, and observed_at.
#
# Source this file after STATE and SCRIPT_DIR are set.  Call
# fm_nomistakes_liveness_observe <task>; it prints exactly one token-tight
# diagnostic line beginning `nomistakes-liveness:` and returns zero for every
# readable or unavailable observation.  The caller owns wake delivery.

FM_NOMISTAKES_LIVENESS_INTERVAL=${FM_NOMISTAKES_LIVENESS_INTERVAL:-60}
case "$FM_NOMISTAKES_LIVENESS_INTERVAL" in ''|*[!0-9]*) FM_NOMISTAKES_LIVENESS_INTERVAL=60 ;; esac
FM_NOMISTAKES_STALL_SECS=${FM_NOMISTAKES_STALL_SECS:-1200}
case "$FM_NOMISTAKES_STALL_SECS" in ''|*[!0-9]*) FM_NOMISTAKES_STALL_SECS=1200 ;; esac
FM_NOMISTAKES_LIVENESS_TIMEOUT=${FM_NOMISTAKES_LIVENESS_TIMEOUT:-10}
case "$FM_NOMISTAKES_LIVENESS_TIMEOUT" in ''|*[!0-9]*) FM_NOMISTAKES_LIVENESS_TIMEOUT=10 ;; esac

fm_nm_liveness_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_nm_liveness_bounded() {  # <worktree> <no-mistakes args...>
  local wt=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$wt" && timeout "$FM_NOMISTAKES_LIVENESS_TIMEOUT" no-mistakes "$@" ) 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    ( cd "$wt" && gtimeout "$FM_NOMISTAKES_LIVENESS_TIMEOUT" no-mistakes "$@" ) 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    ( cd "$wt" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$FM_NOMISTAKES_LIVENESS_TIMEOUT" no-mistakes "$@" ) 2>/dev/null
  else
    return 127
  fi
}

fm_nm_liveness_field() {  # <status-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1 | sed 's/^"//;s/"$//'
}

fm_nm_liveness_active_step() {  # <status-output>
  printf '%s\n' "$1" | awk -F, '
    /^[[:space:]]*steps\[[0-9]+\].*:/ { in_steps = 1; next }
    in_steps && /^[[:space:]]*[A-Za-z][A-Za-z0-9_-]*,[[:space:]]*"?(running|fixing)"?,/ {
      step = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", step)
      print step
      exit
    }
    in_steps && /^[^[:space:]]/ { exit }
  '
}

fm_nm_liveness_receipt() {  # <task>
  printf '%s/.nomistakes-liveness-%s' "$STATE" "$1"
}

fm_nm_liveness_clear() {  # <task>
  rm -f "$(fm_nm_liveness_receipt "$1")"
}

fm_nomistakes_liveness_observe() {  # <task>
  local task=$1 meta wt kind branch head status run_id run_branch run_head run_status step log_tail
  local fingerprint receipt prior_run prior_fingerprint prior_observed now age
  [ -n "$task" ] || { printf '%s\n' 'nomistakes-liveness: unavailable missing-task'; return 0; }
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || { printf '%s\n' 'nomistakes-liveness: unavailable missing-meta'; return 0; }
  kind=$(fm_nm_liveness_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: inactive non-ship'; return 0; }
  wt=$(fm_nm_liveness_meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: unavailable worktree'; return 0; }
  command -v no-mistakes >/dev/null 2>&1 || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: unavailable tool'; return 0; }
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ -n "$branch" ] && [ -n "$head" ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: inactive no-branch'; return 0; }
  status=$(fm_nm_liveness_bounded "$wt" axi status 2>/dev/null || true)
  [ -n "$status" ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: unavailable status'; return 0; }
  run_id=$(fm_nm_liveness_field "$status" id)
  run_branch=$(fm_nm_liveness_field "$status" branch)
  run_head=$(fm_nm_liveness_field "$status" head)
  run_status=$(fm_nm_liveness_field "$status" status)
  if [ -z "$run_id" ] || [ "$run_branch" != "$branch" ] || [ -z "$run_head" ] || \
     ! git -C "$wt" merge-base --is-ancestor "$head" "$run_head" 2>/dev/null; then
    fm_nm_liveness_clear "$task"
    printf '%s\n' 'nomistakes-liveness: inactive unattributed-run'
    return 0
  fi
  case "$run_status" in running|fixing) ;; *)
    fm_nm_liveness_clear "$task"
    printf '%s\n' 'nomistakes-liveness: inactive terminal-or-gate'
    return 0
  esac
  step=$(fm_nm_liveness_active_step "$status")
  [ -n "$step" ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: inactive no-active-step'; return 0; }
  [ "$step" = review ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: inactive non-review-step'; return 0; }
  log_tail=$(fm_nm_liveness_bounded "$wt" axi logs --step "$step" --run "$run_id" 2>/dev/null || true)
  [ -n "$log_tail" ] || { fm_nm_liveness_clear "$task"; printf '%s\n' 'nomistakes-liveness: unavailable step-log'; return 0; }
  # API durations tick without reviewer work.  This deliberately fingerprints
  # only the attributed run identity, active state, and review log tail, so it
  # is a progress receipt rather than a clock receipt.
  fingerprint=$( { printf 'run=%s\nstatus=%s\nstep=%s\n' "$run_id" "$run_status" "$step"; printf '%s\n' "$log_tail"; } | cksum | awk '{print $1 ":" $2}')
  receipt=$(fm_nm_liveness_receipt "$task")
  prior_run=$(sed -n 's/^run_id=//p' "$receipt" 2>/dev/null | head -1)
  prior_fingerprint=$(sed -n 's/^fingerprint=//p' "$receipt" 2>/dev/null | head -1)
  prior_observed=$(sed -n 's/^observed_at=//p' "$receipt" 2>/dev/null | head -1)
  now=$(date +%s)
  case "$prior_observed" in ''|*[!0-9]*) prior_observed=0 ;; esac
  if [ "$prior_run" != "$run_id" ] || [ "$prior_fingerprint" != "$fingerprint" ] || [ "$prior_observed" -eq 0 ]; then
    printf 'run_id=%s\nfingerprint=%s\nobserved_at=%s\n' "$run_id" "$fingerprint" "$now" > "$receipt"
    printf 'nomistakes-liveness: active run=%s step=%s\n' "$run_id" "$step"
    return 0
  fi
  age=$(( now - prior_observed ))
  if [ "$age" -ge "$FM_NOMISTAKES_STALL_SECS" ]; then
    printf 'nomistakes-liveness: stalled run=%s step=%s unchanged=%ss threshold=%ss\n' \
      "$run_id" "$step" "$age" "$FM_NOMISTAKES_STALL_SECS"
  else
    printf 'nomistakes-liveness: quiet run=%s step=%s unchanged=%ss threshold=%ss\n' \
      "$run_id" "$step" "$age" "$FM_NOMISTAKES_STALL_SECS"
  fi
}
