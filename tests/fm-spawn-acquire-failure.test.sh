#!/usr/bin/env bash
# Regression tests for fm-spawn's worktree-acquisition reporting.
#
# `treehouse get` is typed into the worker's own shell, so a failed acquisition
# used to show up only as a silent wait ending in a generic timeout: the real
# cause (in the incident that motivated this, a stale lock surfacing as exit 128)
# never reached the operator. These tests drive the real spawn path with a fake
# terminal that actually RUNS what fm-spawn types, so the exit status and the
# acquisition tool's own message travel the same route they do live, and prove
# a genuine failure reports both while a timeout stays a clearly labelled
# timeout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-acquire-failure)

# A fake tmux that simulates a pane instead of canning its contents: send-keys
# runs the typed line in a real shell (in the background, as a terminal would),
# `#{pane_current_path}` reports that pane's current directory, and capture-pane
# replays everything the line printed. Nothing about fm-spawn's typed command is
# reproduced here, so whatever it types is what gets executed and observed.
make_pane_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state="${FM_FAKE_PANE_STATE:?FM_FAKE_PANE_STATE unset}"
case "$*" in
  *"#{pane_current_path}"*) cat "$state/cwd"; exit 0 ;;
esac
case "${1:-}" in
  capture-pane) cat "$state/transcript" 2>/dev/null; exit 0 ;;
  send-keys)
    text=""
    prev=""
    for arg in "$@"; do
      [ "$arg" = Enter ] && text="$prev"
      prev="$arg"
    done
    [ -n "$text" ] || exit 0
    (
      cd "$(cat "$state/cwd")" || exit 1
      FM_FAKE_PANE_STATE="$state" sh -c "$text" >> "$state/transcript" 2>&1
    ) &
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> <treehouse-body>: a home, a project, and a fake
# `treehouse` whose body decides how acquisition behaves in the simulated pane.
make_case() {
  local name=$1 id=$2 body=$3 case_dir home project fakebin state
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  state="$case_dir/pane"
  fakebin=$(make_pane_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$state"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$case_dir/origin.git"
  git -C "$project" fetch --quiet origin
  printf '%s\n' "$project" > "$state/cwd"
  : > "$state/transcript"

  printf '#!/bin/sh\n%s\n' "$body" > "$fakebin/treehouse"
  chmod +x "$fakebin/treehouse"

  printf '%s\n' "$case_dir|$home|$project|$fakebin|$state"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR FAKEBIN_DIR PANE_STATE <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_STATE="$PANE_STATE" \
    FM_SPAWN_WORKTREE_POLLS="${FM_TEST_POLLS:-6}" \
    FM_SPAWN_WORKTREE_POLL_INTERVAL="${FM_TEST_POLL_INTERVAL:-0.5}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode direct-PR --yolo off "$@" 2>&1
}

# The incident's shape: acquisition refuses immediately with a real exit status
# and a real message. Both must reach the operator, and the spawn must not sit
# out the settle bound first.
test_failed_acquisition_reports_status_and_message() {
  local rec id out status start elapsed
  id='acquire-refused-p1'
  rec=$(make_case refused "$id" 'echo "Error: all 16 worktrees are in use or dirty" >&2
exit 128')
  read_case_record "$rec"

  start=$(date +%s)
  out=$(run_spawn "$id")
  status=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a refused worktree acquisition"
  assert_contains "$out" "failed with exit status 128" \
    "spawn did not report the acquisition's real exit status"
  assert_contains "$out" "all 16 worktrees are in use or dirty" \
    "spawn did not report what the acquisition tool actually said"
  assert_not_contains "$out" "did not enter a worktree within" \
    "a genuine acquisition failure was reported as a timeout"
  [ "$elapsed" -le 3 ] \
    || fail "an immediate acquisition failure took ${elapsed}s to report - it waited out the settle bound"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "spawn recorded task metadata for a task whose worktree was never acquired"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed acquisition refusal (%ss):\n%s\n' "$elapsed" "$(printf '%s\n' "$out" | tail -n 2)"
  fi
  pass "a refused worktree acquisition reports its real exit status and the tool's own message"
}

# A non-zero status other than the incident's must travel too: the status is
# read from the acquisition, never assumed.
test_reported_status_is_the_acquisition_s_own() {
  local rec id out
  id='acquire-refused-p2'
  rec=$(make_case refused-other "$id" 'echo "fatal: could not lock ref" >&2
exit 3')
  read_case_record "$rec"

  out=$(run_spawn "$id")
  assert_contains "$out" "failed with exit status 3" \
    "spawn did not report the acquisition's own exit status"
  assert_contains "$out" "could not lock ref" \
    "spawn did not report the acquisition tool's message"
  pass "the reported exit status is the one acquisition actually returned"
}

# An acquisition that is simply slow must stay a timeout: labelled as one,
# explicit that nothing reported a failure, and never dressed up with an
# invented exit status.
test_timeout_stays_distinguishable_from_failure() {
  local rec id out status
  id='acquire-timeout-p3'
  rec=$(make_case timeout "$id" 'echo "acquiring a fresh pool slot..."
sleep 5')
  read_case_record "$rec"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite never entering a worktree"
  assert_contains "$out" "did not enter a worktree within" \
    "spawn did not report a timeout as a timeout"
  assert_contains "$out" "never reported a failure" \
    "the timeout did not say acquisition never reported a failure"
  assert_not_contains "$out" "failed with exit status" \
    "a timeout was reported as an acquisition failure"
  assert_contains "$out" "acquiring a fresh pool slot..." \
    "the timeout did not show what the pane was doing"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed acquisition timeout:\n%s\n' "$(printf '%s\n' "$out" | tail -n 2)"
  fi
  pass "a slow acquisition times out as a timeout, distinct from a reported failure"
}

# The failure marker must never fire on the success path: acquisition returns
# zero only when the worker's shell is in the worktree, and that spawn must
# proceed normally.
test_successful_acquisition_is_unaffected() {
  local rec id out status wt
  id='acquire-success-p4'
  rec=$(make_case success "$id" 'printf %s\\n "$FM_FAKE_WT" > "$FM_FAKE_PANE_STATE/cwd"')
  read_case_record "$rec"
  wt="$CASE_DIR/wt"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$wt" HEAD
  export FM_FAKE_WT="$wt"

  out=$(run_spawn "$id")
  status=$?
  unset FM_FAKE_WT
  expect_code 0 "$status" "spawn should succeed when acquisition enters a worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "failed with exit status" \
    "a successful acquisition was reported as a failure"
  assert_grep "worktree=$wt" "$HOME_DIR/state/$id.meta" \
    "meta did not record the acquired worktree"
  pass "a successful acquisition still launches, with no failure reported"
}

test_failed_acquisition_reports_status_and_message
test_reported_status_is_the_acquisition_s_own
test_timeout_stays_distinguishable_from_failure
test_successful_acquisition_is_unaffected

echo "# all fm-spawn-acquire-failure tests passed"
