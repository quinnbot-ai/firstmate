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
  get)
    printf '{"path":"%s","lease_id":"%s","lease_holder":"fixture"}\n' \
      "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
      "${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset}"
    printf '%s\n' "$FM_FAKE_TREEHOUSE_LEASE_ID" > "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}"
    ;;
  return)
    case " $* " in
      *" --if-lease-id ${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset} "*)
        rm -f -- "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}"
        ;;
      *) exit 1 ;;
    esac
    ;;
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
    FM_BUSY_LOCK_STALE_SECS="${FM_TEST_BUSY_LOCK_STALE_SECS:-5}" \
    FM_FAKE_ENDPOINT="$HOME_DIR/state/$id.endpoint" \
    FM_FAKE_LEASE="$HOME_DIR/state/$id.lease" \
    FM_FAKE_TREEHOUSE_PATH="${FM_FAKE_TREEHOUSE_PATH_OVERRIDE:-$POOL_DIR}" \
    FM_FAKE_TREEHOUSE_LEASE_ID="lease-$id" \
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

test_bare_modal_imperative_reference_refuses() {
  local id=brief-bare-modal-a16 rec out status expected
  rec=$(make_case bare-modal-command "$id" 'Must run bin/fm-bare-modal-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent bare-modal helper command"
  expected="$POOL_DIR/bin/fm-bare-modal-missing.sh"
  assert_contains "$out" "$expected" "bare-modal imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "bare-modal helper refusal published metadata"
  pass "a bare-modal imperative helper reference refuses dispatch"
}

test_infinitive_imperative_reference_refuses() {
  local id=brief-infinitive-a12 rec out status expected
  rec=$(make_case infinitive-command "$id" 'Make sure to run bin/fm-infinitive-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent infinitive helper command"
  expected="$POOL_DIR/bin/fm-infinitive-missing.sh"
  assert_contains "$out" "$expected" "infinitive imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "infinitive helper refusal published metadata"
  pass "an infinitive imperative helper reference refuses dispatch"
}

test_second_person_imperative_reference_refuses() {
  local id=brief-second-person-a13 rec out status expected
  rec=$(make_case second-person-command "$id" 'Ensure you run bin/fm-second-person-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a second-person helper instruction"
  expected="$POOL_DIR/bin/fm-second-person-missing.sh"
  assert_contains "$out" "$expected" "second-person imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "second-person helper refusal published metadata"
  pass "a second-person imperative helper reference refuses dispatch"
}

test_unenumerated_imperative_reference_refuses() {
  local id=brief-unenumerated-a18 rec out status expected
  rec=$(make_case unenumerated-command "$id" 'Launch bin/fm-launch-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent helper in an affirmative directive"
  expected="$POOL_DIR/bin/fm-launch-missing.sh"
  assert_contains "$out" "$expected" "an unenumerated imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "unenumerated helper refusal published metadata"
  pass "an affirmative helper directive does not depend on an execution-verb allowlist"
}

test_negative_modal_reference_refuses() {
  local id=brief-negative-modal-a8 rec out status
  rec=$(make_case negative-modal "$id" 'You must never run bin/fm-negative-only.sh.')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  expect_code 1 "$status" "an absent helper in a negative instruction dispatched: $out"
  assert_contains "$out" "fm-negative-only.sh" "the negative helper reference was not diagnosed"
  pass "a syntactic helper reference refuses without natural-language inference"
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
  assert_contains "$out" "fm-old-helper.sh" "the first syntactic helper reference was not diagnosed"
  pass "mixed clauses validate every syntactic helper reference"
}

test_sentence_after_negation_still_refuses_positive_instruction() {
  local id=brief-sentence-a11 rec out status
  rec=$(make_case sentence-negation "$id" 'Do not run bin/fm-old-helper.sh. Instead run bin/fm-sentence-missing.sh.')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id" 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "a positive sentence after a negated sentence dispatched: $out"
  assert_contains "$out" "fm-sentence-missing.sh" \
    "the positive sentence's missing helper was not diagnosed"
  assert_contains "$out" "fm-old-helper.sh" "the negated sentence's helper reference was not diagnosed"
  pass "separate sentences validate every syntactic helper reference"
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

test_prepublication_failure_rolls_back_fresh_resources() {
  local id=brief-abort-a14 rec out status
  rec=$(make_case prepublication-abort "$id" 'Proceed with the task.')
  read_case "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  : > "$HOME_DIR/state/$id.busy-state.lock"
  FM_TEST_BUSY_LOCK_STALE_SECS=9999

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  unset FM_TEST_BUSY_LOCK_STALE_SECS
  [ "$status" -ne 0 ] || fail "spawn succeeded despite the blocked busy-state publication"
  assert_contains "$out" "failed to arm the busy-state contract" \
    "fixture did not fail after fresh ownership binding"
  assert_absent "$HOME_DIR/state/$id.meta" "failed spawn published task metadata"
  assert_absent "$HOME_DIR/state/$id.endpoint" "failed spawn leaked its endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "failed spawn leaked its pooled lease"
  fm_worktree_binding_is_absent "$POOL_DIR" \
    || fail "failed spawn left an orphan worktree binding"
  pass "a prepublication failure rolls back its exact fresh resources"
}

test_invalid_allocated_worktree_returns_exact_lease() {
  local id=brief-invalid-lease-a17 rec out status
  rec=$(make_case invalid-allocated-worktree "$id" 'Proceed with the task.')
  read_case "$rec"
  FM_FAKE_TREEHOUSE_PATH_OVERRIDE=$PROJECT_DIR

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  unset FM_FAKE_TREEHOUSE_PATH_OVERRIDE
  [ "$status" -ne 0 ] || fail "spawn accepted the primary checkout as an allocated worktree"
  assert_contains "$out" "did not yield an isolated worktree" \
    "fixture did not fail at allocated-worktree validation"
  assert_absent "$HOME_DIR/state/$id.endpoint" "invalid allocation leaked its endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "invalid allocation leaked its exact durable lease"
  pass "an invalid allocation returns only its exact durable lease"
}

test_conditional_prose_reference_refuses() {
  local id=brief-conditional-prose-a15 rec out status
  rec=$(make_case conditional-prose "$id" \
    'If you run bin/fm-conditional-example.sh in older releases, it prints a legacy report.')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  expect_code 1 "$status" "an absent helper in conditional prose dispatched: $out"
  assert_contains "$out" "fm-conditional-example.sh" "the conditional helper reference was not diagnosed"
  pass "conditional prose cannot bypass syntactic helper validation"
}

test_prose_only_mention_refuses() {
  local id=brief-prose-a4 rec out status
  # shellcheck disable=SC2016 # The literal variable reference exercises the prose parser path.
  rec=$(make_case prose-only "$id" 'The historical examples run `$FM_ROOT/bin/fm-prose-only.sh` only as background context.')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  expect_code 1 "$status" "an absent helper in prose dispatched: $out"
  assert_contains "$out" "fm-prose-only.sh" "the prose helper reference was not diagnosed"
  pass "prose cannot bypass syntactic helper validation"
}

test_dont_forget_reference_refuses() {
  local id=brief-dont-forget-a19 rec out status
  rec=$(make_case dont-forget "$id" "Don't forget to run bin/fm-dont-forget-missing.sh before editing.")
  read_case "$rec"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  expect_code 1 "$status" "an affirmative don't-forget helper instruction dispatched: $out"
  assert_contains "$out" "fm-dont-forget-missing.sh" "the don't-forget helper was not diagnosed"
  pass "don't-forget instructions cannot bypass helper validation"
}

test_brief_parser_failure_refuses_and_rolls_back() {
  local id=brief-parser-failure-a21 rec out status
  rec=$(make_case parser-failure "$id" 'Run bin/fm-any-helper.sh before editing.')
  read_case "$rec"
  cat > "$FAKEBIN_DIR/perl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$FAKEBIN_DIR/perl"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e

  expect_code 1 "$status" "spawn dispatched after its brief parser failed: $out"
  assert_contains "$out" "could not inspect brief helper references" \
    "parser failure did not produce a fail-closed refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "parser failure published worker metadata"
  assert_absent "$HOME_DIR/state/$id.endpoint" "parser failure leaked its fresh endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "parser failure leaked its pooled worktree lease"
  pass "brief parser failures refuse dispatch and roll back fresh resources"
}

test_linked_homes_share_pool_transition_lock() {
  local rec linked state_a state_b lock_a lock_b
  rec=$(make_case cross-home-pool-lock brief-cross-home-a20 'Proceed with the task.')
  read_case "$rec"
  linked="${PROJECT_DIR}-linked"
  state_a="$HOME_DIR/state"
  state_b="${HOME_DIR}-peer/state"
  mkdir -p "$state_b"
  git -C "$PROJECT_DIR" worktree add -q -b fm/cross-home-lock "$linked" main

  lock_a=$(fm_worktree_pool_transition_lock_path "$state_a" "$PROJECT_DIR") \
    || fail "could not resolve the primary home's pool lock"
  lock_b=$(fm_worktree_pool_transition_lock_path "$state_b" "$linked") \
    || fail "could not resolve the linked home's pool lock"
  [ "$lock_a" = "$lock_b" ] \
    || fail "linked Firstmate homes resolved different pool locks: $lock_a != $lock_b"
  pass "linked Firstmate homes share one repository pool lock"
}

test_absent_variable_expanded_helper_refuses_at_task_worktree
test_present_helper_passes
test_fenced_command_reference_refuses
test_unquoted_command_reference_refuses
test_prefixed_imperative_reference_refuses
test_modal_imperative_reference_refuses
test_bare_modal_imperative_reference_refuses
test_infinitive_imperative_reference_refuses
test_second_person_imperative_reference_refuses
test_unenumerated_imperative_reference_refuses
test_negative_modal_reference_refuses
test_mixed_negation_still_refuses_positive_instruction
test_sentence_after_negation_still_refuses_positive_instruction
test_prose_only_mention_refuses
test_dont_forget_reference_refuses
test_brief_parser_failure_refuses_and_rolls_back
test_linked_homes_share_pool_transition_lock
test_pool_transition_lock_precedes_allocation
test_prepublication_failure_rolls_back_fresh_resources
test_invalid_allocated_worktree_returns_exact_lease
test_conditional_prose_reference_refuses

echo "# all fm-spawn-brief-script-reference tests passed"
