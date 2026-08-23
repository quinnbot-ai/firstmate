#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-binding-lib.sh disable=SC1091
. "$ROOT/bin/fm-worktree-binding-lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-worktree-guard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_active_worktree_presence_is_captured_with_ownership() {
  local home fakebin project worktree moved fake_crew out
  home="$TMP_ROOT/home"
  project="$home/project"
  worktree="$home/projects/owned-copy"
  moved="$worktree.reassigned"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_worktree "$project" "$worktree" active-worktree-snapshot
  fm_write_meta "$home/state/active-task.meta" \
    "window=firstmate:fm-active-task" \
    "worktree=$worktree" \
    "worktree_binding=fm-worktree-binding.v2" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  fm_worktree_binding_write "$worktree" "$home/state" active-task \
    || fail "could not publish the active task binding"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  fake_crew="$home/fake-crew-state.sh"
  cat > "$fake_crew" <<'SH'
#!/usr/bin/env bash
if [ -d "${FM_SNAPSHOT_TEST_MOVE_WORKTREE:-}" ]; then
  mv -- "$FM_SNAPSHOT_TEST_MOVE_WORKTREE" "$FM_SNAPSHOT_TEST_MOVED_WORKTREE"
fi
printf 'state: unknown · source: none\n'
SH
  chmod +x "$fake_crew"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_BIN="$fake_crew" \
    FM_SNAPSHOT_TEST_MOVE_WORKTREE="$worktree" FM_SNAPSHOT_TEST_MOVED_WORKTREE="$moved" \
    "$SNAPSHOT" --json)
  assert_present "$moved" "the controlled post-capture reassignment did not run"
  printf '%s' "$out" | jq -e --arg worktree "$worktree" '
    .tasks[] | select(.id == "active-task")
    | .paths.worktree == {path:$worktree,present:true}
  ' >/dev/null || fail "worktree presence was read after its ownership snapshot: $out"
  pass "fleet snapshots capture active worktree presence with ownership"
}

test_active_worktree_presence_is_captured_with_ownership
