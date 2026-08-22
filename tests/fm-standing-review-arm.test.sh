#!/usr/bin/env bash
# Behavior tests for bin/fm-standing-review-arm.sh - the registration path.
#
# THE FAILURE UNDER TEST. The watcher runs a custom check only when the check's
# current bytes match the hash firstmate registered for it, and it runs the file
# by path with no firstmate environment of its own. Two things follow, and both
# are easy to get wrong once and never notice:
#   - a shim that resolved its home from the environment would review whatever
#     home happened to launch the watcher, silently reviewing the wrong fleet;
#   - task ids and check ids share one namespace, so arming can quietly clobber
#     a live task's merge poll, or be deleted by that task's cleanup.
# These tests pin the arming path against both, and pin that an unusable spec
# is refused HERE, while a human is watching, rather than becoming a wake every
# interval once the watcher owns it.
#
# The watcher-side acceptance test drives the real trust functions the watcher
# uses (fm-check-lib.sh), not a restatement of them, so a change to how checks
# are trusted fails here instead of in production.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-standing-review-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-standing-review-arm)

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$ROOT/bin/fm-check-lib.sh"

make_home() {  # <case-name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config/standing-reviews" "$home/subjects/acme"
  printf '{"rows":[{"venture":"acme","cost_30d":10,"commits_30d":0}]}\n' > "$home/source.json"
  cat > "$home/config/standing-reviews/r.json" <<JSON
{
  "version": "fm-standing-review-v1",
  "subject_root": "$home/subjects",
  "sources": [
    { "name": "src", "path": "$home/source.json", "records": "rows" }
  ],
  "rules": [
    { "name": "candidate", "source": "src", "subject_field": "venture",
      "when": [{"field":"commits_30d","op":"eq","value":0}],
      "evidence_fields": ["cost_30d","commits_30d"],
      "action": "dispatch a worker to decide this" }
  ]
}
JSON
  printf '%s\n' "$home"
}

arm() {  # <home> <args...>
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" "$ARM" --home "$home" "$@"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$ARM" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-standing-review-arm.sh does not parse: $out"
  pass "fm-standing-review-arm: script parses"
}

test_arming_registers_a_check_the_watcher_accepts() {
  local home out
  home=$(make_home accepted)
  out=$(arm "$home" --id r 2>&1) || fail "arming failed: $out"
  assert_present "$home/state/r.check.sh" "arming wrote no check"
  [ "$(fm_pr_file_mode "$home/state/r.check.sh")" = 700 ] \
    || fail "the check is not the private mode the watcher requires"

  # The watcher's own acceptance path, not a restatement of it.
  fm_custom_check_snapshot_prepare "$home/state" r \
    || fail "the watcher would reject the check this script just armed"
  out=$(bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  fm_custom_check_snapshot_cleanup
  [ -n "$out" ] || fail "the armed check produced no finding on its first run"
  case "$out" in
    *acme*) ;;
    *) fail "the armed check did not review the home it was armed in: $out" ;;
  esac
  pass "arming registers a check the watcher accepts and runs"
}

test_the_check_ignores_the_environment_it_is_run_with() {
  local home other out
  home=$(make_home env-proof)
  other=$(make_home env-decoy)
  arm "$home" --id r >/dev/null 2>&1 || fail "arming failed"

  # The watcher exports FM_HOME only for its own Relay shim, and may itself
  # have been launched from a different home. A shim that read the environment
  # would review the decoy.
  out=$(FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" \
        FM_CONFIG_OVERRIDE="$other/config" bash "$home/state/r.check.sh")
  [ -n "$out" ] || fail "the check produced nothing under a foreign environment"
  assert_absent "$other/state/r.standing-review-latch" \
    "the check recorded its wake in the wrong home"
  assert_present "$home/state/r.standing-review-latch" \
    "the check did not record its wake in the home it was armed in"
  pass "an armed check reviews the home it was armed in, whatever the environment"
}

test_editing_the_check_revokes_it() {
  local home
  home=$(make_home tamper)
  arm "$home" --id r >/dev/null 2>&1 || fail "arming failed"
  printf '# edited after registration\n' >> "$home/state/r.check.sh"
  ! fm_custom_check_snapshot_prepare "$home/state" r \
    || fail "the watcher accepted a check edited after registration"
  fm_custom_check_snapshot_cleanup
  pass "a check edited after arming is no longer trusted"
}

test_an_unusable_spec_is_refused_before_arming() {
  local home out rc
  home=$(make_home bad-spec)
  printf '{"version":"wrong"}\n' > "$home/config/standing-reviews/r.json"
  out=$(arm "$home" --id r 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unusable spec was armed anyway"
  assert_absent "$home/state/r.check.sh" "a refused arming left a check behind"
  case "$out" in
    *version*) ;;
    *) fail "the refusal does not say what is wrong: $out" ;;
  esac
  pass "an unusable spec is refused while a human is watching"
}

test_arming_refuses_an_id_that_names_a_task() {
  local home out rc
  home=$(make_home task-collision)
  : > "$home/state/r.meta"
  out=$(arm "$home" --id r 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a review was armed onto a live task id"
  assert_absent "$home/state/r.check.sh" "the refused arming still wrote a check"
  pass "arming refuses an id a task already owns"
}

test_arming_refuses_to_overwrite_a_foreign_check() {
  local home out rc before
  home=$(make_home foreign-check)
  printf '#!/usr/bin/env bash\n# someone else owns this\n' > "$home/state/r.check.sh"
  chmod 0700 "$home/state/r.check.sh"
  before=$(cat "$home/state/r.check.sh")
  out=$(arm "$home" --id r 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "arming overwrote a check it did not generate"
  [ "$(cat "$home/state/r.check.sh")" = "$before" ] \
    || fail "the foreign check was modified by a refused arming"
  pass "arming refuses to overwrite a check it did not generate"
}

test_disarm_stops_the_review_and_keeps_what_it_reported() {
  local home
  home=$(make_home disarm)
  arm "$home" --id r >/dev/null 2>&1 || fail "arming failed"
  bash "$home/state/r.check.sh" >/dev/null
  arm "$home" --id r --disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/r.check.sh" "disarm left the check armed"
  assert_absent "$home/state/r.check-trust" "disarm left the registration behind"
  # Keeping the record is the point: re-arming must not re-report old findings.
  assert_present "$home/state/r.standing-review-latch" \
    "disarm discarded what the review already reported"
  arm "$home" --id r --disarm --purge >/dev/null || fail "purge failed"
  assert_absent "$home/state/r.standing-review-latch" "purge kept the durable record"
  pass "disarm stops the review and keeps its history unless asked to purge"
}

test_disarm_refuses_a_foreign_check() {
  local out rc home
  home=$(make_home disarm-foreign)
  printf '#!/usr/bin/env bash\n# someone else owns this\n' > "$home/state/r.check.sh"
  chmod 0700 "$home/state/r.check.sh"
  out=$(arm "$home" --id r --disarm 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "disarm removed a check it did not generate"
  assert_present "$home/state/r.check.sh" "disarm deleted a foreign check"
  pass "disarm refuses a check it did not generate"
}

test_list_reports_what_is_armed() {
  local home out
  home=$(make_home listing)
  out=$(arm "$home" --list)
  case "$out" in
    *"no standing reviews"*) ;;
    *) fail "an empty home did not report itself as empty: $out" ;;
  esac
  arm "$home" --id r >/dev/null 2>&1 || fail "arming failed"
  out=$(arm "$home" --list)
  case "$out" in
    *r*registered*) ;;
    *) fail "an armed review is not listed as registered: $out" ;;
  esac
  pass "the armed reviews in a home are inspectable"
}

test_script_parses
test_arming_registers_a_check_the_watcher_accepts
test_the_check_ignores_the_environment_it_is_run_with
test_editing_the_check_revokes_it
test_an_unusable_spec_is_refused_before_arming
test_arming_refuses_an_id_that_names_a_task
test_arming_refuses_to_overwrite_a_foreign_check
test_disarm_stops_the_review_and_keeps_what_it_reported
test_disarm_refuses_a_foreign_check
test_list_reports_what_is_armed
