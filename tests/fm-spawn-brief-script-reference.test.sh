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
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_BLOCK_ENTERED:-}" ] && [ -s "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}" ]; then
      : > "$FM_FAKE_PANE_BLOCK_ENTERED"
      while [ ! -e "${FM_FAKE_PANE_BLOCK_RELEASE:?FM_FAKE_PANE_BLOCK_RELEASE unset}" ]; do
        /bin/sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"
    exit 0
    ;;
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
    case "${FM_FAKE_TREEHOUSE_RESULT:-complete}" in
      missing-lease-id)
        printf '{"path":"%s","lease_holder":"%s"}\n' \
          "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
          "${FM_FAKE_TREEHOUSE_HOLDER:?FM_FAKE_TREEHOUSE_HOLDER unset}"
        ;;
      missing-path)
        printf '{"lease_id":"%s","lease_holder":"%s"}\n' \
          "${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset}" \
          "${FM_FAKE_TREEHOUSE_HOLDER:?FM_FAKE_TREEHOUSE_HOLDER unset}"
        ;;
      *)
        printf '{"path":"%s","lease_id":"%s","lease_holder":"%s"}\n' \
          "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
          "${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset}" \
          "${FM_FAKE_TREEHOUSE_HOLDER:?FM_FAKE_TREEHOUSE_HOLDER unset}"
        ;;
    esac
    printf '%s\n' "$FM_FAKE_TREEHOUSE_LEASE_ID" > "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}"
    : > "${FM_FAKE_TREEHOUSE_ALLOCATION:?FM_FAKE_TREEHOUSE_ALLOCATION unset}"
    if [ -n "${FM_FAKE_TREEHOUSE_GET_ENTERED:-}" ]; then
      : > "$FM_FAKE_TREEHOUSE_GET_ENTERED"
      while [ ! -e "${FM_FAKE_TREEHOUSE_GET_RELEASE:?FM_FAKE_TREEHOUSE_GET_RELEASE unset}" ]; do
        /bin/sleep 0.01
      done
    fi
    ;;
  status)
    if [ "${FM_FAKE_TREEHOUSE_STATUS_FAIL_AFTER_GET_ONCE:-0}" = 1 ] \
       && [ -e "${FM_FAKE_TREEHOUSE_ALLOCATION:?FM_FAKE_TREEHOUSE_ALLOCATION unset}" ] \
       && [ ! -e "${FM_FAKE_TREEHOUSE_STATUS_FAILED:?FM_FAKE_TREEHOUSE_STATUS_FAILED unset}" ]; then
      : > "$FM_FAKE_TREEHOUSE_STATUS_FAILED"
      exit 1
    fi
    if [ -e "${FM_FAKE_TREEHOUSE_ALLOCATION:?FM_FAKE_TREEHOUSE_ALLOCATION unset}" ]; then
      printf '[{"path":"%s","status":"leased","lease_id":"%s","lease_holder":"%s","processes":[]}]\n' \
        "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
        "${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset}" \
        "${FM_FAKE_TREEHOUSE_HOLDER:?FM_FAKE_TREEHOUSE_HOLDER unset}"
    else
      printf '[]\n'
    fi
    ;;
  return)
    case " $* " in
      *" --if-lease-id ${FM_FAKE_TREEHOUSE_LEASE_ID:?FM_FAKE_TREEHOUSE_LEASE_ID unset} "*)
        rm -f -- "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}"
        rm -f -- "${FM_FAKE_TREEHOUSE_ALLOCATION:?FM_FAKE_TREEHOUSE_ALLOCATION unset}"
        ;;
      *" --if-lease-holder ${FM_FAKE_TREEHOUSE_HOLDER:?FM_FAKE_TREEHOUSE_HOLDER unset} "*)
        rm -f -- "${FM_FAKE_LEASE:?FM_FAKE_LEASE unset}"
        rm -f -- "${FM_FAKE_TREEHOUSE_ALLOCATION:?FM_FAKE_TREEHOUSE_ALLOCATION unset}"
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
    FM_FAKE_PANE_BLOCK_ENTERED="${FM_FAKE_PANE_BLOCK_ENTERED:-}" \
    FM_FAKE_PANE_BLOCK_RELEASE="${FM_FAKE_PANE_BLOCK_RELEASE:-}" \
    FM_FAKE_TREEHOUSE_PATH="${FM_FAKE_TREEHOUSE_PATH_OVERRIDE:-$POOL_DIR}" \
    FM_FAKE_TREEHOUSE_LEASE_ID="lease-$id" \
    FM_FAKE_TREEHOUSE_HOLDER="$id" \
    FM_FAKE_TREEHOUSE_ALLOCATION="$HOME_DIR/state/$id.treehouse-allocation" \
    FM_FAKE_TREEHOUSE_STATUS_FAILED="$HOME_DIR/state/$id.treehouse-status-failed" \
    FM_FAKE_TREEHOUSE_RESULT="${FM_FAKE_TREEHOUSE_RESULT:-complete}" \
    FM_FAKE_TREEHOUSE_STATUS_FAIL_AFTER_GET_ONCE="${FM_FAKE_TREEHOUSE_STATUS_FAIL_AFTER_GET_ONCE:-0}" \
    FM_FAKE_TREEHOUSE_GET_ENTERED="${FM_FAKE_TREEHOUSE_GET_ENTERED:-}" \
    FM_FAKE_TREEHOUSE_GET_RELEASE="${FM_FAKE_TREEHOUSE_GET_RELEASE:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    exec "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
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

test_object_bearing_directive_reference_refuses() {
  local id=brief-object-command-a31 rec out status expected
  rec=$(make_case object-command "$id" 'Run the helper bin/fm-object-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an object-bearing helper command"
  expected="$POOL_DIR/bin/fm-object-missing.sh"
  assert_contains "$out" "$expected" "object-bearing command did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "object-bearing helper refusal published metadata"
  pass "an object-bearing helper command refuses dispatch"
}

test_prepositional_object_directive_reference_refuses() {
  local id=brief-prepositional-command-a32 rec out status expected
  rec=$(make_case prepositional-command "$id" \
    'Run the command located at bin/fm-prepositional-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a prepositional helper command"
  expected="$POOL_DIR/bin/fm-prepositional-missing.sh"
  assert_contains "$out" "$expected" \
    "prepositional command did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "prepositional helper refusal published metadata"
  pass "a prepositional helper command refuses dispatch"
}

test_dotted_helper_reference_refuses() {
  local id=brief-dotted-a18 rec out status expected
  rec=$(make_case dotted-command "$id" 'Run bin/fm-dotted-missing.v2.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent dotted helper command"
  expected="$POOL_DIR/bin/fm-dotted-missing.v2.sh"
  assert_contains "$out" "$expected" "dotted helper did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "dotted helper refusal published metadata"
  pass "a dotted helper basename is checked before dispatch"
}

test_punctuated_helper_reference_refuses() {
  local id=brief-punctuated-a21 rec out status expected
  rec=$(make_case punctuated-command "$id" 'Run bin/fm-missing+v2.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent punctuated helper command"
  expected="$POOL_DIR/bin/fm-missing+v2.sh"
  assert_contains "$out" "$expected" "punctuated helper did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "punctuated helper refusal published metadata"
  pass "a punctuated helper basename is checked before dispatch"
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

test_assurance_imperative_reference_refuses() {
  local id=brief-assurance-a34 rec out status expected
  rec=$(make_case assurance-command "$id" 'Be sure to run bin/fm-assurance-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent helper in an assurance instruction"
  expected="$POOL_DIR/bin/fm-assurance-missing.sh"
  assert_contains "$out" "$expected" "assurance instruction did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "assurance helper refusal published metadata"
  pass "an assurance helper instruction refuses dispatch"
}

test_markdown_linked_directive_reference_refuses() {
  local id=brief-markdown-link-a35 rec out status expected
  rec=$(make_case markdown-link-command "$id" \
    'Run [the helper](bin/fm-markdown-link-missing.sh) before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent Markdown-linked helper instruction"
  expected="$POOL_DIR/bin/fm-markdown-link-missing.sh"
  assert_contains "$out" "$expected" \
    "Markdown-linked helper did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "Markdown-linked helper refusal published metadata"
  pass "a Markdown-linked helper instruction refuses dispatch"
}

test_markdown_emphasized_directive_reference_refuses() {
  local id=brief-markdown-emphasis-a36 rec out status expected
  rec=$(make_case markdown-emphasis-command "$id" \
    'Run **bin/fm-markdown-emphasis-missing.sh** before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent Markdown-emphasized helper instruction"
  expected="$POOL_DIR/bin/fm-markdown-emphasis-missing.sh"
  assert_contains "$out" "$expected" \
    "Markdown-emphasized helper did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "Markdown-emphasized helper refusal published metadata"
  pass "a Markdown-emphasized helper instruction refuses dispatch"
}

test_markdown_emphasized_object_directive_reference_refuses() {
  local id=brief-markdown-object-a37 rec out status expected
  rec=$(make_case markdown-object-command "$id" \
    'Run the **helper** bin/fm-markdown-object-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent helper with a Markdown-emphasized command object"
  expected="$POOL_DIR/bin/fm-markdown-object-missing.sh"
  assert_contains "$out" "$expected" \
    "helper with a Markdown-emphasized command object did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "helper with a Markdown-emphasized command object published metadata"
  pass "a helper with a Markdown-emphasized command object refuses dispatch"
}

test_markdown_task_directive_reference_refuses() {
  local id=brief-markdown-task-a43 rec out status expected
  rec=$(make_case markdown-task-command "$id" \
    '- [ ] Run bin/fm-markdown-task-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent Markdown task-list helper instruction"
  expected="$POOL_DIR/bin/fm-markdown-task-missing.sh"
  assert_contains "$out" "$expected" \
    "Markdown task-list helper did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "Markdown task-list helper refusal published metadata"
  pass "a Markdown task-list helper instruction refuses dispatch"
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

test_directed_subject_reference_refuses() {
  local id=brief-directed-subject-a33 rec out status expected
  rec=$(make_case directed-subject-command "$id" \
    'Before editing, you are to run bin/fm-directed-subject-missing.sh.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an absent helper in a directed-subject instruction"
  expected="$POOL_DIR/bin/fm-directed-subject-missing.sh"
  assert_contains "$out" "$expected" "directed-subject instruction did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "directed-subject helper refusal published metadata"
  pass "a directed-subject helper instruction refuses dispatch"
}

test_commissioned_subject_reference_refuses() {
  local id=brief-commissioned-subject-a38 rec out status expected
  rec=$(make_case commissioned-subject-command "$id" \
    'I need you to run bin/fm-commissioned-subject-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a commissioned helper instruction"
  expected="$POOL_DIR/bin/fm-commissioned-subject-missing.sh"
  assert_contains "$out" "$expected" \
    "commissioned-subject instruction did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "commissioned-subject helper refusal published metadata"
  pass "a commissioned-subject helper instruction refuses dispatch"
}

test_interrogative_request_reference_refuses() {
  local id=brief-interrogative-request-a42 rec out status expected
  rec=$(make_case interrogative-request-command "$id" \
    'Can you run bin/fm-interrogative-request-missing.sh before editing?')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an interrogative helper request"
  expected="$POOL_DIR/bin/fm-interrogative-request-missing.sh"
  assert_contains "$out" "$expected" \
    "interrogative request did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "interrogative helper refusal published metadata"
  pass "an interrogative helper request refuses dispatch"
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

test_ordered_imperative_reference_refuses() {
  local id=brief-ordered-a25 rec out status expected
  rec=$(make_case ordered-command "$id" 'First run bin/fm-ordered-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an ordered helper instruction"
  expected="$POOL_DIR/bin/fm-ordered-missing.sh"
  assert_contains "$out" "$expected" "ordered imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "ordered helper refusal published metadata"
  pass "an ordered imperative helper reference refuses dispatch"
}

test_linked_imperative_reference_refuses() {
  local id=brief-linked-a26 rec out status expected
  rec=$(make_case linked-command "$id" 'Start by running bin/fm-linked-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a linked helper instruction"
  expected="$POOL_DIR/bin/fm-linked-missing.sh"
  assert_contains "$out" "$expected" "linked imperative did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "linked helper refusal published metadata"
  pass "a linked imperative helper reference refuses dispatch"
}

test_noun_phrase_directive_reference_refuses() {
  local id=brief-noun-phrase-a27 rec out status expected
  rec=$(make_case noun-phrase-command "$id" \
    'Your first action is to run bin/fm-noun-phrase-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a noun-phrase helper instruction"
  expected="$POOL_DIR/bin/fm-noun-phrase-missing.sh"
  assert_contains "$out" "$expected" "noun-phrase directive did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "noun-phrase helper refusal published metadata"
  pass "a noun-phrase helper directive refuses dispatch"
}

test_colon_labeled_directive_reference_refuses() {
  local id=brief-colon-label-a28 rec out status expected
  rec=$(make_case colon-label-command "$id" 'Run: bin/fm-colon-label-missing.sh before editing.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a colon-labeled helper instruction"
  expected="$POOL_DIR/bin/fm-colon-label-missing.sh"
  assert_contains "$out" "$expected" "colon-labeled directive did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "colon-labeled helper refusal published metadata"

  id=brief-step-label-a30
  rec=$(make_case step-label-command "$id" \
    'Step 1: run bin/fm-step-label-missing.sh before editing.')
  read_case "$rec"
  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a step-labeled helper instruction"
  expected="$POOL_DIR/bin/fm-step-label-missing.sh"
  assert_contains "$out" "$expected" "step-labeled directive did not resolve against the task worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "step-labeled helper refusal published metadata"

  id=brief-colon-prose-a29
  rec=$(make_case colon-label-prose "$id" \
    'Documentation: bin/fm-retired.sh describes the old workflow.')
  read_case "$rec"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "colon-labeled prose was treated as a helper instruction: $out"
  assert_contains "$out" "spawned $id" "colon-labeled prose did not reach worker dispatch"
  pass "colon and step-labeled helper directives refuse dispatch"
}

test_negative_modal_reference_passes() {
  local id=brief-negative-modal-a8 rec out status
  rec=$(make_case negative-modal "$id" 'You must never run bin/fm-negative-only.sh.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "a prohibition was treated as an executable helper instruction: $out"
  assert_contains "$out" "spawned $id" "a prohibition did not reach worker dispatch"
  pass "a prohibited helper mention is not treated as executable"
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
  assert_not_contains "$out" "fm-old-helper.sh" "the prohibited helper was treated as executable"
  pass "mixed clauses validate only the affirmative helper instruction"
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
  assert_not_contains "$out" "fm-old-helper.sh" "the prohibited sentence was treated as executable"
  pass "separate sentences validate only the affirmative helper instruction"
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

test_fresh_metadata_publication_waits_for_identity_lock() {
  local id=brief-meta-lock-a37 rec lock out_file pid status
  rec=$(make_case meta-lock "$id" 'Proceed with the task.')
  read_case "$rec"
  lock=$(fm_meta_lock_path "$HOME_DIR/state/$id.meta") || \
    fail "could not resolve the fixture metadata lock"
  fm_lock_acquire_wait "$lock"
  out_file="$HOME_DIR/state/$id.spawn-output"
  run_spawn "$id" >"$out_file" &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_lock_release "$lock"
    wait "$pid" || true
    fail "fresh spawn did not wait for the held metadata lock: $(cat "$out_file")"
  fi
  assert_absent "$HOME_DIR/state/$id.meta" \
    "fresh spawn published metadata while its identity lock was held"
  fm_lock_release "$lock"
  wait "$pid"
  status=$?
  expect_code 0 "$status" \
    "fresh spawn failed after the metadata lock was released: $(cat "$out_file")"
  assert_present "$HOME_DIR/state/$id.meta" \
    "fresh spawn did not publish metadata after the identity lock was released"
  pass "fresh metadata publication waits for its task identity lock"
}

test_pool_transition_lock_releases_before_endpoint_settle() {
  local id=brief-pool-release-a21 rec lock out_file entered release pid status i
  rec=$(make_case pool-release "$id" 'Proceed with the task.')
  read_case "$rec"
  lock=$(fm_worktree_pool_transition_lock_path "$HOME_DIR/state" "$PROJECT_DIR") || \
    fail "could not resolve the fixture pool transition lock"
  entered="$HOME_DIR/state/$id.pane-block-entered"
  release="$HOME_DIR/state/$id.pane-block-release"
  out_file="$HOME_DIR/state/$id.spawn-output"
  FM_FAKE_PANE_BLOCK_ENTERED=$entered
  FM_FAKE_PANE_BLOCK_RELEASE=$release
  run_spawn "$id" >"$out_file" &
  pid=$!
  i=0
  while [ ! -e "$entered" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    /bin/sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$entered" ]; then
    : > "$release"
    wait "$pid" || true
    unset FM_FAKE_PANE_BLOCK_ENTERED FM_FAKE_PANE_BLOCK_RELEASE
    fail "spawn did not reach the blocked endpoint-settle read: $(cat "$out_file")"
  fi
  if ! fm_worktree_binding_matches "$POOL_DIR" "$HOME_DIR/state" "$id"; then
    : > "$release"
    wait "$pid" || true
    unset FM_FAKE_PANE_BLOCK_ENTERED FM_FAKE_PANE_BLOCK_RELEASE
    fail "spawn did not publish ownership before endpoint settling"
  fi
  if ! fm_lock_try_acquire "$lock"; then
    : > "$release"
    wait "$pid" || true
    unset FM_FAKE_PANE_BLOCK_ENTERED FM_FAKE_PANE_BLOCK_RELEASE
    fail "pool transition lock remained held during endpoint settling"
  fi
  fm_lock_release "$lock"
  : > "$release"
  wait "$pid"
  status=$?
  unset FM_FAKE_PANE_BLOCK_ENTERED FM_FAKE_PANE_BLOCK_RELEASE
  expect_code 0 "$status" "spawn failed after endpoint settling resumed: $(cat "$out_file")"
  assert_present "$HOME_DIR/state/$id.meta" "spawn did not publish metadata after settling"
  pass "the pool transition lock releases after binding and before endpoint settling"
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

test_conditional_prose_reference_passes() {
  local id=brief-conditional-prose-a15 rec out status
  rec=$(make_case conditional-prose "$id" \
    'If you run bin/fm-conditional-example.sh in older releases, it prints a legacy report.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "conditional historical prose was treated as an instruction: $out"
  assert_contains "$out" "spawned $id" "conditional prose did not reach worker dispatch"
  pass "conditional historical prose is not treated as executable"
}

test_historical_prose_mention_passes() {
  local id=brief-prose-a4 rec out status
  rec=$(make_case prose-only "$id" 'The old workflow used bin/fm-retired.sh; do not run it.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "historical prose was treated as an executable instruction: $out"
  assert_contains "$out" "spawned $id" "historical prose did not reach worker dispatch"
  pass "historical and prohibitive prose does not refuse dispatch"
}

test_descriptive_prose_mention_passes() {
  local id=brief-descriptive-prose-a24 rec out status
  rec=$(make_case descriptive-prose "$id" \
    'Documentation for the command located at bin/fm-retired.sh describes the old workflow.')
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "descriptive prose was treated as an executable instruction: $out"
  assert_contains "$out" "spawned $id" "descriptive prose did not reach worker dispatch"
  pass "descriptive helper prose is not treated as executable"
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

test_missing_lease_identity_rolls_back_the_holder_allocation() {
  local id=brief-missing-lease-id-a22 rec out status
  rec=$(make_case missing-lease-id "$id" 'Proceed with the task.')
  read_case "$rec"

  set +e
  out=$(FM_FAKE_TREEHOUSE_RESULT=missing-lease-id run_spawn "$id")
  status=$?
  set -e

  expect_code 1 "$status" "spawn accepted a lease without an identity: $out"
  assert_contains "$out" "lease without an identity" \
    "malformed lease refusal did not identify the missing field"
  assert_absent "$HOME_DIR/state/$id.endpoint" "malformed lease leaked its fresh endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "malformed lease leaked its holder-owned allocation"
  assert_absent "$HOME_DIR/state/$id.meta" "malformed lease published task metadata"
  pass "a lease missing its identity is returned through its holder guard"
}

test_missing_lease_path_recovers_and_returns_the_exact_allocation() {
  local id=brief-missing-lease-path-a23 rec out status
  rec=$(make_case missing-lease-path "$id" 'Proceed with the task.')
  read_case "$rec"

  set +e
  out=$(FM_FAKE_TREEHOUSE_RESULT=missing-path run_spawn "$id")
  status=$?
  set -e

  expect_code 1 "$status" "spawn accepted a lease without a path: $out"
  assert_contains "$out" "lease without a valid worktree path" \
    "malformed lease refusal did not identify the missing path"
  assert_absent "$HOME_DIR/state/$id.endpoint" "pathless lease leaked its fresh endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "pathless lease leaked its exact allocation"
  assert_absent "$HOME_DIR/state/$id.meta" "pathless lease published task metadata"
  pass "a pathless lease is recovered from pool status and returned exactly"
}

test_missing_lease_path_retries_status_recovery() {
  local id=brief-missing-lease-path-retry-a25 rec out status
  rec=$(make_case missing-lease-path-retry "$id" 'Proceed with the task.')
  read_case "$rec"

  set +e
  out=$(FM_FAKE_TREEHOUSE_RESULT=missing-path \
    FM_FAKE_TREEHOUSE_STATUS_FAIL_AFTER_GET_ONCE=1 run_spawn "$id")
  status=$?
  set -e

  expect_code 1 "$status" "spawn accepted a lease without a path after status retry: $out"
  assert_contains "$out" "lease without a valid worktree path" \
    "retried malformed lease refusal did not identify the missing path"
  assert_absent "$HOME_DIR/state/$id.endpoint" "status retry leaked its fresh endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "status retry leaked its exact allocation"
  assert_absent "$HOME_DIR/state/$id.meta" "status retry published task metadata"
  pass "a pathless lease survives transient status failure during rollback"
}

test_allocation_interruption_rolls_back_the_exact_lease() {
  local id=brief-allocation-interrupt-a26 rec entered release pid i rc
  rec=$(make_case allocation-interrupt "$id" 'Proceed with the task.')
  read_case "$rec"
  entered="$HOME_DIR/state/$id.get-entered"
  release="$HOME_DIR/state/$id.get-release"

  FM_FAKE_TREEHOUSE_GET_ENTERED="$entered" FM_FAKE_TREEHOUSE_GET_RELEASE="$release" \
    run_spawn "$id" > "$HOME_DIR/state/$id.spawn.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$entered" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  assert_present "$entered" "spawn did not reach the allocated lease boundary"
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt worktree allocation"
  : > "$release"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ] \
    || fail "allocation-interrupted spawn exited with $rc: $(cat "$HOME_DIR/state/$id.spawn.out")"
  assert_absent "$HOME_DIR/state/$id.endpoint" "interrupted allocation leaked its endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "interrupted allocation leaked its exact lease"
  assert_absent "$HOME_DIR/state/$id.treehouse-allocation" \
    "interrupted allocation remained in pool status"
  assert_absent "$HOME_DIR/state/$id.meta" "interrupted allocation published task metadata"
  pass "an allocation interruption rolls back its exact lease"
}

test_metadata_publication_interruption_rolls_back_the_exact_incarnation() {
  local id=brief-metadata-interrupt-a27 rec hook out status
  rec=$(make_case metadata-interrupt "$id" 'Proceed with the task.')
  read_case "$rec"
  hook="$HOME_DIR/state/$id.bash-env"
  cat > "$hook" <<'SH'
if [ "${0:-}" = "${FM_TEST_SIGNAL_SPAWN_SCRIPT:-}" ]; then
  fm_test_signal_after_metadata() {
    trap - DEBUG
    if [ -f "${FM_TEST_SIGNAL_META:?FM_TEST_SIGNAL_META unset}" ] \
       && grep -q '^spawn_gen=' "$FM_TEST_SIGNAL_META"; then
      : > "${FM_TEST_SIGNAL_MARKER:?FM_TEST_SIGNAL_MARKER unset}"
      kill -TERM "${BASHPID:-$$}"
      return
    fi
    trap fm_test_signal_after_metadata DEBUG
  }
  trap fm_test_signal_after_metadata DEBUG
fi
SH

  set +e
  out=$(BASH_ENV="$hook" \
    FM_TEST_SIGNAL_SPAWN_SCRIPT="$SPAWN" \
    FM_TEST_SIGNAL_META="$HOME_DIR/state/$id.meta" \
    FM_TEST_SIGNAL_MARKER="$HOME_DIR/state/$id.signal-fired" \
    run_spawn "$id")
  status=$?
  set -e

  expect_code 143 "$status" "metadata-interrupted spawn exited unexpectedly: $out"
  assert_present "$HOME_DIR/state/$id.signal-fired" "metadata publication interruption did not fire"
  assert_absent "$HOME_DIR/state/$id.meta" "interrupted spawn retained its published metadata"
  assert_absent "$HOME_DIR/state/$id.endpoint" "metadata interruption leaked its endpoint"
  assert_absent "$HOME_DIR/state/$id.lease" "metadata interruption leaked its exact lease"
  assert_absent "$HOME_DIR/state/$id.treehouse-allocation" \
    "metadata interruption remained in pool status"
  fm_worktree_binding_is_absent "$POOL_DIR" \
    || fail "metadata interruption left an orphan worktree binding"
  pass "metadata publication interruption rolls back its exact incarnation"
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
test_object_bearing_directive_reference_refuses
test_prepositional_object_directive_reference_refuses
test_dotted_helper_reference_refuses
test_punctuated_helper_reference_refuses
test_prefixed_imperative_reference_refuses
test_modal_imperative_reference_refuses
test_bare_modal_imperative_reference_refuses
test_infinitive_imperative_reference_refuses
test_assurance_imperative_reference_refuses
test_markdown_linked_directive_reference_refuses
test_markdown_emphasized_directive_reference_refuses
test_markdown_emphasized_object_directive_reference_refuses
test_markdown_task_directive_reference_refuses
test_second_person_imperative_reference_refuses
test_directed_subject_reference_refuses
test_commissioned_subject_reference_refuses
test_interrogative_request_reference_refuses
test_unenumerated_imperative_reference_refuses
test_ordered_imperative_reference_refuses
test_linked_imperative_reference_refuses
test_noun_phrase_directive_reference_refuses
test_colon_labeled_directive_reference_refuses
test_negative_modal_reference_passes
test_mixed_negation_still_refuses_positive_instruction
test_sentence_after_negation_still_refuses_positive_instruction
test_historical_prose_mention_passes
test_descriptive_prose_mention_passes
test_dont_forget_reference_refuses
test_brief_parser_failure_refuses_and_rolls_back
test_missing_lease_identity_rolls_back_the_holder_allocation
test_missing_lease_path_recovers_and_returns_the_exact_allocation
test_missing_lease_path_retries_status_recovery
test_allocation_interruption_rolls_back_the_exact_lease
test_metadata_publication_interruption_rolls_back_the_exact_incarnation
test_linked_homes_share_pool_transition_lock
test_pool_transition_lock_precedes_allocation
test_fresh_metadata_publication_waits_for_identity_lock
test_pool_transition_lock_releases_before_endpoint_settle
test_prepublication_failure_rolls_back_fresh_resources
test_invalid_allocated_worktree_returns_exact_lease
test_conditional_prose_reference_passes

echo "# all fm-spawn-brief-script-reference tests passed"
