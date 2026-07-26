#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's dirty-path safety boundary.
#
# A local-only fast-forward may preserve unrelated standing runtime drift, but
# it must refuse before changing the default branch when any dirty path is also
# changed by the task branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/project"
  git -C "$case_dir/project" init -q -b main
  printf 'shared base\n' > "$case_dir/project/shared.txt"
  printf 'runtime base\n' > "$case_dir/project/runtime.txt"
  git -C "$case_dir/project" add shared.txt runtime.txt
  git -C "$case_dir/project" commit -qm "baseline"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

test_unrelated_dirty_paths_allow_fast_forward() {
  local case_dir out before after
  case_dir=$(make_case unrelated-dirty)
  printf 'captain procedure\n' > "$case_dir/wt/captain-procedure.md"
  git -C "$case_dir/wt" add captain-procedure.md
  git -C "$case_dir/wt" commit -qm "add captain procedure"
  printf 'runtime drift\n' > "$case_dir/project/runtime.txt"
  printf 'backup\n' > "$case_dir/project/runtime.backup"
  before=$(git -C "$case_dir/project" rev-parse main)

  out=$(run_merge_local "$case_dir") \
    || fail "unrelated-dirty: non-intersecting runtime drift blocked the fast-forward"
  after=$(git -C "$case_dir/project" rev-parse main)

  [ "$after" = "$(git -C "$case_dir/wt" rev-parse fm/task-x1)" ] \
    || fail "unrelated-dirty: main did not advance to the task branch"
  [ "$after" != "$before" ] || fail "unrelated-dirty: main did not advance"
  [ "$(cat "$case_dir/project/runtime.txt")" = "runtime drift" ] \
    || fail "unrelated-dirty: tracked runtime drift was not preserved"
  [ "$(cat "$case_dir/project/runtime.backup")" = "backup" ] \
    || fail "unrelated-dirty: untracked runtime artifact was not preserved"
  assert_contains "$out" "merged fm/task-x1 into local main" \
    "unrelated-dirty: merge did not report the completed fast-forward"
  pass "fm-merge-local permits dirty paths outside the fast-forward change set"
}

test_intersecting_dirty_path_refuses() {
  local case_dir rc before after err
  case_dir=$(make_case intersecting-dirty)
  printf 'task change\n' > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add shared.txt
  git -C "$case_dir/wt" commit -qm "change shared file"
  printf 'runtime change\n' > "$case_dir/project/shared.txt"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  after=$(git -C "$case_dir/project" rev-parse main)
  err=$(cat "$case_dir/stderr")

  expect_code 1 "$rc" "intersecting-dirty: merge must refuse dirty overlap"
  [ "$after" = "$before" ] || fail "intersecting-dirty: main moved despite the refusal"
  assert_contains "$err" "REFUSED:" "intersecting-dirty: refusal was not loud"
  assert_contains "$err" "shared.txt" "intersecting-dirty: refusal did not name the overlapping path"
  [ "$(cat "$case_dir/project/shared.txt")" = "runtime change" ] \
    || fail "intersecting-dirty: the dirty file was modified"
  pass "fm-merge-local refuses and names dirty paths changed by the fast-forward"
}

test_unrelated_dirty_paths_allow_fast_forward
test_intersecting_dirty_path_refuses
