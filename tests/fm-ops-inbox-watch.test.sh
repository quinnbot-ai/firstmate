#!/usr/bin/env bash
# Behavior tests for the operational alert inbox watch: the standing poll
# (fm-ops-inbox-poll.sh), bootstrap's arming sweep, the supervision-need
# predicate, and one end-to-end watcher dispatch.
#
# Everything here drives the real scripts against a synthetic alert spool in a
# temp directory, so no test depends on this machine actually running an
# operations runtime. The watch must be INERT by default (no inbox -> nothing
# armed, nothing printed) and, when armed, must wake exactly once per genuinely
# new condition rather than on every poll.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-ops-inbox-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-ops-inbox-watch)
NOW=$(date -u +%s)

iso_at() {  # <seconds-ago>
  local ago=$1
  if [ "$(uname)" = Darwin ]; then
    date -u -r $((NOW - ago)) +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$((NOW - ago))" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# make_home <name>: a temp firstmate home plus an empty operations state dir.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/ops"
  printf '%s\n' "$home"
}

# alert <home> <id> <seconds-ago> <source> [severity] [ack]
alert() {
  local home=$1 id=$2 ago=$3 source=$4 severity=${5:-critical} ack=${6:-false}
  printf '{"id":"%s","ts":"%s","source":"%s","severity":"%s","message":"synthetic %s","ack":%s}\n' \
    "$id" "$(iso_at "$ago")" "$source" "$severity" "$id" "$ack" \
    >> "$home/ops/ops-inbox.jsonl"
}

ack_alert() {  # <home> <id>
  printf '{"event_id":"%s","ts":"%s","acked_by":"firstmate"}\n' "$2" "$(iso_at 0)" \
    >> "$1/ops/ops-inbox-acks.jsonl"
}

# receipt <home> <count> <seconds-ago>
receipt() {
  local home=$1 count=$2 ago=$3 file
  file="$home/ops/ops-inbox-receipt.json"
  printf '{"ts":"%s","status":"attention","unacked_critical_count":%s,"unacked_ids":[]}\n' \
    "$(iso_at "$ago")" "$count" > "$file"
  touch -t "$(receipt_stamp "$ago")" "$file"
}

receipt_stamp() {  # <seconds-ago> -> local [[CC]YY]MMDDhhmm.SS for touch -t
  local ago=$1
  if [ "$(uname)" = Darwin ]; then
    date -r $((NOW - ago)) +%Y%m%d%H%M.%S
  else
    date -d "@$((NOW - ago))" +%Y%m%d%H%M.%S
  fi
}

# configure <home> [extra-json-pairs]: point the watch at this home's spool.
configure() {
  local home=$1 extra=${2:-}
  if [ -n "$extra" ]; then
    printf '{"state_dir": "%s/ops", %s}\n' "$home" "$extra" > "$home/config/ops-inbox.json"
  else
    printf '{"state_dir": "%s/ops"}\n' "$home" > "$home/config/ops-inbox.json"
  fi
}

run_poll() {  # <home>
  FM_HOME="$1" "$POLL" 2>/dev/null
}

# Bootstrap runs many detect steps; these tests only care about its alert-watch
# behavior, so filter its output to the lines this feature owns.
run_bootstrap() {  # <home>
  FM_HOME="$1" FM_BOOTSTRAP_VERBOSE_FACTS=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep -E 'OPS_INBOX|operational alert watch' || true
}

# The migration gate refuses to let a watcher run without its completed markers.
seed_migration_markers() {  # <home>
  local home=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
}

test_inert_without_an_inbox() {
  local home out
  home=$(make_home inert)
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "the poll must say nothing when this home has no alert inbox (got: $out)"
  out=$(run_bootstrap "$home")
  [ -z "$out" ] || fail "bootstrap must say nothing about an alert watch it never arms (got: $out)"
  assert_absent "$home/state/ops-watch.check.sh" "bootstrap armed a watch with no inbox to watch"
  pass "the alert watch stays inert on a home with no alert inbox"
}

test_quiet_backlog_is_silent() {
  local home out
  home=$(make_home quiet)
  configure "$home"
  alert "$home" q1 600 backup-verify
  alert "$home" q2 600 routine-scheduler
  receipt "$home" 2 60
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "a small, fresh, reviewed-recently backlog must not wake firstmate (got: $out)"
  assert_absent "$home/state/.ops-inbox-wake" "a silent poll must not record a wake"
  pass "a small backlog under a fresh receipt stays silent"
}

test_age_threshold_wakes_with_digest() {
  local home out
  home=$(make_home age)
  configure "$home"
  alert "$home" a1 32400 backup-verify          # 9h old, past the 6h default
  alert "$home" a2 600 backup-verify
  alert "$home" a3 600 routine-scheduler
  alert "$home" a4 600 acked-class
  alert "$home" a5 600 warning-class warning
  ack_alert "$home" a4
  receipt "$home" 3 60
  out=$(run_poll "$home")
  assert_contains "$out" "ops-inbox:" "an aged critical backlog must wake firstmate"
  assert_contains "$out" "3 unacked critical alerts" "the digest must carry the unacked count"
  assert_contains "$out" "oldest 9h" "the digest must carry the oldest alert age"
  assert_contains "$out" "top: backup-verify 2" "the digest must rank the busiest alert class first"
  assert_contains "$out" "routine-scheduler 1" "the digest must name the other classes"
  assert_not_contains "$out" "acked-class" "an acknowledged alert must not reach the digest"
  assert_not_contains "$out" "warning-class" "a non-critical alert must not reach the digest"
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] \
    || fail "the wake must be exactly one line"
  assert_present "$home/state/.ops-inbox-wake" "a wake must be recorded for dedupe"
  pass "an alert older than the age threshold wakes with a compact triage digest"
}

test_count_threshold_wakes_when_all_alerts_are_new() {
  local home out i
  home=$(make_home count)
  configure "$home"
  i=0
  while [ "$i" -lt 30 ]; do
    alert "$home" "c$i" 60 flood
    i=$((i + 1))
  done
  receipt "$home" 30 60
  out=$(run_poll "$home")
  assert_contains "$out" "30 unacked critical alerts" "a backlog past the count threshold must wake even when every alert is new"
  pass "a backlog past the count threshold wakes on volume alone"
}

test_stale_receipt_is_itself_wake_worthy() {
  local home out
  home=$(make_home stale-receipt)
  configure "$home"
  alert "$home" s1 600 backup-verify
  receipt "$home" 1 21600                       # 6h old, past the 3h default
  out=$(run_poll "$home")
  assert_contains "$out" "alert receipt stale 6h" "a stale receipt must wake even when the backlog itself is small"
  assert_contains "$out" "1 unacked critical alert" "a stale-receipt wake must still carry the current backlog"
  pass "a stale review receipt wakes firstmate on its own"
}

test_missing_receipt_is_wake_worthy() {
  local home out
  home=$(make_home missing-receipt)
  configure "$home"
  alert "$home" m1 600 backup-verify
  out=$(run_poll "$home")
  assert_contains "$out" "alert receipt missing" "a missing receipt must wake firstmate"
  pass "a missing review receipt wakes firstmate on its own"
}

test_fresh_receipt_count_is_authoritative() {
  local home out
  home=$(make_home receipt-count)
  configure "$home"
  alert "$home" r1 32400 backup-verify
  receipt "$home" 41 60
  out=$(run_poll "$home")
  assert_contains "$out" "41 unacked critical alerts" "a fresh receipt's own count must be reported"
  pass "a fresh receipt's count is used for the digest total"
}

test_corrupt_recent_receipt_is_unreadable() {
  local home out
  home=$(make_home corrupt-receipt)
  configure "$home"
  alert "$home" cr1 600 backup-verify
  printf 'not json\n' > "$home/ops/ops-inbox-receipt.json"
  touch -t "$(receipt_stamp 60)" "$home/ops/ops-inbox-receipt.json"
  out=$(run_poll "$home")
  assert_contains "$out" "alert receipt unreadable" \
    "a recent receipt with no usable count must wake as unreadable"
  assert_contains "$out" "1 unacked critical alert" \
    "an unreadable receipt must fall back to the spool-scanned count"
  pass "a corrupt recent receipt wakes as unreadable"
}

test_malformed_spool_fails_closed() {
  local home out
  home=$(make_home malformed-spool)
  configure "$home"
  printf '{"id":"broken"\n' > "$home/ops/ops-inbox.jsonl"
  receipt "$home" 0 60
  out=$(run_poll "$home")
  assert_contains "$out" "ops-inbox: alert inbox at $home/ops/ops-inbox.jsonl could not be read" \
    "a malformed spool must wake through the scan-failure path"
  assert_not_contains "$out" "0 unacked critical alerts" \
    "a malformed spool must not be reported as a clean zero"
  pass "a malformed spool wakes fail-closed"
}

test_standing_backlog_does_not_rewake_every_poll() {
  local home first second
  home=$(make_home dedupe)
  configure "$home"
  alert "$home" d1 32400 backup-verify
  receipt "$home" 1 60
  first=$(run_poll "$home")
  assert_contains "$first" "ops-inbox:" "the first sight of a backlog must wake"
  second=$(run_poll "$home")
  [ -z "$second" ] || fail "an unchanged standing backlog must not wake again (got: $second)"
  pass "an unchanged standing backlog wakes once, not every poll"
}

test_material_growth_wakes_again() {
  local home out i
  home=$(make_home growth)
  configure "$home" '"growth": 5'
  alert "$home" g0 32400 backup-verify
  receipt "$home" 1 60
  run_poll "$home" >/dev/null
  alert "$home" g1 600 backup-verify
  receipt "$home" 2 60
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "one extra alert is not material growth (got: $out)"
  i=0
  while [ "$i" -lt 5 ]; do
    alert "$home" "gg$i" 600 backup-verify
    i=$((i + 1))
  done
  receipt "$home" 7 60
  out=$(run_poll "$home")
  assert_contains "$out" "7 unacked critical alerts" "a materially larger backlog must wake again"
  pass "the backlog wakes again only after it grows materially"
}

test_new_alert_class_wakes_again() {
  local home out
  home=$(make_home new-class)
  configure "$home"
  alert "$home" n1 32400 backup-verify
  receipt "$home" 1 60
  run_poll "$home" >/dev/null
  alert "$home" n2 600 disk-pressure
  receipt "$home" 2 60
  out=$(run_poll "$home")
  assert_contains "$out" "disk-pressure" "a newly failing alert class must wake again immediately"
  pass "a new alert class wakes again without waiting for the re-remind interval"
}

test_reremind_interval_wakes_again() {
  local home out stale_epoch
  home=$(make_home reremind)
  configure "$home" '"remind_hours": 1'
  alert "$home" rr1 32400 backup-verify
  receipt "$home" 1 60
  run_poll "$home" >/dev/null
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "the same backlog must stay quiet inside the re-remind interval (got: $out)"
  stale_epoch=$((NOW - 7200))
  printf '%s\n%s\n%s\n%s\n%s\n' fm-ops-inbox-wake-v1 "$stale_epoch" 1 fresh backup-verify \
    > "$home/state/.ops-inbox-wake"
  out=$(run_poll "$home")
  assert_contains "$out" "ops-inbox:" "an unreviewed backlog must be raised again once the re-remind interval passes"
  pass "a still-unreviewed backlog is raised again on the re-remind interval"
}

test_cleared_backlog_resets_dedupe() {
  local home out
  home=$(make_home cleared)
  configure "$home"
  alert "$home" x1 32400 backup-verify
  receipt "$home" 1 60
  run_poll "$home" >/dev/null
  assert_present "$home/state/.ops-inbox-wake" "the first wake must be recorded"
  ack_alert "$home" x1
  receipt "$home" 0 60
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "a cleared backlog must be silent (got: $out)"
  assert_absent "$home/state/.ops-inbox-wake" "a cleared backlog must drop its dedupe record"
  alert "$home" x2 32400 backup-verify
  receipt "$home" 1 60
  out=$(run_poll "$home")
  assert_contains "$out" "ops-inbox:" "a fresh backlog after a cleared one must wake immediately"
  pass "clearing the backlog resets dedupe so the next one wakes immediately"
}

test_unusable_configuration_is_reported_not_guessed() {
  local home out
  home=$(make_home bad-config)
  printf 'not json at all\n' > "$home/config/ops-inbox.json"
  out=$(run_poll "$home")
  assert_contains "$out" "alert watch configuration is unusable" "a malformed config must be reported, not silently defaulted"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "OPS_INBOX:" "bootstrap must report a malformed alert-watch config"
  assert_absent "$home/state/ops-watch.check.sh" "bootstrap must not arm a watch it cannot configure"
  pass "an unusable alert-watch configuration is reported instead of guessed"
}

test_rejected_threshold_value_is_reported() {
  local home out
  home=$(make_home bad-threshold)
  configure "$home" '"age_hours": "soon"'
  out=$(run_poll "$home")
  assert_contains "$out" "age_hours must be a non-negative integer" "a non-numeric threshold must be reported"
  pass "a non-numeric threshold is refused with a specific reason"
}

test_explicit_disable_wins() {
  local home out
  home=$(make_home disabled)
  configure "$home" '"enabled": false'
  alert "$home" o1 32400 backup-verify
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "an explicitly disabled watch must stay silent (got: $out)"
  pass "an explicitly disabled alert watch stays silent"
}

test_bootstrap_arms_registers_and_is_idempotent() {
  local home out sum1 sum2
  home=$(make_home arm)
  configure "$home"
  alert "$home" b1 600 backup-verify
  out=$(run_bootstrap "$home")
  assert_contains "$out" "operational alert watch armed" "bootstrap must report the watch it armed"
  assert_present "$home/state/ops-watch.check.sh" "bootstrap must drop the standing check"
  [ -x "$home/state/ops-watch.check.sh" ] || fail "the standing check must be executable"
  assert_grep "fm-ops-inbox-poll.sh" "$home/state/ops-watch.check.sh" \
    "the standing check must run the trusted poll script"
  assert_present "$home/state/ops-watch.check-trust" "bootstrap must bind the check to its bytes"
  sum1=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  out=$(run_bootstrap "$home")
  [ -z "$out" ] || fail "re-arming an already-armed watch must be silent (got: $out)"
  sum2=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  [ "$sum1" = "$sum2" ] || fail "arming the alert watch must be idempotent"
  pass "bootstrap arms and registers the standing alert check, idempotently"
}

test_bootstrap_disarms_when_the_inbox_goes_away() {
  local home out
  home=$(make_home disarm)
  configure "$home"
  alert "$home" b2 600 backup-verify
  run_bootstrap "$home" >/dev/null
  assert_present "$home/state/ops-watch.check.sh" "the watch must be armed before the disarm case"
  rm -f "$home/ops/ops-inbox.jsonl"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "operational alert watch disarmed" "bootstrap must report the disarm"
  assert_absent "$home/state/ops-watch.check.sh" "bootstrap must remove the standing check"
  assert_absent "$home/state/ops-watch.check-trust" "bootstrap must remove the trust binding"
  pass "bootstrap disarms the watch when there is no longer an inbox to watch"
}

test_bootstrap_refuses_to_take_a_live_task_id() {
  local home out
  home=$(make_home reserved)
  configure "$home"
  alert "$home" b3 600 backup-verify
  fm_write_meta "$home/state/ops-watch.meta" "window=firstmate:fm-ops-watch" "harness=echo"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "OPS_INBOX: task id ops-watch is in use" "bootstrap must refuse to collide with live work"
  assert_absent "$home/state/ops-watch.check.sh" "bootstrap must not arm over a live task's records"
  pass "bootstrap refuses to arm the watch over a live task holding its reserved id"
}

test_live_task_artifacts_survive_disarm() {
  local home out sum_before sum_after
  home=$(make_home live-task-disarm)
  configure "$home"
  printf 'foreign check\n' > "$home/state/ops-watch.check.sh"
  chmod 0700 "$home/state/ops-watch.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" ops-watch >/dev/null
  sum_before=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  fm_write_meta "$home/state/ops-watch.meta" "window=firstmate:fm-ops-watch" "harness=echo"
  out=$(run_bootstrap "$home")
  assert_contains "$out" "OPS_INBOX: task id ops-watch is in use" \
    "live work must win before a disarm-triggering path examines artifacts"
  assert_grep "foreign check" "$home/state/ops-watch.check.sh" \
    "bootstrap must not remove a live task's foreign check"
  sum_after=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  [ "$sum_before" = "$sum_after" ] \
    || fail "bootstrap must not alter a live task's registered foreign check"
  pass "live task artifacts survive a disarm-triggering bootstrap run"
}

test_foreign_check_survives_disarm() {
  local home out sum_before sum_after
  home=$(make_home foreign-check-disarm)
  configure "$home"
  printf 'foreign check\n' > "$home/state/ops-watch.check.sh"
  chmod 0700 "$home/state/ops-watch.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" ops-watch >/dev/null
  sum_before=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  out=$(run_bootstrap "$home")
  assert_contains "$out" "OPS_INBOX: state/ops-watch.check.sh is not this operational alert watch" \
    "bootstrap must report a foreign reserved-id check instead of deleting it"
  assert_grep "foreign check" "$home/state/ops-watch.check.sh" \
    "a foreign reserved-id check must survive disarm"
  sum_after=$(cat "$home/state/ops-watch.check.sh" "$home/state/ops-watch.check-trust" | shasum)
  [ "$sum_before" = "$sum_after" ] \
    || fail "a foreign registered check and its trust record must survive disarm"
  pass "a foreign reserved-id check survives disarm"
}

test_armed_watch_needs_supervision() {
  local home needed desc
  home=$(make_home supervision)
  configure "$home"
  alert "$home" b4 600 backup-verify
  needed=$(
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" && echo yes || echo no
  )
  [ "$needed" = no ] || fail "an idle home with no armed watch must not need supervision"
  run_bootstrap "$home" >/dev/null
  needed=$(
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" && echo yes || echo no
  )
  [ "$needed" = yes ] || fail "an armed alert watch must need a live watcher"
  desc=$(
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_status "$home/state"
    printf '%s' "$FM_SUP_STANDING_DESC"
  )
  assert_contains "$desc" "operational alert monitoring" \
    "the supervision banner must name the alert watch in plain language"
  pass "an armed alert watch counts as a supervision need with no fleet work"
}

test_read_cap_is_reported_not_hidden() {
  local home out i
  home=$(make_home read-cap)
  configure "$home" '"max_lines": 5'
  i=0
  while [ "$i" -lt 8 ]; do
    alert "$home" "cap$i" 600 flood
    i=$((i + 1))
  done
  receipt "$home" 8 60
  out=$(run_poll "$home")
  assert_contains "$out" "inbox past its 5-line read cap" \
    "a spool too long to read inside one check must say so instead of failing quietly"
  assert_contains "$out" "understated" "the digest must warn that a capped total understates the backlog"
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] || fail "the capped wake must still be one line"
  pass "a spool past the bounded read cap is reported rather than silently truncated"
}

test_secondmate_home_does_not_auto_arm() {
  local home out
  home=$(make_home secondmate-auto)
  configure "$home"
  alert "$home" sm1 32400 backup-verify
  printf '%s\n' alpha > "$home/.fm-secondmate-home"
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "one machine has one alert inbox, so a secondmate home must not raise it too (got: $out)"
  out=$(run_bootstrap "$home")
  [ -z "$out" ] || fail "bootstrap must not arm the alert watch in a secondmate home by default (got: $out)"
  assert_absent "$home/state/ops-watch.check.sh" "a secondmate home must not auto-arm the alert watch"
  configure "$home" '"enabled": true'
  out=$(run_bootstrap "$home")
  assert_contains "$out" "operational alert watch armed" \
    "an explicit opt-in must still arm the watch in a secondmate home"
  pass "a secondmate home never auto-arms the machine's alert watch"
}

test_watcher_dispatches_the_registered_check() {
  local home status wake drained
  home=$(make_home watcher)
  configure "$home"
  alert "$home" w1 32400 backup-verify
  alert "$home" w2 600 routine-scheduler
  receipt "$home" 2 60
  seed_migration_markers "$home"
  run_bootstrap "$home" >/dev/null
  assert_present "$home/state/ops-watch.check.sh" "the watch must be armed before the watcher runs"
  status=0
  wake=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 20 2>/dev/null) || status=$?
  expect_code 0 "$status" "alert-watch checkpoint exit"
  assert_contains "$wake" "check:" "the alert digest must arrive as an ordinary check wake"
  assert_contains "$wake" "ops-inbox:" "the wake must carry the alert digest"
  assert_contains "$wake" "2 unacked critical alerts" "the wake must carry the unacked count"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "ops-inbox:" "the alert digest must be queued durably"
  pass "the watcher dispatches the registered alert check and queues its digest"
}

test_hostile_alert_source_cannot_break_the_wake_record() {
  local home out
  home=$(make_home hostile)
  configure "$home"
  printf '{"id":"h1","ts":"%s","source":"bad\\tsource with spaces\\nand a newline","severity":"critical","message":"m","ack":false}\n' \
    "$(iso_at 32400)" >> "$home/ops/ops-inbox.jsonl"
  receipt "$home" 1 60
  out=$(run_poll "$home")
  [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" = 0 ] \
    || fail "a hostile alert source must not split the wake into several lines"
  assert_not_contains "$out" "$(printf '\t')" "a hostile alert source must not put a tab in the wake record"
  assert_contains "$out" "top: bad" "the hostile source must still be reported as one class"
  assert_not_contains "$out" "source with spaces" "the source's own whitespace must be neutralized"
  assert_contains "$out" "1 unacked critical alert," "a hostile source must not corrupt the count"
  pass "a hostile alert source is sanitized into one safe wake line"
}

test_inert_without_an_inbox
test_quiet_backlog_is_silent
test_age_threshold_wakes_with_digest
test_count_threshold_wakes_when_all_alerts_are_new
test_stale_receipt_is_itself_wake_worthy
test_missing_receipt_is_wake_worthy
test_fresh_receipt_count_is_authoritative
test_corrupt_recent_receipt_is_unreadable
test_malformed_spool_fails_closed
test_standing_backlog_does_not_rewake_every_poll
test_material_growth_wakes_again
test_new_alert_class_wakes_again
test_reremind_interval_wakes_again
test_cleared_backlog_resets_dedupe
test_unusable_configuration_is_reported_not_guessed
test_rejected_threshold_value_is_reported
test_explicit_disable_wins
test_read_cap_is_reported_not_hidden
test_bootstrap_arms_registers_and_is_idempotent
test_bootstrap_disarms_when_the_inbox_goes_away
test_bootstrap_refuses_to_take_a_live_task_id
test_live_task_artifacts_survive_disarm
test_foreign_check_survives_disarm
test_armed_watch_needs_supervision
test_secondmate_home_does_not_auto_arm
test_watcher_dispatches_the_registered_check
test_hostile_alert_source_cannot_break_the_wake_record
