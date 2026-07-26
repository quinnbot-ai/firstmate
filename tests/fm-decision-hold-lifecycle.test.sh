#!/usr/bin/env bash
# End-to-end tests for durable captain-held decisions discovered by investigations
# and visual reviews.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

# The digest runs against a throwaway git root so its repo-shaped checks operate
# on scratch, while the scripts still come from this tracked code root.
run_session_start() {  # <home> <root>
  local home=$1 root=$2
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$SESSION_START" 2>&1
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --topic sample-access --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=access,route" "$home/state/$id.meta" "decision inventory was not deterministic"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unblock ] && [ "${2:-}" = sample-route-implementation ] \
  && [ ! -f "$FM_HOME/unblock-failed-once" ]; then
  : > "$FM_HOME/unblock-failed-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-route.out" 2> "$home/partial-route.err"; then
    fail "resolution succeeded after a partial dependent-routing failure"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "partial routing failure closed the hold"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "partial routing fixture did not release its first dependent"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: yes" "partial routing fixture unexpectedly released its second dependent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-followup > "$home/reduced-retry.out" 2> "$home/reduced-retry.err"; then
    fail "partial resolution retry accepted a reduced routed task set"
  fi
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/partial-drifted-decision.out" 2> "$home/partial-drifted-decision.err"; then
    fail "partial resolution retry accepted a different captain decision"
  fi
  tasks_in "$home" "done" sample-route-followup >/dev/null \
    || fail "could not complete already-routed dependent work"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "could not resume and complete partial decision routing"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation \
    > "$home/drifted-routes.out" 2> "$home/drifted-routes.err"; then
    fail "resolution retry accepted a different routed task set"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_pruned_resolved_hold_verifies_from_authoritative_archive() {
  local home id hold
  home=$(make_home archived-resolution)
  id=sample-archive-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review archive retention" --kind scout --repo sample --start >/dev/null \
    || fail "could not create archived-resolution origin"
  write_origin_meta "$home" "$id"
  hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the archive route" --reason "captain archive choice pending" --repo sample) \
    || fail "could not create archived-resolution hold"
  tasks_in "$home" add sample-archive-implementation "Apply the archive route" --kind ship --repo sample >/dev/null \
    || fail "could not create archived-resolution dependent"
  tasks_in "$home" block sample-archive-implementation --by "$hold" >/dev/null \
    || fail "could not block archived-resolution dependent"
  printf 'Use the retained archive record.\n' > "$home/archive-decision.txt"
  run_decisions "$home" resolve "$id" route --decision-file "$home/archive-decision.txt" \
    --routed-to sample-archive-implementation >/dev/null \
    || fail "could not resolve archived-resolution hold"
  run_decisions "$home" complete "$id" route >/dev/null \
    || fail "could not attest archived-resolution inventory"
  tasks_in "$home" "done" "$hold" --keep 0 >/dev/null \
    || fail "could not prune archived-resolution hold"
  ! grep -E "^- \\[x\\] $hold -" "$home/data/backlog.md" >/dev/null \
    || fail "resolved hold remained in the live backlog after pruning"
  grep -E "^- \\[x\\] $hold -" "$home/data/done-archive.md" >/dev/null \
    || fail "resolved hold was not retained in the authoritative archive"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "verification rejected a resolved hold retained only in the archive"
  pass "pruned resolved holds verify from the authoritative archive"
}

test_unrecorded_decision_fails_after_retention_lookup() {
  local home id
  home=$(make_home unrecorded-decision)
  id=sample-unrecorded-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=route\n' >> "$home/state/$id.meta"
  printf 'done: review complete\n' > "$home/state/$id.status"
  printf '# Sample review\n\nNo decision record exists.\n' > "$home/data/$id/report.md"
  if run_decisions "$home" verify "$id" > "$home/unrecorded.out" 2> "$home/unrecorded.err"; then
    fail "verification accepted a decision that was never recorded"
  fi
  assert_grep "absent from the live backlog and authoritative archive" "$home/unrecorded.err" \
    "missing decision record did not fail loudly after archive lookup"
  pass "unrecorded decisions still fail loudly after archive lookup"
}

test_same_task_resolution_evidence_remains_compatible() {
  local home id
  home=$(make_home same-task-evidence)
  id=sample-evidence-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=route\n' >> "$home/state/$id.meta"
  printf 'resolved [key=route]: firstmate recorded the compatibility route\n' > "$home/state/$id.status"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "resolved status evidence no longer verified an absent legacy hold"
  : > "$home/state/$id.status"
  printf 'Captain decision: use the compatibility route.\n' > "$home/data/$id/route-decision.md"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "keyed decision artifact evidence no longer verified an absent legacy hold"
  rm "$home/data/$id/route-decision.md"
  printf 'Captain decision recorded for %s-decision-route.\n' "$id" \
    > "$home/data/$id/captain-decision.md"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "hold-naming decision artifact evidence no longer verified an absent legacy hold"
  pass "same-task resolution evidence remains a compatibility fallback"
}

# One resolved decision must never verify a different unrecorded decision, so a
# decision artifact that names no hold is not evidence for an arbitrary key.
test_unkeyed_decision_artifact_is_not_evidence() {
  local home id
  home=$(make_home unkeyed-evidence)
  id=sample-unkeyed-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf 'decisions_reviewed=1\ndecision_keys=route,scope\n' >> "$home/state/$id.meta"
  printf 'resolved [key=route]: firstmate recorded the compatibility route\n' > "$home/state/$id.status"
  printf 'Captain decision: use the compatibility route.\n' > "$home/data/$id/captain-decision.md"
  if run_decisions "$home" verify "$id" > "$home/unkeyed.out" 2> "$home/unkeyed.err"; then
    fail "an unkeyed decision artifact verified an unrecorded decision"
  fi
  assert_grep "$id-decision-scope is absent from the live backlog and authoritative archive" \
    "$home/unkeyed.err" "unrecorded second decision did not fail loudly"
  pass "decision artifacts only verify the hold they name"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --topic sample-layout --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --topic sample-release --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

test_cross_origin_topic_refuses_duplicate_decision() {
  local home first second rc
  home=$(make_home cross-origin-topic)
  first=sample-first-review
  second=sample-second-review
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"

  run_decisions "$home" hold "$first" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample >/dev/null \
    || fail "could not create the first topic-bound hold"
  set +e
  run_decisions "$home" hold "$second" route-copy \
    --title "Choose the sample route again" --reason "captain route choice pending" --topic sample-route --repo sample \
    > "$home/duplicate.out" 2> "$home/duplicate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a second origin minted the same repository-scoped decision topic"
  assert_grep "already tracked as $first-decision-route" "$home/duplicate.err" \
    "duplicate refusal did not name the existing captain decision"
  assert_no_grep "$second-decision-route-copy" "$home/data/backlog.md" \
    "duplicate refusal still created a second captain decision"
  pass "repository-scoped decision topics reject cross-origin duplicates"
}

test_resolved_topic_refuses_duplicate_decision() {
  local home first second third rc
  home=$(make_home resolved-topic)
  first=sample-first-review
  second=sample-second-review
  third=sample-third-review
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"
  write_origin_meta "$home" "$third"

  run_decisions "$home" hold "$first" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample >/dev/null \
    || fail "could not create the topic-bound hold to resolve"
  tasks_in "$home" "done" "$first-decision-route" >/dev/null \
    || fail "could not close the topic-bound hold"
  grep -E "^- \[x\] $first-decision-route -" "$home/data/backlog.md" >/dev/null \
    || fail "fixture must leave the resolved hold inline in the backlog Done section"

  set +e
  run_decisions "$home" hold "$second" route-copy \
    --title "Choose the sample route again" --reason "captain route choice pending" --topic sample-route --repo sample \
    > "$home/inline-done.out" 2> "$home/inline-done.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an answered decision topic was re-asked from the backlog Done section"
  assert_grep "already resolved as $first-decision-route" "$home/inline-done.err" \
    "resolved-topic refusal did not name the recorded answer"

  tasks_in "$home" "done" "$first-decision-route" --keep 0 >/dev/null 2>&1 || true
  ! grep -E "^- \[[ x]\] $first-decision-route -" "$home/data/backlog.md" >/dev/null \
    || fail "fixture must archive the resolved hold out of the live backlog"
  grep -E "^- \[x\] $first-decision-route -" "$home/data/done-archive.md" >/dev/null \
    || fail "fixture must archive the resolved hold into done-archive.md"

  set +e
  run_decisions "$home" hold "$third" route-again \
    --title "Choose the sample route once more" --reason "captain route choice pending" --topic sample-route --repo sample \
    > "$home/archived-done.out" 2> "$home/archived-done.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an answered decision topic was re-asked from done-archive.md"
  assert_grep "already resolved as $first-decision-route" "$home/archived-done.err" \
    "archived resolved-topic refusal did not name the recorded answer"
  pass "answered decision topics are refused from both the Done section and the archive"
}

test_topic_match_does_not_collide_on_prefix() {
  local home first second nested
  home=$(make_home topic-prefix)
  first=sample-first-review
  second=sample-second-review
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"

  nested=$(run_decisions "$home" hold "$first" route-north \
    --title "Choose the northern sample route" --reason "captain northern choice pending" \
    --topic sample-route.north --repo sample) \
    || fail "could not create the dotted-topic hold"
  run_decisions "$home" hold "$second" route \
    --title "Choose the sample route" --reason "captain route choice pending" \
    --topic sample-route --repo sample >/dev/null \
    || fail "a distinct topic was suppressed by a longer topic sharing its prefix"
  assert_grep "$second-decision-route" "$home/data/backlog.md" \
    "the genuinely distinct captain decision was not registered"
  [ "$nested" = "$first-decision-route-north" ] || fail "dotted-topic hold identity drifted: $nested"
  pass "decision topics match on full value, not on a shared prefix"
}

test_untagged_legacy_title_flags_possible_duplicate() {
  local home origin legacy rc
  home=$(make_home legacy-title-duplicate)
  origin=sample-new-review
  legacy=sample-legacy-route
  write_origin_meta "$home" "$origin"
  tasks_in "$home" add "$legacy" "Choose the sample route" --kind captain --repo sample >/dev/null \
    || fail "could not create untagged legacy captain decision"
  tasks_in "$home" hold "$legacy" --reason "captain route choice pending" --kind captain >/dev/null \
    || fail "could not activate untagged legacy captain decision"
  set +e
  run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample \
    > "$home/legacy-duplicate.out" 2> "$home/legacy-duplicate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a matching untagged legacy hold did not flag a possible duplicate"
  assert_grep "possible duplicate captain decision" "$home/legacy-duplicate.err" \
    "legacy duplicate signal did not clearly identify the ambiguity"
  assert_grep "$legacy" "$home/legacy-duplicate.err" \
    "legacy duplicate signal did not identify the existing hold"
  pass "untagged legacy exact-title matches are clearly flagged"
}

# A backlog entry without a `(repo: ...)` group emits an empty scan field, and tab
# is IFS whitespace, so an unguarded emit would collapse the gap and shift every
# later field left until the audit's own held/hold-kind guards silently dropped the
# entry. The oldest untagged holds are exactly the ones with no repo group.
test_repoless_captain_hold_still_reaches_the_audit() {
  local home legacy entry audit
  home=$(make_home repoless-audit)
  legacy=sample-legacy-route
  tasks_in "$home" add "$legacy" "Choose the sample route" --kind captain >/dev/null \
    || fail "could not create a repo-less captain decision"
  tasks_in "$home" hold "$legacy" --reason "captain chose route north" --kind captain >/dev/null \
    || fail "could not activate the repo-less captain hold"
  entry=$(grep -E "^- \[ \] $legacy -" "$home/data/backlog.md") \
    || fail "fixture did not reach the live backlog"
  case "$entry" in
    *"(repo: "*) fail "fixture must leave the captain hold without a repo group" ;;
  esac
  audit=$(run_decisions "$home" audit) || fail "audit failed with a repo-less captain hold"
  assert_contains "$audit" "answered-open: $legacy: captain chose route north" \
    "a captain hold with no repo group was silently dropped by the audit"
  pass "captain holds without a repo group still reach the answered-open audit"
}

# The audit section only keeps its urgency while it stays rare, so a pending
# question that labels itself must not read as a recorded answer.
test_pending_decision_label_stays_out_of_the_audit() {
  local home origin audit
  home=$(make_home pending-label-audit)
  origin=sample-label-review
  write_origin_meta "$home" "$origin"
  run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "decision: route north or route coastal" \
    --topic sample-route --repo sample >/dev/null \
    || fail "could not create the decision-labelled pending hold"
  run_decisions "$home" hold "$origin" access \
    --title "Choose the sample access level" --reason "captain answer: needed on sample access" \
    --topic sample-access --repo sample >/dev/null \
    || fail "could not create the answer-labelled pending hold"
  audit=$(run_decisions "$home" audit) || fail "audit failed with labelled pending holds"
  assert_contains "$audit" "answered-open: none" \
    "a pending question labelled as a decision or an answer was flagged as answered"
  pass "pending questions labelled decision or answer stay out of the audit"
}

# The duplicate guard is worth least against decisions the tool itself answered, so
# the resolution record must carry the topic forward rather than erase it.
test_resolved_hold_keeps_its_topic_for_the_duplicate_guard() {
  local home first second hold show rc
  home=$(make_home resolve-keeps-topic)
  first=sample-first-review
  second=sample-second-review
  write_origin_meta "$home" "$first"
  write_origin_meta "$home" "$second"

  hold=$(run_decisions "$home" hold "$first" route \
    --title "Choose the sample route" --reason "captain route choice pending" \
    --topic sample-route --repo sample) \
    || fail "could not create the topic-bound hold to resolve"
  tasks_in "$home" add sample-route-work "Apply the selected sample route" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null \
    || fail "could not create the routed dependent work"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  run_decisions "$home" resolve "$first" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-work >/dev/null \
    || fail "could not resolve the topic-bound hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "Decision topic: sample-route." \
    "the resolution record dropped the decision topic"

  tasks_in "$home" "done" "$hold" --keep 0 >/dev/null 2>&1 || true
  grep -E "^- \[x\] $hold -" "$home/data/done-archive.md" >/dev/null \
    || fail "fixture must archive the resolved hold into done-archive.md"

  set +e
  run_decisions "$home" hold "$second" route-copy \
    --title "Choose the sample route again" --reason "captain route choice pending" \
    --topic sample-route --repo sample > "$home/resolved-dup.out" 2> "$home/resolved-dup.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a decision answered through resolve was re-asked after archival"
  assert_grep "already resolved as $hold" "$home/resolved-dup.err" \
    "the archived resolution record did not name the recorded answer"
  assert_no_grep "$second-decision-route-copy" "$home/data/backlog.md" \
    "the refused re-ask still minted a duplicate captain decision"

  # tasks-axi re-adds an archived id as a fresh queued item rather than refusing it,
  # and `show` cannot see the archive, so the original origin and key re-asking the
  # same decision is the easiest way to resurrect an answer that was already given.
  set +e
  run_decisions "$home" hold "$first" route \
    --title "Choose the sample route" --reason "captain route choice pending" \
    --topic sample-route --repo sample > "$home/resolved-self.out" 2> "$home/resolved-self.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the original identity re-opened its own archived resolved decision"
  assert_grep "already resolved as $hold" "$home/resolved-self.err" \
    "the same-identity re-ask did not name the archived recorded answer"
  ! grep -E "^- \[[ x]\] $hold -" "$home/data/backlog.md" >/dev/null \
    || fail "the refused same-identity re-ask still recreated the resolved hold in the live backlog"
  pass "resolve carries the decision topic into the archived resolution record"
}

test_answered_open_audit_surfaces_without_closing() {
  local home origin hold audit show
  home=$(make_home answered-open-audit)
  origin=sample-answer-review
  write_origin_meta "$home" "$origin"
  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain chose route north" --topic sample-route --repo sample) \
    || fail "could not create answered-open captain hold fixture"
  audit=$(run_decisions "$home" audit) || fail "answered-open audit failed"
  assert_contains "$audit" "answered-open: $hold: captain chose route north" \
    "audit did not surface the answer recorded in the still-open hold"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "audit silently closed an answered-open hold"
  assert_contains "$show" "held: yes" "audit silently released an answered-open hold"
  pass "answered-open captain holds are surfaced without heuristic closure"
}

# The audit only stops a re-ask if it actually reaches the reader, so the session
# start digest is part of the guard rather than presentation around it. It must
# print the flagged decision while the answer sits unrouted and stay silent
# otherwise, so an ordinary pending choice never trains the reader to skim it.
test_session_start_surfaces_answered_open_decision() {
  local home origin root hold out
  home=$(make_home answered-open-session-start)
  origin=sample-answer-review
  write_origin_meta "$home" "$origin"
  root="$TMP_ROOT/answered-open-session-start-root"
  mkdir -p "$root"
  git init -q -b main "$root" || fail "could not create the throwaway session-start root"
  git -C "$root" config user.name "Firstmate test" || fail "could not configure the throwaway session-start root"
  git -C "$root" config user.email "firstmate-test@example.invalid" || fail "could not configure the throwaway session-start root"
  git -C "$root" commit -q --allow-empty -m init || fail "could not seed the throwaway session-start root"

  hold=$(run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain chose route north" --topic sample-route --repo sample) \
    || fail "could not create answered-open captain hold fixture"
  out=$(run_session_start "$home" "$root") || fail "session start failed with an answered-open hold"
  assert_contains "$out" "ANSWERED-OPEN CAPTAIN DECISIONS" \
    "session start did not surface the answered-open decision section"
  assert_contains "$out" "answered-open: $hold: captain chose route north" \
    "session start omitted the answered-but-open captain decision"

  run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain route choice pending" --topic sample-route --repo sample >/dev/null \
    || fail "could not return the hold to a genuinely pending reason"
  out=$(run_session_start "$home" "$root") || fail "session start failed with a genuinely pending hold"
  assert_not_contains "$out" "ANSWERED-OPEN CAPTAIN DECISIONS" \
    "session start flagged a genuinely pending captain decision as already answered"
  pass "session start prints answered-open decisions and stays quiet for pending ones"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --topic edge-first --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --topic edge-mid --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --topic edge-last --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --topic edge-absent --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# The guard reads the backlog and the archive as text, so it has to accept every
# row and group form bin/fm-fleet-snapshot.sh already parses. A narrower grammar
# reads `sample, since 2026-07-14` as the whole repo value, stops an archived
# record at the blank line above its own topic, and skips an emphasized or
# uppercase-checked row outright, and each of those misses mints exactly the
# duplicate the guard exists to refuse.
test_scan_accepts_the_canonical_backlog_grammar() {
  local home origin rc
  home=$(make_home canonical-grammar-comma)
  origin=sample-grammar-review
  write_origin_meta "$home" "$origin"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-legacy-route - Choose the sample route (repo: sample, since 2026-07-14) (kind: captain) (hold: captain route choice pending) (hold-kind: captain)

## Done
EOF
  set +e
  run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain route choice pending" \
    --topic sample-route --repo sample > "$home/comma.out" 2> "$home/comma.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a comma-continued repo group hid an untagged legacy captain hold"
  assert_grep "possible duplicate captain decision" "$home/comma.err" \
    "the comma-grouped legacy hold was not flagged as a possible duplicate"
  assert_no_grep "$origin-decision-route" "$home/data/backlog.md" \
    "the refused re-ask still minted a duplicate captain decision"

  home=$(make_home canonical-grammar-archive)
  origin=sample-archive-review
  write_origin_meta "$home" "$origin"
  cat > "$home/data/done-archive.md" <<'EOF'
## Archived 2026-07-14
- [X] sample-old-route-decision - Choose the sample route (repo: sample, kind: captain)
  Resolution recorded by fm-decision-hold.
  Decision digest: 0000

  Decision topic: sample-route.
  Captain decision:
  Use route north.

  Routed work:
  - sample-route-work
- **sample-old-access-decision** - Choose the sample access level (repo: sample) (kind: captain)
  Resolution recorded by fm-decision-hold.
  Decision digest: 1111

  Decision topic: sample-access.
  Captain decision:
  Use read-only access.
EOF
  set +e
  run_decisions "$home" hold "$origin" route \
    --title "Choose the sample route" --reason "captain route choice pending" \
    --topic sample-route --repo sample > "$home/archive.out" 2> "$home/archive.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an archived resolution record was invisible past its blank body line"
  assert_grep "already resolved as sample-old-route-decision" "$home/archive.err" \
    "the uppercase-checked archived record did not match its topic after a blank body line"

  set +e
  run_decisions "$home" hold "$origin" access \
    --title "Choose the sample access level" --reason "captain access choice pending" \
    --topic sample-access --repo sample > "$home/emphasis.out" 2> "$home/emphasis.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an emphasized-id archived resolution record was skipped by the topic scan"
  assert_grep "already resolved as sample-old-access-decision" "$home/emphasis.err" \
    "the emphasized-id archived record did not match its topic"
  assert_no_grep "$origin-decision-" "$home/data/backlog.md" \
    "a refused archived re-ask still minted a duplicate captain decision"
  pass "the hold scan accepts the canonical backlog row, group, and body grammar"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_pruned_resolved_hold_verifies_from_authoritative_archive
test_unrecorded_decision_fails_after_retention_lookup
test_same_task_resolution_evidence_remains_compatible
test_unkeyed_decision_artifact_is_not_evidence
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_cross_origin_topic_refuses_duplicate_decision
test_resolved_topic_refuses_duplicate_decision
test_topic_match_does_not_collide_on_prefix
test_untagged_legacy_title_flags_possible_duplicate
test_scan_accepts_the_canonical_backlog_grammar
test_repoless_captain_hold_still_reaches_the_audit
test_pending_decision_label_stays_out_of_the_audit
test_resolved_hold_keeps_its_topic_for_the_duplicate_guard
test_answered_open_audit_surfaces_without_closing
test_session_start_surfaces_answered_open_decision
test_resolve_matches_quoted_blocked_by_edges
