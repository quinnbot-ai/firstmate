#!/usr/bin/env bash
# Tests for bin/fm-reconcile-worktree-pointers.sh and the binding-independent
# ownership proof in bin/fm-worktree-owner-lib.sh.
#
# THE GAP THESE COVER. The current-owner check in bin/fm-teardown.sh reads an
# ownership binding out of the copy, so it protects every copy assigned after
# bindings existed and deliberately does nothing for the collisions that already
# exist - a record with no declared binding, over a copy carrying none. Those are
# exactly the collisions a home accumulates, because the lanes holding stale
# pointers are preserved lanes that are never torn down and therefore never
# repaired. The second proof reads the branch the copy actually has checked out
# and cross-confirms it against that claimant's own record.
#
# Matrix:
#   (r1) unbound copy on another recorded task's branch  -> STALE, pointer retired
#   (r2) unbound copy still on this lane's own branch    -> quiet (nothing to repair)
#   (r3) branch names a task this home does not record   -> UNRESOLVED, untouched
#   (r4) readable binding disagrees with the branch      -> binding wins, quiet
#   (r5) default run reports without changing anything   -> dry-run by default
#   (r6) re-run over an already-retired pointer          -> counted, not rewritten
#   (r7) copy on a detached HEAD                         -> UNRESOLVED, untouched
#   (r8) kind=secondmate home                            -> skipped entirely
#   (r9) any repair                                      -> never appends to a status log
#  (r10) --help                                          -> pure read, real usage
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-binding-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RECONCILE="$ROOT/bin/fm-reconcile-worktree-pointers.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile-pointer-tests)

# Build a home with a project repo and one pooled copy. The copy starts on
# fm/lane-a, which is lane-a's own branch. Echoes the case dir.
make_home() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/lane-a
  printf '%s\n' "$case_dir"
}

# Record a task as holding the shared copy. Args: case_dir task_id [extra kv...]
record_lane() {
  local case_dir=$1 id=$2
  shift 2
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
}

# Hand the copy to another task the way a fresh spawn into a recycled pool slot
# does, but WITHOUT writing an ownership binding - the pre-binding shape that the
# existing check cannot see. Args: case_dir branch
hand_copy_to_branch() {
  local case_dir=$1 branch=$2
  git -C "$case_dir/wt" checkout -q -b "$branch"
}

run_reconcile() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$RECONCILE" "$@"
}

# (r1) The reproduction: lane-a's record still names a slot the pool has since
# handed to lane-b. Neither side carries a binding, so only the branch the copy
# actually has checked out can settle it.
test_unbound_recycled_slot_is_retired() {
  local case_dir out
  case_dir=$(make_home unbound-recycled)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "RETIRED: lane-a" "unbound: the stale pointer is retired"
  assert_contains "$out" "owned by lane-b" "unbound: the report names the owning task"
  assert_contains "$out" "via branch" "unbound: the report names the proof it used"
  assert_grep "worktree_retired=lane-b" "$case_dir/state/lane-a.meta" \
    "unbound: the durable retirement names the proven owner"
  assert_grep "worktree=$case_dir/wt" "$case_dir/state/lane-a.meta" \
    "unbound: the stale pointer is kept as history, not deleted"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-b.meta" \
    "unbound: the live owner's own record is left alone"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = fm/lane-b ] \
    || fail "unbound: the copy itself must be untouched"
  pass "reconcile retires a stale pointer over a copy that carries no binding"
}

# (r2) The quiet case that matters most: an old unbound record whose copy is
# still its own. Repairing this would retire a live pointer.
test_own_copy_is_not_reassigned() {
  local case_dir out
  case_dir=$(make_home own-copy)
  record_lane "$case_dir" lane-a

  out=$(run_reconcile "$case_dir" --apply)

  assert_not_contains "$out" "lane-a" "own-copy: a lane holding its own copy is not reported"
  assert_contains "$out" "0 stale pointer(s)" "own-copy: nothing is stale"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "own-copy: a live pointer must never be retired"
  pass "reconcile leaves a lane that still holds its own copy alone"
}

# (r3) One-sided evidence. The copy carries some fm/* branch, but this home has
# no record of that task holding it, so nothing is proven either way.
test_branch_without_a_matching_record_is_unresolved() {
  local case_dir out
  case_dir=$(make_home ghost-branch)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/ghost

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED: lane-a" "ghost: an unconfirmed branch is not a verdict"
  assert_contains "$out" "no record of task ghost" "ghost: the report says what was missing"
  assert_not_contains "$out" "RETIRED" "ghost: nothing is retired on one-sided evidence"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "ghost: the record is left untouched"
  pass "reconcile refuses to call a reassignment from the branch name alone"
}

# (r4) A readable binding is authoritative. A worker that checks out some other
# task's branch inside its OWN copy must not look reassigned.
test_binding_outranks_the_checked_out_branch() {
  local case_dir out
  case_dir=$(make_home binding-wins)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  fm_worktree_binding_write "$case_dir/wt" lane-a \
    || fail "binding-wins: could not bind the copy to lane-a"

  out=$(run_reconcile "$case_dir" --apply)

  assert_not_contains "$out" "RETIRED: lane-a" \
    "binding-wins: the copy's own binding settles ownership"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "binding-wins: lane-a keeps its live pointer"
  assert_contains "$out" "RETIRED: lane-b" \
    "binding-wins: the other claimant is the stale one here"
  pass "reconcile trusts the copy's ownership binding over its checked-out branch"
}

# (r5) Reporting must be the default; a repair tool that mutates on a bare
# invocation cannot be run to find out what it would do.
test_default_run_changes_nothing() {
  local case_dir out
  case_dir=$(make_home dry-run)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b

  out=$(run_reconcile "$case_dir")

  assert_contains "$out" "STALE: lane-a" "dry-run: the stale pointer is reported"
  assert_contains "$out" "re-run with --apply" "dry-run: the report names the repair"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "dry-run: a default run must not write"
  pass "reconcile reports without changing anything unless --apply is given"
}

# (r6) Re-runnable, because this accumulation is structural and will need
# draining again rather than being caught in one pass.
test_rerun_is_idempotent() {
  local case_dir out before
  case_dir=$(make_home rerun)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  run_reconcile "$case_dir" --apply >/dev/null
  before=$(cat "$case_dir/state/lane-a.meta")

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "1 already retired" "rerun: an already-retired pointer is counted"
  assert_not_contains "$out" "RETIRED: lane-a" "rerun: it is not retired twice"
  [ "$(cat "$case_dir/state/lane-a.meta")" = "$before" ] \
    || fail "rerun: the record must not be rewritten on a second pass"
  pass "reconcile is idempotent across repeated runs"
}

# (r7) A pooled slot sitting on a detached HEAD says nothing about ownership.
test_detached_head_is_unresolved() {
  local case_dir out
  case_dir=$(make_home detached)
  record_lane "$case_dir" lane-a
  git -C "$case_dir/wt" checkout -q --detach

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED: lane-a" "detached: ownership is unprovable"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "detached: nothing is retired"
  pass "reconcile leaves a copy on a detached HEAD alone"
}

# (r8) A secondmate home is a persistent home, not a pooled slot; it is never
# recycled underneath its record and its own removal validation owns it.
test_secondmate_home_is_skipped() {
  local case_dir out
  case_dir=$(make_home secondmate)
  fm_write_meta "$case_dir/state/lane-a.meta" \
    "window=firstmate:fm-lane-a" \
    "endpoint_task_id=lane-a" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=no-mistakes"
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b

  out=$(run_reconcile "$case_dir" --apply)

  assert_not_contains "$out" "lane-a" "secondmate: a persistent home is out of scope"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "secondmate: its record is untouched"
  pass "reconcile skips secondmate homes"
}

# (r9) Every stale pointer belongs to a deliberately paused lane, and ANY status
# append re-declares that lane's current state and un-throttles its pause. A
# repair that announced itself in the status log would wake every lane it fixed.
test_repair_never_touches_the_status_log() {
  local case_dir
  case_dir=$(make_home quiet-status)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  printf 'paused [key=preserved]: do not clean up\n' > "$case_dir/state/lane-a.status"

  run_reconcile "$case_dir" --apply >/dev/null

  [ "$(cat "$case_dir/state/lane-a.status")" = 'paused [key=preserved]: do not clean up' ] \
    || fail "quiet-status: the repair must not append to a paused lane's status log"
  assert_absent "$case_dir/state/lane-b.status" \
    "quiet-status: the repair must not create a status log for the live lane"
  pass "reconcile repairs records without waking any paused lane"
}

# (r10) --help must stay a pure read, and must keep describing the real script.
test_help_is_a_pure_read() {
  local case_dir out rc
  case_dir=$(make_home help)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b

  set +e
  out=$(run_reconcile "$case_dir" --help)
  rc=$?
  set -e

  expect_code 0 "$rc" "help: --help exits cleanly"
  assert_contains "$out" "Usage: fm-reconcile-worktree-pointers.sh [--apply]" \
    "help: --help states how to run the repair"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "help: --help must never change a record"
  pass "--help prints the script's own documentation and changes nothing"
}

test_unbound_recycled_slot_is_retired
test_own_copy_is_not_reassigned
test_branch_without_a_matching_record_is_unresolved
test_binding_outranks_the_checked_out_branch
test_default_run_changes_nothing
test_rerun_is_idempotent
test_detached_head_is_unresolved
test_secondmate_home_is_skipped
test_repair_never_touches_the_status_log
test_help_is_a_pure_read
