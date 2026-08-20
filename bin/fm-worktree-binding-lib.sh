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
# The marker is exactly two lines, atomically replaced by fresh assignment:
#   schema=fm-worktree-binding.v1
#   task_id=<task-id>
#
# Usage: . bin/fm-worktree-binding-lib.sh
#
# Public entry points:
#   fm_worktree_binding_write <worktree> <task-id>
#     Atomically binds a freshly assigned worktree to its current task.
#   fm_worktree_binding_matches <worktree> <task-id>
#     Returns 0 only for an exact, readable binding. Any absent, malformed, or
#     uninterrogable marker returns non-zero; fm_worktree_binding_detail prints
#     its reason, while an exact but different task id reports a mismatch.
#   fm_worktree_binding_detail
#     Prints the diagnostic for the latest failed read or comparison.

FM_WORKTREE_BINDING_TASK_ID=
FM_WORKTREE_BINDING_DETAIL=

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

fm_worktree_binding_git_dir() {  # <worktree> -> absolute per-worktree git dir
  local worktree=${1-} git_dir
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -d "$git_dir" ] || return 1
  printf '%s\n' "$git_dir"
}

fm_worktree_binding_read() {  # <worktree>
  local worktree=${1-} git_dir marker line schema='' task_id=''
  local saw_schema=0 saw_task_id=0
  FM_WORKTREE_BINDING_TASK_ID=
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
  if [ "$schema" != fm-worktree-binding.v1 ] \
     || [ "$saw_schema" -ne 1 ] \
     || [ "$saw_task_id" -ne 1 ] \
     || ! fm_worktree_binding_task_id_valid "$task_id"; then
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: malformed current-task binding for $worktree"
    return 1
  fi
  FM_WORKTREE_BINDING_TASK_ID=$task_id
  return 0
}

fm_worktree_binding_matches() {  # <worktree> <expected-task-id>
  local worktree=${1-} expected=${2-}
  fm_worktree_binding_task_id_valid "$expected" || {
    FM_WORKTREE_BINDING_DETAIL="worktree binding unverifiable: invalid expected task identity"
    return 1
  }
  fm_worktree_binding_read "$worktree" || return 1
  if [ "$FM_WORKTREE_BINDING_TASK_ID" != "$expected" ]; then
    FM_WORKTREE_BINDING_DETAIL="worktree binding mismatch: meta task $expected but worktree is bound to $FM_WORKTREE_BINDING_TASK_ID"
    return 1
  fi
  return 0
}

fm_worktree_binding_write() {  # <worktree> <task-id>
  local worktree=${1-} task_id=${2-} git_dir marker tmp old_umask
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
    printf '%s\n' 'schema=fm-worktree-binding.v1'
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
