#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
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

test_metadata_replacement_uses_one_incarnation() {
  local home fakebin project_a project_b worktree_a worktree_b fake_crew lock
  local wait_marker out_file err_file next_meta pid attempt out real_sleep
  home="$TMP_ROOT/replacement-home"
  project_a="$home/project-a"
  project_b="$home/project-b"
  worktree_a="$home/projects/old-copy"
  worktree_b="$home/projects/current-copy"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_worktree "$project_a" "$worktree_a" fleet-metadata-old
  fm_git_worktree "$project_b" "$worktree_b" fleet-metadata-current
  fm_write_meta "$home/state/reused.meta" \
    "window=firstmate:fm-reused" \
    "worktree=$worktree_a" \
    "worktree_binding=fm-worktree-binding.v2" \
    "project=$project_a" \
    "harness=claude" \
    "kind=scout" \
    "mode=ship" \
    "yolo=off"
  fm_worktree_binding_write "$worktree_a" "$home/state" reused \
    || fail "could not bind the old fleet metadata incarnation"
  fm_worktree_binding_write "$worktree_b" "$home/state" reused \
    || fail "could not bind the replacement fleet metadata incarnation"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  wait_marker="$home/meta-lock.waiting"
  real_sleep=$(command -v sleep)
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
: > "${FM_FAKE_LOCK_WAIT:?FM_FAKE_LOCK_WAIT unset}"
exec "${FM_REAL_SLEEP:?FM_REAL_SLEEP unset}" "$@"
SH
  chmod +x "$fakebin/sleep"
  fake_crew="$home/fake-crew-state.sh"
  cat > "$fake_crew" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none\n'
SH
  chmod +x "$fake_crew"
  lock=$(fm_meta_lock_path "$home/state/reused.meta") \
    || fail "could not resolve the fleet metadata replacement lock"
  fm_lock_acquire_wait "$lock"
  out_file="$home/fleet.out"
  err_file="$home/fleet.err"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_BIN="$fake_crew" \
    FM_FAKE_LOCK_WAIT="$wait_marker" FM_REAL_SLEEP="$real_sleep" \
    "$SNAPSHOT" --json > "$out_file" 2> "$err_file" &
  pid=$!
  attempt=0
  while [ ! -e "$wait_marker" ] && kill -0 "$pid" 2>/dev/null \
    && [ "$attempt" -lt 100 ]; do
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  if [ ! -e "$wait_marker" ]; then
    fm_lock_release "$lock"
    wait "$pid" || true
    fail "fleet snapshot did not wait for the metadata replacement lock: $(cat "$err_file")"
  fi
  next_meta="$home/state/reused.meta.next"
  fm_write_meta "$next_meta" \
    "window=firstmate:fm-reused" \
    "worktree=$worktree_b" \
    "worktree_binding=fm-worktree-binding.v2" \
    "project=$project_b" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=on"
  mv -- "$next_meta" "$home/state/reused.meta"
  fm_lock_release "$lock"
  wait "$pid" || fail "fleet snapshot failed after metadata replacement: $(cat "$err_file")"
  out=$(cat "$out_file")
  printf '%s' "$out" | jq -e \
    --arg project "$project_b" --arg worktree "$worktree_b" '
      .tasks[] | select(.id == "reused")
      | .kind == "ship"
        and .harness == "codex"
        and .mode == "no-mistakes"
        and .yolo == "on"
        and .project == $project
        and .paths.worktree == {path:$worktree,present:true}
    ' >/dev/null || fail "fleet snapshot mixed metadata incarnations: $out"
  pass "fleet snapshot captures one metadata incarnation"
}

test_post_guard_metadata_replacement_skips_mixed_row() {
  local home fakebin project_a project_b worktree fake_crew next_meta out
  home="$TMP_ROOT/post-guard-home"
  project_a="$home/project-a"
  project_b="$home/project-b"
  worktree="$home/projects/old-copy"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$project_b"
  fm_git_worktree "$project_a" "$worktree" fleet-post-guard-old
  fm_write_meta "$home/state/reused.meta" \
    "window=firstmate:fm-reused" \
    "worktree=$worktree" \
    "worktree_binding=fm-worktree-binding.v2" \
    "project=$project_a" \
    "harness=claude" \
    "kind=scout" \
    "mode=ship" \
    "spawn_gen=old-incarnation"
  fm_worktree_binding_write "$worktree" "$home/state" reused \
    || fail "could not bind the pre-replacement fleet metadata"
  next_meta="$home/state/reused.meta.next"
  fm_write_meta "$next_meta" \
    "window=firstmate:fm-reused" \
    "project=$project_b" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=new-incarnation"
  fakebin=$(fm_fakebin "$home")
  fake_crew="$home/fake-crew-state.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'mv -- "${FM_SNAPSHOT_TEST_NEXT_META:?}" "${FM_SNAPSHOT_TEST_META:?}"' \
    'printf "%s\n" "working: replacement-incarnation" > "${FM_SNAPSHOT_TEST_STATUS:?}"' \
    'printf "%s\n" "state: working · source: pane"' > "$fake_crew"
  chmod +x "$fake_crew"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_BIN="$fake_crew" \
    FM_SNAPSHOT_TEST_NEXT_META="$next_meta" \
    FM_SNAPSHOT_TEST_META="$home/state/reused.meta" \
    FM_SNAPSHOT_TEST_STATUS="$home/state/reused.status" \
    "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    [.tasks[] | select(.id == "reused")] | length == 0
  ' >/dev/null || fail "fleet snapshot emitted a mixed post-guard incarnation: $out"
  pass "fleet snapshot skips post-guard metadata replacement"
}

test_active_worktree_presence_is_captured_with_ownership
test_metadata_replacement_uses_one_incarnation
test_post_guard_metadata_replacement_skips_mixed_row
