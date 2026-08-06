#!/usr/bin/env bash
# Behavior tests for the shared exact-candidate merge execution boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_EXECUTE="$ROOT/bin/fm-merge-execute.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge)

make_case() {
  local name=$1 case_dir base candidate
  case_dir=$TMP_ROOT/$name
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  git -C "$case_dir/project" branch -M main
  mkdir -p "$case_dir/wt/.firstmate" "$case_dir/wt/tests"
  cat > "$case_dir/wt/.firstmate/test-inventory.json" <<'EOF'
{"schema_version":1,"status":"test-bearing","baseline":{"version":1,"declarations":1,"test_files":1},"maximum_unreviewed_deletion":0}
EOF
  cat > "$case_dir/wt/tests/test_receipt.py" <<'EOF'
def test_literal():
    pass
EOF
  "$ROOT/bin/fm-test-inventory.sh" collect "$case_dir/wt" >/dev/null
  git -C "$case_dir/wt" add .firstmate tests
  git -C "$case_dir/wt" commit -qm inventory
  git -C "$case_dir/project" merge --ff-only fm/task-x1 >/dev/null
  base=$(git -C "$case_dir/project" rev-parse main)
  printf 'candidate\n' > "$case_dir/wt/change.txt"
  git -C "$case_dir/wt" add change.txt
  git -C "$case_dir/wt" commit -qm candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
  printf '%s\n%s\n%s\n' "$case_dir" "$base" "$candidate"
}

run_local_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_EXECUTE" local task-x1
}

test_exact_literal_receipt_lands_candidate() {
  local values case_dir base candidate
  values=$(make_case exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  run_local_merge "$case_dir" >/dev/null || fail "shared boundary refused an exact literal receipt"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$candidate" ] || fail "boundary did not land the exact candidate SHA"
  [ "$base" != "$candidate" ] || fail "fixture did not create a distinct candidate SHA"
  pass "shared boundary verifies and lands the exact literal-source candidate"
}

test_uncommitted_receipt_source_refuses_before_merge() {
  local values case_dir before rc
  values=$(make_case dirty-source)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  before=$(git -C "$case_dir/project" rev-parse main)
  printf 'def test_uncommitted():\n    pass\n' >> "$case_dir/wt/tests/test_receipt.py"
  set +e
  run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "dirty candidate source must refuse exact merge verification"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] || fail "boundary merged after receipt source changed"
  grep -q 'task worktree is dirty' "$case_dir/err" || fail "dirty receipt refusal was unclear"
  pass "shared boundary preserves the base when literal source changes after receipt generation"
}

test_exact_literal_receipt_lands_candidate
test_uncommitted_receipt_source_refuses_before_merge
