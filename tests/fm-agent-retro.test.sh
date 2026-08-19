#!/usr/bin/env bash
# Behavior tests for the bounded, read-only agent retrospective.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETRO="$ROOT/bin/fm-agent-retro.sh"
TMP_ROOT=$(fm_test_tmproot fm-agent-retro)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id> <kind> <mode> <harness> <model> <effort>
  fm_write_meta "$1/state/$2.meta" \
    "window=fixture:fm-$2" \
    "worktree=/private/fixture/$2" \
    "project=/private/fixture" \
    "harness=$5" \
    "kind=$3" \
    "mode=$4" \
    "model=$6" \
    "effort=$7"
}

run_retro() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" "$RETRO" "$@"
}

fingerprint() {  # <home>
  find "$1/state" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
}

# Two recent tasks plus an older one, so a window smaller than the fixture
# proves the bound rather than merely fitting inside it.
standard_fixture() {  # <home>
  local home=$1
  write_task "$home" alpha ship no-mistakes codex default high
  write_task "$home" beta scout scout codex default medium
  write_task "$home" z-old ship direct-PR codex default low
  printf '%s\n' 'working: setup done' > "$home/state/alpha.status"
  printf '%s\n' 'failed: fixture failure under /private/fixture with token=secret-value' >> "$home/state/alpha.status"
  printf '%s\n' 'needs-decision: fixture choice about /private/fixture and token=secret-value' > "$home/state/beta.status"
  printf '%s\n' 'failed: excluded older failure token=stale-secret' > "$home/state/z-old.status"
  : > "$home/state/alpha.turn-ended"
  touch -t 202601010000 "$home/state/z-old.meta"
}

test_bounded_window_coverage_and_redaction() {
  local home first second
  home=$(make_home bounded)
  standard_fixture "$home"
  first=$(run_retro "$home" --window 2) || fail "bounded retrospective failed: $first"
  second=$(run_retro "$home" --window 2) || fail "repeated retrospective failed: $second"
  [ "$first" = "$second" ] || fail "retrospective output is not deterministic"
  assert_contains "$first" 'schema: "fm-agent-retro.v1"' "output contract missing"
  assert_contains "$first" 'state: "ok"' "populated state was not reported"
  assert_contains "$first" '  sampled: 2' "the window bound was not applied"
  assert_contains "$first" '  total: 3' "the unsampled remainder was not disclosed"
  assert_contains "$first" '  status_logs: 2' "status-log coverage is wrong"
  assert_contains "$first" '  status_events: 3' "status-event coverage is wrong"
  assert_contains "$first" '  turn_end_markers: 1' "turn-end coverage is wrong"
  assert_contains "$first" '  terminal_outcomes: 1' "terminal-outcome coverage is wrong"
  assert_contains "$first" 'task_mix[2]{kind,mode,harness,model,effort,tasks}:' "task mix missing"
  assert_contains "$first" '"scout","scout","codex","default","medium",1' "task-mix row is wrong"
  assert_contains "$first" 'outcome_categories[2]{rank,category,events,tasks,proposal}:' "outcome categories missing"
  assert_contains "$first" '1,"recorded_failure",1,1,' "count ranking tie-break is not deterministic"
  assert_contains "$first" '2,"supervisor_gate",1,1,' "count ranking tie-break is not deterministic"
  assert_contains "$first" 'Proposal only - human approval required:' "proposals are not approval-gated"
  assert_contains "$first" 'confidence: "low"' "a small sample was not reported as low confidence"
  assert_not_contains "$first" 'alpha' "a task id leaked into the report"
  assert_not_contains "$first" '/private/fixture' "a recorded path leaked into the report"
  assert_not_contains "$first" 'secret-value' "status text leaked into the report"
  assert_not_contains "$first" 'stale-secret' "an unsampled task's status log was read"
  pass "bounded window, source coverage, and redacted output"
}

test_empty_state_is_explicit() {
  local home out
  home=$(make_home empty)
  out=$(run_retro "$home") || fail "empty retrospective failed: $out"
  assert_contains "$out" 'state: "empty"' "an empty home was not explicit"
  assert_contains "$out" 'task_mix: []' "an empty task mix was not explicit"
  assert_contains "$out" 'outcome_categories: []' "empty outcome categories were not explicit"
  assert_contains "$out" 'limitations[4]:' "the limitations block is missing"
  pass "an empty home reports an explicit empty result"
}

test_unsafe_sources_are_disclosed_not_read() {
  local home out
  home=$(make_home unsafe)
  write_task "$home" linked ship no-mistakes codex default high
  printf '%s\n' 'failed: outside-the-home source' > "$TMP_ROOT/outside.status"
  ln -s "$TMP_ROOT/outside.status" "$home/state/linked.status"
  out=$(run_retro "$home") || fail "unsafe-source retrospective failed: $out"
  assert_contains "$out" '  status_logs: 0' "a symlinked status log was read"
  assert_contains "$out" '  unreadable_sources: 1' "a skipped source was not disclosed"
  assert_contains "$out" 'outcome_categories: []' "a symlinked status log reached the categories"
  pass "a source outside the home is skipped and disclosed"
}

test_unexpected_metadata_values_are_normalized() {
  local home out
  home=$(make_home values)
  fm_write_meta "$home/state/odd.meta" \
    'harness=/private/fixture/launch --token secret-value' \
    'kind=scout' \
    'model=default' \
    'model=default'
  out=$(run_retro "$home") || fail "normalizing retrospective failed: $out"
  assert_contains "$out" '"scout","unknown","other","other","unknown",1' "unexpected metadata was not normalized"
  assert_not_contains "$out" 'secret-value' "a metadata value leaked into the report"
  assert_not_contains "$out" '/private/fixture' "a metadata path leaked into the report"
  pass "unexpected metadata values normalize instead of leaking"
}

test_retrospective_changes_nothing() {
  local home before after
  home=$(make_home readonly)
  standard_fixture "$home"
  before=$(fingerprint "$home")
  run_retro "$home" >/dev/null || fail "read-only retrospective failed"
  after=$(fingerprint "$home")
  [ "$before" = "$after" ] || fail "the retrospective changed a source record"
  pass "the retrospective leaves every source record unchanged"
}

test_usage_and_refusals() {
  local home out rc
  home=$(make_home usage)
  out=$(run_retro "$home" --help) || fail "--help must succeed"
  assert_contains "$out" 'usage: fm-agent-retro.sh' "--help did not print usage"
  set +e
  out=$(run_retro "$home" --not-a-flag)
  rc=$?
  set -e
  expect_code 2 "$rc" "an unknown flag must be a usage error"
  assert_contains "$out" 'Valid flags: --window <1-100>, --help.' "an unknown flag was not actionable"
  set +e
  out=$(run_retro "$home" --window 101)
  rc=$?
  set -e
  expect_code 2 "$rc" "an out-of-range window must be a usage error"
  assert_contains "$out" 'schema: "fm-agent-retro.v1"' "a refusal must keep the output contract"
  set +e
  out=$(FM_HOME="$TMP_ROOT/absent-home" "$RETRO")
  rc=$?
  set -e
  expect_code 1 "$rc" "an unresolvable home must refuse"
  assert_contains "$out" 'error:' "an unresolvable home lacked a structured error"
  pass "usage, refusals, and structured errors"
}

test_bounded_window_coverage_and_redaction
test_empty_state_is_explicit
test_unsafe_sources_are_disclosed_not_read
test_unexpected_metadata_values_are_normalized
test_retrospective_changes_nothing
test_usage_and_refusals
