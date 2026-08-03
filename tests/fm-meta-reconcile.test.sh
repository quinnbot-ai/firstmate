#!/usr/bin/env bash
# Regression coverage for the explicit detached legacy metadata reconciler.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RECONCILE="$ROOT/bin/fm-meta-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-meta-reconcile)

make_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin"
  git init -q "$dir/project"
  git -C "$dir/project" checkout -q -b main
  git -C "$dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  if [ "${FM_TEST_TMUX_LIVE:-0}" = 1 ]; then
    printf '%s\n' "fm-${FM_TEST_ID:?}"
    exit 0
  fi
  printf '%s\n' "can't find session: missing" >&2
  exit 1
fi
if [ "${1:-}" = display-message ]; then
  printf '%s\n' codex
fi
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'return %s\n' "$*" >> "${FM_TEST_TREEHOUSE_LOG:?}"
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'pr view' ] && [ "${FM_TEST_PR_MERGED:-0}" = 1 ]; then
  printf 'MERGED\t%s\n' "${FM_TEST_PR_HEAD:?}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/gh"
  printf '%s\n' "$dir"
}

make_task_branch() {  # <case> <id> [worktree]
  local dir=$1 id=$2 worktree=${3:-$1/worktree}
  git -C "$dir/project" worktree add -q -b "fm/$id" "$worktree" main
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m task
  printf '%s\n' "$worktree"
}

land_branch_locally() {  # <case> <id>
  git -C "$1/project" merge -q --ff-only "fm/$2"
}

write_legacy_meta() {  # <case> <id> <worktree> [pr]
  local dir=$1 id=$2 worktree=$3 pr=${4:-}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window_detached_20260729=legacy:fm-$id  # detached" \
    "endpoint_task_id=$id" "worktree=$worktree" "project=$dir/project" \
    'kind=ship' 'landed_20260729=abc1234'
  [ -z "$pr" ] || printf 'pr=%s\n' "$pr" >> "$dir/home/state/$id.meta"
}

run_case() {  # <case> <id> [--apply]
  local dir=$1 id=$2 mode=${3:-}
  if [ -n "$mode" ]; then
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ID="$id" \
      FM_TEST_TREEHOUSE_LOG="$dir/treehouse.log" PATH="$dir/fakebin:$PATH" \
      "$RECONCILE" "$mode" "$id"
  else
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_ID="$id" \
      FM_TEST_TREEHOUSE_LOG="$dir/treehouse.log" PATH="$dir/fakebin:$PATH" \
      "$RECONCILE" "$id"
  fi
}

test_local_main_proof_archives_and_cleans() {
  local dir worktree id=local-main out archive
  dir=$(make_case local-main)
  worktree=$(make_task_branch "$dir" "$id")
  land_branch_locally "$dir" "$id"
  write_legacy_meta "$dir" "$id" "$worktree"
  printf 'done: stale\n' > "$dir/home/state/$id.status"
  : > "$dir/home/state/$id.turn-ended"
  : > "$dir/home/state/$id.check.sh"
  out=$(run_case "$dir" "$id")
  assert_contains "$out" "$id: would reconcile: endpoint=missing, proof=local-main" "local main dry run"
  [ -f "$dir/home/state/$id.meta" ] || fail "dry run changed metadata"
  run_case "$dir" "$id" --apply >/dev/null
  archive="$dir/home/state/meta-archive/$(date +%F)/$id.meta"
  [ -f "$archive" ] || fail "local main proof did not archive metadata"
  [ ! -e "$dir/home/state/$id.status" ] || fail "local main proof retained stale status"
  [ ! -e "$dir/home/state/$id.turn-ended" ] || fail "local main proof retained turn marker"
  [ ! -e "$dir/home/state/$id.check.sh" ] || fail "local main proof retained check artifact"
  pass "meta reconcile: local-main proof archives metadata and clears stale artifacts"
}

test_recorded_merged_pr_proof() {
  local dir worktree id=merged-pr head out
  dir=$(make_case merged-pr)
  worktree=$(make_task_branch "$dir" "$id")
  head=$(git -C "$dir/project" rev-parse "refs/heads/fm/$id")
  write_legacy_meta "$dir" "$id" "$worktree" 'https://github.com/example/repo/pull/7'
  out=$(FM_TEST_PR_MERGED=1 FM_TEST_PR_HEAD="$head" run_case "$dir" "$id")
  assert_contains "$out" "$id: would reconcile: endpoint=missing, proof=merged-pr" "recorded merged PR dry run"
  [ -f "$dir/home/state/$id.meta" ] || fail "merged PR dry run changed metadata"
  pass "meta reconcile: recorded merged PR proves detached task branch"
}

test_unprovable_record_is_preserved() {
  local dir worktree id=unproved out
  dir=$(make_case unproved)
  worktree=$(make_task_branch "$dir" "$id")
  write_legacy_meta "$dir" "$id" "$worktree"
  out=$(run_case "$dir" "$id")
  assert_contains "$out" "$id: preserved: no merged-PR or local-main landed proof" "unproved output"
  [ -f "$dir/home/state/$id.meta" ] || fail "unproved record was changed"
  pass "meta reconcile: unproved record remains untouched"
}

test_live_endpoint_is_preserved() {
  local dir worktree id=live-endpoint out
  dir=$(make_case live-endpoint)
  worktree=$(make_task_branch "$dir" "$id")
  land_branch_locally "$dir" "$id"
  write_legacy_meta "$dir" "$id" "$worktree"
  out=$(FM_TEST_TMUX_LIVE=1 run_case "$dir" "$id")
  assert_contains "$out" "$id: preserved: endpoint is not confidently dead or missing" "live endpoint output"
  [ -f "$dir/home/state/$id.meta" ] || fail "live endpoint record was changed"
  pass "meta reconcile: live endpoint blocks reconciliation"
}

test_held_lease_is_returned_before_cleanup() {
  local dir worktree id=held-lease archive
  dir=$(make_case held-lease)
  worktree=$(make_task_branch "$dir" "$id")
  land_branch_locally "$dir" "$id"
  write_legacy_meta "$dir" "$id" "$worktree"
  printf 'treehouse_lease=1\n' >> "$dir/home/state/$id.meta"
  run_case "$dir" "$id" --apply >/dev/null
  assert_contains "$(cat "$dir/treehouse.log")" "return --force $worktree" "held lease return"
  archive="$dir/home/state/meta-archive/$(date +%F)/$id.meta"
  [ -f "$archive" ] || fail "held lease metadata was not archived"
  pass "meta reconcile: held lease returns through treehouse before archiving"
}

test_local_main_proof_archives_and_cleans
test_recorded_merged_pr_proof
test_unprovable_record_is_preserved
test_live_endpoint_is_preserved
test_held_lease_is_returned_before_cleanup
