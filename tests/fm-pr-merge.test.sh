#!/usr/bin/env bash
# Behavior tests for the shared exact-candidate merge execution boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_EXECUTE="$ROOT/bin/fm-merge-execute.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
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

run_local_merge_with_path() {
  local case_dir=$1 fakebin=$2 real_git=$3
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_RACE_PROJECT="$case_dir/project" FM_TEST_REAL_GIT="$real_git" \
    PATH="$fakebin:$PATH" "$MERGE_EXECUTE" local task-x1
}

add_github_mocks() {
  local case_dir=$1
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_GH_UNAVAILABLE:-0}" -eq 0 ] || exit 1
printf '%s\n' "$FM_TEST_GH_HEAD"
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "api POST")
    post_count=$(grep -c '^api POST ' "$FM_TEST_GH_AXI_LOG")
    api_head=$FM_TEST_GH_API_HEAD
    api_base=$FM_TEST_GH_BASE
    protection=${FM_TEST_GH_PROTECTION:-protected}
    if [ "$post_count" -gt 1 ]; then
      api_head=${FM_TEST_GH_API_HEAD_AFTER:-$api_head}
      api_base=${FM_TEST_GH_BASE_AFTER:-$api_base}
      protection=${FM_TEST_GH_PROTECTION_AFTER:-$protection}
    fi
    printf 'data:\n  repository:\n    pullRequest:\n      headRefOid: %s\n      baseRefOid: %s\n      baseRefName: main\n      headRefName: fm/task-x1\n      state: OPEN\n      isDraft: false\n      merged: false\n      headRepository:\n        nameWithOwner: example/repo\n      baseRef:\n' \
      "$api_head" "$api_base"
    case "$protection" in
      protected)
        printf '        branchProtectionRule:\n          requiresStrictStatusChecks: true\n          isAdminEnforced: true\n'
        ;;
      null)
        printf '        branchProtectionRule: null\n'
        ;;
      partial)
        printf '        branchProtectionRule:\n          requiresStrictStatusChecks: true\n'
        ;;
      duplicate-null)
        printf '        branchProtectionRule: null\n        branchProtectionRule: null\n'
        ;;
      non-strict)
        printf '        branchProtectionRule:\n          requiresStrictStatusChecks: false\n          isAdminEnforced: true\n'
        ;;
      *) exit 97 ;;
    esac
    ;;
  "api PUT")
    printf 'merged: %s\n' "${FM_TEST_GH_MERGED:-true}"
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
}

run_github_merge() {
  local case_dir=$1 head=$2 api_head=$3 base=$4
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_HEAD="$head" FM_TEST_GH_API_HEAD="$api_head" FM_TEST_GH_BASE="$base" \
    FM_TEST_GH_API_HEAD_AFTER="${FM_TEST_GH_API_HEAD_AFTER:-}" \
    FM_TEST_GH_BASE_AFTER="${FM_TEST_GH_BASE_AFTER:-}" \
    FM_TEST_GH_PROTECTION="${FM_TEST_GH_PROTECTION:-protected}" \
    FM_TEST_GH_PROTECTION_AFTER="${FM_TEST_GH_PROTECTION_AFTER:-}" \
    FM_TEST_GH_MERGED="${FM_TEST_GH_MERGED:-true}" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 -- --merge
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

test_raced_local_edit_is_preserved() {
  local values case_dir base fakebin real_git rc
  values=$(make_case raced-edit)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  printf 'raced local edit\n' > "$FM_TEST_RACE_PROJECT/change.txt"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a raced project edit must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "raced edit advanced the default ref"
  [ "$(cat "$case_dir/project/change.txt")" = 'raced local edit' ] || fail "raced edit was discarded"
  pass "local merge preserves an edit raced into the checkout"
}

test_intervening_base_movement_is_refused() {
  local values case_dir base intervening candidate fakebin real_git rc
  values=$(make_case raced-base)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  intervening=$(printf '%s\n' "$values" | sed -n '3p')
  printf 'final candidate\n' > "$case_dir/wt/final.txt"
  git -C "$case_dir/wt" add final.txt
  git -C "$case_dir/wt" commit -qm final-candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  "$FM_TEST_REAL_GIT" -C "$FM_TEST_RACE_PROJECT" update-ref refs/heads/main "$FM_TEST_INTERVENING" "$FM_TEST_BASE"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  FM_TEST_BASE="$base" FM_TEST_INTERVENING="$intervening" \
    run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "intervening base movement must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$intervening" ] || fail "boundary overwrote intervening base movement"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$candidate" ] || fail "fixture lost the final candidate"
  [ ! -e "$case_dir/project/final.txt" ] || fail "refused base race changed the project checkout"
  pass "local merge refuses an intervening base before checkout transition"
}

test_unchanged_path_drift_is_preserved() {
  local values case_dir base fakebin real_git rc
  values=$(make_case unchanged-path-drift)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  printf 'raced unchanged path\n' > "$FM_TEST_RACE_PROJECT/README.md"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unchanged-path drift must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "unchanged-path drift advanced the default ref"
  [ "$(cat "$case_dir/project/README.md")" = 'raced unchanged path' ] || fail "unchanged-path drift was discarded"
  [ ! -e "$case_dir/project/change.txt" ] || fail "refused unchanged-path drift retained candidate checkout changes"
  pass "local merge preserves unchanged-path drift and refuses landing"
}

test_prepared_transaction_drift_is_preserved() {
  local values case_dir base hooks rc
  values=$(make_case prepared-drift)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  hooks=$(git -C "$case_dir/project" rev-parse --path-format=absolute --git-path hooks)
  cat > "$hooks/reference-transaction" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = prepared ]; then
  while read -r _old _new ref; do
    if [ "$ref" = refs/heads/main ]; then
      printf 'raced after checkout observation\n' > "$FM_TEST_LATE_PROJECT/change.txt"
    fi
  done
fi
SH
  chmod +x "$hooks/reference-transaction"
  set +e
  FM_TEST_LATE_PROJECT="$case_dir/project" run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepared-transaction drift must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "prepared drift advanced the default ref"
  [ "$(cat "$case_dir/project/change.txt")" = 'raced after checkout observation' ] || fail "prepared drift was discarded"
  [ "$(git -C "$case_dir/project" status --short)" = '?? change.txt' ] || fail "prepared drift did not leave the base checkout coherent"
  pass "prepared transaction drift is preserved before the ref commits"
}

test_wrong_branch_transaction_is_refused() {
  local values case_dir base fakebin real_git rc
  values=$(make_case wrong-branch)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  git -C "$case_dir/project" branch other "$base"
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  "$FM_TEST_REAL_GIT" -C "$FM_TEST_RACE_PROJECT" symbolic-ref HEAD refs/heads/other
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a wrong-branch transaction must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "wrong-branch transaction advanced the default ref"
  [ "$(git -C "$case_dir/project" rev-parse other)" = "$base" ] || fail "wrong-branch transaction advanced the other ref"
  [ "$(git -C "$case_dir/project" symbolic-ref HEAD)" = refs/heads/other ] || fail "boundary overwrote the raced branch switch"
  [ ! -e "$case_dir/project/change.txt" ] || fail "refused wrong-branch transaction retained candidate checkout changes"
  [ -z "$(git -C "$case_dir/project" status --short)" ] || fail "refused wrong-branch transaction left an incoherent checkout"
  pass "local merge refuses a transaction for an unexpected branch"
}

test_github_merge_uses_verified_exact_sha() {
  local values case_dir base candidate
  values=$(make_case github-exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >/dev/null \
    || fail "GitHub boundary refused the verified candidate"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "GitHub boundary did not condition the merge on the verified exact SHA"
  pass "GitHub merge conditions its REST request on the verified candidate SHA"
}

test_unprotected_github_merge_uses_verified_exact_sha() {
  local values case_dir base candidate
  values=$(make_case github-unprotected-exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  FM_TEST_GH_PROTECTION=null run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "GitHub boundary refused the verified candidate for an unprotected repository"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "unprotected GitHub boundary did not condition the merge on the verified exact SHA"
  grep -q 'unprotected repository' "$case_dir/err" \
    || fail "unprotected GitHub merge did not diagnose the sanctioned path"
  pass "GitHub merge sanctions a null protection rule without weakening the exact candidate mutation"
}

test_github_merge_refuses_changed_remote_head() {
  local values case_dir base candidate rc
  values=$(make_case github-changed-head)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_API_HEAD_AFTER="$base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "GitHub head drift during verification must refuse merging"
  grep -q 'exact candidate changed during merge verification' "$case_dir/err" \
    || fail "GitHub head drift refusal did not identify the verification race"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "changed GitHub head reached the merge API"
  pass "unprotected GitHub merge refuses remote head drift during verification"
}

test_unprotected_github_merge_refuses_changed_remote_base() {
  local values case_dir base candidate advanced_base rc
  values=$(make_case github-changed-base)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  advanced_base=$(printf '%s\n' "$values" | sed -n '3p')
  printf 'final candidate\n' > "$case_dir/wt/final.txt"
  git -C "$case_dir/wt" add final.txt
  git -C "$case_dir/wt" commit -qm final-candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_BASE_AFTER="$advanced_base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "GitHub base drift during verification must refuse an unprotected merge"
  git -C "$case_dir/wt" merge-base --is-ancestor "$advanced_base" "$candidate" \
    || fail "base drift fixture did not remain inside candidate ancestry"
  grep -q 'exact candidate changed during merge verification' "$case_dir/err" \
    || fail "GitHub base drift refusal did not identify the verification race"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "changed GitHub base reached the merge API"
  pass "unprotected GitHub merge refuses remote base drift even when the new base remains an ancestor"
}

test_github_merge_refuses_partial_protection_payload() {
  local values case_dir base candidate rc
  values=$(make_case github-partial-protection)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=partial \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "partial protection data must refuse merging"
  grep -q 'malformed or ambiguous base branch protection data' "$case_dir/err" \
    || fail "partial protection refusal was not explicit"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "partial protection data reached the merge API"
  pass "GitHub merge rejects a partial protection object instead of treating it as absent"
}

test_github_merge_refuses_ambiguous_null_protection_payload() {
  local values case_dir base candidate rc
  values=$(make_case github-ambiguous-null-protection)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=duplicate-null \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous null protection data must refuse merging"
  grep -q 'malformed or ambiguous base branch protection data' "$case_dir/err" \
    || fail "ambiguous null protection refusal was not explicit"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "ambiguous null protection data reached the merge API"
  pass "GitHub merge rejects duplicate null protection markers"
}

test_protected_github_merge_still_requires_strict_checks() {
  local values case_dir base candidate rc
  values=$(make_case github-non-strict-protection)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=non-strict \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "protected repositories must retain strict-check enforcement"
  grep -q 'requires strict, admin-enforced base branch protection' "$case_dir/err" \
    || fail "non-strict protected-repository refusal was unclear"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "non-strict protection reached the merge API"
  pass "protected GitHub merge retains strict and administrator enforcement"
}

test_unprotected_github_merge_requires_post_mutation_confirmation() {
  local values case_dir base candidate rc
  values=$(make_case github-unconfirmed-merge)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_MERGED=false \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unconfirmed exact-candidate mutation must fail"
  grep -q 'did not merge the verified candidate' "$case_dir/err" \
    || fail "unconfirmed exact-candidate mutation refusal was unclear"
  pass "unprotected GitHub merge requires post-mutation candidate confirmation"
}

test_github_merge_accepts_live_head_without_recorded_head() {
  local values case_dir base candidate
  values=$(make_case github-live-head)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  FM_TEST_GH_UNAVAILABLE=1 run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >/dev/null \
    || fail "GitHub boundary refused a live exact head without recorded head metadata"
  ! grep -q '^pr_head=' "$case_dir/state/task-x1.meta" || fail "unavailable gh unexpectedly recorded PR head metadata"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "live GraphQL head was not used for a wrapper-authenticated merge"
  pass "GitHub merge binds an absent recorded head to live and local heads"
}

test_invalid_merge_args_are_side_effect_free() {
  local values case_dir before rc
  values=$(make_case invalid-args)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  before=$(cat "$case_dir/state/task-x1.meta")
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 -- --admin >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unsupported merge arguments must fail as invalid input"
  [ "$(cat "$case_dir/state/task-x1.meta")" = "$before" ] || fail "invalid merge arguments rewrote task metadata"
  [ ! -e "$case_dir/state/task-x1.check.sh" ] || fail "invalid merge arguments published a watcher"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "invalid merge arguments reached the credential wrapper"
  pass "invalid merge arguments fail before metadata and watcher side effects"
}

test_exact_literal_receipt_lands_candidate
test_uncommitted_receipt_source_refuses_before_merge
test_raced_local_edit_is_preserved
test_intervening_base_movement_is_refused
test_unchanged_path_drift_is_preserved
test_prepared_transaction_drift_is_preserved
test_wrong_branch_transaction_is_refused
test_github_merge_uses_verified_exact_sha
test_unprotected_github_merge_uses_verified_exact_sha
test_github_merge_refuses_changed_remote_head
test_unprotected_github_merge_refuses_changed_remote_base
test_github_merge_refuses_partial_protection_payload
test_github_merge_refuses_ambiguous_null_protection_payload
test_protected_github_merge_still_requires_strict_checks
test_unprotected_github_merge_requires_post_mutation_confirmation
test_github_merge_accepts_live_head_without_recorded_head
test_invalid_merge_args_are_side_effect_free
