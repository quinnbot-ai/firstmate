#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded local landing path for a
# local-only ship task, and its one exception to the clean-checkout requirement
# - dirt the fast-forward itself would produce.
#
# Matrix:
#   (a) a clean checkout still fast-forwards
#   (b) dirt whose content is already the tip's lands with the merge
#   (c) an untracked path the tip adds with the same bytes lands with the merge
#   (d) a staged change already equal to the tip lands with the merge
#   (e) one differing byte still refuses, and keeps the local content
#   (f) a staged version that is neither HEAD's nor the tip's still refuses
#   (f2) a fully staged version differing from the tip still refuses
#   (g) an executable-bit difference over identical bytes still refuses
#   (h) a locally deleted tracked file still refuses
#   (i) an untracked path the tip does not carry still refuses
#   (j) a diverged branch still refuses, without staging the identical dirt
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
TASK=task-m1

# Build one case sandbox: a project whose default branch holds gen.txt=v1 plus
# keep.txt, and a fm/<task> branch that rewrites gen.txt to v2 and adds new.txt.
# Echoes the case dir; the project checkout is left on the default branch.
make_case() {
  local name=$1 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state" "$case_dir/tmp" "$proj"
  git -C "$proj" init -q
  printf 'v1\n' > "$proj/gen.txt"
  printf 'keep\n' > "$proj/keep.txt"
  git -C "$proj" add gen.txt keep.txt
  git -C "$proj" commit -qm base
  DEFAULT_BRANCH=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" checkout -q -b "fm/$TASK"
  printf 'v2\n' > "$proj/gen.txt"
  printf 'added\n' > "$proj/new.txt"
  git -C "$proj" add gen.txt new.txt
  git -C "$proj" commit -qm tip
  git -C "$proj" checkout -q "$DEFAULT_BRANCH"
  fm_write_meta "$case_dir/state/$TASK.meta" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  TMPDIR="$case_dir/tmp" \
    "$MERGE_LOCAL" "$TASK" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

# assert_no_scratch_left <case_dir> <label>: the working scratch the identity
# check allocates must not outlive the command.
assert_no_scratch_left() {
  local case_dir=$1 label=$2
  [ -z "$(find "$case_dir/tmp" -maxdepth 1 -name 'fm-merge-local.*' -print -quit)" ] \
    || fail "$label: the identity check left its scratch directory behind"
}

head_sha() { git -C "$1/project" rev-parse HEAD; }
tip_sha() { git -C "$1/project" rev-parse "fm/$TASK"; }

# assert_landed <case_dir> <label>: the default branch is the tip and the
# checkout came out clean, with the tip's bytes on disk.
assert_landed() {
  local case_dir=$1 label=$2
  [ "$(head_sha "$case_dir")" = "$(tip_sha "$case_dir")" ] \
    || fail "$label: default branch did not fast-forward to the task branch"
  [ -z "$(git -C "$case_dir/project" status --porcelain)" ] \
    || fail "$label: checkout is still dirty after the merge"
  [ "$(cat "$case_dir/project/gen.txt")" = v2 ] \
    || fail "$label: merged working tree does not hold the tip's content"
  assert_no_scratch_left "$case_dir" "$label"
}

# assert_refused <case_dir> <label>: the dirty-tree refusal fired, nothing
# merged, and nothing was staged on the way out.
assert_refused() {
  local case_dir=$1 label=$2
  assert_grep 'has a dirty working tree; refusing to merge into it' "$case_dir/stderr" \
    "$label: the dirty-working-tree refusal did not fire"
  [ "$(head_sha "$case_dir")" != "$(tip_sha "$case_dir")" ] \
    || fail "$label: the merge landed despite the refusal"
  assert_no_scratch_left "$case_dir" "$label"
}

test_clean_checkout_merges() {
  local case_dir rc
  case_dir=$(make_case clean)

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 0 "$rc" "clean: fm-merge-local should fast-forward a clean checkout"
  assert_landed "$case_dir" clean
  assert_grep 'merged fm/task-m1 into local' "$case_dir/stdout" \
    "clean: the merge outcome line is missing"
  pass "fm-merge-local fast-forwards a clean local-only checkout"
}

test_identical_unstaged_dirt_lands() {
  local case_dir rc
  case_dir=$(make_case identical-unstaged)
  printf 'v2\n' > "$case_dir/project/gen.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 0 "$rc" "identical-unstaged: dirt equal to the tip should not block the merge"
  assert_landed "$case_dir" identical-unstaged
  assert_grep 'already match fm/task-m1' "$case_dir/stderr" \
    "identical-unstaged: the merge did not report landing the matching dirt"
  pass "fm-merge-local lands unstaged dirt whose content is already the tip's"
}

test_identical_untracked_dirt_lands() {
  local case_dir rc
  case_dir=$(make_case identical-untracked)
  printf 'added\n' > "$case_dir/project/new.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 0 "$rc" "identical-untracked: an untracked copy of a file the tip adds should not block the merge"
  assert_landed "$case_dir" identical-untracked
  pass "fm-merge-local lands an untracked path the tip adds with the same bytes"
}

test_identical_staged_dirt_lands() {
  local case_dir rc
  case_dir=$(make_case identical-staged)
  printf 'v2\n' > "$case_dir/project/gen.txt"
  git -C "$case_dir/project" add gen.txt

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 0 "$rc" "identical-staged: a staged change equal to the tip should not block the merge"
  assert_landed "$case_dir" identical-staged
  pass "fm-merge-local lands a staged change that already equals the tip"
}

test_one_byte_difference_refuses() {
  local case_dir rc
  case_dir=$(make_case one-byte)
  printf 'v3\n' > "$case_dir/project/gen.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "one-byte: fm-merge-local should refuse dirt that differs from the tip"
  assert_refused "$case_dir" one-byte
  [ "$(cat "$case_dir/project/gen.txt")" = v3 ] \
    || fail "one-byte: the local content was not preserved"
  git -C "$case_dir/project" diff --cached --quiet \
    || fail "one-byte: the refusal left changes staged in the project index"
  pass "fm-merge-local still refuses dirt that differs from the tip by one byte"
}

test_staged_other_version_refuses() {
  local case_dir rc
  case_dir=$(make_case staged-other-version)
  printf 'v9\n' > "$case_dir/project/gen.txt"
  git -C "$case_dir/project" add gen.txt
  printf 'v2\n' > "$case_dir/project/gen.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "staged-other-version: staged work that is neither HEAD's nor the tip's must refuse"
  assert_refused "$case_dir" staged-other-version
  [ "$(git -C "$case_dir/project" show :gen.txt)" = v9 ] \
    || fail "staged-other-version: the staged version was lost"
  pass "fm-merge-local refuses when staging would discard a different staged version"
}

test_staged_only_difference_refuses() {
  local case_dir rc
  case_dir=$(make_case staged-only-difference)
  printf 'v9\n' > "$case_dir/project/gen.txt"
  git -C "$case_dir/project" add gen.txt

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "staged-only-difference: a staged change differing from the tip must refuse"
  assert_refused "$case_dir" staged-only-difference
  [ "$(git -C "$case_dir/project" show :gen.txt)" = v9 ] \
    || fail "staged-only-difference: the staged version was lost"
  pass "fm-merge-local refuses a staged change that differs from the tip"
}

test_mode_difference_refuses() {
  local case_dir rc
  case_dir=$(make_case mode-difference)
  printf 'v2\n' > "$case_dir/project/gen.txt"
  chmod +x "$case_dir/project/gen.txt"
  if [ -z "$(git -C "$case_dir/project" status --porcelain)" ]; then
    pass "fm-merge-local mode check not applicable: this filesystem's git ignores the executable bit"
    return 0
  fi

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "mode-difference: an executable-bit difference must refuse"
  assert_refused "$case_dir" mode-difference
  [ -x "$case_dir/project/gen.txt" ] \
    || fail "mode-difference: the local file mode was not preserved"
  pass "fm-merge-local refuses identical bytes carrying a different file mode"
}

test_local_deletion_refuses() {
  local case_dir rc
  case_dir=$(make_case local-deletion)
  rm "$case_dir/project/keep.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "local-deletion: a locally deleted tracked file must refuse"
  assert_refused "$case_dir" local-deletion
  pass "fm-merge-local refuses a locally deleted file the tip still carries"
}

test_untracked_path_absent_from_tip_refuses() {
  local case_dir rc
  case_dir=$(make_case untracked-absent)
  printf 'scratch\n' > "$case_dir/project/scratch.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "untracked-absent: an untracked path the tip does not carry must refuse"
  assert_refused "$case_dir" untracked-absent
  git -C "$case_dir/project" status --porcelain > "$case_dir/status"
  assert_grep '?? scratch.txt' "$case_dir/status" \
    "untracked-absent: the untracked file no longer reads as untracked"
  pass "fm-merge-local refuses an untracked path the tip does not carry"
}

test_diverged_branch_refuses_before_staging() {
  local case_dir rc
  case_dir=$(make_case diverged)
  # Move the default branch forward so the task branch is no longer a
  # fast-forward, then dirty the checkout with the tip's own content.
  printf 'sideways\n' > "$case_dir/project/side.txt"
  git -C "$case_dir/project" add side.txt
  git -C "$case_dir/project" commit -qm sideways
  printf 'v2\n' > "$case_dir/project/gen.txt"

  set +e; run_merge_local "$case_dir"; rc=$?; set -e

  expect_code 1 "$rc" "diverged: a diverged branch must still refuse"
  assert_grep 'is not a fast-forward of' "$case_dir/stderr" \
    "diverged: the diverged refusal did not fire"
  git -C "$case_dir/project" diff --cached --quiet \
    || fail "diverged: identical dirt was staged before the diverged refusal"
  pass "fm-merge-local refuses a diverged branch without staging matching dirt first"
}

test_clean_checkout_merges
test_identical_unstaged_dirt_lands
test_identical_untracked_dirt_lands
test_identical_staged_dirt_lands
test_one_byte_difference_refuses
test_staged_other_version_refuses
test_staged_only_difference_refuses
test_mode_difference_refuses
test_local_deletion_refuses
test_untracked_path_absent_from_tip_refuses
test_diverged_branch_refuses_before_staging
