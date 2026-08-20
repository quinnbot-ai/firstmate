#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's conflict advisory: the line firstmate sees at
# the moment it starts waiting on a pull request.
#
# THE REGRESSION. A pull request whose branch conflicts with its base has no
# merge ref, so GitHub never schedules its pull_request workflows and it waits
# forever while presenting as an ordinary pull request with no CI configured.
# bin/fm-pr-merge.sh's gate cannot help there: it only speaks when someone tries
# to merge, and the cost is accrued before that. Arming the merge poll is the
# one moment firstmate is guaranteed to look at the pull request, so the
# conflict is named there, with the remedy, or nothing names it at all.
#
# Matrix:
#   (a) a conflicted pull request is named at arming, with cause and remedy
#   (b) the remedy names merging the base in and forbids the force-push fix
#   (c) a mergeable pull request arms silently
# The silent cases assert on the advisory's own cause sentence rather than the
# bare word "conflict", because the guard banners that share this stream can
# legitimately carry that word (a branch name, for one).
#   (d) an uncomputed mergeable_state arms silently (no false alarm)
#   (e) an unreadable answer arms silently and still exits 0 (advisory only)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# One sandbox: a state dir with a task meta, and a fakebin whose gh-axi answers
# mergeable_state from FM_TEST_MERGEABLE. `gh` is stubbed silent so the pr_head
# lookup neither reaches the network nor influences the advisory.
make_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin"
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "window=fm-task-c1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-}" = api ]; then
  case " $* " in
    *mergeable_state*)
      if [ "${FM_TEST_MERGEABLE-clean}" = __error__ ]; then
        printf '%s\n' 'error: Validation error'
        printf '%s\n' 'code: VALIDATION_ERROR'
      else
        printf '%s\n' "${FM_TEST_MERGEABLE-clean}"
      fi
      ;;
  esac
fi
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_pr_check() {  # <case_dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_MERGEABLE="${FM_TEST_MERGEABLE-clean}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_conflict_is_named_at_arming() {
  local case_dir rc
  case_dir=$(make_case conflicted)
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_MERGEABLE=dirty run_pr_check "$case_dir" task-c1 \
    https://github.com/example/repo/pull/148 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "conflicted: arming must still succeed"
  assert_grep 'armed: state/task-c1.check.sh' "$case_dir/stdout" \
    "conflicted: the merge poll was not armed"
  assert_grep 'https://github.com/example/repo/pull/148 is conflicted' "$case_dir/stderr" \
    "conflicted: arming did not name the conflicted pull request"
  assert_grep 'conflicts with its base' "$case_dir/stderr" \
    "conflicted: the advisory did not state the cause"
  assert_grep 'never schedule them until the conflict is resolved' "$case_dir/stderr" \
    "conflicted: the advisory did not say the CI will never run on its own"
  pass "fm-pr-check names a conflicted pull request when it arms the merge poll"
}

# The remedy is load-bearing on its own: the obvious way to clear a conflict is
# a rebase and force-push, which rewrites a published branch and is forbidden.
# An advisory that reports the conflict without the safe fix invites the unsafe
# one.
test_advisory_carries_the_safe_remedy() {
  local case_dir
  case_dir=$(make_case remedy)
  : > "$case_dir/gh-axi.log"

  FM_TEST_MERGEABLE=dirty run_pr_check "$case_dir" task-c1 \
    https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "remedy: arming must still succeed"

  assert_grep 'merge the base branch into the pull request branch' "$case_dir/stderr" \
    "remedy: the advisory did not name the safe fix"
  assert_grep 'never rebase and force-push a published branch' "$case_dir/stderr" \
    "remedy: the advisory did not rule out the unsafe fix"
  pass "fm-pr-check's conflict advisory names the safe remedy and rules out the unsafe one"
}

test_mergeable_pr_arms_silently() {
  local case_dir
  case_dir=$(make_case mergeable)
  : > "$case_dir/gh-axi.log"

  FM_TEST_MERGEABLE=clean run_pr_check "$case_dir" task-c1 \
    https://github.com/example/repo/pull/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mergeable: arming failed"

  assert_grep 'armed: state/task-c1.check.sh' "$case_dir/stdout" \
    "mergeable: the merge poll was not armed"
  assert_no_grep 'conflicts with its base' "$case_dir/stderr" \
    "mergeable: a mergeable pull request was reported as conflicted"
  pass "fm-pr-check arms a mergeable pull request without an advisory"
}

# GitHub computes mergeable_state asynchronously and answers `unknown` for the
# first moments of a pull request's life - exactly when firstmate arms the poll.
# Only an explicit `dirty` may speak, or the advisory becomes noise on every
# freshly opened pull request and stops being read.
test_uncomputed_state_arms_silently() {
  local case_dir
  case_dir=$(make_case unknown-state)
  : > "$case_dir/gh-axi.log"

  FM_TEST_MERGEABLE=unknown run_pr_check "$case_dir" task-c1 \
    https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unknown-state: arming failed"

  assert_grep 'armed: state/task-c1.check.sh' "$case_dir/stdout" \
    "unknown-state: the merge poll was not armed"
  assert_no_grep 'conflicts with its base' "$case_dir/stderr" \
    "unknown-state: an uncomputed mergeable state was reported as a conflict"
  pass "fm-pr-check stays silent while GitHub has not computed the mergeable state"
}

# The advisory is a diagnostic layered on top of the guarantee this script owes.
# Arming the poll must survive an answer the advisory cannot read.
test_unreadable_answer_does_not_cost_the_arming() {
  local case_dir rc
  case_dir=$(make_case unreadable)
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_MERGEABLE=__error__ run_pr_check "$case_dir" task-c1 \
    https://github.com/example/repo/pull/14 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unreadable: an unreadable advisory answer must not fail the arming"
  assert_grep 'armed: state/task-c1.check.sh' "$case_dir/stdout" \
    "unreadable: the merge poll was not armed"
  assert_no_grep 'conflicts with its base' "$case_dir/stderr" \
    "unreadable: an unreadable answer was reported as a conflict"
  pass "fm-pr-check arms the merge poll even when the conflict read is unreadable"
}

test_conflict_is_named_at_arming
test_advisory_carries_the_safe_remedy
test_mergeable_pr_arms_silently
test_uncomputed_state_arms_silently
test_unreadable_answer_does_not_cost_the_arming
