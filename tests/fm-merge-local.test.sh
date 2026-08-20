#!/usr/bin/env bash
# Behavior tests for the local-only merge boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  git -C "$case_dir/project" branch -M main
  printf 'candidate\n' > "$case_dir/wt/change.txt"
  git -C "$case_dir/wt" add change.txt
  git -C "$case_dir/wt" commit -qm candidate
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

run_local_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-x1
}

test_failed_native_merge_preserves_late_checkout_writer() {
  local case_dir hooks hook rc
  case_dir=$(make_case late-writer)
  hooks=$(git -C "$case_dir/project" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$hooks"
  read -r -d '' hook <<'SH' || true
#!/usr/bin/env bash
if [ "${1:-}" = prepared ]; then
  while read -r _old _new ref; do
    if [ "$ref" = refs/heads/main ]; then
      printf "actor\\n" > "$FM_TEST_RACE_PROJECT/change.txt"
      exit 1
    fi
  done
fi
SH
  printf '%s\n' "$hook" > "$hooks/reference-transaction"
  chmod +x "$hooks/reference-transaction"

  set +e
  FM_TEST_RACE_PROJECT="$case_dir/project" run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "a refused local merge must report failure"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$(git -C "$case_dir/project" rev-parse HEAD)" ] \
    || fail "a refused local merge left the checkout detached from main"
  [ "$(cat "$case_dir/project/change.txt")" = actor ] \
    || fail "a refused local merge discarded the late checkout writer"
  pass "local merge leaves late checkout writes to their owner after a refusal"
}

test_snapshot_rollback_discards_an_intermediate_advance() {
  local case_dir base candidate actor changed dirty
  case_dir=$(make_case snapshot-rollback)
  base=$(git -C "$case_dir/project" rev-parse main)
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)

  # This reconstructs the retired generic rollback boundary at its ownership
  # seam: the checkout reached candidate, its dirty paths were observed, then
  # a second writer advanced main before the stale snapshot was restored.
  git -C "$case_dir/project" read-tree --reset -u "$candidate"
  changed=$(git -C "$case_dir/project" diff-tree --no-commit-id --name-only -r "$base" "$candidate")
  dirty=$(git -C "$case_dir/project" diff --name-only "$candidate" --)
  [ -z "$dirty" ] || fail "rollback fixture did not begin with a candidate checkout"
  printf 'actor\n' > "$case_dir/project/change.txt"
  git -C "$case_dir/project" add change.txt
  git -C "$case_dir/project" commit -qm actor
  actor=$(git -C "$case_dir/project" rev-parse main)
  [ "$actor" != "$base" ] || fail "intervening writer did not advance main"
  [ "$(cat "$case_dir/project/change.txt")" = actor ] \
    || fail "intervening writer did not own the checkout before rollback"

  case "$changed" in
    *change.txt*) git -C "$case_dir/project" restore --source="$base" --worktree -- change.txt ;;
    *) fail "rollback fixture did not identify the candidate path" ;;
  esac
  git -C "$case_dir/project" read-tree "$base"

  [ "$(git -C "$case_dir/project" rev-parse main)" = "$actor" ] \
    || fail "rollback fixture did not retain the intervening ref advance"
  [ ! -e "$case_dir/project/change.txt" ] \
    || fail "snapshot rollback unexpectedly preserved the intervening writer"
  pass "snapshot rollback reproduces loss of an intermediate checkout advance"
}

test_snapshot_rollback_discards_an_intermediate_advance
test_failed_native_merge_preserves_late_checkout_writer
