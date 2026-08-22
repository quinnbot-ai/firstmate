#!/usr/bin/env bash
# Behavior tests for the worker-brief helper-script preflight in fm-spawn.sh.
#
# These use the real spawn path through a fake tmux/treehouse transport.  The
# pane reports the pooled task worktree, so the preflight is proven against the
# location where the worker will actually run rather than the firstmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worktree-binding-lib.sh"

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
  new-window) : > "${FM_FAKE_ENDPOINT:?FM_FAKE_ENDPOINT unset}"; printf '@1\n'; exit 0 ;;
  kill-window) rm -f -- "${FM_FAKE_ENDPOINT:?FM_FAKE_ENDPOINT unset}"; exit 0 ;;
  send-keys)
    case "$*" in *"treehouse get"*) : > "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}" ;; esac
    exit 0
    ;;
  list-windows|has-session|new-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  return) rm -f -- "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
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
    FM_FAKE_ENDPOINT="$HOME_DIR/state/$id.endpoint" \
    FM_FAKE_LEASE="$HOME_DIR/state/$id.lease" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

test_absent_variable_expanded_helper_refuses_at_task_worktree() {
  local id=brief-missing-var-a1 rec out status expected
  # shellcheck disable=SC2016 # The brief must retain its literal worker-time variable.
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
  assert_absent "$HOME_DIR/state/$id.endpoint" "refused spawn leaked its fresh endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "refused spawn leaked its pooled worktree lease"
  pass "an absent variable-expanded helper refuses with its task-worktree path"
}

test_present_helper_passes() {
  local id=brief-present-a2 rec out status
  # shellcheck disable=SC2016 # The brief is literal task instruction text, not shell input.
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

test_unquoted_command_reference_refuses() {
  local id=brief-unquoted-a5 rec out status expected
  rec=$(make_case unquoted-command "$id" 'Run bin/fm-unquoted-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent unquoted helper command"
  expected="$POOL_DIR/bin/fm-unquoted-missing.sh"
  assert_contains "$out" "$expected" "unquoted command did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "refused unquoted helper dispatch published metadata"
  pass "an absent unquoted helper command refuses dispatch"
}

test_prefixed_imperative_reference_refuses() {
  local id=brief-prefixed-a6 rec out status expected
  rec=$(make_case prefixed-command "$id" 'Before editing, run bin/fm-prefixed-missing.sh.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent prefixed helper command"
  expected="$POOL_DIR/bin/fm-prefixed-missing.sh"
  assert_contains "$out" "$expected" "prefixed imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "prefixed helper refusal published metadata"
  pass "a prefixed imperative helper reference refuses dispatch"
}

test_modal_imperative_reference_refuses() {
  local id=brief-modal-a7 rec out status expected
  rec=$(make_case modal-command "$id" 'You must run bin/fm-modal-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent modal helper command"
  expected="$POOL_DIR/bin/fm-modal-missing.sh"
  assert_contains "$out" "$expected" "modal imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "modal helper refusal published metadata"
  pass "a modal imperative helper reference refuses dispatch"
}

test_negative_modal_reference_does_not_refuse() {
  local id=brief-negative-modal-a8 rec out status
  rec=$(make_case negative-modal "$id" 'You must never run bin/fm-negative-only.sh.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a negative helper instruction should not block dispatch: $out"
  assert_contains "$out" "spawned $id" "negative helper instruction did not reach worker dispatch"
  pass "a negative modal helper reference does not refuse dispatch"
}

test_mixed_negation_still_refuses_positive_instruction() {
  local id=brief-mixed-a10 rec out status
  rec=$(make_case mixed-negation "$id" 'Do not run bin/fm-old-helper.sh; instead run bin/fm-mixed-missing.sh.')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id" 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "a positive clause after a negated clause dispatched: $out"
  assert_contains "$out" "fm-mixed-missing.sh" "the positive missing helper was not diagnosed"
  assert_not_contains "$out" "resolves in this task worktree to $POOL_DIR/bin/fm-old-helper.sh" \
    "the negated helper was treated as an instruction"
  pass "mixed negation still refuses the positive missing-helper instruction"
}

test_pool_transition_lock_precedes_allocation() {
  local id=brief-pool-lock-a9 rec lock out_file pid status
  rec=$(make_case pool-lock "$id" 'Proceed with the task.')
  read_case "$rec"
  lock=$(fm_worktree_pool_transition_lock_path "$HOME_DIR/state" "$PROJECT_DIR") || \
    fail "could not resolve the fixture pool transition lock"
  fm_lock_acquire_wait "$lock"
  out_file="$HOME_DIR/state/$id.spawn-output"
  run_spawn "$id" >"$out_file" &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_lock_release "$lock"
    wait "$pid" || true
    fail "spawn did not wait for the held pool transition lock: $(cat "$out_file")"
  fi
  assert_present "$HOME_DIR/state/$id.endpoint" "spawn held the pool lock across endpoint creation"
  assert_absent "$HOME_DIR/state/$id.lease" "spawn acquired a pooled worktree while allocation was locked"
  fm_lock_release "$lock"
  wait "$pid"
  status=$?
  expect_code 0 "$status" "spawn failed after the pool transition lock was released: $(cat "$out_file")"
  assert_present "$HOME_DIR/state/$id.lease" "spawn never acquired the pooled worktree after lock release"
  assert_present "$HOME_DIR/state/$id.meta" "spawn never published its binding after lock release"
  pass "the pool transition lock covers allocation through binding publication"
}

test_prose_only_mention_does_not_refuse() {
  local id=brief-prose-a4 rec out status
  # shellcheck disable=SC2016 # The literal variable reference exercises the prose parser path.
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
test_unquoted_command_reference_refuses
test_prefixed_imperative_reference_refuses
test_modal_imperative_reference_refuses
test_negative_modal_reference_does_not_refuse
test_mixed_negation_still_refuses_positive_instruction
test_prose_only_mention_does_not_refuse
test_pool_transition_lock_precedes_allocation

echo "# all fm-spawn-brief-script-reference tests passed"
