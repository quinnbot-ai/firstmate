#!/usr/bin/env bash
# Behavior tests for the generated-crewmate status reporting boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-status-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-report)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then
  printf '%s\n' "$FM_STATUS_REPORT_TEST_EPOCH"
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$FAKEBIN/date"

make_home() {
  local name home
  name=$1
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

report_event() {
  local file=$1 line=$2 epoch=${3:-1000000}
  PATH="$FAKEBIN:$PATH" FM_STATUS_REPORT_TEST_EPOCH="$epoch" "$REPORT" "$file" "$line"
}

line_count() {
  awk 'END { print NR + 0 }' "$1"
}

# The old generated brief issued direct `echo >> status` commands, so every
# long-cadence unchanged recheck added another identical paused line.
# This is intentionally process-level: each invocation is a fresh reporter
# process through the production reporting boundary.
test_unchanged_keyed_pause_is_deduplicated_across_reporter_processes() {
  local home status line out
  home=$(make_home duplicate)
  status="$home/state/held.status"
  line='paused [key=upstream-release]: waiting for upstream release'

  out=$(report_event "$status" "$line" 1000000) || fail "first pause report failed"
  [ "$out" = appended ] || fail "first pause report was not appended: $out"
  out=$(report_event "$status" "$line" 1000010) || fail "second pause report failed"
  [ "$out" = suppressed ] || fail "unchanged second pause was not suppressed: $out"
  out=$(report_event "$status" "$line" 1000020) || fail "third pause report failed"
  [ "$out" = suppressed ] || fail "unchanged third pause was not suppressed: $out"
  [ "$(line_count "$status")" -eq 1 ] || fail "unchanged rechecks bloated status history"
  assert_grep "$line" "$status" "first material pause was not retained"
  pass "keyed unchanged pause reports deduplicate across fresh reporter processes"
}

test_dedupe_identity_is_home_task_and_phase_key() {
  local home_a home_b line a_task a_other_task b_task a_other_key
  home_a=$(make_home identity-a)
  home_b=$(make_home identity-b)
  line='paused [key=upstream-release]: waiting for upstream release'
  a_task="$home_a/state/task-a.status"
  a_other_task="$home_a/state/task-b.status"
  b_task="$home_b/state/task-a.status"
  a_other_key='paused [key=vendor-release]: waiting for upstream release'

  report_event "$a_task" "$line" >/dev/null || fail "home A task A initial report failed"
  report_event "$a_task" "$line" 1000010 >/dev/null || fail "home A task A duplicate report failed"
  report_event "$a_other_task" "$line" 1000010 >/dev/null || fail "distinct task was suppressed"
  report_event "$b_task" "$line" 1000010 >/dev/null || fail "distinct home was suppressed"
  report_event "$a_task" "$a_other_key" 1000010 >/dev/null || fail "distinct key was suppressed"

  [ "$(line_count "$a_task")" -eq 2 ] || fail "distinct key did not remain independent"
  [ "$(line_count "$a_other_task")" -eq 1 ] || fail "distinct task crossed dedupe boundary"
  [ "$(line_count "$b_task")" -eq 1 ] || fail "distinct home crossed dedupe boundary"
  pass "pause dedupe identity is isolated by home, task, and stable key"
}

test_changed_pause_and_keyed_transition_append_immediately() {
  local home status first changed resolved out
  home=$(make_home transitions)
  status="$home/state/held.status"
  first='paused [key=upstream-release]: waiting for upstream release'
  changed='paused [key=upstream-release]: waiting for vendor approval instead'
  resolved='resolved [key=upstream-release]: upstream release landed'

  report_event "$status" "$first" >/dev/null || fail "initial pause failed"
  report_event "$status" "$first" 1000010 >/dev/null || fail "duplicate pause failed"
  out=$(report_event "$status" "$changed" 1000020) || fail "changed pause failed"
  [ "$out" = appended ] || fail "changed pause was not appended: $out"
  out=$(report_event "$status" "$resolved" 1000030) || fail "resolved transition failed"
  [ "$out" = appended ] || fail "resolved transition was not appended: $out"
  out=$(report_event "$status" "$first" 1000040) || fail "pause after resolved transition failed"
  [ "$out" = appended ] || fail "pause after transition was incorrectly suppressed: $out"
  [ "$(line_count "$status")" -eq 4 ] || fail "changed pause or transition was lost"
  assert_grep "$changed" "$status" "changed reason missing from history"
  assert_grep "$resolved" "$status" "resolved transition missing from history"
  pass "changed pause reasons and keyed state transitions append immediately"
}

test_unchanged_pause_resurfaces_after_one_hour() {
  local home status line out
  home=$(make_home hourly)
  status="$home/state/held.status"
  line='paused [key=upstream-release]: waiting for upstream release'

  report_event "$status" "$line" 1000000 >/dev/null || fail "initial pause failed"
  out=$(report_event "$status" "$line" 1003599) || fail "pre-hour recheck failed"
  [ "$out" = suppressed ] || fail "pause resurfaced before one hour: $out"
  out=$(report_event "$status" "$line" 1003600) || fail "hourly recheck failed"
  [ "$out" = appended ] || fail "unchanged pause did not resurface at one hour: $out"
  [ "$(line_count "$status")" -eq 2 ] || fail "hourly safety resurface did not append exactly once"
  pass "unchanged keyed pauses resurface at the one-hour safety boundary"
}

test_concurrent_reporters_preserve_all_material_transitions() {
  local home status line changed resolved pids pid i
  home=$(make_home concurrent)
  status="$home/state/held.status"
  line='paused [key=upstream-release]: waiting for upstream release'
  changed='paused [key=upstream-release]: waiting for vendor approval instead'
  resolved='resolved [key=upstream-release]: vendor approved release'

  pids=
  i=1
  while [ "$i" -le 16 ]; do
    report_event "$status" "$line" 1000000 >/dev/null &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent unchanged reporter failed"
  done
  [ "$(line_count "$status")" -eq 1 ] || fail "concurrent unchanged reports were not serialized"

  report_event "$status" "$changed" 1000010 >/dev/null &
  pids="$!"
  report_event "$status" "$resolved" 1000010 >/dev/null &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent material transition reporter failed"
  done
  assert_grep "$changed" "$status" "concurrent changed pause was lost"
  assert_grep "$resolved" "$status" "concurrent resolved transition was lost"
  [ "$(line_count "$status")" -eq 3 ] || fail "concurrent material transitions did not append deterministically"
  pass "lock-safe concurrent reporters retain every material transition"
}

test_history_is_never_rewritten_across_a_reporter_restart() {
  local home status first later before after
  home=$(make_home restart)
  status="$home/state/held.status"
  first='working [key=build]: implementing status reporting'
  later='paused [key=build]: waiting for the test window'

  report_event "$status" "$first" >/dev/null || fail "working phase failed"
  before=$(cat "$status")
  report_event "$status" "$later" 1000010 >/dev/null || fail "fresh reporter pause failed"
  report_event "$status" "$later" 1000020 >/dev/null || fail "fresh reporter dedupe failed"
  after=$(head -n 1 "$status")
  [ "$after" = "$before" ] || fail "restart rewrote existing append-only status history"
  [ "$(line_count "$status")" -eq 2 ] || fail "restart did not preserve one appended material pause"
  pass "durable pause state survives reporter restarts without rewriting history"
}

test_unchanged_keyed_pause_is_deduplicated_across_reporter_processes
test_dedupe_identity_is_home_task_and_phase_key
test_changed_pause_and_keyed_transition_append_immediately
test_unchanged_pause_resurfaces_after_one_hour
test_concurrent_reporters_preserve_all_material_transitions
test_history_is_never_rewritten_across_a_reporter_restart
