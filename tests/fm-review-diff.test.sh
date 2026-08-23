#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-binding-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "worktree_binding=fm-worktree-binding.v2" \
    "$@"
  fm_worktree_binding_write "$case_dir/wt" "$case_dir/state" task-x1 \
    || fail "could not bind the review fixture worktree"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

test_retired_pointer_refuses_replacement_lane_diff() {
  local case_dir out status
  case_dir=$(make_case retired-pointer)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" "worktree_retired=live-task"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 --stat 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "retired-pointer: review used a historical worktree pointer"
  assert_contains "$out" "retired after reassignment to task live-task" \
    "retired-pointer: refusal did not identify the replacement owner"
  assert_not_contains "$out" "feature.txt" \
    "retired-pointer: review exposed a diff from the replacement lane"
  pass "fm-review-diff refuses a retired worktree pointer"
}

test_mismatched_binding_refuses_recycled_worktree_diff() {
  local case_dir out status
  case_dir=$(make_case mismatched-binding)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir" "worktree_binding=fm-worktree-binding.v2"
  fm_worktree_binding_write "$case_dir/wt" "$case_dir/state" live-task \
    || fail "mismatched-binding: could not publish the replacement owner's binding"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 --stat 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "mismatched-binding: review used another task's live worktree"
  assert_contains "$out" "worktree binding mismatch" \
    "mismatched-binding: refusal did not identify the ownership mismatch"
  assert_contains "$out" "live-task" \
    "mismatched-binding: refusal did not identify the current owner"
  assert_not_contains "$out" "feature.txt" \
    "mismatched-binding: review exposed a diff from the replacement lane"
  pass "fm-review-diff refuses a positively mismatched active pointer"
}

test_reassignment_waits_for_review_snapshot() {
  local case_dir fakebin real_git out review_pid transition_pid i
  case_dir=$(make_case guarded-snapshot)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"
  git -C "$case_dir/wt" checkout -q -b fm/live-task main
  printf 'live-owner\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "replacement lane"
  git -C "$case_dir/wt" checkout -q fm/task-x1

  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${FM_REVIEW_BLOCK_ENTERED:-}" ] \
   && [ ! -e "$FM_REVIEW_BLOCK_ENTERED" ]; then
  for arg in "$@"; do
    if [ "$arg" = refs/remotes/origin/HEAD ]; then
      : > "$FM_REVIEW_BLOCK_ENTERED"
      while [ ! -e "${FM_REVIEW_BLOCK_RELEASE:?}" ]; do sleep 0.02; done
      break
    fi
  done
fi
exec "${FM_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  out="$case_dir/review.out"
  FM_REVIEW_BLOCK_ENTERED="$case_dir/review-entered" \
  FM_REVIEW_BLOCK_RELEASE="$case_dir/review-release" \
  FM_REAL_GIT="$real_git" PATH="$fakebin:$PATH" \
    run_review_diff "$case_dir" task-x1 > "$out" 2> "$case_dir/review.err" &
  review_pid=$!
  i=0
  while [ ! -e "$case_dir/review-entered" ] && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -e "$case_dir/review-entered" ] || fail "guarded-snapshot: review did not reach the controlled read"

  (
    FM_HOME="$case_dir"
    FM_STATE_OVERRIDE="$case_dir/state"
    export FM_HOME FM_STATE_OVERRIDE
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-worktree-binding-lib.sh"
    pool_lock=$(fm_worktree_pool_transition_lock_path "$case_dir/state" "$case_dir/project") || exit 1
    worktree_lock=$(fm_worktree_transition_lock_path "$case_dir/state" "$case_dir/wt") || exit 1
    fm_lock_acquire_wait "$pool_lock"
    fm_lock_acquire_wait "$worktree_lock"
    : > "$case_dir/transition-entered"
    "$real_git" -C "$case_dir/wt" checkout -q fm/live-task
    fm_worktree_binding_write "$case_dir/wt" "$case_dir/state" live-task
    fm_lock_release "$worktree_lock"
    fm_lock_release "$pool_lock"
  ) &
  transition_pid=$!
  sleep 0.2
  [ ! -e "$case_dir/transition-entered" ] \
    || fail "guarded-snapshot: reassignment crossed an in-progress review snapshot"
  : > "$case_dir/review-release"
  wait "$review_pid" || fail "guarded-snapshot: review failed: $(cat "$case_dir/review.err")"
  wait "$transition_pid" || fail "guarded-snapshot: reassignment failed after review released its guard"

  assert_contains "$(cat "$out")" '+stale-local' \
    "guarded-snapshot: review did not preserve the requested lane's commit"
  assert_not_contains "$(cat "$out")" '+live-owner' \
    "guarded-snapshot: review exposed the concurrently reassigned lane"
  pass "fm-review-diff snapshots commit identities under the transition guard"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_retired_pointer_refuses_replacement_lane_diff
test_mismatched_binding_refuses_recycled_worktree_diff
test_reassignment_waits_for_review_snapshot
