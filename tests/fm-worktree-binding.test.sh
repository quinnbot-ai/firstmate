#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-binding-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-binding)

fm_task_set_lock_path() {
  printf '%s/.task-set.lock\n' "$1"
}

fm_lock_acquire_wait() {
  return 0
}

fm_lock_release() {
  return 0
}

test_binding_publication_rejects_non_regular_markers() {
  local project worktree state git_dir marker target out status
  project="$TMP_ROOT/project"
  worktree="$TMP_ROOT/worktree"
  state="$TMP_ROOT/state"
  mkdir -p "$state"
  fm_git_worktree "$project" "$worktree" binding-targets
  git_dir=$(fm_worktree_binding_git_dir "$worktree") \
    || fail "could not resolve the fixture worktree Git directory"
  marker="$git_dir/firstmate-task-binding"

  mkdir "$marker"
  set +e
  out=$(fm_worktree_binding_write "$worktree" "$state" lane-a 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "binding publication accepted a directory marker"
  [ -d "$marker" ] || fail "binding publication replaced the directory marker"
  assert_contains "$out" "non-regular worktree binding" \
    "directory marker refusal did not identify the invalid target"

  rmdir "$marker"
  target="$TMP_ROOT/marker-target"
  mkdir "$target"
  ln -s "$target" "$marker"
  set +e
  out=$(fm_worktree_binding_write "$worktree" "$state" lane-a 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "binding publication accepted a directory symlink marker"
  [ -L "$marker" ] || fail "binding publication replaced the directory symlink marker"
  [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "binding publication moved temporary state into the marker directory"

  rm "$marker"
  fm_worktree_binding_write "$worktree" "$state" lane-a \
    || fail "binding publication rejected a valid absent marker"
  fm_worktree_binding_matches "$worktree" "$state" lane-a \
    || fail "published binding did not match its intended owner"
  pass "binding publication rejects non-regular targets and confirms ownership"
}

test_linked_homes_share_worktree_transition_lock() {
  local project worktree state_a state_b lock_a lock_b
  project="$TMP_ROOT/lock-project"
  worktree="$TMP_ROOT/lock-worktree"
  state_a="$TMP_ROOT/home-a/state"
  state_b="$TMP_ROOT/home-b/state"
  mkdir -p "$state_a" "$state_b"
  fm_git_worktree "$project" "$worktree" binding-lock

  lock_a=$(fm_worktree_transition_lock_path "$state_a" "$worktree") \
    || fail "could not resolve the first home's worktree transition lock"
  lock_b=$(fm_worktree_transition_lock_path "$state_b" "$worktree") \
    || fail "could not resolve the linked home's worktree transition lock"
  [ "$lock_a" = "$lock_b" ] \
    || fail "linked homes resolved different worktree transition locks"
  pass "linked homes share one worktree transition lock"
}

test_missing_recorded_worktree_is_not_active() {
  local state meta missing
  state="$TMP_ROOT/missing-state"
  meta="$state/lane-a.meta"
  missing="$TMP_ROOT/missing-worktree"
  mkdir -p "$state"
  fm_write_meta "$meta" \
    "worktree=$missing" \
    "project=$TMP_ROOT/project" \
    "kind=ship" \
    "worktree_binding=fm-worktree-binding.v2"

  if fm_worktree_record_active_guard_acquire "$meta"; then
    fm_worktree_record_active_guard_release
    fail "a missing recorded worktree resolved as active"
  fi
  [ -z "$FM_WORKTREE_RECORD_ACTIVE_PATH" ] \
    || fail "a missing recorded worktree remained available to consumers"
  assert_contains "$FM_WORKTREE_RECORD_DETAIL" "is not present" \
    "missing worktree refusal did not explain the inactive path"
  pass "missing recorded worktrees fail closed for active consumers"
}

test_active_guard_serializes_metadata_identity() {
  local project_a project_b worktree_a worktree_b state meta expected_pool expected_transition
  project_a="$TMP_ROOT/identity-project-a"
  project_b="$TMP_ROOT/identity-project-b"
  worktree_a="$TMP_ROOT/identity-worktree-a"
  worktree_b="$TMP_ROOT/identity-worktree-b"
  state="$TMP_ROOT/identity-state"
  meta="$state/lane-a.meta"
  mkdir -p "$state"
  fm_git_worktree "$project_a" "$worktree_a" identity-a
  fm_git_worktree "$project_b" "$worktree_b" identity-b
  fm_worktree_binding_write "$worktree_b" "$state" lane-a \
    || fail "could not bind the replacement fixture worktree"
  fm_write_meta "$meta" \
    "worktree=$worktree_a" \
    "project=$project_a" \
    "kind=ship" \
    "worktree_binding=fm-worktree-binding.v2"

  TEST_IDENTITY_TASK_SET="$state/.task-set.lock"
  TEST_IDENTITY_META=$meta
  TEST_IDENTITY_PROJECT=$project_b
  TEST_IDENTITY_WORKTREE=$worktree_b
  TEST_IDENTITY_LOCKED=0
  fm_lock_acquire_wait() {
    local lock=$1
    if [ "$TEST_IDENTITY_LOCKED" -eq 0 ]; then
      [ "$lock" = "$TEST_IDENTITY_TASK_SET" ] \
        || fail "active guard did not serialize task identity before repository locking"
      TEST_IDENTITY_LOCKED=1
      fm_write_meta "$TEST_IDENTITY_META" \
        "worktree=$TEST_IDENTITY_WORKTREE" \
        "project=$TEST_IDENTITY_PROJECT" \
        "kind=ship" \
        "worktree_binding=fm-worktree-binding.v2"
    fi
    return 0
  }

  fm_worktree_record_active_guard_acquire "$meta" \
    || fail "active guard rejected the replacement metadata snapshot: $FM_WORKTREE_RECORD_DETAIL"
  expected_pool=$(fm_worktree_pool_transition_lock_path "$state" "$project_b") \
    || fail "could not resolve the replacement project's pool lock"
  expected_transition=$(fm_worktree_transition_lock_path "$state" "$worktree_b") \
    || fail "could not resolve the replacement worktree's transition lock"
  [ "$FM_WORKTREE_RECORD_ACTIVE_PATH" = "$worktree_b" ] \
    || fail "active guard returned a stale metadata worktree"
  [ "$FM_WORKTREE_RECORD_ACTIVE_POOL_LOCK" = "$expected_pool" ] \
    || fail "active guard returned a path outside its repository pool lock"
  [ "$FM_WORKTREE_RECORD_ACTIVE_TRANSITION_LOCK" = "$expected_transition" ] \
    || fail "active guard returned a path outside its worktree transition lock"
  fm_worktree_record_active_guard_release
  pass "active guard serializes task identity before worktree ownership"
}

test_binding_publication_rejects_non_regular_markers
test_linked_homes_share_worktree_transition_lock
test_missing_recorded_worktree_is_not_active
test_active_guard_serializes_metadata_identity

echo "# all fm-worktree-binding tests passed"
