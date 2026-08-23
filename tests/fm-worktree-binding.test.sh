#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-binding-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-binding)

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

test_binding_publication_rejects_non_regular_markers
test_linked_homes_share_worktree_transition_lock
test_missing_recorded_worktree_is_not_active

echo "# all fm-worktree-binding tests passed"
