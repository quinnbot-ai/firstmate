#!/usr/bin/env bash
# Tests for bin/fm-reconcile-worktree-pointers.sh and its binding-independent
# live-endpoint ownership proof.
#
# THE GAP THESE COVER. The current-owner check in bin/fm-teardown.sh reads an
# ownership binding out of the copy, so it protects every copy assigned after
# bindings existed and deliberately does nothing for the collisions that already
# exist - a record with no declared binding, over a copy carrying none. Those are
# exactly the collisions a home accumulates, because the lanes holding stale
# pointers are preserved lanes that are never torn down and therefore never
# repaired. The second proof requires one task's durable record and live endpoint
# to agree on the copy's exact physical path.
#
# Matrix:
#   (r1) unbound copy proven by another task's endpoint  -> STALE, pointer retired
#   (r2) unbound copy proven by this lane's endpoint     -> quiet (nothing to repair)
#   (r3) unbound copy with no live endpoint proof        -> UNRESOLVED, untouched
#   (r4) readable binding disagrees with the branch      -> binding wins, quiet
#   (r5) default run reports without changing anything   -> dry-run by default
#   (r6) re-run over an already-retired pointer          -> counted, not rewritten
#   (r7) copy on a detached HEAD                         -> UNRESOLVED, untouched
#   (r8) kind=secondmate home                            -> skipped entirely
#   (r9) any repair                                      -> never appends to a status log
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
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$case_dir/state" "$case_dir/endpoints"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -t ]; then
    shift
    target=${1:-}
    break
  fi
  shift
done
id=${target##*:fm-}
path_file=${FM_FAKE_ENDPOINT_ROOT:?FM_FAKE_ENDPOINT_ROOT unset}/$id.cwd
[ -f "$path_file" ] || exit 1
IFS= read -r path < "$path_file"
printf '%s\n' "$path"
SH
  chmod +x "$fakebin/tmux"
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

place_endpoint() {
  local case_dir=$1 id=$2 path=${3:-$1/wt}
  printf '%s\n' "$path" > "$case_dir/endpoints/$id.cwd"
}

run_reconcile() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_FAKE_ENDPOINT_ROOT="$case_dir/endpoints" \
    PATH="$case_dir/fake/fakebin:$PATH" "$RECONCILE" "$@"
}

run_reconcile_owner() {
  local case_dir=$1 owner_state=$2 owner_task=$3
  shift 3
  run_reconcile "$case_dir" --owner-state "$owner_state" --owner-task "$owner_task" "$@"
}

# (r1) The reproduction: lane-a's record still names a slot the pool has since
# handed to lane-b. Neither side carries a binding, so lane-b's live endpoint
# and durable record must match the supervisor-supplied owner identity before
# reconciliation establishes an authoritative binding.
test_unbound_recycled_slot_is_retired() {
  local case_dir out state_real
  case_dir=$(make_home unbound-recycled)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-b

  out=$(run_reconcile_owner "$case_dir" "$case_dir/state" lane-b --apply)
  state_real=$(CDPATH='' cd -- "$case_dir/state" && pwd -P)

  assert_contains "$out" "RETIRED: lane-a" "unbound: the stale pointer is retired"
  assert_contains "$out" "owned by lane-b" "unbound: the report names the owning task"
  assert_contains "$out" "via binding" "unbound: the report names the durable proof it established"
  fm_worktree_binding_matches "$case_dir/wt" "$case_dir/state" lane-b \
    || fail "unbound: the asserted owner was not bound before retirement"
  assert_grep "worktree_retired=lane-b" "$case_dir/state/lane-a.meta" \
    "unbound: the durable retirement names the proven owner"
  assert_grep "worktree_retired_state=$state_real" "$case_dir/state/lane-a.meta" \
    "unbound: the durable retirement preserves the owner's state identity"
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
  place_endpoint "$case_dir" lane-a

  out=$(run_reconcile "$case_dir" --apply)

  assert_not_contains "$out" "lane-a" "own-copy: a lane holding its own copy is not reported"
  assert_contains "$out" "0 stale pointer(s)" "own-copy: nothing is stale"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "own-copy: a live pointer must never be retired"
  pass "reconcile leaves a lane that still holds its own copy alone"
}

# (r3) Workspace content alone is not evidence. Without a live endpoint proving
# this copy's path, nothing is proven either way.
test_branch_without_a_matching_record_is_unresolved() {
  local case_dir out
  case_dir=$(make_home ghost-branch)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/ghost

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED: lane-a" "ghost: an unconfirmed branch is not a verdict"
  assert_contains "$out" "no single active task endpoint" "ghost: the report says what was missing"
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
  fm_worktree_binding_write "$case_dir/wt" "$case_dir/state" lane-a \
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

test_binding_distinguishes_same_task_id_across_homes() {
  local case_dir other_state other_state_real out
  case_dir=$(make_home cross-home-same-id)
  other_state="$case_dir/other-state"
  mkdir -p "$other_state"
  record_lane "$case_dir" lane-a
  fm_write_meta "$other_state/lane-a.meta" \
    "window=other:fm-lane-a" \
    "endpoint_task_id=lane-a" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  fm_worktree_binding_write "$case_dir/wt" "$other_state" lane-a \
    || fail "cross-home: could not bind the copy to the other home"

  out=$(run_reconcile "$case_dir" --apply)
  other_state_real=$(CDPATH='' cd -- "$other_state" && pwd -P)

  assert_contains "$out" "RETIRED: lane-a" \
    "cross-home: an equal task id in another home is still a different owner"
  assert_grep "worktree_retired=lane-a" "$case_dir/state/lane-a.meta" \
    "cross-home: the stale local pointer is retired"
  assert_grep "worktree_retired_state=$other_state_real" "$case_dir/state/lane-a.meta" \
    "cross-home: retirement preserves the other home's identity"
  assert_no_grep "worktree_retired" "$other_state/lane-a.meta" \
    "cross-home: the live owner's record is untouched"
  pass "bindings distinguish equal task ids in different Firstmate homes"
}

# (r5) Reporting must be the default; a repair tool that mutates on a bare
# invocation cannot be run to find out what it would do.
test_default_run_changes_nothing() {
  local case_dir out
  case_dir=$(make_home dry-run)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-b

  out=$(run_reconcile_owner "$case_dir" "$case_dir/state" lane-b --dry-run)

  assert_contains "$out" "STALE: lane-a" "dry-run: the stale pointer is reported"
  assert_contains "$out" "re-run with --apply" "dry-run: the report names the repair"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "dry-run: a default run must not write"
  pass "reconcile accepts an explicit dry run without changing anything"
}

test_apply_revalidates_ownership_inside_the_transition_lock() {
  local case_dir holder_pid reconcile_pid out i=0 ready switch
  case_dir=$(make_home ownership-transition)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  record_lane "$case_dir" lane-c
  place_endpoint "$case_dir" lane-b
  ready="$case_dir/transition-ready"
  switch="$case_dir/transition-switch"
  env ROOT="$ROOT" STATE="$case_dir/state" WT="$case_dir/wt" ENDPOINTS="$case_dir/endpoints" \
    READY="$ready" SWITCH="$switch" bash -c '
      . "$ROOT/bin/fm-wake-lib.sh"
      . "$ROOT/bin/fm-worktree-binding-lib.sh"
      lock=$(fm_worktree_transition_lock_path "$STATE" "$WT") || exit 1
      fm_lock_acquire_wait "$lock"
      : > "$READY"
      while [ ! -e "$SWITCH" ]; do /bin/sleep 0.01; done
      rm -f "$ENDPOINTS/lane-b.cwd"
      printf "%s\n" "$WT" > "$ENDPOINTS/lane-c.cwd"
      fm_lock_release "$lock"
    ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "transition lock holder did not start"
  run_reconcile_owner "$case_dir" "$case_dir/state" lane-c --apply > "$case_dir/reconcile.out" &
  reconcile_pid=$!
  /bin/sleep 0.2
  : > "$switch"
  wait "$holder_pid" || fail "ownership transition failed"
  wait "$reconcile_pid" || fail "reconcile failed after ownership transition"
  out=$(cat "$case_dir/reconcile.out")

  assert_contains "$out" "RETIRED: lane-a" "transition: stale claimant is retired"
  assert_grep "worktree_retired=lane-c" "$case_dir/state/lane-a.meta" \
    "transition: retirement records the owner proven after the lock was acquired"
  pass "reconcile revalidates ownership inside the shared transition lock"
}

# (r6) Re-runnable, because this accumulation is structural and will need
# draining again rather than being caught in one pass.
test_rerun_is_idempotent() {
  local case_dir out before
  case_dir=$(make_home rerun)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-b
  run_reconcile_owner "$case_dir" "$case_dir/state" lane-b --apply >/dev/null
  before=$(cat "$case_dir/state/lane-a.meta")

  out=$(run_reconcile_owner "$case_dir" "$case_dir/state" lane-b --apply)

  assert_contains "$out" "1 already retired" "rerun: an already-retired pointer is counted"
  assert_not_contains "$out" "RETIRED: lane-a" "rerun: it is not retired twice"
  [ "$(cat "$case_dir/state/lane-a.meta")" = "$before" ] \
    || fail "rerun: the record must not be rewritten on a second pass"
  pass "reconcile is idempotent across repeated runs"
}

# (r7) A pooled slot with no live endpoint proof says nothing about ownership,
# regardless of its checked-out branch.
test_copy_without_live_endpoint_is_unresolved() {
  local case_dir out
  case_dir=$(make_home detached)
  record_lane "$case_dir" lane-a
  git -C "$case_dir/wt" checkout -q --detach

  out=$(run_reconcile_owner "$case_dir" "$case_dir/state" lane-a --apply)

  assert_contains "$out" "UNRESOLVED: lane-a" "detached: ownership is unprovable"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "detached: nothing is retired"
  pass "reconcile leaves a copy without live endpoint proof alone"
}

test_branch_name_cannot_override_live_endpoint_owner() {
  local case_dir out
  case_dir=$(make_home branch-deception)
  record_lane "$case_dir" lane-a
  hand_copy_to_branch "$case_dir" fm/lane-b
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-a

  out=$(run_reconcile_owner "$case_dir" "$case_dir/state" lane-a --apply)

  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "branch-deception: mutable branch content cannot retire the live owner's pointer"
  assert_grep "worktree_retired=lane-a" "$case_dir/state/lane-b.meta" \
    "branch-deception: the endpoint-proven owner retires only the stale claimant"
  assert_contains "$out" "RETIRED: lane-b" \
    "branch-deception: the stale branch-named claimant is reported"
  pass "live endpoint proof outranks a misleading task branch"
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
  place_endpoint "$case_dir" lane-b

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
  place_endpoint "$case_dir" lane-b
  printf 'paused [key=preserved]: do not clean up\n' > "$case_dir/state/lane-a.status"

  run_reconcile_owner "$case_dir" "$case_dir/state" lane-b --apply >/dev/null

  [ "$(cat "$case_dir/state/lane-a.status")" = 'paused [key=preserved]: do not clean up' ] \
    || fail "quiet-status: the repair must not append to a paused lane's status log"
  assert_absent "$case_dir/state/lane-b.status" \
    "quiet-status: the repair must not create a status log for the live lane"
  pass "reconcile repairs records without waking any paused lane"
}

test_ambiguous_legacy_claimants_require_an_explicit_owner() {
  local case_dir out
  case_dir=$(make_home ambiguous-claimants)
  record_lane "$case_dir" lane-a
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-a

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED:" "ambiguous: automatic legacy ownership fails closed"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "ambiguous: lane-a's live pointer was retired"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-b.meta" \
    "ambiguous: lane-b's pointer was retired"
  pass "reconcile requires an explicit owner when legacy records collide"
}

test_declared_record_without_marker_remains_a_claimant() {
  local case_dir out
  case_dir=$(make_home declared-claimant)
  record_lane "$case_dir" lane-a "worktree_binding=fm-worktree-binding.v2"
  record_lane "$case_dir" lane-b
  place_endpoint "$case_dir" lane-a
  place_endpoint "$case_dir" lane-b

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED:" \
    "declared-claimant: automatic legacy ownership ignored a declared claimant"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "declared-claimant: the declared claimant was retired"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-b.meta" \
    "declared-claimant: the legacy claimant was retired"
  fm_worktree_binding_is_absent "$case_dir/wt" \
    || fail "declared-claimant: ambiguity created an ownership binding"
  pass "declared records remain claimants when their private marker is missing"
}

test_legacy_claimant_inventory_spans_linked_homes() {
  local case_dir mate out
  case_dir=$(make_home linked-home-claimants)
  mate="$case_dir/mate"
  mkdir -p "$case_dir/data" "$mate/state" "$mate/data"
  printf '%s\n' '- mate - fixture (home: '"$mate"'; scope: fixture; projects: sample; added 2026-08-22)' \
    > "$case_dir/data/secondmates.md"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir" \
    > "$mate/.fm-secondmate-parent"
  record_lane "$case_dir" lane-a
  fm_write_meta "$mate/state/lane-b.meta" \
    "window=firstmate:fm-lane-b" \
    "endpoint_task_id=lane-b" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  place_endpoint "$case_dir" lane-a

  out=$(run_reconcile "$case_dir" --apply)

  assert_contains "$out" "UNRESOLVED:" "linked-home: the remote claimant prevents a local verdict"
  assert_no_grep "worktree_retired" "$case_dir/state/lane-a.meta" \
    "linked-home: the local pointer was retired despite the linked-home claimant"
  pass "legacy ownership inventories every linked local Firstmate home"
}

test_legacy_endpoint_proof_supports_every_flat_backend() {
  local case_dir backend
  case_dir=$(make_home flat-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-worktree-owner-lib.sh"
  fm_backend_validate_task_endpoint() {
    FM_BACKEND_VALIDATED_BACKEND=$(fm_meta_get "$1" backend)
    [ -n "$FM_BACKEND_VALIDATED_BACKEND" ] || FM_BACKEND_VALIDATED_BACKEND=tmux
    FM_BACKEND_VALIDATED_TARGET=fixture
  }
  fm_backend_source() { return 0; }
  fm_backend_tmux_current_path() { printf '%s\n' "$case_dir/wt"; }
  fm_backend_herdr_current_path() { printf '%s\n' "$case_dir/wt"; }
  fm_backend_zellij_current_path() { printf '%s\n' "$case_dir/wt"; }
  fm_backend_cmux_current_path() { printf '%s\n' "$case_dir/wt"; }
  for backend in tmux herdr zellij cmux; do
    rm -f "$case_dir/state"/*.meta
    record_lane "$case_dir" lane-a "backend=$backend"
    fm_worktree_owner_resolve "$case_dir/wt" "$case_dir/state" \
      || fail "$backend: legacy ownership proof rejected a supported flat backend"
    [ "$FM_WORKTREE_OWNER_TASK_ID" = lane-a ] \
      || fail "$backend: legacy ownership proof selected the wrong owner"
  done
  pass "legacy ownership proof supports every flat runtime backend"
}

test_unbound_recycled_slot_is_retired
test_own_copy_is_not_reassigned
test_branch_without_a_matching_record_is_unresolved
test_binding_outranks_the_checked_out_branch
test_binding_distinguishes_same_task_id_across_homes
test_default_run_changes_nothing
test_apply_revalidates_ownership_inside_the_transition_lock
test_rerun_is_idempotent
test_copy_without_live_endpoint_is_unresolved
test_branch_name_cannot_override_live_endpoint_owner
test_secondmate_home_is_skipped
test_repair_never_touches_the_status_log
test_ambiguous_legacy_claimants_require_an_explicit_owner
test_declared_record_without_marker_remains_a_claimant
test_legacy_claimant_inventory_spans_linked_homes
test_legacy_endpoint_proof_supports_every_flat_backend
