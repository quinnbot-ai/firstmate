#!/usr/bin/env bash
# tests/fm-backlog-graph-lint.test.sh - graph integrity gate for the durable
# backlog and the refill path that turns `tasks-axi ready` into dispatch evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-backlog-graph-lint.py"
REFILL="$ROOT/bin/fm-refill.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-graph-lint)

write_backlog() {  # <path> <body>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

run_lint() {  # <path>
  "$LINT" "$1" 2>&1
}

assert_failure_contains() {  # <needle> <command output> <label>
  case "$2" in *"$1"*) ;; *) fail "$3: expected '$1' in: $2" ;; esac
}

test_acyclic_graph_is_accepted() {
  local path out
  path="$TMP_ROOT/acyclic/backlog.md"
  write_backlog "$path" '# Backlog

## In flight
- [ ] build - Build

## Queued
- [ ] verify - Verify blocked-by: build

## Done
- [x] complete - Completed
'
  out=$(run_lint "$path")
  expect_code 0 $? "an acyclic graph should pass"
  assert_contains "$out" "BACKLOG GRAPH OK" "the valid graph did not report success"
  pass "an acyclic graph passes the graph lint"
}

test_two_node_cycle_is_rejected() {
  local path out rc
  path="$TMP_ROOT/two-cycle/backlog.md"
  write_backlog "$path" '# Backlog
## Queued
- [ ] alpha - Alpha blocked-by: beta
- [ ] beta - Beta blocked-by: alpha
'
  out=$(run_lint "$path"); rc=$?
  [ "$rc" -ne 0 ] || fail "a two-node cycle passed"
  assert_failure_contains "CYCLE: alpha -> beta -> alpha" "$out" "two-node cycle"
  pass "a two-node dependency cycle fails loudly"
}

test_longer_cycle_is_rejected() {
  local path out rc
  path="$TMP_ROOT/long-cycle/backlog.md"
  write_backlog "$path" '# Backlog
## Queued
- [ ] alpha - Alpha blocked-by: beta
- [ ] beta - Beta blocked-by: gamma
- [ ] gamma - Gamma blocked-by: delta
- [ ] delta - Delta blocked-by: alpha
'
  out=$(run_lint "$path"); rc=$?
  [ "$rc" -ne 0 ] || fail "a longer cycle passed"
  assert_failure_contains "CYCLE: alpha -> beta -> gamma -> delta -> alpha" "$out" "longer cycle"
  pass "a longer dependency cycle fails loudly"
}

test_dangling_blocker_is_rejected() {
  local path out rc
  path="$TMP_ROOT/dangling/backlog.md"
  write_backlog "$path" '# Backlog
## Queued
- [ ] dependent - Depends blocked-by: missing
'
  out=$(run_lint "$path"); rc=$?
  [ "$rc" -ne 0 ] || fail "a dangling blocker passed"
  assert_failure_contains "DANGLING: dependent" "$out" "dangling blocker"
  assert_failure_contains "blocked-by 'missing'" "$out" "dangling blocker"
  pass "a dangling blocker fails loudly"
}

test_completed_blocker_is_accepted() {
  local path out
  path="$TMP_ROOT/completed/backlog.md"
  write_backlog "$path" '# Backlog
## Queued
- [ ] dependent - Depends blocked-by: completed

## Done
- [x] completed - Completed
'
  out=$(run_lint "$path")
  expect_code 0 $? "a completed blocker should be accepted"
  assert_contains "$out" "BACKLOG GRAPH OK" "completed blocker did not preserve valid semantics"
  pass "a completed blocker remains a valid dependency"
}

test_malformed_structured_input_is_rejected() {
  local path out rc
  path="$TMP_ROOT/malformed/backlog.md"
  write_backlog "$path" '# Backlog
## Queued
- [x] active - Wrong checkbox state
'
  out=$(run_lint "$path"); rc=$?
  [ "$rc" -ne 0 ] || fail "malformed structured input passed"
  assert_failure_contains "MALFORMED: line 3: active tasks must use - [ ]" "$out" "malformed structured input"
  pass "malformed structured task records fail loudly"
}

fake_tasks_axi() {  # <bin-dir> <log>
  mkdir -p "$1"
  cat > "$1/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version)
    printf 'tasks-axi 0.2.5\n'
    exit 0
    ;;
  update)
    printf '%s\n' '--archive-body'
    exit 0
    ;;
  mv)
    printf '%s\n' '[<id>...]'
    exit 0
    ;;
  ready)
    printf '%s\n' "${FM_FAKE_TASKS_AXI_LOG:?}" >> "$FM_FAKE_TASKS_AXI_LOG"
    printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  unsafe,queued,task,-,Unsafe\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/tasks-axi"
}

test_refill_refuses_to_make_an_invalid_graph_dispatchable() {
  local home path fake log out rc
  home="$TMP_ROOT/refill-boundary"
  path="$home/data/backlog.md"
  fake="$home/fakebin"
  log="$home/tasks-axi.log"
  mkdir -p "$home/state" "$home/config"
  write_backlog "$path" '# Backlog
## Queued
- [ ] unsafe - Unsafe blocked-by: missing
'
  fake_tasks_axi "$fake" "$log"
  out=$(PATH="$fake:$PATH" FM_FAKE_TASKS_AXI_LOG="$log" "$REFILL" "$home/state" "$home/config" "$path" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "refill did not return graph-lint failure status: rc=$rc output=$out"
  assert_failure_contains "BACKLOG GRAPH INVALID" "$out" "refill graph boundary"
  [ ! -e "$log" ] || fail "refill queried tasks-axi ready after graph lint failed"
  pass "refill rejects an invalid graph before it can produce dispatch evidence"
}

test_acyclic_graph_is_accepted
test_two_node_cycle_is_rejected
test_longer_cycle_is_rejected
test_dangling_blocker_is_rejected
test_completed_blocker_is_accepted
test_malformed_structured_input_is_rejected
test_refill_refuses_to_make_an_invalid_graph_dispatchable
