#!/usr/bin/env bash
# Behavior tests for typed condition holds on backlog items.
#
# Every case drives the real backlog through tasks-axi and asserts what an
# operator would see: whether `tasks-axi ready` surfaces the work, and what the
# contract announced. Nothing here asserts implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONDITION_HOLD="$ROOT/bin/fm-condition-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-condition-hold)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
## Queued
## Done
EOF
  printf '%s\n' "$home"
}

run_tasks() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_hold() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    ${FM_CONDITION_HOLD_NOW:+FM_CONDITION_HOLD_NOW="$FM_CONDITION_HOLD_NOW"} \
    "$CONDITION_HOLD" "$@"
}

# An evaluator whose answer is a file the test controls, so a false-to-true
# transition is something the test causes rather than waits for.
write_evaluator() {  # <home> <name> <marker-path>
  local home=$1 name=$2 marker=$3
  cat > "$home/$name" <<EOF
#!/usr/bin/env bash
if [ -f "$marker" ]; then
  printf 'result: satisfied\n'
else
  printf 'result: unsatisfied\n'
fi
printf 'observed: %s\n' "\$(date -u +%s)"
printf 'evidence: retention cycle marker\n'
EOF
  chmod +x "$home/$name"
  printf '%s\n' "$home/$name"
}

ready_ids() {  # <home>
  run_tasks "$1" ready | sed -n 's/^  \([A-Za-z0-9._-]*\),.*/\1/p'
}

# --- the defect: a condition-gated hold never surfaced ------------------------

home=$(make_home defect)
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_tasks "$home" hold fm-retire-fallback --reason "release after a retention cycle" --kind future >/dev/null
out=$(ready_ids "$home")
assert_not_contains "$out" fm-retire-fallback \
  "a future hold with no date must never surface on its own (the defect under test)"
pass "condition-gated future hold is invisible to ready without the contract"

# --- unsatisfied: held, bookkeeping only --------------------------------------

home=$(make_home unsatisfied)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
out=$(run_hold "$home" evaluate fm-retire-fallback --force)
code=$?
expect_code 0 "$code" "an unsatisfied condition is not a failure"
[ -z "$out" ] || fail "an unsatisfied condition must announce nothing, got: $out"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "an unsatisfied condition must stay held"
show=$(run_hold "$home" show fm-retire-fallback)
assert_contains "$show" "last_result: unsatisfied" "the unsatisfied result is durable"
assert_contains "$show" "rechecks: 1 of" "an unsatisfied evaluation advances the recheck count"
pass "unsatisfied condition stays held and advances only recheck bookkeeping"

# --- satisfied: resurfaces, exactly once per transition -----------------------

touch "$marker"
out=$(run_hold "$home" evaluate fm-retire-fallback --force)
expect_code 0 "$?" "a satisfied condition releases cleanly"
assert_contains "$out" "released:" "the false-to-true transition is announced once"
assert_contains "$(ready_ids "$home")" fm-retire-fallback \
  "a satisfied condition resurfaces the work in ready"
again=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$again" ] || fail "a still-satisfied condition must not re-announce, got: $again"
third=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$third" ] || fail "repeated evaluation must stay silent, got: $third"
pass "satisfied condition resurfaces the task exactly once per transition"

# --- restart mid-transition: releases exactly once ----------------------------

home=$(make_home restart)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
touch "$marker"
# A process that died after committing the transition but before clearing the
# hold: the sequence is ahead of the released sequence and the task is still held.
record="$home/state/fm-retire-fallback.condition-hold"
sed -e 's/^transition_seq=.*/transition_seq=1/' "$record" > "$record.next"
mv "$record.next" "$record"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "the interrupted transition has not released the hold yet"
out=$(run_hold "$home" evaluate fm-retire-fallback --force)
assert_contains "$out" "released:" "an interrupted transition completes on the next evaluation"
assert_contains "$(ready_ids "$home")" fm-retire-fallback \
  "the recovered transition resurfaces the work"
again=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$again" ] || fail "a recovered transition must not release twice, got: $again"
pass "a transition interrupted by restart releases exactly once"

# --- missing evaluator: loud, inspectable, announced once ---------------------

home=$(make_home missing)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
rm -f "$evaluator"
code=0
out=$(run_hold "$home" evaluate fm-retire-fallback --force 2>/dev/null) || code=$?
expect_code 1 "$code" "a missing evaluator must fail loudly"
assert_contains "$out" "error:" "a missing evaluator is announced"
assert_contains "$out" "evaluator is missing" "the announcement names the missing evaluator"
assert_contains "$(run_hold "$home" show fm-retire-fallback)" "last_result: error" \
  "the failure is durable and inspectable"
repeat=$(run_hold "$home" evaluate fm-retire-fallback --force 2>/dev/null) || true
[ -z "$repeat" ] || fail "the same failure must not re-announce every recheck, got: $repeat"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "a failing evaluator must never release the hold"
pass "missing evaluator fails loudly, once, and never releases the hold"

# --- changed evaluator bytes are a distinct failure ---------------------------

home=$(make_home changed)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
cat > "$evaluator" <<'EOF'
#!/usr/bin/env bash
printf 'result: satisfied\n'
printf 'observed: %s\n' "$(date -u +%s)"
EOF
chmod +x "$evaluator"
code=0
out=$(run_hold "$home" evaluate fm-retire-fallback --force 2>/dev/null) || code=$?
expect_code 1 "$code" "a changed evaluator must fail loudly"
assert_contains "$out" "evaluator changed since registration" \
  "the announcement names the identity mismatch"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "an unverified evaluator must never release the hold"
pass "evaluator identity is bound to its bytes"

# --- stale evidence is refused, not acted on ----------------------------------

home=$(make_home stale)
cat > "$home/stale.sh" <<'EOF'
#!/usr/bin/env bash
printf 'result: satisfied\n'
printf 'observed: 1000000000\n'
printf 'evidence: read from a snapshot taken long ago\n'
EOF
chmod +x "$home/stale.sh"
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$home/stale.sh" --cadence 1h --evidence-max-age 1h >/dev/null
code=0
out=$(run_hold "$home" evaluate fm-retire-fallback --force 2>/dev/null) || code=$?
expect_code 1 "$code" "stale evidence must fail loudly"
assert_contains "$out" "evidence is stale" "the announcement names the staleness"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "stale evidence must never release the hold"
pass "stale evaluator evidence is refused rather than acted on"

# --- malformed evaluator output is refused ------------------------------------

home=$(make_home malformed)
cat > "$home/bad.sh" <<'EOF'
#!/usr/bin/env bash
printf 'the retention cycle probably finished\n'
EOF
chmod +x "$home/bad.sh"
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$home/bad.sh" --cadence 1h >/dev/null
code=0
out=$(run_hold "$home" evaluate fm-retire-fallback --force 2>/dev/null) || code=$?
expect_code 1 "$code" "unparseable evaluator output must fail loudly"
assert_contains "$out" "no result line" "the announcement names the malformed output"
pass "malformed evaluator output is refused"

# --- malformed durable state is refused ---------------------------------------

home=$(make_home badstate)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
record="$home/state/fm-retire-fallback.condition-hold"
sed -e 's/^cadence_secs=.*/cadence_secs=soon/' "$record" > "$record.next"
mv "$record.next" "$record"
code=0
err=$(run_hold "$home" evaluate fm-retire-fallback --force 2>&1 >/dev/null) || code=$?
expect_code 1 "$code" "a malformed record must fail loudly"
assert_contains "$err" "malformed cadence_secs" "the failure names the malformed field"
assert_contains "$(run_hold "$home" list)" "malformed" \
  "listing stays inspectable when one record is malformed"
pass "malformed condition state fails loudly and stays inspectable"

# --- bounded rechecks stop silent parking -------------------------------------

home=$(make_home bounded)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h --max-rechecks 2 >/dev/null
first=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$first" ] || fail "the first unsatisfied recheck stays silent, got: $first"
second=$(run_hold "$home" evaluate fm-retire-fallback --force)
assert_contains "$second" "exhausted:" "an exhausted recheck budget is announced"
third=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$third" ] || fail "exhaustion is announced once, got: $third"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "exhaustion must not release the hold"
pass "an unsatisfiable condition is reported instead of parked in silence"

# --- the recheck stays bounded by cadence -------------------------------------

home=$(make_home cadence)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
run_hold "$home" evaluate fm-retire-fallback --force >/dev/null
touch "$marker"
out=$(run_hold "$home" evaluate fm-retire-fallback)
[ -z "$out" ] || fail "an evaluation before the next recheck must do nothing, got: $out"
assert_not_contains "$(ready_ids "$home")" fm-retire-fallback \
  "a condition is not consulted before its next bounded recheck"
pass "recheck cadence bounds how often the evaluator runs"

# --- captain and date holds are untouched -------------------------------------

home=$(make_home compat)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-captain "captain gated" >/dev/null
run_tasks "$home" hold fm-captain --reason "captain decision pending" --kind captain >/dev/null
run_tasks "$home" add fm-dated "date gated" >/dev/null
run_tasks "$home" hold fm-dated --reason "start after launch" --until 2001-01-01 >/dev/null
run_tasks "$home" add fm-condition "condition gated" >/dev/null
run_hold "$home" hold fm-condition --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
ready=$(ready_ids "$home")
assert_contains "$ready" fm-dated "an elapsed date hold still surfaces exactly as before"
assert_not_contains "$ready" fm-captain "a captain hold still waits for the captain"
assert_not_contains "$ready" fm-condition "an unevaluated condition hold stays held"
run_hold "$home" evaluate fm-condition --force >/dev/null
ready=$(ready_ids "$home")
assert_contains "$ready" fm-dated "evaluating a condition hold does not disturb a date hold"
assert_not_contains "$ready" fm-captain "evaluating a condition hold does not disturb a captain hold"
code=0
err=$(run_hold "$home" hold fm-captain --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h 2>&1 >/dev/null) || code=$?
expect_code 1 "$code" "a captain hold must not be converted into a condition hold"
assert_contains "$err" "already carries a captain hold" "the refusal names the existing hold kind"
pass "captain holds and date holds keep their existing behavior"

# --- external release retires the record --------------------------------------

home=$(make_home external)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
run_tasks "$home" unhold fm-retire-fallback >/dev/null
out=$(run_hold "$home" evaluate fm-retire-fallback --force)
assert_contains "$out" "retired:" "a hold cleared elsewhere retires the condition record"
again=$(run_hold "$home" evaluate fm-retire-fallback --force)
[ -z "$again" ] || fail "a retired record must stay quiet, got: $again"
pass "a hold cleared outside the contract retires its record instead of fighting it"

# --- identity validation guards every removal ---------------------------------

home=$(make_home identity)
for command in release disarm show evaluate arm; do
  code=0
  err=$(run_hold "$home" "$command" "" 2>&1 >/dev/null) || code=$?
  expect_code 1 "$code" "$command must refuse an empty task id"
  assert_contains "$err" "a task id is required" "$command names the empty task id"
  code=0
  err=$(run_hold "$home" "$command" "../escape" 2>&1 >/dev/null) || code=$?
  expect_code 1 "$code" "$command must refuse an unsafe task id"
  assert_contains "$err" "privacy-safe slug" "$command names the unsafe task id"
done
mkdir -p "$home/outside"
printf 'keep me\n' > "$home/outside/file"
code=0
run_hold "$home" release "../outside" >/dev/null 2>&1 || code=$?
expect_code 1 "$code" "a traversing task id never reaches a removal"
assert_present "$home/outside/file" "no removal runs against a path outside this task's state"
pass "every command validates its task id before any path is built or removed"

# --- arming rides the existing registered-check path --------------------------

home=$(make_home armed)
marker="$home/marker"
evaluator=$(write_evaluator "$home" evaluator.sh "$marker")
run_tasks "$home" add fm-retire-fallback "retire the fallback" >/dev/null
run_hold "$home" hold fm-retire-fallback --reason "release after a retention cycle" \
  --evaluator "$evaluator" --cadence 1h >/dev/null
run_hold "$home" arm fm-retire-fallback >/dev/null
assert_present "$home/state/fm-retire-fallback.check.sh" "arming writes the watcher check"
assert_present "$home/state/fm-retire-fallback.check-trust" "arming registers the check"
touch "$marker"
out=$("$home/state/fm-retire-fallback.check.sh")
assert_contains "$out" "released:" "the armed check is what turns a satisfied condition into a wake"
assert_contains "$(ready_ids "$home")" fm-retire-fallback \
  "the armed check resurfaces the work through the ordinary backlog"
assert_absent "$home/state/fm-retire-fallback.check.sh" \
  "a released condition takes its own check back out"
assert_absent "$home/state/fm-retire-fallback.check-trust" \
  "a released condition also removes its check registration"
run_hold "$home" release fm-retire-fallback >/dev/null
assert_absent "$home/state/fm-retire-fallback.check.sh" "release removes the armed check"
assert_absent "$home/state/fm-retire-fallback.condition-hold" "release removes the record"
pass "an armed condition hold resurfaces work through the existing check path"

echo "all fm-condition-hold tests passed"
