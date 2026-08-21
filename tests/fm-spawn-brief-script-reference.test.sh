#!/usr/bin/env bash
# Behavior tests for the worker-brief helper-script preflight in fm-spawn.sh.
#
# These use the real spawn path through a fake tmux/treehouse transport.  The
# pane reports the pooled task worktree, so the preflight is proven against the
# location where the worker will actually run rather than the firstmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-script-reference)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id> <brief-body> [present-helper]
make_case() {
  local name=$1 id=$2 brief_body=$3 present_helper=${4:-} dir home project pool fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  pool="$dir/pool"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$brief_body" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$pool" "pool-$name"
  if [ -n "$present_helper" ]; then
    mkdir -p "$project/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$project/bin/$present_helper"
    chmod +x "$project/bin/$present_helper"
    git -C "$project" add "bin/$present_helper"
    git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'add helper fixture'
    git -C "$project" push --quiet origin HEAD
  fi
  printf '%s\n' "$home|$project|$pool|$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

test_absent_variable_expanded_helper_refuses_at_task_worktree() {
  local id=brief-missing-var-a1 rec out status expected
  # shellcheck disable=SC2016 # Fixture must preserve the literal brief variable.
  rec=$(make_case missing-variable "$id" 'Run `$FM_ROOT/bin/fm-missing-helper.sh` before editing.')
  read_case "$rec"
  mkdir -p "$HOME_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/bin/fm-missing-helper.sh"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent helper named by its brief"
  expected="$POOL_DIR/bin/fm-missing-helper.sh"
  assert_contains "$out" "$expected" "refusal did not resolve \$FM_ROOT against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published worker metadata"
  pass "an absent variable-expanded helper refuses with its task-worktree path"
}

test_present_helper_passes() {
  local id=brief-present-a2 rec out status
  # shellcheck disable=SC2016 # Fixture must preserve the literal inline command.
  rec=$(make_case present-helper "$id" 'Run `bin/fm-present-helper.sh` before editing.' fm-present-helper.sh)
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should allow a helper present in the task worktree: $out"
  assert_contains "$out" "spawned $id" "present helper did not reach worker dispatch"
  pass "a present brief helper passes the preflight"
}

test_fenced_command_reference_refuses() {
  local id=brief-fenced-a3 rec out status expected brief
  brief=$'```bash\n$FM_ROOT/bin/fm-fenced-missing.sh\n```'
  rec=$(make_case fenced-command "$id" "$brief")
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent fenced helper command"
  expected="$POOL_DIR/bin/fm-fenced-missing.sh"
  assert_contains "$out" "$expected" "fenced command did not resolve against the task worktree"
  pass "a fenced helper command is checked before dispatch"
}

test_prose_only_mention_does_not_refuse() {
  local id=brief-prose-a4 rec out status
  # shellcheck disable=SC2016 # Fixture must preserve the literal prose mention.
  rec=$(make_case prose-only "$id" 'The dispatcher uses `$FM_ROOT/bin/fm-prose-only.sh` only as historical context.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a prose-only helper mention should not block dispatch: $out"
  assert_contains "$out" "spawned $id" "prose-only mention did not reach worker dispatch"
  pass "a prose-only helper mention is advisory context, not an invocation"
}

test_absent_variable_expanded_helper_refuses_at_task_worktree
test_present_helper_passes
test_fenced_command_reference_refuses
test_prose_only_mention_does_not_refuse

echo "# all fm-spawn-brief-script-reference tests passed"
