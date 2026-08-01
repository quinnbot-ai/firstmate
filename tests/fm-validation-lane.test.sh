#!/usr/bin/env bash
# Behavior tests for the home-local no-mistakes validation lane.
#
# These cases execute the public scheduler and its generated watcher check in
# disposable state directories.  Delivery and crew-state reads are fixture
# binaries, so they never attach to a live runtime or start a validation run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-validation-lane.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-lane)

make_case() {
  local name=$1 dir
  dir=$TMP_ROOT/$name
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  : > "$dir/send.log"
  cat > "$dir/fakebin/send" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "${*:2}" >> "$FM_TEST_SEND_LOG"
printf '%s\n' "${FM_TEST_SEND_OUTPUT:-}"
exit "${FM_TEST_SEND_RC:-0}"
SH
  cat > "$dir/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE:-state: working · source: run-step · validating}"
SH
  chmod +x "$dir/fakebin/send" "$dir/fakebin/crew-state"
  printf '%s\n' "$dir"
}

run_lane() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" "$LANE" "$@"
}

assert_state() {  # <case-dir> <expected-content> <message>
  local actual
  actual=$(cat "$1/home/state/validation-lane" 2>/dev/null || true)
  [ "$actual" = "$2" ] || fail "$3 (got: $actual)"
}

test_enqueue_reserves_and_delivers_first_task() {
  local dir out
  dir=$(make_case first)
  out=$(run_lane "$dir" enqueue alpha)
  assert_contains "$out" "released alpha" "first enqueue did not release alpha"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=alpha' "first task was not recorded as holder"
  [ -x "$dir/home/state/validation-lane.check.sh" ] || fail "watcher check was not installed"
  [ -f "$dir/home/state/validation-lane.check-trust" ] || fail "watcher check was not registered"
  assert_contains "$(cat "$dir/send.log")" "alpha|Validation slot reserved." "release did not use the send boundary"
  pass "validation lane: first enqueue reserves and delivers through registered watcher state"
}

test_queue_is_fifo_and_terminal_check_releases_next() {
  local dir out
  dir=$(make_case fifo)
  run_lane "$dir" enqueue alpha >/dev/null
  out=$(run_lane "$dir" enqueue beta)
  assert_contains "$out" "queued beta" "second task was not queued"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=alpha\nqueued=beta' "queue did not preserve alpha then beta"
  FM_TEST_CREW_STATE='state: working · source: run-step · validating' run_lane "$dir" check > "$dir/check-working.out"
  [ ! -s "$dir/check-working.out" ] || fail "working holder released its slot"
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green' run_lane "$dir" check > "$dir/check-terminal.out"
  assert_contains "$(cat "$dir/check-terminal.out")" "released beta" "terminal holder did not release beta"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=beta' "beta was not promoted from the FIFO queue"
  [ "$(wc -l < "$dir/send.log" | tr -d '[:space:]')" = 2 ] || fail "release delivered an unexpected number of messages"
  pass "validation lane: queued work releases in FIFO order only after a terminal run-step"
}

test_status_log_terminal_does_not_free_a_slot() {
  local dir
  dir=$(make_case status-log)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  FM_TEST_CREW_STATE='state: done · source: status-log · stale event' run_lane "$dir" check > "$dir/check.out"
  [ ! -s "$dir/check.out" ] || fail "status-log terminal result released its slot"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=alpha\nqueued=beta' "status-log result changed validation ownership"
  pass "validation lane: only an authoritative run-step terminal result frees a slot"
}

test_empty_lane_retires_its_watcher_artifacts() {
  local dir
  dir=$(make_case retire)
  run_lane "$dir" enqueue alpha >/dev/null
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green' run_lane "$dir" check > "$dir/check.out"
  [ ! -e "$dir/home/state/validation-lane" ] || fail "empty lane state was not retired"
  [ ! -e "$dir/home/state/validation-lane.check.sh" ] || fail "empty lane check was not retired"
  [ ! -e "$dir/home/state/validation-lane.check-trust" ] || fail "empty lane trust was not retired"
  pass "validation lane: an empty lane retires its watcher artifacts"
}

test_failed_delivery_remains_pending_and_is_retried() {
  local dir out
  dir=$(make_case retry)
  FM_TEST_SEND_RC=7 FM_TEST_SEND_OUTPUT='fixture transport down' run_lane "$dir" enqueue alpha > "$dir/enqueue.out"
  out=$(cat "$dir/enqueue.out")
  assert_contains "$out" "release failed for alpha: fixture transport down" "failed delivery was not loud"
  assert_state "$dir" $'fm-validation-lane-v1\nrelease=alpha' "failed delivery lost its durable release reservation"
  FM_TEST_SEND_RC=7 FM_TEST_SEND_OUTPUT='fixture transport down' run_lane "$dir" enqueue beta >/dev/null
  assert_state "$dir" $'fm-validation-lane-v1\nrelease=alpha\nqueued=beta' "failed head was skipped when beta queued"
  out=$(run_lane "$dir" check)
  assert_contains "$out" "released alpha" "pending release was not retried"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=alpha\nqueued=beta' "retry did not retain FIFO ordering"
  pass "validation lane: failed delivery stays loud and preserves the queue head for retry"
}

test_generated_check_executes_scheduler_without_live_runtime() {
  local dir out
  dir=$(make_case generated-check)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" \
    FM_TEST_CREW_STATE='state: failed · source: run-step · validation failed' \
    "$dir/home/state/validation-lane.check.sh")
  assert_contains "$out" "released beta" "generated watcher check did not release the next task"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=beta' "generated watcher check did not commit beta as holder"
  pass "validation lane: registered watcher check releases a terminal holder through fixture transport"
}

test_watcher_check_releases_and_queues_a_wake() {
  local dir out status drained
  dir=$(make_case watcher)
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$dir/home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$dir/home/state/.pr-check-migration-v1"
  chmod 0600 "$dir/home/state/.pr-check-migration-scan-v1" "$dir/home/state/.pr-check-migration-v1"
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 > "$dir/checkpoint.out" 2> "$dir/checkpoint.err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  out=$(cat "$dir/checkpoint.out")
  assert_contains "$out" "check: $dir/home/state/validation-lane.check.sh: released beta" "watcher did not surface validation release"
  assert_state "$dir" $'fm-validation-lane-v1\nholder=beta' "watcher check did not commit beta as holder"
  drained=$(FM_HOME="$dir/home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tcheck\t' "watcher release wake was not queued"
  assert_contains "$drained" 'released beta' "queued watcher wake lost release diagnostic"
  pass "validation lane: watcher check releases through the authenticated check path"
}

test_enqueue_reserves_and_delivers_first_task
test_queue_is_fifo_and_terminal_check_releases_next
test_status_log_terminal_does_not_free_a_slot
test_empty_lane_retires_its_watcher_artifacts
test_failed_delivery_remains_pending_and_is_retried
test_generated_check_executes_scheduler_without_live_runtime
test_watcher_check_releases_and_queues_a_wake
