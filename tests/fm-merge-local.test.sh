#!/usr/bin/env bash
# Behavioral coverage for the guarded local-only fast-forward.
#
# The worker-custody matrix exercises the initiating metadata mismatch, the
# ordinary clean path that masks it, and each smallest counterfactual. Target
# coverage proves exact tracked adoption while leaving untracked collision and
# preservation decisions to Git. Untracked files, symlinks, and directories are
# deliberately included because the helper does not enumerate or mutate them.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local case_dir=$TMP_ROOT/$1
  mkdir -p "$case_dir/state" "$case_dir/project"
  git -C "$case_dir/project" init -q -b main
  printf 'base\n' >"$case_dir/project/payload.txt"
  git -C "$case_dir/project" add payload.txt
  git -C "$case_dir/project" commit -qm base
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/worker" main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$case_dir/project" "mode=local-only" "worktree=$case_dir/worker"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-x1
}

commit_candidate() {
  local case_dir=$1 contents=${2:-candidate}
  printf '%s\n' "$contents" >"$case_dir/worker/payload.txt"
  git -C "$case_dir/worker" add payload.txt
  git -C "$case_dir/worker" commit -qm candidate
}

enable_normalizing_filter() {
  local case_dir=$1 filter=$1/normalize-filter
  cat >"$filter" <<'SH'
#!/bin/sh
printf 'candidate\n'
SH
  chmod +x "$filter"
  git -C "$case_dir/project" config filter.normalize.clean "$filter"
  git -C "$case_dir/project" config filter.normalize.smudge cat
  printf 'payload.txt filter=normalize\n' >"$case_dir/project/.gitattributes"
  git -C "$case_dir/project" add .gitattributes
  git -C "$case_dir/project" commit -qm "configure payload normalization"
  git -C "$case_dir/worker" merge -q --ff-only main
}

assert_ref_unchanged() {
  local case_dir=$1 before_main=$2 before_worker=$3 message=$4
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before_main" ] || fail "$message: main advanced"
  [ "$(git -C "$case_dir/project" rev-parse fm/task-x1)" = "$before_worker" ] || fail "$message: worker ref changed"
}

assert_ref_advanced() {
  local case_dir=$1 message=$2
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$(git -C "$case_dir/project" rev-parse fm/task-x1)" ] || fail "$message"
}

refusal_preserves() {
  local case_dir=$1 expected=$2 before_main before_worker rc
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$expected: command should refuse"
  assert_grep "$expected" "$case_dir/stderr" "$expected: refusal did not identify its invariant"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "$expected"
}

test_clean_recorded_worker_fast_forwards() {
  local case_dir
  case_dir=$(make_case clean-worker)
  commit_candidate "$case_dir"
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "clean worker: merge failed"
  assert_ref_advanced "$case_dir" "clean worker: main did not advance"
  pass "fm-merge-local fast-forwards the exact clean recorded worker"
}

test_foreign_same_repository_worker_refuses() {
  local case_dir
  case_dir=$(make_case foreign-worker)
  git -C "$case_dir/worker" checkout -q -b fm/other
  git -C "$case_dir/project" worktree add -q "$case_dir/foreign" fm/task-x1
  printf 'foreign candidate\n' >"$case_dir/foreign/payload.txt"
  git -C "$case_dir/foreign" add payload.txt
  git -C "$case_dir/foreign" commit -qm foreign
  refusal_preserves "$case_dir" "expected fm/task-x1"
  pass "fm-merge-local refuses a same-repository foreign worker branch"
}

test_worker_state_changed_after_preflight_refuses() {
  local before_main before_worker case_dir fakebin rc real_git
  case_dir=$(make_case stale-worker)
  commit_candidate "$case_dir" worker
  fakebin=$case_dir/fakebin
  real_git=$(command -v git)
  mkdir "$fakebin"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge-base --is-ancestor '*)
    if [ ! -e "$FM_TEST_MUTATION_MARKER" ]; then
      : >"$FM_TEST_MUTATION_MARKER"
      "$REAL_GIT" -C "$FM_TEST_WORKER" checkout -q --detach
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_WORKER="$case_dir/worker" \
    FM_TEST_MUTATION_MARKER="$case_dir/mutated" run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "worker changed after preflight: command should refuse"
  assert_grep 'expected fm/task-x1' "$case_dir/stderr" "worker changed after preflight: final custody recheck did not refuse"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "worker changed after preflight"
  pass "fm-merge-local rechecks worker custody after mutable target validation"
}

test_worker_branch_ref_changed_after_preflight_refuses() {
  local before_main case_dir fakebin rc real_git
  case_dir=$(make_case moved-worker-ref)
  commit_candidate "$case_dir" worker
  fakebin=$case_dir/fakebin
  real_git=$(command -v git)
  mkdir "$fakebin"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge-base --is-ancestor '*)
    if [ ! -e "$FM_TEST_MUTATION_MARKER" ]; then
      : >"$FM_TEST_MUTATION_MARKER"
      "$REAL_GIT" -C "$FM_TEST_TARGET" update-ref refs/heads/fm/task-x1 refs/heads/main
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  before_main=$(git -C "$case_dir/project" rev-parse main)
  set +e
  PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_TARGET="$case_dir/project" \
    FM_TEST_MUTATION_MARKER="$case_dir/mutated" run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "worker ref changed after preflight: command should refuse"
  assert_grep 'branch fm/task-x1 moved after custody verification' "$case_dir/stderr" "worker ref changed after preflight: pinned candidate was not enforced"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before_main" ] || fail "worker ref changed after preflight: main advanced"
  [ "$(git -C "$case_dir/project" rev-parse fm/task-x1)" = "$before_main" ] || fail "worker ref changed after preflight: command altered the churned worker ref"
  [ "$(tr -d '\n' <"$case_dir/worker/payload.txt")" = worker ] || fail "worker ref changed after preflight: worker content changed"
  pass "fm-merge-local rejects worker branch-ref drift from the pinned candidate"
}

test_detached_and_different_repository_workers_refuse() {
  local case_dir other
  case_dir=$(make_case detached-worker)
  commit_candidate "$case_dir"
  git -C "$case_dir/worker" checkout -q --detach
  refusal_preserves "$case_dir" "expected fm/task-x1"

  case_dir=$(make_case foreign-repository)
  commit_candidate "$case_dir"
  other=$case_dir/other-repository
  mkdir -p "$other"
  git -C "$other" init -q -b fm/task-x1
  printf 'other\n' >"$other/payload.txt"
  git -C "$other" add payload.txt
  git -C "$other" commit -qm other
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$case_dir/project" "mode=local-only" "worktree=$other"
  refusal_preserves "$case_dir" "different repository"
  pass "fm-merge-local refuses detached and different-repository workers"
}

test_unlanded_worker_states_refuse_without_mutation() {
  local case_dir state before_status
  for state in modified staged untracked; do
    case_dir=$(make_case "dirty-worker-$state")
    commit_candidate "$case_dir"
    case "$state" in
      modified) printf 'unlanded modified\n' >>"$case_dir/worker/payload.txt" ;;
      staged) printf 'unlanded staged\n' >"$case_dir/worker/extra.txt"; git -C "$case_dir/worker" add extra.txt ;;
      untracked) printf 'unlanded untracked\n' >"$case_dir/worker/extra.txt" ;;
    esac
    before_status=$(git -C "$case_dir/worker" status --porcelain=v1 --untracked-files=all)
    refusal_preserves "$case_dir" "not clean"
    [ "$(git -C "$case_dir/worker" status --porcelain=v1 --untracked-files=all)" = "$before_status" ] || fail "$state worker: refusal changed worker state"
  done
  pass "fm-merge-local preserves modified, staged, and untracked worker state"
}

test_hidden_worker_dirt_refuses_without_mutation() {
  local case_dir flag
  for flag in assume-unchanged skip-worktree; do
    case_dir=$(make_case "hidden-worker-$flag")
    commit_candidate "$case_dir"
    printf 'hidden worker dirt\n' >"$case_dir/worker/payload.txt"
    git -C "$case_dir/worker" update-index --"$flag" payload.txt
    refusal_preserves "$case_dir" "not clean"
  done
  pass "fm-merge-local detects worker dirt hidden by index flags"
}

test_clean_filter_cannot_hide_worker_or_target_bytes() {
  local before_main before_worker case_dir candidate_blob raw_object rc
  case_dir=$(make_case filter-hidden-worker)
  enable_normalizing_filter "$case_dir"
  commit_candidate "$case_dir"
  printf 'worker bytes hidden by clean filter\n' >"$case_dir/worker/payload.txt"
  git -C "$case_dir/worker" diff --quiet -- \
    || fail "clean-filter worker: fixture did not mask raw dirt from Git diff"
  refusal_preserves "$case_dir" "not clean"
  [ "$(tr -d '\n' <"$case_dir/worker/payload.txt")" = 'worker bytes hidden by clean filter' ] \
    || fail "clean-filter worker: refusal changed worker bytes"

  case_dir=$(make_case filter-hidden-target)
  enable_normalizing_filter "$case_dir"
  commit_candidate "$case_dir"
  candidate_blob=$(git -C "$case_dir/project" rev-parse fm/task-x1:payload.txt)
  git -C "$case_dir/project" update-index --cacheinfo 100644 "$candidate_blob" payload.txt
  printf 'target raw object %s\n' "$case_dir" >"$case_dir/project/payload.txt"
  git -C "$case_dir/project" diff --quiet -- \
    || fail "clean-filter target: fixture did not mask raw worktree dirt"
  git -C "$case_dir/project" diff --cached --quiet fm/task-x1 -- \
    || fail "clean-filter target: fixture index did not match the candidate"
  raw_object=$(git -C "$case_dir/project" hash-object --no-filters -- payload.txt)
  if git -C "$case_dir/project" cat-file -e "$raw_object" 2>/dev/null; then
    fail "clean-filter target: raw object unexpectedly existed before verification"
  fi
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "clean-filter target: command should refuse"
  assert_grep 'does not exactly match fm/task-x1' "$case_dir/stderr" "clean-filter target: raw dirt bypassed verification"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "clean-filter target"
  if git -C "$case_dir/project" cat-file -e "$raw_object" 2>/dev/null; then
    fail "clean-filter target: verification wrote the raw object"
  fi
  [ "$(tr -d '\n' <"$case_dir/project/payload.txt")" = "target raw object $case_dir" ] \
    || fail "clean-filter target: refusal changed target bytes"
  pass "fm-merge-local compares raw bytes without filters or object writes"
}

test_replacement_refs_cannot_hide_worker_bytes() {
  local case_dir original_blob replacement_blob
  case_dir=$(make_case replacement-hidden-worker)
  commit_candidate "$case_dir"
  original_blob=$(git -C "$case_dir/project" rev-parse fm/task-x1:payload.txt)
  replacement_blob=$(printf 'replacement-hidden worker bytes\n' | git -C "$case_dir/project" hash-object -w --stdin)
  git -C "$case_dir/project" replace "$original_blob" "$replacement_blob"
  printf 'replacement-hidden worker bytes\n' >"$case_dir/worker/payload.txt"
  [ "$(git -C "$case_dir/project" cat-file blob "$original_blob")" = 'replacement-hidden worker bytes' ] \
    || fail "replacement ref: fixture did not substitute candidate bytes"
  refusal_preserves "$case_dir" "not clean"
  [ "$(tr -d '\n' <"$case_dir/worker/payload.txt")" = 'replacement-hidden worker bytes' ] \
    || fail "replacement ref: refusal changed worker bytes"
  [ "$(git -C "$case_dir/project" replace -l)" = "$original_blob" ] \
    || fail "replacement ref: refusal changed replacement refs"
  pass "fm-merge-local disables replacement refs during custody verification"
}

test_ambient_git_overrides_cannot_redirect_verification() {
  local alternate_index before_main before_worker candidate_blob case_dir foreign local_blob rc
  case_dir=$(make_case ambient-overrides)
  commit_candidate "$case_dir"
  candidate_blob=$(git -C "$case_dir/project" rev-parse fm/task-x1:payload.txt)
  printf 'staged target dirt\n' >"$case_dir/project/payload.txt"
  git -C "$case_dir/project" add payload.txt
  local_blob=$(git -C "$case_dir/project" rev-parse :payload.txt)
  printf 'candidate\n' >"$case_dir/project/payload.txt"
  alternate_index=$case_dir/alternate-index
  GIT_INDEX_FILE="$alternate_index" git -C "$case_dir/project" read-tree fm/task-x1
  foreign=$case_dir/foreign
  mkdir "$foreign"
  git -C "$foreign" init -q -b main
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  GIT_DIR="$foreign/.git" \
    GIT_COMMON_DIR="$foreign/.git" \
    GIT_WORK_TREE="$foreign" \
    GIT_INDEX_FILE="$alternate_index" \
    GIT_NAMESPACE=redirected \
    GIT_OBJECT_DIRECTORY="$foreign/.git/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$foreign/.git/objects" \
    GIT_QUARANTINE_PATH="$foreign/.git/objects" \
    GIT_SHALLOW_FILE="$foreign/.git/shallow" \
    GIT_REPLACE_REF_BASE=refs/redirected/replace \
    GIT_EXEC_PATH="$foreign" \
    run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambient overrides: command should refuse the real target index"
  assert_grep 'does not exactly match fm/task-x1' "$case_dir/stderr" "ambient overrides: verification was redirected"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "ambient overrides"
  [ "$(git -C "$case_dir/project" rev-parse :payload.txt)" = "$local_blob" ] \
    || fail "ambient overrides: refusal changed the real index"
  [ "$(git -C "$case_dir/project" rev-parse fm/task-x1:payload.txt)" = "$candidate_blob" ] \
    || fail "ambient overrides: refusal changed the candidate"
  [ "$(tr -d '\n' <"$case_dir/project/payload.txt")" = candidate ] \
    || fail "ambient overrides: refusal changed target bytes"
  pass "fm-merge-local neutralizes ambient Git repository overrides"
}

test_missing_duplicate_and_subdirectory_worktree_metadata_refuse() {
  local case_dir
  case_dir=$(make_case missing-worktree)
  commit_candidate "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" "project=$case_dir/project" "mode=local-only"
  refusal_preserves "$case_dir" "exactly one nonempty worktree="

  case_dir=$(make_case duplicate-worktree)
  commit_candidate "$case_dir"
  printf 'worktree=%s\n' "$case_dir/worker" >>"$case_dir/state/task-x1.meta"
  refusal_preserves "$case_dir" "exactly one nonempty worktree="

  case_dir=$(make_case subdirectory-worktree)
  commit_candidate "$case_dir"
  mkdir "$case_dir/worker/subdirectory"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$case_dir/project" "mode=local-only" "worktree=$case_dir/worker/subdirectory"
  refusal_preserves "$case_dir" "must name its checkout root"
  pass "fm-merge-local never infers or broadens recorded worktree metadata"
}

test_candidate_equivalent_target_index_and_worktree_fast_forward() {
  local case_dir
  case_dir=$(make_case candidate-equivalent)
  commit_candidate "$case_dir" resolved
  chmod +x "$case_dir/worker/payload.txt"
  git -C "$case_dir/worker" add payload.txt
  git -C "$case_dir/worker" commit -qm "make resolved payload executable"
  printf 'resolved\n' >"$case_dir/project/payload.txt"
  chmod +x "$case_dir/project/payload.txt"
  git -C "$case_dir/project" add payload.txt
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "candidate-equivalent target: merge failed"
  assert_ref_advanced "$case_dir" "candidate-equivalent target: main did not advance"
  [ -z "$(git -C "$case_dir/project" status --porcelain=v1 --untracked-files=all)" ] || fail "candidate-equivalent target: tracked dirt remained"
  pass "fm-merge-local adopts target index and worktree already equal to the candidate"
}

test_target_difference_refuses_and_many_paths_have_bounded_diagnostic() {
  local case_dir i
  case_dir=$(make_case target-difference)
  for i in $(seq 1 60); do printf 'base %s\n' "$i" >"$case_dir/project/local-$i.txt"; done
  git -C "$case_dir/project" add .
  git -C "$case_dir/project" commit -qm "target-only paths"
  commit_candidate "$case_dir" candidate
  for i in $(seq 1 60); do printf 'local %s\n' "$i" >"$case_dir/project/local-$i.txt"; done
  refusal_preserves "$case_dir" "does not exactly match fm/task-x1"
  [ "$(wc -l <"$case_dir/stderr")" -lt 20 ] || fail "target difference: diagnostic enumerated unbounded paths"
  pass "fm-merge-local refuses distinct tracked dirt with a bounded diagnostic"
}

test_hidden_target_bytes_and_modes_refuse() {
  local case_dir
  case_dir=$(make_case hidden-target-bytes)
  commit_candidate "$case_dir" candidate
  printf 'hidden local bytes\n' >"$case_dir/project/payload.txt"
  git -C "$case_dir/project" update-index --assume-unchanged payload.txt
  refusal_preserves "$case_dir" "does not exactly match fm/task-x1"

  case_dir=$(make_case hidden-target-mode)
  commit_candidate "$case_dir" resolved
  chmod +x "$case_dir/worker/payload.txt"
  git -C "$case_dir/worker" add payload.txt
  git -C "$case_dir/worker" commit -qm "make candidate executable"
  printf 'resolved\n' >"$case_dir/project/payload.txt"
  git -C "$case_dir/project" update-index --chmod=+x payload.txt
  chmod -x "$case_dir/project/payload.txt"
  git -C "$case_dir/project" config core.fileMode false
  refusal_preserves "$case_dir" "does not exactly match fm/task-x1"
  pass "fm-merge-local detects target byte and mode differences hidden by Git settings"
}

test_target_state_changed_after_preflight_refuses() {
  local before_main before_worker case_dir fakebin rc real_git
  case_dir=$(make_case target-churn)
  commit_candidate "$case_dir" candidate
  fakebin=$case_dir/fakebin
  real_git=$(command -v git)
  mkdir "$fakebin"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge-base --is-ancestor '*)
    if [ ! -e "$FM_TEST_MUTATION_MARKER" ]; then
      : >"$FM_TEST_MUTATION_MARKER"
      printf 'late target churn\n' >"$FM_TEST_TARGET/payload.txt"
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_TARGET="$case_dir/project" \
    FM_TEST_MUTATION_MARKER="$case_dir/mutated" run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "target changed after preflight: command should refuse"
  assert_grep 'does not exactly match fm/task-x1' "$case_dir/stderr" "target changed after preflight: final target recheck did not refuse"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "target changed after preflight"
  [ "$(tr -d '\n' <"$case_dir/project/payload.txt")" = 'late target churn' ] || fail "target changed after preflight: target content changed"
  pass "fm-merge-local rechecks target state at the final pre-mutation boundary"
}

test_target_churn_during_final_diagnostic_refuses() {
  local before_main before_worker case_dir fakebin rc real_git
  case_dir=$(make_case final-diagnostic-churn)
  printf 'candidate addition\n' >"$case_dir/worker/candidate.txt"
  git -C "$case_dir/worker" add candidate.txt
  git -C "$case_dir/worker" commit -qm "add candidate path"
  fakebin=$case_dir/fakebin
  real_git=$(command -v git)
  mkdir "$fakebin"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' rev-parse --short main '*)
    if [ ! -e "$FM_TEST_MUTATION_MARKER" ]; then
      : >"$FM_TEST_MUTATION_MARKER"
      printf 'final diagnostic churn\n' >"$FM_TEST_TARGET/payload.txt"
    fi
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_TARGET="$case_dir/project" \
    FM_TEST_MUTATION_MARKER="$case_dir/mutated" run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "final diagnostic churn: command should refuse"
  assert_grep 'does not exactly match fm/task-x1' "$case_dir/stderr" "final diagnostic churn: final validation did not refuse"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "final diagnostic churn"
  [ "$(tr -d '\n' <"$case_dir/project/payload.txt")" = 'final diagnostic churn' ] \
    || fail "final diagnostic churn: target content changed"
  pass "fm-merge-local validates target state after final diagnostics"
}

test_signal_at_final_merge_boundary_refuses() {
  local before_main before_worker case_dir expected fakebin rc real_git signal suffix
  for signal in HUP INT TERM; do
    case "$signal" in
      HUP) expected=129; suffix=hup ;;
      INT) expected=130; suffix=int ;;
      TERM) expected=143; suffix=term ;;
    esac
    case_dir=$(make_case "signal-$suffix")
    commit_candidate "$case_dir" candidate
    fakebin=$case_dir/fakebin
    real_git=$(command -v git)
    mkdir "$fakebin"
    cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge --ff-only '*)
    kill -s "$FM_TEST_SIGNAL" "$PPID"
    exit 99
    ;;
esac
exec "$REAL_GIT" "$@"
SH
    chmod +x "$fakebin/git"
    before_main=$(git -C "$case_dir/project" rev-parse main)
    before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
    set +e
    PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_SIGNAL="$signal" \
      run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
    rc=$?
    set -e
    expect_code "$expected" "$rc" "signal $signal at final boundary: command should terminate"
    assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "signal $signal at final boundary"
    [ "$(tr -d '\n' <"$case_dir/project/payload.txt")" = base ] \
      || fail "signal $signal at final boundary: target content changed"
    [ "$(tr -d '\n' <"$case_dir/worker/payload.txt")" = candidate ] \
      || fail "signal $signal at final boundary: worker content changed"
  done
  pass "fm-merge-local terminates safely on final-boundary signals"
}

test_untracked_content_is_preserved_or_git_refuses_collision() {
  local case_dir before_main before_worker fakebin rc real_git
  case_dir=$(make_case untracked-noncollision)
  commit_candidate "$case_dir"
  printf 'runtime*\nruntime-dir/\n' >"$case_dir/worker/.gitignore"
  git -C "$case_dir/worker" add .gitignore
  git -C "$case_dir/worker" commit -qm "ignore runtime state"
  printf 'runtime\n' >"$case_dir/project/runtime.log"
  ln -s runtime.log "$case_dir/project/runtime-link"
  mkdir "$case_dir/project/runtime-dir"
  printf 'runtime\n' >"$case_dir/project/runtime-dir/state"
  fakebin=$case_dir/fakebin
  real_git=$(command -v git)
  mkdir "$fakebin"
  cat >"$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' merge --ff-only '*)
    "$REAL_GIT" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then printf 'runtime churn\n' >"$FM_TEST_CHURN_PATH"; fi
    exit "$rc"
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  PATH="$fakebin:$PATH" REAL_GIT="$real_git" FM_TEST_CHURN_PATH="$case_dir/project/runtime.log" \
    run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "untracked noncollision: merge failed"
  assert_ref_advanced "$case_dir" "untracked noncollision: main did not advance"
  [ -f "$case_dir/project/runtime.log" ] && [ -L "$case_dir/project/runtime-link" ] && [ -d "$case_dir/project/runtime-dir" ] || fail "untracked noncollision: merge lost target content"
  [ "$(tr -d '\n' <"$case_dir/project/runtime.log")" = 'runtime churn' ] || fail "untracked noncollision: live runtime churn was not preserved"

  case_dir=$(make_case untracked-collision)
  printf 'candidate collision\n' >"$case_dir/worker/collision.txt"
  git -C "$case_dir/worker" add collision.txt
  git -C "$case_dir/worker" commit -qm "add collision path"
  printf 'untracked collision\n' >"$case_dir/project/collision.txt"
  before_main=$(git -C "$case_dir/project" rev-parse main)
  before_worker=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  set +e
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "untracked collision: Git should refuse final collision"
  assert_ref_unchanged "$case_dir" "$before_main" "$before_worker" "untracked collision"
  [ "$(tr -d '\n' <"$case_dir/project/collision.txt")" = 'untracked collision' ] || fail "untracked collision: target content changed"
  pass "fm-merge-local leaves untracked files, symlinks, and directories to Git's final collision check"
}

test_clean_target_ordinary_path() {
  local case_dir
  case_dir=$(make_case ordinary-path)
  commit_candidate "$case_dir"
  run_merge "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "ordinary path: merge failed"
  assert_ref_advanced "$case_dir" "ordinary path: main did not advance"
  pass "fm-merge-local preserves the ordinary clean target path"
}

test_clean_recorded_worker_fast_forwards
test_foreign_same_repository_worker_refuses
test_worker_state_changed_after_preflight_refuses
test_worker_branch_ref_changed_after_preflight_refuses
test_detached_and_different_repository_workers_refuse
test_unlanded_worker_states_refuse_without_mutation
test_hidden_worker_dirt_refuses_without_mutation
test_clean_filter_cannot_hide_worker_or_target_bytes
test_replacement_refs_cannot_hide_worker_bytes
test_ambient_git_overrides_cannot_redirect_verification
test_missing_duplicate_and_subdirectory_worktree_metadata_refuse
test_candidate_equivalent_target_index_and_worktree_fast_forward
test_target_difference_refuses_and_many_paths_have_bounded_diagnostic
test_hidden_target_bytes_and_modes_refuse
test_target_state_changed_after_preflight_refuses
test_target_churn_during_final_diagnostic_refuses
test_signal_at_final_merge_boundary_refuses
test_untracked_content_is_preserved_or_git_refuses_collision
test_clean_target_ordinary_path
