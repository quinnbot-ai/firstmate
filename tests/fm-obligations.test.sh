#!/usr/bin/env bash
# Behavior tests for bin/fm-obligations.sh and the fm-brief.sh flags that feed it.
#
# THE FAILURE UNDER TEST. Two workers were each given a brief containing an
# explicit instruction - "your regression test must FAIL on the unfixed base and
# PASS at your head; run both and report the pair" - and both delivered good work
# while silently omitting the report. Nothing noticed, because the only thing
# that remembered what the brief asked was the supervisor. Separately, a brief
# was written that carried only one of the two fix locations its originating
# instruction offered; the worker hit the wall of the one it was given, correctly
# reported blocked, and could not choose the other because it was never told the
# other existed.
#
# Both are the same shape: a stated requirement that exists only in prose nobody
# is forced to re-read. These tests pin the two mechanical answers:
#   - a reporting obligation is a durable record with a gate (record/verify/waive
#     and the teardown refusal in tests/fm-teardown.test.sh), so a silent
#     omission becomes a refusal;
#   - recording an originating instruction forces the narrowing to be named
#     (--source-instruction requires --excluded) and hands the worker the source
#     it can read when the narrowed task dead-ends.
#
# What is deliberately NOT tested, because it is deliberately not built: nothing
# compares the brief's task text against the originating instruction to judge
# whether the narrowing was correct. That comparison is semantic, and a shell
# heuristic for it would be false precision. The scaffold forces the decision to
# be written down; a reader still judges it.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OBLIGATIONS="$ROOT/bin/fm-obligations.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-obligations)

# A fresh firstmate home for one case; echoes its path.
make_home() {
  local name=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

ob() {  # <home> <args...>
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$OBLIGATIONS" "$@"
}

brief() {  # <home> <args...>
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$@"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$OBLIGATIONS" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-obligations.sh must parse cleanly (got: $out)"
  # The repo ships to macOS stock Bash 3.2, whose parser differs from the
  # ambient Bash 5 (tests/fm-brief.test.sh documents the defect class). CI sweeps
  # every shell file there; parse it here too whenever a 3.2 is on this machine.
  if [ -x /bin/bash ] && /bin/bash -c 'case "$BASH_VERSION" in 3.2*) exit 0 ;; esac; exit 1'; then
    out=$(/bin/bash -n "$OBLIGATIONS" 2>&1); rc=$?
    expect_code 0 "$rc" "stock Bash 3.2 must parse bin/fm-obligations.sh (got: $out)"
  fi
  pass "fm-obligations: parses and is Bash 3.2 parse-safe"
}

# The core loop: recorded -> unmet -> reported. This is the exact sequence the
# two workers broke, so it is pinned end to end rather than by unit.
test_recorded_obligation_is_unmet_until_the_note_lands() {
  local home out rc
  home=$(make_home unmet-then-reported)
  ob "$home" record t1 base-vs-head \
    --text "Run the regression on the unfixed base and at your head; report the pair." >/dev/null \
    || fail "record must succeed"
  assert_grep "base-vs-head" "$home/data/t1/obligations.tsv" \
    "record must write a durable obligation record"

  out=$(ob "$home" list t1)
  case "$out" in
    *"unmet"*) : ;;
    *) fail "a recorded obligation must start unmet (got: $out)" ;;
  esac

  out=$(ob "$home" verify t1 2>&1); rc=$?
  expect_code 1 "$rc" "verify must fail while an obligation is unreported"
  case "$out" in
    *"base-vs-head"*) : ;;
    *) fail "verify must name the unmet obligation (got: $out)" ;;
  esac

  # The deliverable landing does NOT satisfy the obligation - that is the whole
  # failure: good work plus a silent omission used to look like success.
  printf '%s\n' "done: PR https://example.invalid/pull/1" >> "$home/state/t1.status"
  ob "$home" verify t1 >/dev/null 2>&1
  expect_code 1 "$?" "a terminal done: line must not satisfy a reporting obligation"

  printf '%s\n' "note [key=base-vs-head]: base FAILS (1 failure), head PASSES (0)" \
    >> "$home/state/t1.status"
  ob "$home" verify t1 >/dev/null 2>&1
  expect_code 0 "$?" "verify must pass once the keyed note line lands"
  pass "fm-obligations: an obligation stays unmet until its keyed note line lands"
}

# The gate is only worth having if it means one checkable thing, so a note under
# a different key, or the right key under a non-note verb, must not satisfy it.
test_satisfaction_requires_the_exact_verb_and_key() {
  local home
  home=$(make_home exact-shape)
  ob "$home" record t1 base-vs-head --text "report the pair" >/dev/null
  printf '%s\n' \
    "note [key=something-else]: unrelated" \
    "working [key=base-vs-head]: started the controls" \
    "blocked [key=base-vs-head]: cannot run the base" \
    >> "$home/state/t1.status"
  ob "$home" verify t1 >/dev/null 2>&1
  expect_code 1 "$?" "only a note: line under the obligation's own key may satisfy it"
  pass "fm-obligations: satisfaction requires the exact note verb and key"
}

# A waiver is the supervisor saying "I produced this evidence myself" - durable
# and attributable, not a quiet delete.
test_waive_is_explicit_reasoned_and_scoped() {
  local home out rc
  home=$(make_home waive)
  ob "$home" record t1 base-vs-head --text "report the pair" >/dev/null

  out=$(ob "$home" waive t1 base-vs-head 2>&1); rc=$?
  expect_code 1 "$rc" "waive must require a reason"

  out=$(ob "$home" waive t1 no-such-key --reason "x" 2>&1); rc=$?
  expect_code 1 "$rc" "waive must refuse a key that was never recorded"

  ob "$home" waive t1 base-vs-head --reason "firstmate ran both controls itself" >/dev/null \
    || fail "waive must succeed for a recorded key with a reason"
  assert_grep "firstmate ran both controls itself" "$home/data/t1/obligations.waived" \
    "a waiver must record its reason durably"
  ob "$home" verify t1 >/dev/null 2>&1
  expect_code 0 "$?" "a waived obligation must satisfy verify"

  ob "$home" waive t1 base-vs-head --reason "firstmate ran both controls itself" >/dev/null \
    || fail "waiving twice must be idempotent"
  expect_code 1 "$(wc -l < "$home/data/t1/obligations.waived" | tr -d ' ')" \
    "an idempotent waive must not append a second record"
  pass "fm-obligations: waiving is explicit, reasoned, key-scoped, and idempotent"
}

# Silently rewriting a stated requirement is the class of change this whole
# mechanism exists to prevent, so record refuses it in its own record file too.
test_record_refuses_a_silently_changed_requirement() {
  local home out rc
  home=$(make_home rewrite)
  ob "$home" record t1 k --text "original requirement" >/dev/null
  ob "$home" record t1 k --text "original requirement" >/dev/null \
    || fail "re-recording identical text must be idempotent"
  expect_code 1 "$(wc -l < "$home/data/t1/obligations.tsv" | tr -d ' ')" \
    "an idempotent record must not append a duplicate"
  out=$(ob "$home" record t1 k --text "quietly narrowed requirement" 2>&1); rc=$?
  expect_code 1 "$rc" "record must refuse a changed requirement under an existing key"
  case "$out" in
    *"already recorded"*) : ;;
    *) fail "the refusal must say the key is already recorded (got: $out)" ;;
  esac
  pass "fm-obligations: a recorded requirement is never silently rewritten"
}

test_malformed_input_is_refused() {
  local home
  home=$(make_home malformed)
  ob "$home" record t1 "bad key" --text "x" >/dev/null 2>&1
  expect_code 1 "$?" "a non-slug obligation key must be refused"
  ob "$home" record "../escape" k --text "x" >/dev/null 2>&1
  expect_code 1 "$?" "a task id that is not a slug must be refused"
  ob "$home" record t1 k --text "" >/dev/null 2>&1
  expect_code 1 "$?" "empty obligation text must be refused"
  ob "$home" bogus t1 >/dev/null 2>&1
  expect_code 1 "$?" "an unknown command must be refused"
  pass "fm-obligations: malformed keys, ids, text, and commands are refused"
}

# --- fm-brief.sh integration -------------------------------------------------

test_brief_report_flag_records_and_renders() {
  local home b
  home=$(make_home brief-report)
  brief "$home" t1 myrepo --mode direct-PR \
    --report "base-vs-head=Run the regression on the unfixed base and at your head; report the pair." \
    --report "lint=Report the exact lint command you ran." >/dev/null \
    || fail "--report must scaffold"
  b="$home/data/t1/brief.md"
  assert_grep "# Reporting obligations" "$b" "the brief must carry a reporting-obligations section"
  assert_grep "note [key=base-vs-head]:" "$b" \
    "the brief must hand the worker the exact satisfying command"
  assert_grep "note [key=lint]:" "$b" "every obligation must render its own command"
  assert_grep "cleanup of this task is refused" "$b" \
    "the brief must say the obligation is gated, not merely requested"
  assert_grep "base-vs-head" "$home/data/t1/obligations.tsv" \
    "--report must write the durable record the gate reads"
  assert_grep "lint" "$home/data/t1/obligations.tsv" \
    "every --report must reach the durable record"
  ob "$home" verify t1 >/dev/null 2>&1
  expect_code 1 "$?" "a freshly scaffolded obligation must start unmet"
  pass "fm-brief: --report records the obligation and renders its exact command"
}

test_brief_report_flag_validates() {
  local home
  home=$(make_home brief-report-bad)
  brief "$home" t1 myrepo --mode direct-PR --report "no-equals-sign" >/dev/null 2>&1
  expect_code 1 "$?" "--report without <key>=<text> must be refused"
  assert_absent "$home/data/t1/brief.md" "a refused --report must not leave a brief"
  brief "$home" t2 myrepo --mode direct-PR --report "bad key=text" >/dev/null 2>&1
  expect_code 1 "$?" "--report with a non-slug key must be refused"
  brief "$home" t3 myrepo --mode direct-PR --report "k=a" --report "k=b" >/dev/null 2>&1
  expect_code 1 "$?" "duplicate --report keys must be refused"
  brief "$home" t4 --secondmate proj --report "k=a" >/dev/null 2>&1
  expect_code 1 "$?" "--report must be refused on a secondmate charter"
  pass "fm-brief: --report validates its key, uniqueness, and applicable brief kinds"
}

test_brief_report_applies_to_scouts() {
  local home b
  home=$(make_home brief-report-scout)
  brief "$home" t1 myrepo --scout --report "repro=State whether you reproduced it and how." >/dev/null \
    || fail "--report must apply to scout briefs"
  b="$home/data/t1/brief.md"
  assert_grep "# Reporting obligations" "$b" "a scout brief must carry its obligations"
  assert_grep "# Definition of done" "$b" "the scout definition of done must survive the insertion"
  pass "fm-brief: --report applies to scouts as well as ships"
}

# The dropped-alternative half. Recording the source is the act of admitting the
# brief narrows it, so the narrowing must be named rather than left silent.
test_source_instruction_forces_the_narrowing_to_be_named() {
  local home b src out rc
  home=$(make_home source-instruction)
  src="$home/instruction.txt"
  printf '%s\n' "Fix the flake in the ci step OR in a firstmate-owned wrapper around it." > "$src"

  out=$(brief "$home" t1 myrepo --mode direct-PR --source-instruction "$src" 2>&1); rc=$?
  expect_code 1 "$rc" "--source-instruction without --excluded must be refused"
  case "$out" in
    *"--excluded"*) : ;;
    *) fail "the refusal must name the missing flag (got: $out)" ;;
  esac
  assert_absent "$home/data/t1/brief.md" "a refused scaffold must not leave a brief"
  assert_absent "$home/data/t1/source-instruction.md" \
    "a refused scaffold must not leave a source record"

  brief "$home" t1 myrepo --mode direct-PR --source-instruction "$src" \
    --excluded "the firstmate-owned wrapper around the ci step" >/dev/null \
    || fail "--source-instruction with --excluded must scaffold"
  b="$home/data/t1/brief.md"
  assert_grep "# Originating instruction" "$b" "the brief must point at the recorded instruction"
  assert_grep "$home/data/t1/source-instruction.md" "$b" \
    "the brief must carry the source record's path"
  assert_grep "the firstmate-owned wrapper around the ci step" "$b" \
    "the brief must name what it deliberately dropped"
  assert_grep "READ that file before you report blocked" "$b" \
    "the brief must tell a walled-in worker to read the originating instruction"
  assert_grep "Fix the flake in the ci step OR in a firstmate-owned wrapper" \
    "$home/data/t1/source-instruction.md" \
    "the originating instruction must be recorded verbatim"
  pass "fm-brief: recording an originating instruction forces the narrowing to be named"
}

test_excluded_none_is_a_whole_instruction_attestation() {
  local home b
  home=$(make_home excluded-none)
  printf '%s\n' "Do the whole thing." > "$home/src.txt"
  brief "$home" t1 myrepo --mode direct-PR --source-instruction "$home/src.txt" \
    --excluded none >/dev/null || fail "--excluded none must scaffold"
  b="$home/data/t1/brief.md"
  assert_grep "carries that instruction whole and drops nothing" "$b" \
    "--excluded none must render as an explicit whole-instruction attestation"

  brief "$home" t2 myrepo --mode direct-PR --source-instruction "$home/src.txt" \
    --excluded none --excluded "the wrapper" >/dev/null 2>&1
  expect_code 1 "$?" "--excluded none must not be combinable with real exclusions"
  pass "fm-brief: --excluded none is an attestation, not one item in a list"
}

test_source_instruction_validates_its_input() {
  local home
  home=$(make_home source-bad)
  brief "$home" t1 myrepo --mode direct-PR \
    --source-instruction "$home/missing.txt" --excluded none >/dev/null 2>&1
  expect_code 1 "$?" "an unreadable --source-instruction must be refused"
  assert_absent "$home/data/t1/brief.md" "an unreadable source must not leave a brief"
  : > "$home/empty.txt"
  brief "$home" t2 myrepo --mode direct-PR \
    --source-instruction "$home/empty.txt" --excluded none >/dev/null 2>&1
  expect_code 1 "$?" "an empty --source-instruction must be refused"
  brief "$home" t3 --secondmate proj --source-instruction "$home/src" --excluded none >/dev/null 2>&1
  expect_code 1 "$?" "--source-instruction must be refused on a secondmate charter"
  pass "fm-brief: --source-instruction refuses unreadable, empty, and inapplicable input"
}

# The scaffolds are a shared safety contract, so adding these sections must not
# perturb a brief that does not use them.
test_unused_flags_leave_the_scaffolds_untouched() {
  local home b
  home=$(make_home untouched)
  brief "$home" t1 myrepo --mode direct-PR >/dev/null
  b="$home/data/t1/brief.md"
  assert_no_grep "# Reporting obligations" "$b" \
    "a brief with no --report must carry no obligations section"
  assert_no_grep "# Originating instruction" "$b" \
    "a brief with no --source-instruction must carry no source section"
  assert_absent "$home/data/t1/obligations.tsv" "no --report must leave no record"
  # The blank line that separated Task from the Herdr declaration, and Project
  # memory from the definition of done, must still be exactly one blank line.
  grep -A1 '^{TASK}$' "$b" | tail -1 | grep -q '^$' \
    || fail "an unused source section must leave exactly the original blank line after {TASK}"
  pass "fm-brief: unused flags leave the generated brief structurally unchanged"
}

test_script_parses
test_recorded_obligation_is_unmet_until_the_note_lands
test_satisfaction_requires_the_exact_verb_and_key
test_waive_is_explicit_reasoned_and_scoped
test_record_refuses_a_silently_changed_requirement
test_malformed_input_is_refused
test_brief_report_flag_records_and_renders
test_brief_report_flag_validates
test_brief_report_applies_to_scouts
test_source_instruction_forces_the_narrowing_to_be_named
test_excluded_none_is_a_whole_instruction_attestation
test_source_instruction_validates_its_input
test_unused_flags_leave_the_scaffolds_untouched
