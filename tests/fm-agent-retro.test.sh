#!/usr/bin/env bash
# Behavior tests for the bounded, redacted agent-retrospective helper.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETRO="$ROOT/bin/fm-agent-retro.sh"
SKILL="$ROOT/.agents/skills/agent-retro/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-agent-retro)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_meta() { # <home> <id> <kind> <mode> <harness> <model> <effort>
  local home=$1 id=$2 kind=$3 mode=$4 harness=$5 model=$6 effort=$7
  fm_write_meta "$home/state/$id.meta" \
    "window=fixture:fm-$id" "worktree=/private/fixture/$id" "project=fixture" \
    "harness=$harness" "model=$model" "effort=$effort" "kind=$kind" "mode=$mode"
}

run_retro() { # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$RETRO" "$@"
}

fingerprint() { # <home>
  find "$1/state" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
}

write_standard_fixture() {
  local home=$1
  write_meta "$home" alpha ship no-mistakes codex gpt-5.6-sol high
  write_meta "$home" beta scout scout codex gpt-5.6-sol medium
  write_meta "$home" z-old ship no-mistakes claude opus low
  printf '%s\n' 'failed: fixture failure included /private/path and token=secret-value' > "$home/state/alpha.status"
  printf '%s\n' 'needs-decision: fixture choice included /private/path and token=secret-value' > "$home/state/beta.status"
  printf '%s\n' 'failed: excluded old failure token=old-secret' > "$home/state/z-old.status"
  : > "$home/state/alpha.turn-ended"
  touch -t 202608111200 "$home/state/alpha.meta" "$home/state/beta.meta" "$home/state/z-old.meta"
}

test_deterministic_ranking_window_redaction_and_coverage() {
  local home first second
  home=$(make_home ranking)
  write_standard_fixture "$home"
  first=$(run_retro "$home" --window 2) || fail "fixture retrospective failed: $first"
  second=$(run_retro "$home" --window 2) || fail "repeated retrospective failed: $second"
  [ "$first" = "$second" ] || fail "retrospective output is not deterministic"
  assert_contains "$first" 'tasks: 2 sampled of 3 safe metadata records' "bounded metadata task window was not disclosed"
  assert_contains "$first" 'source_coverage:' "source coverage missing"
  assert_contains "$first" 'status_logs: 2' "status-log coverage is wrong"
  assert_contains "$first" 'turn_end_markers: 1' "turn-end coverage is wrong"
  assert_contains "$first" 'confidence: "low"' "small sample confidence was not disclosed"
  assert_contains "$first" 'failure_categories[2]{rank,category,count,examples,proposal}:' "failure table missing"
  assert_contains "$first" '1,"terminal_failure",1' "ranking tie-break must put terminal failure first"
  assert_contains "$first" '2,"workflow_gate",1' "ranking tie-break must keep workflow gate second"
  assert_contains "$first" 'Proposal only - human approval required' "proposal approval gate missing"
  assert_contains "$first" 'task_mix[2]{kind,mode,harness,model,effort,tasks}:' "task-mix breakdown missing"
  assert_not_contains "$first" 'alpha' "raw task id leaked"
  assert_not_contains "$first" '/private/path' "raw path leaked"
  assert_not_contains "$first" 'secret-value' "raw status content leaked"
  assert_not_contains "$first" 'old-secret' "unselected status record was read or leaked"
  pass "deterministic bounded ranking, redaction, and coverage"
}

test_empty_state_and_model_suppression() {
  local home out
  home=$(make_home empty)
  out=$(run_retro "$home") || fail "empty retrospective failed: $out"
  assert_contains "$out" 'state: "empty"' "empty state was not explicit"
  assert_contains "$out" 'failure_categories: []' "empty failure categories were not explicit"
  assert_contains "$out" 'model_comparisons: []' "sparse model comparison was not suppressed"
  assert_contains "$out" 'model_quality: "suppressed:' "model-quality limitation missing"
  pass "explicit empty state and sparse model suppression"
}

test_examples_remain_bounded() {
  local home out id
  home=$(make_home examples)
  for id in a b c d e; do
    write_meta "$home" "$id" ship direct codex gpt-5.6-sol high
    printf '%s\n' 'failed: repeatable fixture failure' > "$home/state/$id.status"
    touch -t 202608111201 "$home/state/$id.meta"
  done
  out=$(run_retro "$home" --window 5) || fail "example-bound fixture failed: $out"
  assert_contains "$out" '"terminal_failure",5,"redacted task samples: 3"' "examples exceeded or hid the documented bound"
  pass "failure examples stay bounded and redacted"
}

test_malformed_symlink_and_unsafe_sources_refuse() {
  local home out rc target
  home=$(make_home malformed)
  write_meta "$home" malformed ship direct codex gpt-5.6-sol high
  printf '%s\n' 'not-a-record' > "$home/state/malformed.meta"
  set +e
  out=$(run_retro "$home")
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed metadata must fail closed"
  assert_contains "$out" 'error:' "malformed metadata lacked structured error"

  home=$(make_home symlink)
  write_meta "$home" linked ship direct codex gpt-5.6-sol high
  target="$TMP_ROOT/outside.status"
  printf '%s\n' 'failed: outside source' > "$target"
  ln -s "$target" "$home/state/linked.status"
  set +e
  out=$(run_retro "$home")
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked status source must fail closed"
  assert_contains "$out" 'error:' "symlink refusal lacked structured error"

  home=$(make_home hardlink)
  write_meta "$home" linked ship direct codex gpt-5.6-sol high
  printf '%s\n' 'failed: shared source' > "$TMP_ROOT/hardlink-source"
  ln "$TMP_ROOT/hardlink-source" "$home/state/linked.status"
  set +e
  out=$(run_retro "$home")
  rc=$?
  set -e
  expect_code 1 "$rc" "hardlinked status source must fail closed"
  assert_contains "$out" 'single-link source record' "hardlink refusal was not specific"
  pass "malformed and symlinked sources fail closed"
}

test_read_only_unknown_flags_and_toon_shape() {
  local home before after out rc
  home=$(make_home readonly)
  write_meta "$home" clean ship no-mistakes codex gpt-5.6-sol high
  printf '%s\n' 'done: PR fixture checks green' > "$home/state/clean.status"
  before=$(fingerprint "$home")
  out=$(run_retro "$home") || fail "read-only fixture failed: $out"
  after=$(fingerprint "$home")
  [ "$before" = "$after" ] || fail "read-only helper changed a source record"
  assert_contains "$out" 'schema: "fm-agent-retro.v1"' "TOON schema missing"
  assert_contains "$out" 'ci_review_classes: 1' "recorded CI result class was not counted"
  assert_contains "$out" 'limitations[3]:' "TOON array header is missing or unstable"
  assert_not_contains "$out" $'\r' "TOON must use LF lines"
  set +e
  out=$(run_retro "$home" --not-a-flag)
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown flag exit code"
  assert_contains "$out" 'Valid flags: --window <1-100>, --help.' "unknown flag was not actionable"
  pass "read-only behavior, usage exit, and TOON shape"
}

test_process_level_skill_helper_smoke() {
  local home out
  home=$(make_home smoke)
  [ -f "$SKILL" ] || fail "agent-retro skill is missing"
  assert_grep 'name: agent-retro' "$SKILL" "skill frontmatter missing name"
  assert_grep '/agent-retro' "$SKILL" "skill trigger missing"
  assert_grep 'bin/fm-agent-retro.sh' "$SKILL" "skill does not invoke helper"
  out=$(run_retro "$home" --window 1) || fail "process-level helper smoke failed: $out"
  assert_contains "$out" 'state: "empty"' "helper smoke did not emit report"
  pass "process-level skill and helper smoke path"
}

test_deterministic_ranking_window_redaction_and_coverage
test_empty_state_and_model_suppression
test_examples_remain_bounded
test_malformed_symlink_and_unsafe_sources_refuse
test_read_only_unknown_flags_and_toon_shape
test_process_level_skill_helper_smoke
