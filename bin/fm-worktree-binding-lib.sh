#!/usr/bin/env bash
# Current task ownership binding for a reusable local worktree.
#
# A state/<id>.meta worktree= value is an allocation record, not proof that the
# path still belongs to that task: pooled worktrees are deliberately recycled.
# This library stores the CURRENT owner in the worktree's private Git directory,
# never in the checked-out project where a reset or commit could preserve it.
# A fresh fm-spawn writes the binding immediately before it publishes metadata.
# Readers and relaunches verify it before trusting the worktree. A relaunch must
# never rewrite it, because doing so could claim a worktree already reassigned
# to another task.
#
# The marker is exactly three lines, atomically replaced by fresh assignment:
#   schema=fm-worktree-binding.v2
#   state=<canonical-state-directory>
#   task_id=<task-id>
#
# Usage: . bin/fm-worktree-binding-lib.sh
#
# Public entry points:
#   fm_worktree_pool_transition_lock_path <state-dir> <project>
#     Resolves the repository-scoped allocation/return lock shared by linked
#     Firstmate homes using one local pool.
#   fm_worktree_record_resolve <meta-file>
#     Resolves only an active worktree pointer; a retired pointer is history.
#   fm_worktree_binding_write <worktree> <state-dir> <task-id>
#     Atomically binds a freshly assigned worktree to its current task.
#   fm_worktree_binding_clear <worktree> <state-dir> <task-id>
#     Clears only an exact current-task binding before returning the copy.
#   fm_worktree_binding_matches <worktree> <state-dir> <task-id>
#     Returns 0 only for an exact, readable binding. Any absent, malformed, or
#     uninterrogable marker returns non-zero; fm_worktree_binding_detail prints
#     its reason, while a different state/task owner reports a mismatch.
#   fm_worktree_binding_is_absent <worktree>
#     Returns 0 only when the private marker is definitely absent. This lets a
#     relaunch backfill a pre-binding record after its endpoint has proved the
#     exact copy, without overwriting a malformed or unreadable marker.
#   fm_worktree_binding_detail
#     Prints the diagnostic for the latest failed read or comparison.

FM_WORKTREE_BINDING_TASK_ID=
FM_WORKTREE_BINDING_STATE=
FM_WORKTREE_BINDING_DETAIL=

fm_worktree_transition_lock_path() {  # <state-dir> <worktree>
  local state=${1-} worktree=${2-} state_real worktree_real digest
  [ -n "$state" ] && [ -d "$state" ] || return 1
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  state_real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || return 1
  worktree_real=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  digest=$(printf '%s' "$worktree_real" | git hash-object --stdin 2>/dev/null) || return 1
  [ -n "$digest" ] || return 1
  printf '%s/.worktree-transition-%s.lock\n' "$state_real" "$digest"
}

fm_worktree_pool_transition_lock_path() {  # <state-dir> <project>
  local state=${1-} project=${2-} project_real common_dir
  [ -n "$state" ] && [ -d "$state" ] || return 1
  [ -n "$project" ] && [ -d "$project" ] || return 1
  project_real=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || return 1
  common_dir=$(git -C "$project_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common_dir" ] && [ -d "$common_dir" ] || return 1
  printf '%s/firstmate-worktree-pool-transition.lock\n' "$common_dir"
}

FM_WORKTREE_RECORD_ACTIVE_PATH=
FM_WORKTREE_RECORD_RETIRED_OWNER=

fm_worktree_record_resolve() {  # <meta-file>
  local meta=${1-}
  FM_WORKTREE_RECORD_ACTIVE_PATH=
  FM_WORKTREE_RECORD_RETIRED_OWNER=
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  FM_WORKTREE_RECORD_RETIRED_OWNER=$(sed -n 's/^worktree_retired=//p' "$meta" | tail -1)
  [ -z "$FM_WORKTREE_RECORD_RETIRED_OWNER" ] || return 1
  FM_WORKTREE_RECORD_ACTIVE_PATH=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
  [ -n "$FM_WORKTREE_RECORD_ACTIVE_PATH" ]
}

fm_worktree_binding_detail() {
  printf '%s' "$FM_WORKTREE_BINDING_DETAIL"
}
fm_worktree_binding_task_id_valid() {  # <task-id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

fm_worktree_binding_state_resolve() {  # <state-dir>
  local state=${1-}
  [ -n "$state" ] && [ -d "$state" ] || return 1
  CDPATH='' cd -- "$state" 2>/dev/null && pwd -P
}

fm_worktree_binding_git_dir() {  # <worktree> -> absolute per-worktree git dir
  local worktree=${1-} git_dir
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -d "$git_dir" ] || return 1
  printf '%s\n' "$git_dir"
}

fm_worktree_binding_read() {  # <worktree>
  local worktree=${1-} git_dir marker line schema='' state='' state_real task_id=''
  local saw_schema=0 saw_state=0 saw_task_id=0
  FM_WORKTREE_BINDING_TASK_ID=
  FM_WORKTREE_BINDING_STATE=
  FM_WORKTREE_BINDING_DETAIL=
  git_dir=$(fm_worktree_binding_git_dir "$worktree") || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: cannot inspect Git metadata for $worktree"
    return 1
  }
  marker="$git_dir/firstmate-task-binding"
  if [ ! -f "$marker" ] || [ -L "$marker" ] || [ ! -r "$marker" ]; then
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: no readable current-task binding for $worktree"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        [ "$saw_schema" -eq 0 ] || {
          FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
          return 1
        }
        schema=${line#schema=}
        saw_schema=1
        ;;
      state=*)
        [ "$saw_state" -eq 0 ] || {
          FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
          return 1
        }
        state=${line#state=}
        saw_state=1
        ;;
      task_id=*)
        [ "$saw_task_id" -eq 0 ] || {
          FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
          return 1
        }
        task_id=${line#task_id=}
        saw_task_id=1
        ;;
      *)
        FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
        return 1
        ;;
    esac
  done < "$marker" || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: unreadable current-task binding for $worktree"
    return 1
  }
  state_real=$(fm_worktree_binding_state_resolve "$state" 2>/dev/null || true)
  if [ "$schema" != fm-worktree-binding.v2 ] \
     || [ "$saw_schema" -ne 1 ] \
     || [ "$saw_state" -ne 1 ] \
     || [ "$saw_task_id" -ne 1 ] \
     || [ -z "$state_real" ] \
     || [ "$state" != "$state_real" ] \
     || ! fm_worktree_binding_task_id_valid "$task_id"; then
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
    return 1
  fi
  FM_WORKTREE_BINDING_STATE=$state_real
  FM_WORKTREE_BINDING_TASK_ID=$task_id
  return 0
}

fm_worktree_binding_matches() {  # <worktree> <expected-state-dir> <expected-task-id>
  local worktree=${1-} expected_state=${2-} expected=${3-} expected_state_real
  expected_state_real=$(fm_worktree_binding_state_resolve "$expected_state" 2>/dev/null) || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: invalid expected state identity"
    return 1
  }
  fm_worktree_binding_task_id_valid "$expected" || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: invalid expected task identity"
    return 1
  }
  fm_worktree_binding_read "$worktree" || return 1
  if [ "$FM_WORKTREE_BINDING_STATE" != "$expected_state_real" ] \
     || [ "$FM_WORKTREE_BINDING_TASK_ID" != "$expected" ]; then
    FM_WORKTREE_BINDING_DETAIL="worktree binding mismatch: meta task $expected in $expected_state_real but worktree is bound to $FM_WORKTREE_BINDING_TASK_ID in $FM_WORKTREE_BINDING_STATE"
    return 1
  fi
  return 0
}

fm_worktree_binding_is_absent() {  # <worktree>
  local worktree=${1-} git_dir marker
  FM_WORKTREE_BINDING_DETAIL=
  git_dir=$(fm_worktree_binding_git_dir "$worktree") || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: cannot inspect Git metadata for $worktree"
    return 1
  }
  marker="$git_dir/firstmate-task-binding"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  FM_WORKTREE_BINDING_DETAIL="worktree binding is present for $worktree"
  return 1
}

fm_worktree_binding_write() {  # <worktree> <state-dir> <task-id>
  local worktree=${1-} state=${2-} task_id=${3-} state_real git_dir marker tmp old_umask
  state_real=$(fm_worktree_binding_state_resolve "$state" 2>/dev/null) || {
    echo "error: refusing to write a worktree binding for an invalid state directory" >&2
    return 1
  }
  fm_worktree_binding_task_id_valid "$task_id" || {
    echo "error: refusing to write a worktree binding for an invalid task id" >&2
    return 1
  }
  git_dir=$(fm_worktree_binding_git_dir "$worktree") || {
    echo "error: cannot inspect Git metadata for worktree '$worktree'; refusing to bind it" >&2
    return 1
  }
  marker="$git_dir/firstmate-task-binding"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$git_dir/.firstmate-task-binding.XXXXXX") || {
    umask "$old_umask"
    echo "error: could not create a temporary worktree binding for '$worktree'" >&2
    return 1
  }
  if ! {
    printf '%s\n' 'schema=fm-worktree-binding.v2'
    printf 'state=%s\n' "$state_real"
    printf 'task_id=%s\n' "$task_id"
  } > "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp" 2>/dev/null || true
    umask "$old_umask"
    echo "error: could not publish the worktree binding for '$worktree'" >&2
    return 1
  fi
  umask "$old_umask"
  return 0
}

fm_worktree_binding_clear() {  # <worktree> <expected-state-dir> <expected-task-id>
  local worktree=${1-} expected_state=${2-} expected=${3-} git_dir marker
  fm_worktree_binding_matches "$worktree" "$expected_state" "$expected" || return 1
  git_dir=$(fm_worktree_binding_git_dir "$worktree") || return 1
  marker="$git_dir/firstmate-task-binding"
  rm -f -- "$marker" || {
    echo "error: could not clear the worktree binding for '$worktree'" >&2
    return 1
  }
}
