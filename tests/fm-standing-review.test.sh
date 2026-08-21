#!/usr/bin/env bash
# Behavior tests for bin/fm-standing-review.sh - the evidence gate.
#
# THE FAILURE UNDER TEST. A standing review is a registered watcher check, and
# the watcher wakes firstmate for ANY non-empty output, every sweep, forever.
# So a review that reviews correctly can still be a net loss: waking on "this
# venture looks quiet" spends a supervisor turn on an adjective, and waking
# again every five minutes for as long as a true condition stays true buries
# the queue it was meant to serve. Reviewing well is the easy half; staying
# quiet is the half that decides whether the thing is worth having.
#
# These tests pin the gate rather than the review. Each names the condition it
# exercises (G1..G8 in the script header) so a failure says which property of
# quiet was lost:
#   - G4, G6, and G7 are the three that keep it quiet, and G7 is the one that
#     is easy to omit: without it the review still wakes correctly and also
#     wakes forever, because any drifting evidence value (days_idle, cost) mints
#     a fresh identity that G6 has never seen.
#   - G2 is the opposite guard: a review whose inputs stopped refreshing must
#     get louder, not quieter, or it goes silently blind and reads as "nothing
#     to report".
#
# What is deliberately NOT tested, because it is deliberately not built: nothing
# judges whether a rule is worth having or how rules rank against each other.
# That is a program decision belonging to whoever owns the reviewed surface. The
# gate decides admissibility only, so the tests assert admissibility only.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-standing-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-standing-review)

# A home with a state dir, a spec dir, and a subject root holding <subjects>.
make_home() {  # <case-name> [subject...]
  local home="$TMP_ROOT/$1"; shift
  mkdir -p "$home/state" "$home/config/standing-reviews" "$home/subjects"
  local subject
  for subject in "$@"; do mkdir -p "$home/subjects/$subject"; done
  printf '%s\n' "$home"
}

scan() {  # <home> <args...>
  local home=$1; shift
  "$SCAN" --home "$home" "$@"
}

# Write source records as {"rows": [...]}.
write_source() {  # <home> <json-array>
  printf '{"rows": %s}\n' "$2" > "$1/source.json"
}

# A one-rule spec over $home/source.json. Extra rules can be appended by
# passing a leading comma-prefixed JSON fragment as <extra-rules>.
write_spec() {  # <home> <id> <when> <evidence> [rank] [extra-rules] [knobs]
  local home=$1 id=$2 when=$3 evidence=$4 rank=${5:-0} extra=${6:-} knobs=${7:-}
  cat > "$home/config/standing-reviews/$id.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  $knobs
  "sources": [
    { "name": "src", "path": "$home/source.json", "records": "rows" }
  ],
  "rules": [
    { "name": "candidate", "source": "src", "subject_field": "venture",
      "when": $when, "evidence_fields": $evidence,
      "action": "dispatch a worker to decide this", "rank": $rank }$extra
  ]
}
JSON
}

# Expire the cadence gate so the next run does its work.
expire_cadence() {  # <home> <id>
  touch -t 200001010000 "$1/state/$2.standing-review-last"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$SCAN" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-standing-review.sh does not parse: $out"
  pass "fm-standing-review: script parses"
}

test_quantified_finding_is_emitted_with_its_evidence() {
  local home out
  home=$(make_home admit acme)
  write_source "$home" '[{"venture":"acme","cost_30d":62.5,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  out=$(scan "$home" --id r)
  [ -n "$out" ] || fail "an admissible finding produced no wake line"
  case "$out" in
    *"acme"*) ;;
    *) fail "the wake line does not name its subject: $out" ;;
  esac
  # The line must CARRY the evidence, not merely have been derived from it: a
  # supervisor acts on the line, not on the source file.
  case "$out" in
    *"cost_30d=62.5"*) ;;
    *) fail "the wake line does not carry its measured evidence: $out" ;;
  esac
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] \
    || fail "the wake line spans more than one line: $out"
  pass "G3/G4: an admissible finding wakes once and carries its measurement"
}

test_classification_without_measurement_is_rejected() {
  local home out err
  home=$(make_home quiet-adjective acme)
  # The exact noise case: a true statement about a venture with nothing
  # measured in it. "flag" is a classification someone already made.
  write_source "$home" '[{"venture":"acme","flag":"PARK?"}]'
  write_spec "$home" r '[{"field":"flag","op":"eq","value":"PARK?"}]' '["flag"]'

  err=$("$SCAN" --home "$home" --id r --explain 2>&1 >"$home/out")
  out=$(cat "$home/out")
  [ -z "$out" ] || fail "a classification-only finding woke firstmate: $out"
  case "$err" in
    *"G4 quantified"*) ;;
    *) fail "G4 did not name itself as the rejection: $err" ;;
  esac
  pass "G4: a finding whose whole content is a classification is rejected"
}

test_subject_with_no_work_location_is_rejected() {
  local home out err
  home=$(make_home undispatchable)   # no subject directory created
  write_source "$home" '[{"venture":"ghost","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  err=$("$SCAN" --home "$home" --id r --explain 2>&1 >"$home/out")
  out=$(cat "$home/out")
  [ -z "$out" ] || fail "a finding with no work location woke firstmate: $out"
  case "$err" in
    *"G5 dispatchable"*) ;;
    *) fail "G5 did not name itself as the rejection: $err" ;;
  esac
  pass "G5: a finding naming nothing a worker can be sent to is rejected"
}

test_cadence_silences_the_sweep_between_reviews() {
  local home first second
  home=$(make_home cadence acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  first=$(scan "$home" --id r)
  [ -n "$first" ] || fail "the first review produced nothing"

  # A genuinely new subject appears. It is admissible on every count, so only
  # the cadence gate can keep it waiting - which is what makes this a test of
  # G1 rather than of the latch that would have suppressed a repeat.
  mkdir -p "$home/subjects/beta"
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0},
                         {"venture":"beta","cost_30d":20,"commits_30d":0}]'
  second=$(scan "$home" --id r)
  [ -z "$second" ] || fail "the review ran again inside its interval: $second"
  pass "G1: the watcher's sweep cadence is not the review's cadence"
}

test_the_same_finding_does_not_wake_twice() {
  local home first second err
  home=$(make_home novelty acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  # Let the cadence and the per-subject cooldown lapse, so the finding latch is
  # the only thing left that can hold this back.
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]' 0 '' \
    '"interval_seconds": 1, "subject_cooldown_seconds": 1,'

  first=$(scan "$home" --id r)
  [ -n "$first" ] || fail "the first review produced nothing"
  sleep 2
  err=$("$SCAN" --home "$home" --id r --explain 2>&1 >"$home/out")
  second=$(cat "$home/out")
  [ -z "$second" ] || fail "a standing condition woke firstmate twice: $second"
  case "$err" in
    *"G6 novelty"*) ;;
    *) fail "G6 did not name itself as the rejection: $err" ;;
  esac
  pass "G6: a condition that is still true does not wake again"
}

test_drifting_evidence_does_not_defeat_the_latch() {
  local home first second err
  home=$(make_home cooldown acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  first=$(scan "$home" --id r)
  [ -n "$first" ] || fail "the first review produced nothing"

  # Real evidence drifts: spend accumulates, idle days increment. The finding
  # is now a different identity, so G6 has never seen it - and without G7 the
  # review would wake for the same venture again, and again tomorrow.
  write_source "$home" '[{"venture":"acme","cost_30d":11,"commits_30d":0}]'
  expire_cadence "$home" r
  err=$("$SCAN" --home "$home" --id r --explain 2>&1 >"$home/out")
  second=$(cat "$home/out")
  [ -z "$second" ] || fail "drifting evidence re-woke firstmate for one subject: $second"
  case "$err" in
    *"G7 cooldown"*) ;;
    *) fail "G7 did not name itself as the rejection: $err" ;;
  esac
  pass "G7: a drifting measurement cannot re-wake the same subject"
}

test_the_latch_expires_so_a_recurrence_can_wake_again() {
  local home first second knobs
  home=$(make_home retention acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  knobs='"interval_seconds": 1, "subject_cooldown_seconds": 1, "latch_retention_seconds": 1,'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]' 0 '' "$knobs"

  first=$(scan "$home" --id r)
  [ -n "$first" ] || fail "the first review produced nothing"
  sleep 2
  second=$(scan "$home" --id r)
  [ -n "$second" ] || fail "the latch never expires, so a recurrence stays invisible"
  pass "G6/G7: suppression is time-bounded, so a recurrence is reportable"
}

test_a_stale_source_becomes_the_finding() {
  local home out
  home=$(make_home stale acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'
  # Whatever refreshes the evidence stopped. The review must get LOUDER here:
  # staying quiet would be indistinguishable from "nothing to report".
  touch -t 200001010000 "$home/source.json"

  out=$(scan "$home" --id r)
  case "$out" in
    *source-stale*) ;;
    *) fail "a review reading rotten evidence did not report it: [$out]" ;;
  esac
  case "$out" in
    *age_seconds=*) ;;
    *) fail "the staleness finding carries no measurement: $out" ;;
  esac
  pass "G2: evidence that stopped refreshing is reported, not reasoned from"
}

test_a_stale_source_suppresses_its_own_rules() {
  local home out
  home=$(make_home stale-precedence acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]' 500
  touch -t 200001010000 "$home/source.json"

  out=$(scan "$home" --id r)
  case "$out" in
    *candidate*) fail "a rule finding was reported from a stale source: $out" ;;
  esac
  case "$out" in
    *source-stale*) ;;
    *) fail "the stale source was not reported: $out" ;;
  esac
  pass "G2: a review reports its own blindness before what it saw while blind"
}

test_only_one_finding_is_emitted_per_review() {
  local home out lines
  home=$(make_home one-line acme beta gamma)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0},
                         {"venture":"beta","cost_30d":20,"commits_30d":0},
                         {"venture":"gamma","cost_30d":30,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  out=$(scan "$home" --id r)
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "three findings produced $lines wake lines: $out"
  pass "G8: several qualifying findings still wake firstmate once"
}

test_rank_decides_which_finding_is_reported() {
  local home out extra
  home=$(make_home ranking acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  extra=',
    { "name": "urgent", "source": "src", "subject_field": "venture",
      "when": [{"field":"commits_30d","op":"eq","value":0}],
      "evidence_fields": ["cost_30d"],
      "action": "the higher ranked one", "rank": 90 }'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]' 10 "$extra"

  out=$(scan "$home" --id r)
  case "$out" in
    *urgent*) ;;
    *) fail "ranking did not decide the reported finding: $out" ;;
  esac
  pass "G8: the spec's own ranking decides which single finding is reported"
}

test_an_unusable_spec_is_reported_rather_than_ignored() {
  local home out
  home=$(make_home broken-spec)
  printf '{"version":"fm-standing-review-v1","subject_root":"%s/subjects",\n' "$home" \
    > "$home/config/standing-reviews/r.json"
  printf '"sources":[{"name":"src","path":"%s/source.json","typo":1}],"rules":[]}\n' "$home" \
    >> "$home/config/standing-reviews/r.json"

  out=$(scan "$home" --id r)
  case "$out" in
    *spec-invalid*) ;;
    *) fail "an unusable spec left the review silently dead: [$out]" ;;
  esac
  case "$out" in
    *"unknown keys"*) ;;
    *) fail "the spec finding does not say what is wrong: $out" ;;
  esac
  pass "a review that cannot run says so instead of going quiet"
}

test_a_missing_spec_is_reported() {
  local home out
  home=$(make_home missing-spec)
  out=$(scan "$home" --id r)
  case "$out" in
    *spec-invalid*|*"is missing"*) ;;
    *) fail "an armed review with no spec stayed silent: [$out]" ;;
  esac
  pass "an armed review whose spec disappeared reports itself"
}

test_hostile_field_content_cannot_break_the_wake_line() {
  local home out lines
  home=$(make_home injection)
  mkdir -p "$home/subjects/acme"
  # A source is data from elsewhere. The watcher interpolates this output into
  # a wake reason, so a newline in a field must not become a second wake.
  printf '{"rows":[{"venture":"acme","note":"first\\nsecond\\ttab","cost_30d":5}]}\n' \
    > "$home/source.json"
  write_spec "$home" r '[{"field":"cost_30d","op":"ge","value":1}]' \
    '["note","cost_30d"]'

  out=$(scan "$home" --id r)
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "hostile field content produced $lines lines: $out"
  case "$out" in
    *"first second tab"*) ;;
    *) fail "control characters were not flattened: $out" ;;
  esac
  pass "G3: control characters in source data cannot forge a second wake"
}

test_a_dry_run_leaves_no_trace() {
  local home first second
  home=$(make_home dry-run acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'

  first=$("$SCAN" --home "$home" --id r --dry-run)
  [ -n "$first" ] || fail "a preview reported nothing"
  assert_absent "$home/state/r.standing-review-latch" \
    "a preview wrote a durable record"
  # A preview must not consume the finding it previewed.
  second=$(scan "$home" --id r)
  [ -n "$second" ] || fail "a preview consumed the real finding"
  pass "a preview neither records nor consumes what it reports"
}

test_a_review_never_writes_outside_state() {
  local home before after
  home=$(make_home no-writes acme)
  write_source "$home" '[{"venture":"acme","cost_30d":10,"commits_30d":0}]'
  write_spec "$home" r '[{"field":"commits_30d","op":"eq","value":0}]' \
    '["cost_30d","commits_30d"]'
  before=$(find "$home/subjects" "$home/config" -newer "$home/source.json" | wc -l)
  scan "$home" --id r >/dev/null
  after=$(find "$home/subjects" "$home/config" -newer "$home/source.json" | wc -l)
  [ "$before" = "$after" ] || fail "the review modified a reviewed subject or its spec"
  pass "a review reads its subjects and writes only its own records"
}

test_blindness_is_reported_before_a_finding_from_elsewhere() {
  local home out
  home=$(make_home precedence acme)
  printf '{"rows":[{"venture":"acme","cost_30d":10,"commits_30d":0}]}\n' > "$home/fresh.json"
  printf '{"rows":[]}\n' > "$home/gone.json"
  touch -t 200001010000 "$home/gone.json"
  cat > "$home/config/standing-reviews/r.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  "sources": [
    { "name": "fresh", "path": "$home/fresh.json", "records": "rows" },
    { "name": "gone", "path": "$home/gone.json", "records": "rows" }
  ],
  "rules": [
    { "name": "candidate", "source": "fresh", "subject_field": "venture",
      "when": [{"field":"commits_30d","op":"eq","value":0}],
      "evidence_fields": ["cost_30d"],
      "action": "dispatch a worker", "rank": 900 }
  ]
}
JSON
  # One source went rotten while another still produces a real, high-ranked
  # finding. Reporting the finding first would let the review look healthy on
  # the exact turn it went half blind; the rule finding is latched and keeps
  # until the next review either way.
  out=$(scan "$home" --id r)
  case "$out" in
    *source-stale*) ;;
    *) fail "a half-blind review reported a finding instead of its blindness: $out" ;;
  esac
  pass "a review reports its own blindness ahead of any finding it can still make"
}

test_a_subject_may_be_named_by_absolute_path() {
  local home out
  home=$(make_home absolute-subject acme)
  # Real sources disagree about this: one lists "agent-ops/firstmate", another
  # lists the full path to the same directory. Both must be reviewable.
  printf '{"rows":[{"venture":"%s/subjects/acme","cost_30d":10}]}\n' "$home" \
    > "$home/source.json"
  write_spec "$home" r '[{"field":"cost_30d","op":"ge","value":1}]' '["cost_30d"]'

  out=$(scan "$home" --id r)
  case "$out" in
    *acme*) ;;
    *) fail "a subject named by absolute path was not reviewable: [$out]" ;;
  esac
  pass "a subject may be named relative to the root or by absolute path"
}

test_a_subject_outside_the_declared_root_is_rejected() {
  local home out err
  home=$(make_home escaping-subject)
  mkdir -p "$home/elsewhere"
  # Containment is the point of declaring a root: a source is someone else's
  # file, and a review must not be steerable into naming work outside it. A
  # relative escape is already refused by G3's name shape, so the case that
  # reaches G5 is a well-formed absolute path to a real directory elsewhere.
  printf '{"rows":[{"venture":"%s/elsewhere","cost_30d":10}]}\n' "$home" \
    > "$home/source.json"
  write_spec "$home" r '[{"field":"cost_30d","op":"ge","value":1}]' '["cost_30d"]'

  err=$("$SCAN" --home "$home" --id r --explain 2>&1 >"$home/out")
  out=$(cat "$home/out")
  [ -z "$out" ] || fail "a subject outside the declared root woke firstmate: $out"
  case "$err" in
    *"G5 dispatchable"*"outside"*) ;;
    *) fail "escaping the declared root was not the stated rejection: $err" ;;
  esac
  pass "G5: a subject outside the declared root is rejected however it is spelled"
}

test_measurements_nested_beside_a_label_are_reachable() {
  local home out
  home=$(make_home nested acme)
  # The shape real sources actually have: a flat human label, with the numbers
  # that justify it in an object beside it. A reviewer that can read only the
  # label produces exactly the classification-only finding G4 refuses.
  cat > "$home/source.json" <<'JSON'
{"rows":[{"path":"acme","disposition":"promote-candidate",
          "signals":{"daysSinceCommit":0,"commits90d":360}}]}
JSON
  cat > "$home/config/standing-reviews/r.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  "sources": [
    { "name": "src", "path": "$home/source.json", "records": "rows" }
  ],
  "rules": [
    { "name": "candidate", "source": "src", "subject_field": "path",
      "when": [{"field":"disposition","op":"eq","value":"promote-candidate"},
               {"field":"signals.commits90d","op":"ge","value":10}],
      "evidence_fields": ["signals.commits90d","signals.daysSinceCommit"],
      "action": "assign this to a lane or decline it" }
  ]
}
JSON
  out=$(scan "$home" --id r)
  case "$out" in
    *"signals.commits90d=360"*) ;;
    *) fail "a measurement nested beside its label was unreachable: [$out]" ;;
  esac
  pass "measurements nested beside a label are reachable as evidence"
}

test_predicates_can_match_on_a_missing_measurement() {
  local home out
  home=$(make_home predicates acme beta)
  # Real surfaces are full of nulls: "spending with nothing earned back" is a
  # rule about a field that is ABSENT, which no comparison operator can say.
  write_source "$home" '[{"venture":"acme","cost_30d":10,"revenue_30d":null,"flag":"live"},
                         {"venture":"beta","cost_30d":10,"revenue_30d":5,"flag":"live"}]'
  write_spec "$home" r \
    '[{"field":"revenue_30d","op":"absent"},{"field":"cost_30d","op":"present"},
      {"field":"flag","op":"ne","value":"archived"}]' '["cost_30d"]'

  out=$(scan "$home" --id r)
  case "$out" in
    *acme*) ;;
    *) fail "an absent-field rule did not match the record with the null: $out" ;;
  esac
  case "$out" in
    *beta*) fail "an absent-field rule matched a record that has the field: $out" ;;
  esac
  pass "a rule can match on a measurement that is missing, not only present"
}

test_records_can_be_located_anywhere_in_the_source() {
  local home out
  home=$(make_home record-path acme)
  # Sources are other people's files; their record array is where it is.
  printf '{"report":{"ventures":[{"venture":"acme","cost_30d":10}]}}\n' > "$home/source.json"
  cat > "$home/config/standing-reviews/r.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  "sources": [
    { "name": "src", "path": "$home/source.json", "records": "report.ventures" }
  ],
  "rules": [
    { "name": "candidate", "source": "src", "subject_field": "venture",
      "when": [{"field":"cost_30d","op":"ge","value":1}],
      "evidence_fields": ["cost_30d"], "action": "look at this" }
  ]
}
JSON
  out=$(scan "$home" --id r)
  case "$out" in
    *acme*) ;;
    *) fail "records nested under a dotted path were not found: [$out]" ;;
  esac
  pass "a source's record array can be located by a dotted path"
}

test_a_source_that_changed_shape_is_reported() {
  local home out
  home=$(make_home reshaped acme)
  # The scorecard-shaped failure: the file still refreshes, so it is fresh, but
  # its records moved. Silence here would read as "nothing to report" forever.
  printf '{"results":[{"venture":"acme","cost_30d":10}]}\n' > "$home/source.json"
  write_spec "$home" r '[{"field":"cost_30d","op":"ge","value":1}]' '["cost_30d"]'

  out=$(scan "$home" --id r)
  case "$out" in
    *source-invalid*) ;;
    *) fail "a source whose records moved left the review silently empty: [$out]" ;;
  esac
  pass "a fresh source the review can no longer read is reported"
}

test_a_long_finding_is_bounded_for_the_wake_digest() {
  local home out action
  home=$(make_home long-line acme)
  action=$(printf 'decide %.0s' $(seq 1 80))
  write_source "$home" '[{"venture":"acme","cost_30d":10}]'
  cat > "$home/config/standing-reviews/r.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  "sources": [
    { "name": "src", "path": "$home/source.json", "records": "rows" }
  ],
  "rules": [
    { "name": "candidate", "source": "src", "subject_field": "venture",
      "when": [{"field":"cost_30d","op":"ge","value":1}],
      "evidence_fields": ["cost_30d"], "action": "$action" }
  ]
}
JSON
  out=$(scan "$home" --id r)
  [ "${#out}" -le 220 ] || fail "the wake line is unbounded at ${#out} characters"
  case "$out" in
    *"[truncated]"*) ;;
    *) fail "a cut wake line does not say it was cut: $out" ;;
  esac
  # The evidence must survive the cut: it is why the line is worth waking for.
  case "$out" in
    *"cost_30d=10"*) ;;
    *) fail "truncation dropped the evidence instead of the prose: $out" ;;
  esac
  pass "a wake line stays bounded and keeps its evidence when cut"
}

test_script_parses
test_quantified_finding_is_emitted_with_its_evidence
test_classification_without_measurement_is_rejected
test_subject_with_no_work_location_is_rejected
test_cadence_silences_the_sweep_between_reviews
test_the_same_finding_does_not_wake_twice
test_drifting_evidence_does_not_defeat_the_latch
test_the_latch_expires_so_a_recurrence_can_wake_again
test_a_stale_source_becomes_the_finding
test_a_stale_source_suppresses_its_own_rules
test_only_one_finding_is_emitted_per_review
test_rank_decides_which_finding_is_reported
test_an_unusable_spec_is_reported_rather_than_ignored
test_a_missing_spec_is_reported
test_hostile_field_content_cannot_break_the_wake_line
test_a_dry_run_leaves_no_trace
test_a_review_never_writes_outside_state
test_predicates_can_match_on_a_missing_measurement
test_records_can_be_located_anywhere_in_the_source
test_a_source_that_changed_shape_is_reported
test_a_long_finding_is_bounded_for_the_wake_digest
test_blindness_is_reported_before_a_finding_from_elsewhere
test_a_subject_may_be_named_by_absolute_path
test_a_subject_outside_the_declared_root_is_rejected
test_measurements_nested_beside_a_label_are_reachable
