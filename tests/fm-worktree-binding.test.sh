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

test_binding_publication_rejects_non_regular_markers

echo "# all fm-worktree-binding tests passed"
