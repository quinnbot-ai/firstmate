#!/usr/bin/env bash
# Behavioral regressions for the gh shim's exact-head workflow-runs CI fallback.
#
# The routed invocation under test is the exact argument vector the no-mistakes PR
# step builds for GitHub. Nothing here touches the real gh or the real daemon: a fake gh
# records how it was called. The pinned no-mistakes module is resolved for its public CI
# consumer boundary. CI cases feed raw workflow-run pages through the same jq expression
# the helper gives gh, so they exercise the public command contract rather than asserting
# implementation bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-gh-shim.sh"
CI_FALLBACK="$ROOT/bin/fm-gh-ci-fallback.sh"
NO_MISTAKES_CI_CONSUMER="$ROOT/tests/fixtures/no-mistakes-ci-consumer"
assert_present "$CI_FALLBACK" "bin/fm-gh-ci-fallback.sh is missing"
[ -x "$CI_FALLBACK" ] || fail "bin/fm-gh-ci-fallback.sh must be executable"
assert_present "$NO_MISTAKES_CI_CONSUMER/main.go" "the no-mistakes CI consumer fixture is missing"
assert_present "$NO_MISTAKES_CI_CONSUMER/go.mod" "the no-mistakes CI consumer module is missing"
TMP_ROOT=$(fm_test_tmproot fm-gh-shim)
# Create before normalizing, then normalize: $TMPDIR often carries a trailing slash and
# these cases compare fixture paths against the installer's own `cd`-normalized output,
# so the path must be resolved rather than compared raw. The mkdir is not redundant,
# because a cleanup trap registered inside the command substitution above can remove the
# directory before it is ever used, which would make the normalizing `cd` fail.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export FM_GH_CI_STATE_ROOT="$TMP_ROOT/ci-state"
export FM_GH_CI_ACTIONS_ONLY_REPOS=o/r

# make_fake_ci_gh <dir>: a gh double whose `pr checks` read is forbidden while the
# pull-request and workflow-runs APIs remain readable with the same ambient token.
# FM_TEST_WORKFLOW_PAGES and FM_TEST_STALE_PAGES are outer arrays holding the
# response pages in order; the double streams them one page at a time, because
# real `gh api --paginate` applies a --jq expression to each page on its own.
# It reproduces GitHub CLI 2.92.0's refusal of `--slurp` alongside `--jq`, and
# sorts result keys the way gh's own encoder does.
make_fake_ci_gh() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" << 'EOF'
#!/usr/bin/env bash
# pipefail keeps an unreadable page fixture a failed api call, the way a real
# failed workflow-runs read is, instead of a silent empty page sequence.
set -o pipefail
printf 'argv:%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'token:%s\n' "${GITHUB_TOKEN:-<none>}" >> "$FAKE_GH_LOG"

if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
  case "${FM_TEST_CHECKS_ERROR:-403}" in
    success)
      printf '%s\n' '[{"name":"native-check","state":"SUCCESS","bucket":"pass","completedAt":"2026-08-07T12:34:56Z"}]'
      exit 0
      ;;
    403)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup)" >&2
      ;;
    403-rate-limit)
      echo "HTTP 403: API rate limit exceeded (check-runs)" >&2
      ;;
    403-deep-path)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)" >&2
      ;;
    403-other-api)
      echo "GraphQL: Resource not accessible by personal access token (organization.t000)" >&2
      ;;
    403-lookalike)
      echo "GraphQL: Resource not accessible by personal access token (node.statusCheckRollupSummary.nodes.0)" >&2
      ;;
    *)
      echo "HTTP ${FM_TEST_CHECKS_ERROR}: simulated non-authorization failure" >&2
      ;;
  esac
  exit 1
fi

if [ "${1:-}" = api ]; then
  endpoint=
  query=
  slurp=0
  jq_given=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      repos/*) endpoint=$1; shift ;;
      --jq) query=$2; jq_given=1; shift 2 ;;
      --template) jq_given=1; shift 2 ;;
      --slurp) slurp=1; shift ;;
      *) shift ;;
    esac
  done
  if [ "$slurp" = 1 ] && [ "$jq_given" = 1 ]; then
    echo 'the `--slurp` option is not supported with `--jq` or `--template`' >&2
    exit 1
  fi
  case "$endpoint" in
    "repos/o/r/pulls/7")
      pull_calls=$(grep -c 'argv:api -X GET repos/o/r/pulls/7' "$FAKE_GH_LOG")
      if [ "$pull_calls" -gt 1 ]; then
        if [ -n "${FM_TEST_PR_HEAD_AFTER_ERROR:-}" ]; then
          printf '%s\n' "$FM_TEST_PR_HEAD_AFTER_ERROR" >&2
          exit 1
        fi
        printf '%s\n' "${FM_TEST_PR_HEAD_AFTER:-$FM_TEST_PR_HEAD}"
      else
        if [ -n "${FM_TEST_PR_HEAD_ERROR:-}" ]; then
          printf '%s\n' "$FM_TEST_PR_HEAD_ERROR" >&2
          exit 1
        fi
        printf '%s\n' "$FM_TEST_PR_HEAD"
      fi
      exit 0
      ;;
    "repos/o/r/actions/workflows?per_page=100")
      if [ -n "${FM_TEST_WORKFLOW_INVENTORY:-}" ]; then
        "$FM_TEST_JQ" -c '.[]' "$FM_TEST_WORKFLOW_INVENTORY" | "$FM_TEST_JQ" -S -c "$query"
      else
        "$FM_TEST_JQ" -c \
          '[.[] | {workflows: [.workflow_runs[] | select(.workflow_id != null) | {id: .workflow_id, name, path: (".github/workflows/" + (.workflow_id | tostring) + ".yml"), state: "active"}]}]' \
          "$FM_TEST_WORKFLOW_PAGES" | "$FM_TEST_JQ" -c '.[]' | "$FM_TEST_JQ" -S -c "$query"
      fi
      exit $?
      ;;
    repos/o/r/actions/runs/*/jobs*)
      run_id=${endpoint#repos/o/r/actions/runs/}
      run_id=${run_id%%/*}
      if [ -n "${FM_TEST_JOB_PAGES:-}" ]; then
        "$FM_TEST_JQ" -c '.[]' "$FM_TEST_JOB_PAGES" | "$FM_TEST_JQ" -S -c "$query"
      else
        "$FM_TEST_JQ" -c '.[]' "$FM_TEST_WORKFLOW_PAGES" | \
          "$FM_TEST_JQ" -c --argjson rid "$run_id" \
            '{jobs: [.workflow_runs[] | select(.id == $rid) | {id: ((.id * 100) + .run_attempt), run_id: .id, run_attempt, name: (.name + " job"), head_sha, status, conclusion, started_at: .created_at, completed_at: .updated_at, html_url}]}' | \
          "$FM_TEST_JQ" -S -c "$query"
      fi
      exit $?
      ;;
    "repos/o/r/actions/runs?head_sha=$FM_TEST_PR_HEAD&per_page=100")
      "$FM_TEST_JQ" -c '.[]' "$FM_TEST_WORKFLOW_PAGES" | "$FM_TEST_JQ" -S -c "$query"
      exit $?
      ;;
    repos/o/r/actions/runs*)
      "$FM_TEST_JQ" -c '.[]' "$FM_TEST_STALE_PAGES" | "$FM_TEST_JQ" -S -c "$query"
      exit $?
      ;;
  esac
fi

echo "unexpected fake gh invocation: $*" >&2
exit 2
EOF
  chmod +x "$dir/gh"
}

# assert_run_field <jq> <output> <run-name> <field> <expected> <message>: read the
# emitted check array as JSON and assert one named run's field, so the assertions
# depend on the documented check shape rather than on key order or spacing.
assert_run_field() {
  local jq_bin=$1 out=$2 name=$3 field=$4 expected=$5 message=$6 json actual
  json=$(printf '%s\n' "$out" | grep -E '^\[' | tail -1)
  [ -n "$json" ] || fail "$message (no JSON check array in the output)"
  # shellcheck disable=SC2016 # A literal jq program; its $ names belong to jq.
  actual=$(printf '%s' "$json" | "$jq_bin" -r --arg n "$name" --arg f "$field" \
    'map(select(.name == $n)) | if length == 0 then "<absent>" else (.[0][$f] // "<null>") end') ||
    fail "$message (the emitted check output is not valid JSON)"
  [ "$actual" = "$expected" ] ||
    fail "$message (expected $name.$field=$expected, got $actual)"
}

assert_no_mistakes_ci_consumer_rejects() {
  local out=$1 message=$2 json consumer_dir consumer response verdict
  json=$(printf '%s\n' "$out" | grep -E '^\[' | tail -1)
  [ -n "$json" ] || fail "$message (no JSON check array in the output)"
  consumer_dir="$TMP_ROOT/no-mistakes-ci-consumer"
  consumer="$consumer_dir/consumer"
  response="$consumer_dir/response.json"
  if [ ! -x "$consumer" ]; then
    command -v go >/dev/null 2>&1 || fail "$message (Go is required for the pinned no-mistakes consumer)"
    mkdir -p "$consumer_dir"
    cp "$NO_MISTAKES_CI_CONSUMER/main.go" "$NO_MISTAKES_CI_CONSUMER/go.mod" "$consumer_dir/"
    (cd "$consumer_dir" && GOWORK=off go build -mod=mod -o "$consumer" .) ||
      fail "$message (the pinned no-mistakes consumer did not build)"
  fi
  printf '%s\n' "$json" > "$response"
  verdict=$("$consumer" "$response") || fail "$message (consumer verdict was $verdict)"
  [ "$verdict" = rejected ] || fail "$message (consumer verdict was $verdict)"
}

ci_state_path() {
  printf '%s/owner-o/repository-r/pr-7.json\n' "$1"
}

write_ci_pages() {
  local path=$1 name=$2 status=$3 conclusion=$4 head=${5:-1111111111111111111111111111111111111111}
  cat > "$path" << EOF
[
  {
    "workflow_runs": [
      {
        "id": 123,
        "workflow_id": 7001,
        "run_number": 12,
        "run_attempt": 1,
        "name": "$name",
        "event": "pull_request",
        "head_sha": "$head",
        "status": "$status",
        "conclusion": $conclusion,
        "created_at": "2026-08-07T12:33:56Z",
        "updated_at": "2026-08-07T12:34:56Z",
        "html_url": "https://github.com/o/r/actions/runs/123",
        "repository": {"full_name": "o/r"},
        "pull_requests": [{"number": 7, "head": {"sha": "$head"}}]
      }
    ]
  }
]
EOF
}

test_ci_403_falls_back_to_exact_head_green_without_privileged_token() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-green"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" exact-head completed '"success"' "$head"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"failure"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" \
    GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 0 "$status" "exact-head workflow fallback green verdict"
  assert_run_field "$jq_bin" "$out" exact-head bucket pass \
    "successful exact-head workflow run did not become a green check"
  assert_grep "argv:api -X GET repos/o/r/actions/runs?head_sha=$head&per_page=100 --paginate --jq" \
    "$case_dir/gh.calls" \
    "fallback did not filter workflow runs by the exact PR head SHA"
  assert_grep 'token:narrow-ci-token' "$case_dir/gh.calls" \
    "CI fallback did not preserve the ambient narrow token"
  pass "a check-runs 403 reaches a green exact-head workflow verdict without the privileged token"
}

test_ci_head_lookup_errors_preserve_diagnostics_and_clear_state() {
  local case_dir real_dir head phase state_dir state_path out status jq_bin
  case_dir="$TMP_ROOT/ci-head-errors"
  real_dir="$case_dir/real"
  head=9696969696969696969696969696969696969696
  jq_bin=$(command -v jq) || fail "jq is required to inspect typed head failures"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" exact-head completed '"success"' "$head"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"failure"'

  for phase in initial recheck; do
    state_dir="$case_dir/state-$phase"
    state_path=$(ci_state_path "$state_dir")
    mkdir -p "$(dirname "$state_path")"
    printf '%s\n' '{"head":"old","first_seen":1}' > "$state_path"
    status=0
    if [ "$phase" = initial ]; then
      out=$(FAKE_GH_LOG="$case_dir/$phase.calls" FM_TEST_PR_HEAD="$head" \
        FM_TEST_PR_HEAD_ERROR="HTTP 403: initial head diagnostic" \
        FM_GH_CI_STATE_ROOT="$state_dir" GITHUB_TOKEN=narrow-ci-token \
        "$CI_FALLBACK" "$real_dir/gh" pr checks 7 --repo o/r \
        --json name,state,bucket,completedAt 2>&1) || status=$?
    else
      out=$(FAKE_GH_LOG="$case_dir/$phase.calls" FM_TEST_PR_HEAD="$head" \
        FM_TEST_PR_HEAD_AFTER_ERROR="HTTP 502: recheck head diagnostic" \
        FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
        FM_TEST_JQ="$jq_bin" FM_GH_CI_STATE_ROOT="$state_dir" GITHUB_TOKEN=narrow-ci-token \
        "$CI_FALLBACK" "$real_dir/gh" pr checks 7 --repo o/r \
        --json name,state,bucket,completedAt 2>&1) || status=$?
    fi
    expect_code 0 "$status" "$phase PR-head failure transport"
    assert_contains "$out" "$phase head diagnostic" \
      "$phase PR-head failure suppressed the underlying GitHub diagnostic"
    assert_run_field "$jq_bin" "$out" "Firstmate CI fallback - API error" bucket fail \
      "$phase PR-head failure did not emit a typed failed check"
    assert_no_mistakes_ci_consumer_rejects "$out" \
      "$phase PR-head failure did not fail the no-mistakes CI consumer"
    assert_absent "$state_path" "$phase PR-head failure retained stale pending state"
  done
  pass "both PR-head lookup failures preserve diagnostics and clear deadline state"
}

test_ci_403_falls_back_to_exact_head_red() {
  local case_dir real_dir shim_dir head out status jq_bin
  case_dir="$TMP_ROOT/ci-red"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" failing-workflow completed '"failure"' "$head"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt,link 2>&1) || status=$?

  expect_code 0 "$status" "exact-head workflow fallback red verdict transport"
  assert_run_field "$jq_bin" "$out" failing-workflow state failure \
    "failed exact-head workflow run lost its provider conclusion"
  assert_run_field "$jq_bin" "$out" failing-workflow bucket fail \
    "failed exact-head workflow run did not become a red check"
  assert_no_mistakes_ci_consumer_rejects "$out" \
    "failed exact-head workflow run did not fail the no-mistakes CI consumer"
  assert_run_field "$jq_bin" "$out" failing-workflow link \
    "https://github.com/o/r/actions/runs/123" \
    "failed workflow result did not retain its Actions run link"
  pass "a check-runs 403 reaches a red exact-head workflow verdict"
}

test_ci_wrong_head_run_is_rejected() {
  local case_dir real_dir shim_dir head stale_head out status jq_bin
  case_dir="$TMP_ROOT/ci-wrong-head-run"
  real_dir="$case_dir/real"
  shim_dir="$case_dir/shim"
  head=2323232323232323232323232323232323232323
  stale_head=2424242424242424242424242424242424242424
  jq_bin=$(command -v jq) || fail "jq is required to exercise gh's built-in --jq contract"
  make_fake_ci_gh "$real_dir"
  write_ci_pages "$case_dir/exact.json" CI completed '"success"' "$stale_head"
  write_ci_pages "$case_dir/stale.json" stale-head completed '"success"'
  mkdir -p "$shim_dir"
  ln -sf "$SHIM" "$shim_dir/gh"

  status=0
  out=$(FAKE_GH_LOG="$case_dir/gh.calls" FM_TEST_PR_HEAD="$head" \
    FM_TEST_WORKFLOW_PAGES="$case_dir/exact.json" FM_TEST_STALE_PAGES="$case_dir/stale.json" \
    FM_TEST_JQ="$jq_bin" GITHUB_TOKEN=narrow-ci-token PATH="$shim_dir:$real_dir:$PATH" \
    gh pr checks 7 --repo o/r --json name,state,bucket,completedAt 2>&1) || status=$?

  expect_code 0 "$status" "wrong-head workflow fallback transport"
  assert_run_field "$jq_bin" "$out" "Firstmate CI fallback - unverifiable evidence" bucket fail \
    "a wrong-head workflow run did not fail as unverifiable evidence"
  assert_not_contains "$out" '"bucket":"pass"' \
    "a stale workflow run incorrectly certified the current head green"
  pass "a stale workflow run cannot certify the current PR head"
}

test_ci_403_falls_back_to_exact_head_green_without_privileged_token
test_ci_head_lookup_errors_preserve_diagnostics_and_clear_state
test_ci_403_falls_back_to_exact_head_red
test_ci_wrong_head_run_is_rejected
