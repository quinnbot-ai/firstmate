#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: a local-only fast-forward may reconcile
# working-tree dirt only when every dirty path is proven to match the incoming
# branch content or becomes ignored and untracked at that branch head.
#
# Matrix:
#   (a) byte-identical tracked content permits the fast-forward
#   (b) one unresolved modified file refuses and names the path
#   (c) tracked-to-ignored conversion permits and preserves on-disk content
#   (d) branch-ignored untracked content permits and is preserved
#   (e) a diverged branch still refuses
#   (f) a non-default checkout still refuses
#   (g) mixed resolved and unresolved dirt refuses and names the blocker
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/project"

  git -C "$case_dir/project" init -q
  printf 'tracked base\n' >"$case_dir/project/tracked.txt"
  printf 'resolved base\n' >"$case_dir/project/resolved.txt"
  printf 'unresolved base\n' >"$case_dir/project/unresolved.txt"
  printf 'runtime base\n' >"$case_dir/project/runtime-state.txt"
  git -C "$case_dir/project" add \
    tracked.txt resolved.txt unresolved.txt runtime-state.txt
  git -C "$case_dir/project" commit -qm "base"
  git -C "$case_dir/project" branch -m main
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/branch" main

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/branch" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

assert_main_reached_branch() {
  local case_dir=$1
  [ "$(git -C "$case_dir/project" rev-parse main)" = \
    "$(git -C "$case_dir/project" rev-parse fm/task-x1)" ] \
    || fail "$2"
}

assert_path_clean() {
  local repo=$1 path=$2
  [ -z "$(git -C "$repo" status --porcelain=v1 --untracked-files=all -- "$path")" ] \
    || fail "$3"
}

test_byte_identical_tracked_content_permits() {
  local case_dir
  case_dir=$(make_case byte-identical)
  printf 'tracked target\n' >"$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "resolve tracked drift"
  printf 'tracked target\n' >"$case_dir/project/tracked.txt"

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "byte-identical: merge should succeed"

  assert_main_reached_branch "$case_dir" \
    "byte-identical: main did not fast-forward to the task branch"
  assert_path_clean "$case_dir/project" tracked.txt \
    "byte-identical: previously dirty tracked path was not clean after merge"
  pass "fm-merge-local permits byte-identical tracked dirt resolved by the branch"
}

test_unresolved_modified_file_refuses_with_path() {
  local case_dir before rc
  case_dir=$(make_case unresolved-modified)
  printf 'branch target\n' >"$case_dir/branch/unresolved.txt"
  git -C "$case_dir/branch" add unresolved.txt
  git -C "$case_dir/branch" commit -qm "incoming change"
  printf 'different local drift\n' >"$case_dir/project/unresolved.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unresolved-modified: merge should refuse"
  assert_grep 'unresolved.txt' "$case_dir/stderr" \
    "unresolved-modified: refusal did not name the unresolved path"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "unresolved-modified: refusal advanced main"
  pass "fm-merge-local refuses unresolved modified dirt and names the path"
}

test_untracked_conversion_permits_and_preserves_file() {
  local case_dir before_hash after_hash
  case_dir=$(make_case untracked-conversion)
  git -C "$case_dir/branch" rm -q --cached runtime-state.txt
  printf 'runtime-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "leave runtime log untracked"
  printf 'runtime base\nruntime append\n' >"$case_dir/project/runtime-state.txt"
  before_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "untracked-conversion: merge should succeed"

  after_hash=$(git -C "$case_dir/project" hash-object -- runtime-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "untracked-conversion: merge changed the on-disk runtime file"
  [ -f "$case_dir/project/runtime-state.txt" ] \
    || fail "untracked-conversion: merge removed the on-disk runtime file"
  ! git -C "$case_dir/project" ls-files --error-unmatch runtime-state.txt >/dev/null 2>&1 \
    || fail "untracked-conversion: runtime file remained tracked"
  assert_path_clean "$case_dir/project" runtime-state.txt \
    "untracked-conversion: ignored runtime file remained dirty after merge"
  assert_main_reached_branch "$case_dir" \
    "untracked-conversion: main did not fast-forward to the task branch"
  pass "fm-merge-local preserves a tracked file converted to ignored-untracked"
}

test_branch_ignored_untracked_file_permits() {
  local case_dir before_hash after_hash
  case_dir=$(make_case ignored-untracked)
  printf 'scratch-state.txt\n' >"$case_dir/branch/.gitignore"
  git -C "$case_dir/branch" add .gitignore
  git -C "$case_dir/branch" commit -qm "ignore runtime scratch"
  printf 'runtime scratch\n' >"$case_dir/project/scratch-state.txt"
  before_hash=$(git -C "$case_dir/project" hash-object -- scratch-state.txt)

  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "ignored-untracked: merge should succeed"

  after_hash=$(git -C "$case_dir/project" hash-object -- scratch-state.txt)
  [ "$after_hash" = "$before_hash" ] \
    || fail "ignored-untracked: merge changed the untracked file"
  assert_path_clean "$case_dir/project" scratch-state.txt \
    "ignored-untracked: branch-ignored file remained dirty after merge"
  assert_main_reached_branch "$case_dir" \
    "ignored-untracked: main did not fast-forward to the task branch"
  pass "fm-merge-local permits an untracked path ignored at the branch head"
}

test_diverged_branch_still_refuses() {
  local case_dir rc
  case_dir=$(make_case diverged)
  printf 'branch-only\n' >"$case_dir/branch/branch.txt"
  git -C "$case_dir/branch" add branch.txt
  git -C "$case_dir/branch" commit -qm "branch change"
  printf 'main-only\n' >"$case_dir/project/main.txt"
  git -C "$case_dir/project" add main.txt
  git -C "$case_dir/project" commit -qm "main change"

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged: merge should refuse"
  assert_grep 'is not a fast-forward of main (it has diverged)' "$case_dir/stderr" \
    "diverged: fast-forward refusal changed or disappeared"
  pass "fm-merge-local still refuses a diverged task branch"
}

test_non_default_checkout_still_refuses() {
  local case_dir rc
  case_dir=$(make_case non-default)
  printf 'branch target\n' >"$case_dir/branch/tracked.txt"
  git -C "$case_dir/branch" add tracked.txt
  git -C "$case_dir/branch" commit -qm "branch change"
  git -C "$case_dir/project" checkout -qb other

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-default: merge should refuse"
  assert_grep "is on 'other', expected default branch 'main'; cannot merge safely" \
    "$case_dir/stderr" \
    "non-default: checkout refusal changed or disappeared"
  pass "fm-merge-local still refuses a non-default checkout"
}

test_mixed_resolved_and_unresolved_refuses() {
  local case_dir before rc
  case_dir=$(make_case mixed)
  printf 'resolved target\n' >"$case_dir/branch/resolved.txt"
  printf 'unresolved target\n' >"$case_dir/branch/unresolved.txt"
  git -C "$case_dir/branch" add resolved.txt unresolved.txt
  git -C "$case_dir/branch" commit -qm "incoming mixed changes"
  printf 'resolved target\n' >"$case_dir/project/resolved.txt"
  printf 'different local drift\n' >"$case_dir/project/unresolved.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mixed: merge should refuse"
  assert_grep 'unresolved.txt' "$case_dir/stderr" \
    "mixed: refusal did not name the unresolved path"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "mixed: refusal advanced main despite one unresolved path"
  pass "fm-merge-local refuses a mixed set when any dirty path is unresolved"
}

test_byte_identical_tracked_content_permits
test_unresolved_modified_file_refuses_with_path
test_untracked_conversion_permits_and_preserves_file
test_branch_ignored_untracked_file_permits
test_diverged_branch_still_refuses
test_non_default_checkout_still_refuses
test_mixed_resolved_and_unresolved_refuses
