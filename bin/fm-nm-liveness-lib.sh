#!/usr/bin/env bash
# Read-only no-mistakes reviewer/fixer liveness observation.
#
# Why this exists: an active no-mistakes run-step proves CUSTODY, not PROGRESS.
# A reviewer or fixer can hold a `running`/`fixing` status indefinitely after
# its process stopped producing review output, and every other current-state
# source agrees with it, so the crew reads as healthily validating forever.
#
# This observes that one gap and nothing else. It persists a home-private
# progress receipt per task and reports `stalled` only once the SAME attributed
# run, structural status, and active review-step log tail have all stayed
# unchanged for FM_NM_STALL_SECS. It never controls no-mistakes, its shared
# daemon, the run, the worker, or the worktree - a stall is a diagnosis firstmate
# acts on, never an automatic abort.
#
# Attribution is not decided here: fm_nm_run_matches_worktree in
# bin/fm-nm-run-lib.sh remains the ONE owner of branch and code-identity
# matching, so an isolated pipeline-owned run is observed on exactly the same
# terms fm-crew-state.sh reports it.
#
# bin/fm-watch.sh calls fm_nm_liveness_observe every
# FM_NM_LIVENESS_INTERVAL seconds per task while not in away mode; away mode
# owns its own triage. Each call prints exactly one token-tight line beginning
# `nm-liveness:` and returns 0 for every readable OR unavailable observation,
# because an unreadable pipeline is not evidence of a stall. The caller owns
# wake delivery and the one-shot surfacing marker.
#
# Private volatile state, both safe to delete (the clock simply restarts):
#   <state>/.nm-liveness-<task>            run id, fingerprint, observed_at
#   <state>/.nm-liveness-surfaced-<task>   the exact stall line already surfaced
#
# No side effects on source. set -u safe.

_FM_NM_LIVENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$_FM_NM_LIVENESS_LIB_DIR/fm-nm-run-lib.sh"
unset _FM_NM_LIVENESS_LIB_DIR

# Seconds between per-task observations (the watcher's cadence bound).
FM_NM_LIVENESS_INTERVAL=${FM_NM_LIVENESS_INTERVAL:-60}
case "$FM_NM_LIVENESS_INTERVAL" in ''|*[!0-9]*) FM_NM_LIVENESS_INTERVAL=60 ;; esac
# Unchanged attributed review status + log tail before a stall is reported.
FM_NM_STALL_SECS=${FM_NM_STALL_SECS:-1200}
case "$FM_NM_STALL_SECS" in ''|*[!0-9]*) FM_NM_STALL_SECS=1200 ;; esac
# Hard bound on each no-mistakes query this observation makes.
FM_NM_LIVENESS_TIMEOUT=${FM_NM_LIVENESS_TIMEOUT:-10}
case "$FM_NM_LIVENESS_TIMEOUT" in ''|*[!0-9]*) FM_NM_LIVENESS_TIMEOUT=10 ;; esac

# Task ids reach here as state/<task>.meta basenames; normalize the few
# separators that would otherwise escape the marker namespace.
fm_nm_liveness_key() {  # <task>
  printf '%s' "$1" | tr '/:.' '___'
}

fm_nm_liveness_receipt() {  # <state> <task>
  printf '%s/.nm-liveness-%s' "$1" "$(fm_nm_liveness_key "$2")"
}

fm_nm_liveness_surfaced_marker() {  # <state> <task>
  printf '%s/.nm-liveness-surfaced-%s' "$1" "$(fm_nm_liveness_key "$2")"
}

fm_nm_liveness_clear() {  # <state> <task>
  rm -f "$(fm_nm_liveness_receipt "$1" "$2")"
}

# The surfaced stall line for run <run-id>, or nonzero when this task has no
# surfaced stall for that exact run. Read-only; fm-crew-state.sh uses it to
# report the diagnosis, and fm-watch.sh removes the marker when progress resumes.
fm_nm_liveness_stall_for_run() {  # <state> <task> <run-id>
  local run_id=$3 marker line
  [ -n "$run_id" ] || return 1
  marker=$(fm_nm_liveness_surfaced_marker "$1" "$2")
  [ -f "$marker" ] || return 1
  line=$(grep -F "nm-liveness: stalled run=$run_id " "$marker" 2>/dev/null | tail -1) || return 1
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

fm_nm_liveness_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# First step row in the steps[N]{...} table whose status is running or fixing.
fm_nm_liveness_active_step() {  # <toon-output>
  printf '%s\n' "$1" | awk -F, '
    /^[ \t]*steps\[[0-9]+\].*:/ { in_steps = 1; next }
    in_steps && /^[ \t]*[A-Za-z][A-Za-z0-9_-]*,[ \t]*"?(running|fixing)"?,/ {
      step = $1
      gsub(/^[ \t]+|[ \t]+$/, "", step)
      print step
      exit
    }
    in_steps && /^[^ \t]/ { exit }
  '
}

# One observation of <task> in <state>. Prints exactly one nm-liveness: line:
#   stalled ...    the attributed review has not moved for the whole bound
#   quiet ...      unchanged, but still inside the bound
#   active ...     the receipt just advanced (new run, or new evidence)
#   inactive ...   nothing to observe (not a ship task, no attributed run, a
#                  real gate, a terminal run, or no active review step)
#   unavailable .. the observation itself could not be made
# Only `stalled` is actionable; `active` is the caller's signal to clear a
# previously surfaced stall.
fm_nm_liveness_observe() {  # <state> <task>
  local state=$1 task=$2
  local meta wt kind branch out run_id run_branch run_head run_status step log_tail
  local fingerprint receipt prior_run prior_fingerprint prior_observed now age
  [ -n "$state" ] && [ -n "$task" ] || { printf 'nm-liveness: unavailable missing-task\n'; return 0; }
  meta="$state/$task.meta"
  [ -f "$meta" ] || { printf 'nm-liveness: unavailable missing-meta\n'; return 0; }
  kind=$(fm_nm_liveness_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  # Only ship tasks drive a no-mistakes validation of their own worktree, the
  # same boundary fm-crew-state.sh and fm-teardown.sh draw.
  [ "$kind" = ship ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: inactive non-ship\n'; return 0; }
  wt=$(fm_nm_liveness_meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: unavailable worktree\n'; return 0; }
  command -v no-mistakes >/dev/null 2>&1 || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: unavailable tool\n'; return 0; }
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: inactive no-branch\n'; return 0; }
  out=$(fm_nm_run "$wt" "$FM_NM_LIVENESS_TIMEOUT" axi status)
  [ -n "$out" ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: unavailable status\n'; return 0; }
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  if [ -z "$run_id" ] || [ "$run_branch" != "$branch" ] \
    || ! fm_nm_run_matches_worktree "$wt" "$branch" "$run_id" "$run_head" "$out"; then
    fm_nm_liveness_clear "$state" "$task"
    printf 'nm-liveness: inactive unattributed-run\n'
    return 0
  fi
  case "$run_status" in
    running|fixing) ;;
    *) fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: inactive terminal-or-gate\n'; return 0 ;;
  esac
  step=$(fm_nm_liveness_active_step "$out")
  [ -n "$step" ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: inactive no-active-step\n'; return 0; }
  # Scoped deliberately to review: it is the step that can hold custody with a
  # stopped agent. Other steps have their own bounded machinery.
  [ "$step" = review ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: inactive non-review-step\n'; return 0; }
  log_tail=$(fm_nm_run "$wt" "$FM_NM_LIVENESS_TIMEOUT" axi logs --step "$step" --run "$run_id")
  [ -n "$log_tail" ] || { fm_nm_liveness_clear "$state" "$task"; printf 'nm-liveness: unavailable step-log\n'; return 0; }
  # Reported durations tick without any reviewer work, so the fingerprint covers
  # only the attributed run identity, its active state, and the review log tail.
  # That makes it a progress receipt rather than a clock receipt: a slow but
  # working reviewer keeps resetting it.
  fingerprint=$( { printf 'run=%s\nstatus=%s\nstep=%s\n' "$run_id" "$run_status" "$step"; printf '%s\n' "$log_tail"; } \
    | cksum | awk '{print $1 ":" $2}')
  receipt=$(fm_nm_liveness_receipt "$state" "$task")
  prior_run=$(sed -n 's/^run_id=//p' "$receipt" 2>/dev/null | head -1)
  prior_fingerprint=$(sed -n 's/^fingerprint=//p' "$receipt" 2>/dev/null | head -1)
  prior_observed=$(sed -n 's/^observed_at=//p' "$receipt" 2>/dev/null | head -1)
  case "$prior_observed" in ''|*[!0-9]*) prior_observed=0 ;; esac
  now=$(date +%s)
  if [ "$prior_run" != "$run_id" ] || [ "$prior_fingerprint" != "$fingerprint" ] || [ "$prior_observed" -eq 0 ]; then
    printf 'run_id=%s\nfingerprint=%s\nobserved_at=%s\n' "$run_id" "$fingerprint" "$now" > "$receipt"
    printf 'nm-liveness: active run=%s step=%s\n' "$run_id" "$step"
    return 0
  fi
  age=$(( now - prior_observed ))
  if [ "$age" -ge "$FM_NM_STALL_SECS" ]; then
    printf 'nm-liveness: stalled run=%s step=%s unchanged=%ss threshold=%ss\n' \
      "$run_id" "$step" "$age" "$FM_NM_STALL_SECS"
  else
    printf 'nm-liveness: quiet run=%s step=%s unchanged=%ss threshold=%ss\n' \
      "$run_id" "$step" "$age" "$FM_NM_STALL_SECS"
  fi
}
