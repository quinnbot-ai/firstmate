#!/usr/bin/env bash
# tests/fm-session-lock-holder-state.test.sh - session-lock holder classification
# (bin/fm-session-lock-lib.sh, bin/fm-lock.sh).
#
# The regression these cases pin: a name-pattern probe can only ever produce
# evidence FOR a match, so its no-match result is ambiguous - the pid may be
# dead, or it may be a live session the pattern table cannot name. The acquire
# path used to collapse that ambiguity into "dead" and hand the home to a second
# writer while the first was still running.
#
# Every case here uses a REAL live process, so `kill -0` genuinely succeeds and
# the only thing under test is how an unrecognized NAME is treated. The fake ps
# rewrites the name fields ONLY and delegates every other field - notably etime -
# to the real ps, so the start-time evidence stays truthful.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-holder-state)
LIB="$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$LIB"

CHILDREN=()
cleanup_children() {
  local pid
  for pid in ${CHILDREN+"${CHILDREN[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup_children EXIT

# Start a real long-lived process and publish its pid in LIVE_PID.
#
# This sets a global rather than echoing, because a command substitution would
# run it in a SUBSHELL: the parent's cleanup list would never see the pid and
# every fixture process would leak past the run. The redirections keep the child
# off the caller's stdout for the same structural reason.
LIVE_PID=
start_live_process() {
  sleep 600 >/dev/null 2>&1 </dev/null &
  LIVE_PID=$!
  CHILDREN+=("$LIVE_PID")
}

# Build a fake ps that reports <pid> under an unrecognized wrapper name and every
# other pid as an ordinary claude session. Only comm/args/ppid are faked.
make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) field=$2; shift 2 ;; -p) pid=$2; shift 2 ;; *) shift ;; esac
done
case "$field" in
  comm=|args=|ppid=) ;;
  *) exec /bin/ps -p "$pid" -o "$field" ;;
esac
if [ "$pid" = "${FM_TEST_WRAPPED_PID:-}" ]; then
  # A live session launched through a generated wrapper script: no harness name
  # appears in comm or in argv[0].
  case "$field" in
    comm=) printf '%s\n' 'run-session' ;;
    args=) printf '%s\n' '/var/folders/xy/T/session-launch-4821.sh --home /h' ;;
    ppid=) printf '%s\n' 1 ;;
  esac
else
  case "$field" in
    comm=) printf '%s\n' '/opt/claude/bin/claude' ;;
    args=) printf '%s\n' '/opt/claude/bin/claude' ;;
    ppid=) printf '%s\n' 1 ;;
  esac
fi
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

holder_state() {  # <fakebin> <lock-path> [wrapped-pid]
  local fakebin=$1 lock=$2 wrapped=${3:-}
  PATH="$fakebin:$PATH" FM_TEST_WRAPPED_PID="$wrapped" \
    bash -c '. "$0"; fm_session_lock_holder_state "$1"' "$LIB" "$lock"
}

run_lock() {  # <fakebin> <home> [wrapped-pid]
  local fakebin=$1 home=$2 wrapped=${3:-}
  PATH="$fakebin:$PATH" FM_TEST_WRAPPED_PID="$wrapped" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1
}

# --- the regression ----------------------------------------------------------

test_live_but_unrecognized_holder_keeps_its_lock() {
  local dir fakebin pid state out
  dir="$TMP_ROOT/wrapped-live"
  mkdir -p "$dir/state"
  fakebin=$(make_fakebin "$dir")
  start_live_process; pid=$LIVE_PID
  printf '%s\n' "$pid" > "$dir/state/.lock"

  state=$(holder_state "$fakebin" "$dir/state/.lock" "$pid")
  [ "$state" = unidentified ] \
    || fail "a running holder with an unrecognized name classified '$state', expected unidentified"

  out=$(run_lock "$fakebin" "$dir" "$pid") && \
    fail "fm-lock.sh acquired a lock still held by the live process $pid: $out"
  case "$out" in
    *"RUNNING but is not identifiable"*) ;;
    *) fail "the refusal did not name the ambiguity it was refusing on: $out" ;;
  esac
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$pid" ] \
    || fail "the live holder's lock was overwritten despite the refusal"
  kill -0 "$pid" 2>/dev/null \
    || fail "the fixture process died mid-test, so this case proved nothing"
  pass "session-lock: a running holder whose name matches no pattern keeps its lock"
}

# --- the two outcomes the fix must NOT break ---------------------------------

test_dead_holder_is_still_reclaimable() {
  local dir fakebin pid state out
  dir="$TMP_ROOT/dead-holder"
  mkdir -p "$dir/state"
  fakebin=$(make_fakebin "$dir")
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$dir/state/.lock"

  state=$(holder_state "$fakebin" "$dir/state/.lock")
  [ "$state" = stale ] || fail "a dead holder classified '$state', expected stale"

  out=$(run_lock "$fakebin" "$dir") \
    || fail "fm-lock.sh refused to reclaim a genuinely dead holder: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" != "$pid" ] \
    || fail "the dead holder's pid was left in the lock"
  pass "session-lock: a genuinely dead holder is still reclaimed"
}

test_recycled_pid_does_not_wedge_the_home() {
  local dir fakebin pid state out
  dir="$TMP_ROOT/recycled-pid"
  mkdir -p "$dir/state"
  fakebin=$(make_fakebin "$dir")
  start_live_process; pid=$LIVE_PID
  printf '%s\n' "$pid" > "$dir/state/.lock"
  # Backdate the lock well past this process's start: the number was reissued, so
  # whatever wrote the lock is gone even though the pid is live and unrecognized.
  touch -t 202001010101 "$dir/state/.lock"

  state=$(holder_state "$fakebin" "$dir/state/.lock" "$pid")
  [ "$state" = stale ] \
    || fail "a recycled pid classified '$state', expected stale - the home would wedge"

  out=$(run_lock "$fakebin" "$dir" "$pid") \
    || fail "fm-lock.sh could not reclaim a recycled pid, wedging the home: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" != "$pid" ] \
    || fail "the recycled pid was left in the lock"
  pass "session-lock: a recycled pid is reclaimed, so an unrecognized name cannot wedge the home"
}

# The self-inner path is exercised end to end, in a real process tree, by
# tests/fm-cursor-primary.test.sh's park cases: there a session writes the lock
# under an inner shell pid and must still be able to correct it. What is unit-
# tested here is the two predicates that decision rests on, because a fake ps
# that rewrote ppid would break the very ancestry walk under test.
test_own_ancestry_is_recognized_without_a_name_match() {
  local parent
  fm_pid_is_own_ancestor "$$" \
    || fail "this shell's own pid was not recognized as its own ancestor"
  parent=$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$parent" ] && [ "$parent" -gt 1 ]; then
    fm_pid_is_own_ancestor "$parent" \
      || fail "the real parent pid $parent was not recognized as an ancestor"
  fi
  fm_pid_is_own_ancestor 1 && fail "init was reported as an ancestor; the walk does not terminate"
  fm_pid_is_own_ancestor '' && fail "an empty pid was accepted as an ancestor"
  fm_pid_is_own_ancestor notanumber && fail "a non-numeric pid was accepted as an ancestor"
  pass "session-lock: plain lineage is recognized without any name match"
}

test_only_accountable_states_permit_a_claim() {
  local state
  for state in stale self-inner; do
    fm_session_lock_state_permits_claim "$state" \
      || fail "'$state' must permit a claim"
  done
  for state in live unidentified malformed free; do
    fm_session_lock_state_permits_claim "$state" \
      && fail "'$state' must NOT permit a claim"
  done
  pass "session-lock: only accounted-for holders permit a claim"
}

test_status_reports_unidentified_distinctly_from_stale() {
  local dir fakebin pid out
  dir="$TMP_ROOT/status-wording"
  mkdir -p "$dir/state"
  fakebin=$(make_fakebin "$dir")
  start_live_process; pid=$LIVE_PID
  printf '%s\n' "$pid" > "$dir/state/.lock"

  out=$(PATH="$fakebin:$PATH" FM_TEST_WRAPPED_PID="$pid" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  # Match the CLASSIFICATION, not the word: the correct message explains that the
  # holder is "not stale", so a bare substring test would trip on its own fix.
  case "$out" in
    "lock: stale"*) fail "status classified a running unidentified holder as stale: $out" ;;
  esac
  case "$out" in
    *"not identifiable"*) ;;
    *) fail "status did not distinguish an unidentified holder: $out" ;;
  esac
  pass "session-lock: status reports an unidentified holder distinctly from a stale one"
}

test_elapsed_seconds_parses_every_ps_etime_shape() {
  local got expected shape
  while IFS='|' read -r shape expected; do
    [ -n "$shape" ] || continue
    got=$(PATH="$TMP_ROOT/etime-bin:$PATH" \
      bash -c '. "$0"; FM_TEST_ETIME="$1" fm_process_elapsed_seconds 4242' "$LIB" "$shape")
    [ "$got" = "$expected" ] \
      || fail "ps etime '$shape' parsed to '$got', expected $expected"
  done <<'CASES'
00:09|9
01:30|90
02:03:04|7384
1-00:00:00|86400
3-04:05:06|273906
08:08|488
CASES
  pass "session-lock: every ps etime shape parses, including day spans and leading zeros"
}

mkdir -p "$TMP_ROOT/etime-bin"
cat > "$TMP_ROOT/etime-bin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_ETIME:-}"
SH
chmod +x "$TMP_ROOT/etime-bin/ps"

test_live_but_unrecognized_holder_keeps_its_lock
test_dead_holder_is_still_reclaimable
test_recycled_pid_does_not_wedge_the_home
test_own_ancestry_is_recognized_without_a_name_match
test_only_accountable_states_permit_a_claim
test_status_reports_unidentified_distinctly_from_stale
test_elapsed_seconds_parses_every_ps_etime_shape
