#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-create.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-create)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OWNER="$ROOT/bin/fm-pr-create.sh"

make_case() {
  local name dir
  name=$1
  dir=$TMP_ROOT/$name
  mkdir -p "$dir/home/state" "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${FM_GH_WRAPPER_DEPTH:-}" = 1 ] || {
  printf '%s\n' 'gh did not receive the single fm-gh wrapper boundary' >&2
  exit 70
}
[ "${FM_GH_SHIM_ACTIVE:-}" = 1 ] || {
  printf '%s\n' 'gh did not receive the one-shot shim guard' >&2
  exit 70
}
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
body=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file) body=$2; shift 2; continue ;;
    --body) printf '%s' "$2" > "$FM_TEST_GH_BODY"; shift 2; continue ;;
  esac
  shift
done
[ -z "$body" ] || cp "$body" "$FM_TEST_GH_BODY"
printf '%s\n' 'https://github.com/quinnbot-ai/firstmate/pull/42'
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'nested gh-axi wrapper path is forbidden' >&2
exit 70
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

run_create() {
  local dir=$1
  shift
  env -u FM_GH_WRAPPER_DEPTH -u FM_GH_SHIM_ACTIVE \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_BODY="$dir/body.md" \
    PATH="$dir/fakebin:$PATH" "$OWNER" "$@"
}

test_generated_narrative_order_and_metadata_provenance() {
  local dir body
  dir=$(make_case generated)
  cat > "$dir/home/state/task-1.meta" <<'EOF'
harness=codex
kind=ship
mode=direct-PR
model=gpt-5.6-sol
effort=xhigh
EOF
  run_create "$dir" task-1 --repo quinnbot-ai/firstmate --title 'Narrative test' \
    --problem 'The direct PR path has no concise narrative.' \
    --outcome 'The direct PR path now generates one.' \
    --tests $'- bin/fm-pr-create.test.sh\n- quoted argument: "safe"' >/dev/null \
    || fail "generated direct PR creation failed"
  body="$dir/body.md"
  assert_present "$body" "generated direct PR body was not passed to gh"
  expected=$'## Problem\nThe direct PR path has no concise narrative.\n\n## Outcome\nThe direct PR path now generates one.\n\n## Tests\n- bin/fm-pr-create.test.sh\n- quoted argument: "safe"\n\n## Worker provenance\n- harness: codex\n- model: gpt-5.6-sol\n- effort: xhigh\n'
  [ "$(cat "$body")" = "${expected%$'\n'}" ] || fail "generated PR body did not preserve the required narrative order and quoting"
  assert_grep 'pr create --repo quinnbot-ai/firstmate --title Narrative test --body-file ' "$dir/gh.log" \
    "generated direct PR did not use the explicit fork target"
  pass "fm-pr-create.sh: generated bodies are Problem, Outcome, Tests, then recorded provenance"
}

test_provenance_omits_missing_and_malformed_metadata() {
  local kind dir body
  for kind in missing malformed; do
    dir=$(make_case "metadata-$kind")
    if [ "$kind" = malformed ]; then
      cat > "$dir/home/state/task-2.meta" <<'EOF'
harness=codex
kind=ship
mode=direct-PR
model=gpt-5.6-sol
model=worker-claimed-model
effort=xhigh
EOF
    fi
    run_create "$dir" task-2 --repo quinnbot-ai/firstmate --title 'Metadata test' \
      --problem 'Metadata needs an omission path.' \
      --outcome 'Missing or malformed provenance stays absent.' \
      --tests '- bin/fm-pr-create.test.sh' >/dev/null \
      || fail "$kind metadata should not block PR creation"
    body="$dir/body.md"
    if grep -qx '## Worker provenance' "$body"; then
      fail "$kind metadata unexpectedly produced provenance"
    fi
    assert_no_grep 'worker-claimed-model' "$body" "$kind metadata leaked a worker claim"
  done
  pass "fm-pr-create.sh: missing or malformed metadata omits provenance"
}

test_worker_prose_cannot_inject_provenance() {
  local dir out status
  dir=$(make_case worker-prose)
  out=$(run_create "$dir" task-3 --repo quinnbot-ai/firstmate --title 'Injection test' \
    --problem 'The generated body needs a trusted provenance source.' --outcome 'Worker prose cannot add one.' \
    --tests $'- bin/fm-pr-create.test.sh\n## Worker provenance' 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "worker prose was accepted as a provenance heading"
  assert_contains "$out" 'must not add a Worker provenance heading' \
    "worker-prose refusal did not explain provenance derivation"
  assert_absent "$dir/body.md" "refused worker prose still created a PR body"
  pass "fm-pr-create.sh: worker prose cannot inject a provenance heading"
}

test_custom_bodies_remain_untouched() {
  local dir custom
  dir=$(make_case custom-body)
  custom="$dir/custom.md"
  printf '%s\n' '## Existing custom body' 'Keep this content exactly.' > "$custom"
  run_create "$dir" task-4 --repo quinnbot-ai/firstmate --title 'Custom body' --body-file "$custom" \
    --head 'fm/custom' --base main >/dev/null || fail "explicit custom body creation failed"
  cmp -s "$custom" "$dir/body.md" || fail "explicit custom PR body was changed"
  grep -qxF "pr create --repo quinnbot-ai/firstmate --title Custom body --base main --head fm/custom --body-file $custom" "$dir/gh.log" \
    || fail "custom direct PR did not preserve its explicit fork target and arguments"
  pass "fm-pr-create.sh: explicit custom PR bodies stay untouched"
}

test_generated_narrative_order_and_metadata_provenance
test_provenance_omits_missing_and_malformed_metadata
test_worker_prose_cannot_inject_provenance
test_custom_bodies_remain_untouched
