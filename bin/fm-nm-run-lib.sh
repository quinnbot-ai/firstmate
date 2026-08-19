#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting), fm-nm-liveness-lib.sh (read-only reviewer
# progress observation) and fm-teardown.sh (pre-teardown run abort, see its
# "Fix 1" header comment). Getting this wrong in either direction is unsafe: a
# false negative hides a genuinely parked run, and a false positive lets
# teardown act on a run it does not own.
#
# There are exactly two ways a run binds to a worktree, both owned here and
# combined by fm_nm_run_matches_worktree:
#   1. Code identity by ancestry (fm_nm_head_matches_worktree), the ordinary
#      case where the run head is reachable in this worktree's object store.
#   2. A complete branch_sync custody receipt
#      (fm_nm_pipeline_owned_matches_worktree), for the case where the pipeline
#      owns its gate fixes in an ISOLATED worktree whose current head is
#      deliberately unreachable here, so ancestry cannot decide at all.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Scalar value of a key inside the `branch_sync:` block of captured `axi status`
# output $1. Section $2 is empty for the block's own scalars (state, changed,
# safety) or names a nested section (local, pipeline); key $3 is the field.
# Reads only the branch_sync block, so an identically named key elsewhere in the
# run object can never answer for it.
fm_nm_branch_sync_field() {  # <toon-output> <section> <key>
  printf '%s\n' "$1" | awk -v section="$2" -v key="$3" '
    /^branch_sync:[ \t]*$/ { in_sync = 1; next }
    !in_sync { next }
    /^[^ \t]/ { exit }
    /^[ \t]*$/ { next }
    {
      line = $0
      indent = match(line, /[^ \t]/) - 1
      sub(/^[ \t]+/, "", line)
      name = line
      sub(/:.*$/, "", name)
      value = ""
      if (index(line, ":") > 0) value = substr(line, index(line, ":") + 1)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t]+$/, "", value)
    }
    indent == 2 {
      current = name
      if (section == "" && name == key) { print value; exit }
      next
    }
    indent > 2 && section != "" && current == section && name == key {
      print value
      exit
    }
  '
}

# 0 when two commit ids name the same commit. Either side may be abbreviated, so
# this is a hex prefix comparison with a 7-character floor; anything non-hex or
# shorter cannot identify a commit and never matches.
fm_nm_sha_matches() {  # <sha-a> <sha-b>
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "${#a}" -ge 7 ] && [ "${#b}" -ge 7 ] || return 1
  case "$a" in *[!0-9A-Fa-f]*) return 1 ;; esac
  case "$b" in *[!0-9A-Fa-f]*) return 1 ;; esac
  case "$a" in "$b"*) return 0 ;; esac
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

# 0 when a branch_sync custody receipt binds run <run_head>/<run_id> to worktree
# <worktree> on branch <branch>. Some no-mistakes versions run pipeline-owned
# gate fixes in an isolated worktree, so the run's CURRENT head is intentionally
# absent from this worktree's object database and ancestry cannot establish the
# otherwise-valid binding. The receipt is the explicit custody contract for
# exactly that case, and is accepted only when every one of these holds:
#   - the pipeline still owns a clean crew worktree (state/changed/safety)
#   - the receipt's branch is this worktree's branch
#   - the receipt names THIS run id and reports it still running, so a stale
#     nested receipt cannot rescue an unrelated run
#   - the receipt's local head and submitted head are both exactly this
#     worktree's HEAD, so local work that advanced or diverged is rejected
#   - the receipt's current pipeline head is exactly the top-level run head
#   - git itself confirms the worktree is clean, so a `clean: true` claim that
#     reality contradicts is rejected rather than trusted
#   - the run head is genuinely unresolvable here; a run head this worktree CAN
#     resolve is decided by ancestry alone, so a receipt can never override an
#     ancestry verdict of divergence
fm_nm_pipeline_owned_matches_worktree() {  # <worktree> <branch> <run_id> <run_head> <toon-output>
  local wt=$1 branch=$2 run_id=$3 run_head=$4 out=$5
  local local_head dirty field
  [ -n "$wt" ] && [ -n "$branch" ] && [ -n "$run_id" ] && [ -n "$run_head" ] || return 1
  [ -n "$out" ] || return 1
  local_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  git -C "$wt" rev-parse --verify --quiet "${run_head}^{commit}" >/dev/null 2>&1 && return 1

  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" '' state)")
  [ "$field" = pipeline_owned ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" '' changed)")
  [ "$field" = false ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" '' safety)")
  [ "$field" = blocked_pipeline_owned ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" local branch)")
  [ "$field" = "$branch" ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" local clean)")
  [ "$field" = true ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" pipeline run)")
  [ "$field" = "$run_id" ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" pipeline status)")
  [ "$field" = running ] || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" local head)")
  fm_nm_sha_matches "$field" "$local_head" || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" pipeline submitted_head)")
  fm_nm_sha_matches "$field" "$local_head" || return 1
  field=$(fm_nm_strip_quotes "$(fm_nm_branch_sync_field "$out" pipeline current_head)")
  fm_nm_sha_matches "$field" "$run_head" || return 1

  dirty=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  [ -z "$dirty" ]
}

# 0 when run <run_id>/<run_head> belongs to worktree <worktree> on <branch>, by
# either binding mode above. The single entry point every attribution caller
# should use.
fm_nm_run_matches_worktree() {  # <worktree> <branch> <run_id> <run_head> <toon-output>
  local wt=$1 branch=$2 run_id=$3 run_head=$4 out=$5
  fm_nm_head_matches_worktree "$wt" "$run_head" && return 0
  fm_nm_pipeline_owned_matches_worktree "$wt" "$branch" "$run_id" "$run_head" "$out"
}
