#!/usr/bin/env bash
# End-to-end regression for the primary agent's direct closeout-and-refill
# transaction.
#
# The primary agent remains the one lifecycle owner; there is intentionally no
# production coordinator to test here.
# This test stitches together the existing guarded owners exactly as that agent
# must: standing yolo authority gates fm-pr-merge, fm-teardown proves landing
# before cleanup, and fm-spawn fills the newly open visible slot.
# It also proves that unlanded and captain-gated lanes remain intact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-direct-lifecycle)
CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
PROJECT="$HOME_DIR/projects/project"
ORIGIN="$CASE/origin.git"
COMPLETED_WT="$CASE/completed-wt"
READY_WT="$CASE/ready-wt"
UNLANDED_WT="$CASE/unlanded-wt"
GATED_WT="$CASE/gated-wt"
FAKEBIN="$CASE/fakebin"
GH_AXI_LOG="$CASE/gh-axi.log"
TREEHOUSE_LOG="$CASE/treehouse.log"
TMUX_LOG="$CASE/tmux.log"
HEAD_FILE="$CASE/completed-head"
BASE_PATH=$PATH
REAL_GIT=$(command -v git)

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/projects" "$FAKEBIN"
touch "$HOME_DIR/state/.last-watcher-beat" "$GH_AXI_LOG" \
  "$TREEHOUSE_LOG" "$TMUX_LOG"

git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$CASE/seed" 2>/dev/null
git -C "$CASE/seed" commit -q --allow-empty -m "origin baseline"
git -C "$CASE/seed" push -q origin main
git clone -q "$ORIGIN" "$PROJECT"
git -C "$PROJECT" remote set-head origin main

git -C "$PROJECT" worktree add -q -b fm/completed-y1 "$COMPLETED_WT" main
printf '%s\n' "completed work" > "$COMPLETED_WT/completed.txt"
git -C "$COMPLETED_WT" add completed.txt
git -C "$COMPLETED_WT" commit -qm "complete routine work"
git -C "$COMPLETED_WT" rev-parse HEAD > "$HEAD_FILE"

git -C "$PROJECT" worktree add -q -b fm/ready-r1 "$READY_WT" main

printf '%s\n' '- project [direct-PR +yolo] - lifecycle fixture (added 2026-07-27)' \
  > "$HOME_DIR/data/projects.md"
mkdir -p "$HOME_DIR/data/ready-r1"
printf '%s\n' '# Task' 'Run the ready lifecycle fixture.' \
  > "$HOME_DIR/data/ready-r1/brief.md"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge")
    "$FM_TEST_REAL_GIT" -C "$FM_TEST_COMPLETED_WT" \
      push -q origin HEAD:refs/heads/fm/completed-y1
    exit 0
    ;;
  "pr list")
    printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"
    exit 0
    ;;
  "pr view")
    echo "error: pull request not found" >&2
    exit 1
    ;;
esac
exit 0
SH

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *" --json headRefOid "*)
        cat "$FM_TEST_HEAD_FILE"
        exit 0
        ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
    else
      printf '%s\n' "$FM_TEST_READY_WT"
    fi
    exit 0
    ;;
  return)
    printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_LOG"
    "$FM_TEST_REAL_GIT" -C "$FM_TEST_PROJECT" worktree remove --force "$3"
    exit $?
    ;;
  status)
    exit 0
    ;;
esac
exit 0
SH

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
if [ "${1:-}" = display-message ]; then
  case "$*" in
    *"#{pane_current_path}"*)
      printf '%s\n' "$FM_TEST_READY_WT"
      exit 0
      ;;
    *"#{window_name}"*)
      printf '%s\n' "fm-$FM_TEST_READY_ID"
      exit 0
      ;;
    *"#{pane_id}"*)
      printf '%s\n' '%1'
      exit 0
      ;;
    *"#S"*)
      printf '%s\n' firstmate
      exit 0
      ;;
  esac
fi
case "${1:-}" in
  new-window)
    printf '%s\n' '@17'
    exit 0
    ;;
  list-windows|has-session|new-session|set-window-option|kill-window|send-keys)
    exit 0
    ;;
esac
exit 0
SH

chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/gh" "$FAKEBIN/treehouse" "$FAKEBIN/tmux"

fixture_cmd() {
  FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_TEST_COMPLETED_WT="$COMPLETED_WT" \
    FM_TEST_READY_WT="$READY_WT" \
    FM_TEST_PROJECT="$PROJECT" \
    FM_TEST_HEAD_FILE="$HEAD_FILE" \
    FM_TEST_GH_AXI_LOG="$GH_AXI_LOG" \
    FM_TEST_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_TEST_TMUX_LOG="$TMUX_LOG" \
    FM_TEST_READY_ID=ready-r1 \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    TMUX="fake,1,0" \
    PATH="$FAKEBIN:$BASE_PATH" \
    "$@"
}

write_ship_meta() {
  local id=$1 worktree=$2 yolo=$3
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$worktree" \
    "project=$PROJECT" \
    "harness=opencode" \
    "kind=ship" \
    "treehouse_lease=1" \
    "mode=direct-PR" \
    "yolo=$yolo" \
    "model=default" \
    "effort=default"
  chmod 0600 "$HOME_DIR/state/$id.meta"
}

# The policy check belongs to the primary agent's AGENTS.md transaction.
# The guard scripts below remain the only merge, cleanup, and launch owners.
closeout_with_standing_authority() {
  local id=$1 url=$2 meta="$HOME_DIR/state/$1.meta" kind status yolo
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  yolo=$(sed -n 's/^yolo=//p' "$meta" | tail -1)
  status=$(tail -1 "$HOME_DIR/state/$id.status" 2>/dev/null || true)
  if [ "$kind" != ship ] || ! printf '%s\n' "$status" \
    | grep -Fq 'done: PR checks green'; then
    printf 'ambiguous-or-incomplete: %s\n' "$id"
    return 4
  fi
  if [ "$yolo" != on ]; then
    printf 'captain-gated: %s\n' "$id"
    return 3
  fi
  fixture_cmd "$PR_MERGE" "$id" "$url" || return
  fixture_cmd "$TEARDOWN" "$id"
}

test_complete_land_cleanup_and_visible_refill() {
  local id=completed-y1 out rc
  write_ship_meta "$id" "$COMPLETED_WT" on
  printf '%s\n' 'done: PR checks green; routine change complete' \
    > "$HOME_DIR/state/$id.status"

  set +e
  out=$(closeout_with_standing_authority \
    "$id" https://github.com/example/project/pull/41 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "routine yolo closeout should land and clean up"
  assert_contains "$out" "teardown $id complete" \
    "successful closeout did not run the guarded teardown owner"
  assert_grep 'pr merge 41 --repo example/project --squash' "$GH_AXI_LOG" \
    "successful closeout did not run the guarded merge owner"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "landed work retained task metadata after safe teardown"
  assert_absent "$COMPLETED_WT" \
    "landed leased worktree was not returned"
  assert_grep "return --force $COMPLETED_WT" "$TREEHOUSE_LOG" \
    "safe teardown did not return the exact landed worktree"

  set +e
  out=$(fixture_cmd "$SPAWN" ready-r1 "$PROJECT" --harness opencode 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "ready refill should launch into the newly open slot"
  assert_contains "$out" "spawned ready-r1" \
    "ready refill was not surfaced as a visible worker"
  assert_grep "worktree=$READY_WT" "$HOME_DIR/state/ready-r1.meta" \
    "refill did not record the isolated ready worktree"
  assert_grep 'yolo=on' "$HOME_DIR/state/ready-r1.meta" \
    "refill did not inherit standing project authority"
  assert_grep ' -n fm-ready-r1 ' "$TMUX_LOG" \
    "refill did not create a visible task window"
  pass "routine complete work lands, proves cleanup safety, and visibly refills the open slot"
}

test_unlanded_work_is_preserved() {
  local id=unlanded-u1 before out rc
  git -C "$PROJECT" worktree add -q -b fm/unlanded-u1 "$UNLANDED_WT" main
  printf '%s\n' "unlanded work" > "$UNLANDED_WT/unlanded.txt"
  git -C "$UNLANDED_WT" add unlanded.txt
  git -C "$UNLANDED_WT" commit -qm "unlanded routine work"
  write_ship_meta "$id" "$UNLANDED_WT" on
  before=$(wc -l < "$TREEHOUSE_LOG")

  set +e
  out=$(fixture_cmd "$TEARDOWN" "$id" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded teardown should refuse"
  assert_contains "$out" "REFUSED:" \
    "unlanded teardown did not report its safety refusal"
  assert_contains "$out" "not landed" \
    "unlanded teardown did not identify the failed proof"
  assert_present "$HOME_DIR/state/$id.meta" \
    "unlanded teardown removed recovery metadata"
  assert_present "$UNLANDED_WT" \
    "unlanded teardown removed the worktree"
  [ "$(wc -l < "$TREEHOUSE_LOG")" -eq "$before" ] \
    || fail "unlanded teardown called treehouse return"
  pass "unlanded work fails closed and remains recoverable"
}

test_captain_gated_work_is_untouched() {
  local id=gated-g1 before out rc
  git -C "$PROJECT" worktree add -q -b fm/gated-g1 "$GATED_WT" main
  printf '%s\n' "captain-gated work" > "$GATED_WT/gated.txt"
  git -C "$GATED_WT" add gated.txt
  git -C "$GATED_WT" commit -qm "captain-gated work"
  write_ship_meta "$id" "$GATED_WT" off
  printf '%s\n' 'done: PR checks green; waiting for captain authority' \
    > "$HOME_DIR/state/$id.status"
  before=$(wc -l < "$GH_AXI_LOG")

  set +e
  out=$(closeout_with_standing_authority \
    "$id" https://github.com/example/project/pull/42 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "captain-gated closeout should remain parked"
  assert_contains "$out" "captain-gated: $id" \
    "captain-gated closeout did not identify the authority boundary"
  assert_present "$HOME_DIR/state/$id.meta" \
    "captain-gated closeout removed task metadata"
  assert_present "$GATED_WT" \
    "captain-gated closeout removed its worktree"
  [ "$(wc -l < "$GH_AXI_LOG")" -eq "$before" ] \
    || fail "captain-gated closeout called the merge owner"
  pass "captain-gated completed work remains parked without merge or cleanup"
}

test_complete_land_cleanup_and_visible_refill
test_unlanded_work_is_preserved
test_captain_gated_work_is_untouched

echo "# all direct lifecycle tests passed"
