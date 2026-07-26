#!/usr/bin/env bash
# Colocated behavior tests for sealed report-only auto-dispatch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-auto-dispatch.XXXXXX")
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
PIDS=()
cleanup_auto_dispatch_test() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMPROOT"
}
trap cleanup_auto_dispatch_test EXIT

OWNER_JS="$TMPROOT/codex-owner.mjs"
WATCHER_JS="$TMPROOT/watcher.mjs"

cat > "$OWNER_JS" <<'JS'
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const [lockPath, resultPath, command, ...args] = process.argv.slice(2);
writeFileSync(lockPath, `${process.pid}\n`);
if (command) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: process.env,
  });
  writeFileSync(resultPath, JSON.stringify({
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  }));
}
setInterval(() => {}, 1000);
JS

cat > "$WATCHER_JS" <<'JS'
setInterval(() => {}, 1000);
JS

make_fake_tasks_axi() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command_name=${1:-}
subcommand=${2:-}
state_file=${FM_FAKE_TASKS_STATE:?}

if [ "$subcommand" = --help ]; then
  case "$command_name" in
    ready)
      if [ "${FM_FAKE_API_UNSUPPORTED:-0}" = 1 ]; then
        echo "usage: tasks-axi ready"
      else
        echo "usage: tasks-axi ready --json"
      fi
      ;;
    claim)
      if [ "${FM_FAKE_API_UNSUPPORTED:-0}" = 1 ]; then
        echo "unknown command: claim" >&2
        exit 2
      fi
      echo "usage: tasks-axi claim <id> --if-ready --json"
      ;;
  esac
  exit 0
fi

case "$command_name" in
  ready)
    if [ "${FM_FAKE_READY_RAW:-0}" = 1 ]; then
      # Model a backend whose ready list is not pre-filtered, so the consumer's
      # own per-candidate handling is exercised instead of the fake's.
      ready=$(jq -c '.tasks' "$state_file")
    else
      ready=$(jq -c '[
        .tasks[]
        | select(
            .state == "queued"
            and .blocked == false
            and .held == false
            and .hold == null
            and (.blocked_by | length) == 0
            and .kind != "public-followup"
            and (.public_followup == null)
          )
      ]' "$state_file")
    fi
    jq -n --argjson ready "$ready" \
      '{ok:true,action:"ready",count:($ready|length),ready:$ready}'
    if [ -n "${FM_FAKE_STEAL_AFTER_READY:-}" ]; then
      # Another queue writer wins the ready-to-claim race.
      tmp="${state_file}.tmp.$$"
      jq --arg id "$FM_FAKE_STEAL_AFTER_READY" \
        '(.tasks[] | select(.id == $id) | .state) = "in_flight"' \
        "$state_file" > "$tmp"
      mv "$tmp" "$state_file"
    fi
    ;;
  claim)
    id=${2:?}
    lock="${state_file}.claim-lock"
    if ! mkdir "$lock" 2>/dev/null; then
      echo '{"ok":false,"error":"busy"}' >&2
      exit 2
    fi
    trap 'rmdir "$lock"' EXIT
    task=$(jq -c --arg id "$id" '
      .tasks[]
      | select(.id == $id)
    ' "$state_file")
    if [ -z "$task" ] || ! jq -e '
      .state == "queued"
      and .blocked == false
      and .held == false
      and .hold == null
      and (.blocked_by | length) == 0
      and .kind != "public-followup"
      and (.public_followup == null)
    ' >/dev/null <<< "$task"; then
      echo '{"ok":false,"error":"not-ready"}' >&2
      exit 3
    fi
    tmp="${state_file}.tmp.$$"
    jq --arg id "$id" '
      (.tasks[] | select(.id == $id) | .state) = "in_flight"
      | .claim_count += 1
    ' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    task=$(jq -c --arg id "$id" '.tasks[] | select(.id == $id)' "$state_file")
    jq -n --argjson task "$task" '{ok:true,action:"claim",task:$task}'
    ;;
  reopen)
    id=${2:?}
    tmp="${state_file}.tmp.$$"
    jq --arg id "$id" '
      (.tasks[] | select(.id == $id) | .state) = "queued"
    ' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    task=$(jq -c --arg id "$id" '.tasks[] | select(.id == $id)' "$state_file")
    jq -n --argjson task "$task" '{ok:true,action:"reopen",task:$task}'
    ;;
  *)
    echo "unsupported fake tasks-axi command: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

make_fixture() {
  local name=$1
  FIXTURE="$TMPROOT/$name"
  HOME_DIR="$FIXTURE/home"
  FAKE_ROOT="$FIXTURE/root"
  FAKEBIN="$FIXTURE/fakebin"
  TASKS_STATE="$FIXTURE/tasks.json"
  SNAPSHOT="$FIXTURE/snapshot.json"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$FAKE_ROOT/bin" "$FAKEBIN"
  ln -s "$ROOT/bin/fm-project-mode.sh" "$FAKE_ROOT/bin/fm-project-mode.sh"
  cat > "$FAKE_ROOT/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat "${FM_FAKE_SNAPSHOT:?}"
SH
  chmod +x "$FAKE_ROOT/bin/fm-fleet-snapshot.sh"
  cat > "$FAKE_ROOT/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKE_ROOT/bin/fm-watch.sh"
  cat > "$FAKE_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
touch "${FM_FAKE_SPAWN_MARKER:?}"
SH
  chmod +x "$FAKE_ROOT/bin/fm-spawn.sh"
  make_fake_tasks_axi "$FAKEBIN"
  printf '%s\n' '- alpha [no-mistakes] - fixture project (added 2026-07-26)' > "$HOME_DIR/data/projects.md"
  : > "$HOME_DIR/data/backlog.md"
  cat > "$HOME_DIR/config/auto-dispatch.json" <<'JSON'
{
  "enabled": true,
  "mode": "report-only",
  "target_running": 1,
  "terminal_buffer": 1,
  "max_launches_per_tick": 1,
  "interval_seconds": 60
}
JSON
  printf '{"claim_count":0,"tasks":[]}\n' > "$TASKS_STATE"
  jq -n --arg home "$HOME_DIR" '{
    schema:"fm-fleet-snapshot.v1",
    fm_home:$home,
    main_inventory:{valid:true,reason:null,orphan_in_flight:[],unstructured_current_count:0},
    tasks:[]
  }' > "$SNAPSHOT"
  SPAWN_MARKER="$FIXTURE/spawned"
}

add_task() {
  local id=$1 title=${2:-"Task $1"}
  local tmp="${TASKS_STATE}.tmp"
  jq --arg id "$id" --arg title "$title" '.tasks += [{
    id:$id,
    title:$title,
    state:"queued",
    kind:null,
    repo:"alpha",
    priority:null,
    created:"2026-07-26",
    closed:null,
    deps:[],
    hold:null,
    links:[],
    body:"fixture body",
    blocked:false,
    blocked_by:[],
    held:false,
    public_followup:null
  }]' "$TASKS_STATE" > "$tmp"
  mv "$tmp" "$TASKS_STATE"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
You are a crewmate managed by firstmate.

# Task
Implement the fixture task and verify its acceptance criteria.

# Herdr lifecycle declaration - NOT ENABLED
Do not drive Herdr lifecycle behavior.

# Setup
You are in a disposable git worktree of alpha, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.**
Run \`git checkout -b fm/$id\`.

# Definition of done
Firstmate will then instruct you to run /no-mistakes.
EOF
}

fixture_env() {
  export FM_HOME="$HOME_DIR"
  export FM_ROOT_OVERRIDE="$FAKE_ROOT"
  export FM_FAKE_TASKS_STATE="$TASKS_STATE"
  export FM_FAKE_SNAPSHOT="$SNAPSHOT"
  export FM_FAKE_SPAWN_MARKER="$SPAWN_MARKER"
  export PATH="$FAKEBIN:$ORIGINAL_PATH"
}

# Wait for a path to appear. Staging spans several node, bash, and jq processes,
# so this budget is generous enough to survive a loaded machine while still
# returning the instant the path exists.
wait_for_path() {
  local path=$1 message=$2 _
  for _ in {1..600}; do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  fail "$message"
}

start_owner() {
  local result=$1
  shift
  node "$OWNER_JS" "$HOME_DIR/state/.lock" "$result" "$@" &
  OWNER_PID=$!
  PIDS+=("$OWNER_PID")
  wait_for_path "$result" "owner wrapper did not finish its command"
}

stage_task() {
  local id=$1 result="$FIXTURE/stage-$1.json"
  start_owner "$result" \
    "$ROOT/bin/fm-dispatch-stage.sh" "$id" \
    --repo alpha \
    --kind ship \
    --harness codex \
    --model gpt-fixture \
    --effort low \
    --herdr-lifecycle none
  local status
  status=$(jq -r .status "$result")
  [ "$status" = 0 ] || fail "staging $id failed: $(jq -r .stderr "$result")"
}

start_runtime() {
  node "$WATCHER_JS" &
  WATCHER_PID=$!
  PIDS+=("$WATCHER_PID")
  mkdir -p "$HOME_DIR/state/.watch.lock"
  printf '%s\n' "$WATCHER_PID" > "$HOME_DIR/state/.watch.lock/pid"
  printf '%s\n' "$HOME_DIR" > "$HOME_DIR/state/.watch.lock/fm-home"
  printf '%s\n' "$FAKE_ROOT/bin/fm-watch.sh" > "$HOME_DIR/state/.watch.lock/watcher-path"
  FM_HOME="$HOME_DIR" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$WATCHER_PID" \
    > "$HOME_DIR/state/.watch.lock/pid-identity"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

run_once() {
  "$ROOT/bin/fm-auto-dispatch-once.sh" --force
}

run_once_on_cadence() {
  "$ROOT/bin/fm-auto-dispatch-once.sh"
}

status_verb_count() {
  local verb=$1 file="$HOME_DIR/state/auto-dispatch.status"
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  grep -c "^$verb: " "$file" || true
}

ORIGINAL_PATH=$PATH

# A task worker cannot invoke the staging authority merely because it can read
# the home, while the lock-owning firstmate can create a sealed envelope.
make_fixture author-boundary
fixture_env
add_task author-boundary
node "$OWNER_JS" "$HOME_DIR/state/.lock" "$FIXTURE/idle-result" /usr/bin/true &
owner=$!
PIDS+=("$owner")
wait_for_path "$HOME_DIR/state/.lock" "owner wrapper did not publish a session lock"
if "$ROOT/bin/fm-dispatch-stage.sh" author-boundary \
  --repo alpha --kind ship --harness codex --herdr-lifecycle none \
  >"$FIXTURE/unauthorized.out" 2>"$FIXTURE/unauthorized.err"; then
  fail "non-owning process authored a dispatch envelope"
fi
[ ! -e "$HOME_DIR/data/author-boundary/dispatch.json" ] \
  || fail "unauthorized staging left an envelope"
pass "dispatch envelopes are authored only by the lock-owning firstmate"

make_fixture tamper-seal
fixture_env
add_task tamper-seal
stage_task tamper-seal
start_runtime
jq '.launch_profile.harness = "claude"' "$HOME_DIR/data/tamper-seal/dispatch.json" \
  > "$FIXTURE/tampered"
mv "$FIXTURE/tampered" "$HOME_DIR/data/tamper-seal/dispatch.json"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "tampered envelope reached atomic claim"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "refused the dispatch envelope for tamper-seal" \
  "a broken seal was detected but never reported"
pass "altered dispatch envelopes fail seal verification and are reported before claim"

# A deleted seal key makes every envelope unverifiable, which must be observable
# rather than an invisible skip.
make_fixture missing-seal-key
fixture_env
add_task missing-seal-key
stage_task missing-seal-key
start_runtime
rm -f "$HOME_DIR/state/.auto-dispatch-seal.key"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "unverifiable envelope reached atomic claim"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "seal key is missing" \
  "a lost seal key was not reported"
pass "a lost seal key is reported instead of silently skipping every envelope"

# Every sealed mutable input invalidates the envelope and is skipped before
# queue mutation.
for stale_case in task brief config mode project herdr; do
  make_fixture "stale-$stale_case"
  fixture_env
  add_task "stale-$stale_case"
  stage_task "stale-$stale_case"
  start_runtime
  case "$stale_case" in
    task)
      tmp="${TASKS_STATE}.tmp"
      jq '(.tasks[0].body) = "changed body"' "$TASKS_STATE" > "$tmp"
      mv "$tmp" "$TASKS_STATE"
      ;;
    brief)
      printf '\nChanged after staging.\n' >> "$HOME_DIR/data/stale-brief/brief.md"
      ;;
    config)
      printf '{"default":{"harness":"codex"}}\n' > "$HOME_DIR/config/crew-dispatch.json"
      ;;
    mode)
      printf '%s\n' '- alpha [direct-PR] - fixture project (added 2026-07-26)' > "$HOME_DIR/data/projects.md"
      ;;
    project)
      tmp="${TASKS_STATE}.tmp"
      jq '(.tasks[0].repo) = "other"' "$TASKS_STATE" > "$tmp"
      mv "$tmp" "$TASKS_STATE"
      ;;
    herdr)
      sed 's/# Herdr lifecycle declaration - NOT ENABLED/# Herdr isolation - HARD SAFETY CONTRACT/' \
        "$HOME_DIR/data/stale-herdr/brief.md" > "$FIXTURE/herdr-brief"
      mv "$FIXTURE/herdr-brief" "$HOME_DIR/data/stale-herdr/brief.md"
      ;;
  esac
  run_once
  [ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
    || fail "$stale_case drift reached atomic claim"
done
pass "task, brief, dispatch config, mode, project, and Herdr drift all invalidate staging"

# Unstaged work and every queue-level exclusion remain outside selection.
make_fixture queue-exclusions
fixture_env
add_task unstaged
add_task blocked
add_task held
add_task public
tmp="${TASKS_STATE}.tmp"
jq '
  (.tasks[] | select(.id == "blocked") | .blocked) = true
  | (.tasks[] | select(.id == "blocked") | .blocked_by) = ["dependency"]
  | (.tasks[] | select(.id == "held") | .held) = true
  | (.tasks[] | select(.id == "held") | .hold) = {reason:"wait",kind:"external",until:null}
  | (.tasks[] | select(.id == "public") | .kind) = "public-followup"
  | (.tasks[] | select(.id == "public") | .public_followup) = {delivery:{state:"queued"}}
' "$TASKS_STATE" > "$tmp"
mv "$tmp" "$TASKS_STATE"
node "$OWNER_JS" "$HOME_DIR/state/.lock" "$FIXTURE/queue-owner-result" /usr/bin/true &
PIDS+=("$!")
wait_for_path "$HOME_DIR/state/.lock" "owner wrapper did not publish a session lock"
start_runtime
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "unstaged, blocked, held, or public work reached claim"
pass "only staged authoritative ready work is considered"

# Invalid or unknowable caps fail closed before any queue mutation.
make_fixture cap-indeterminate
fixture_env
add_task cap-indeterminate
node "$OWNER_JS" "$HOME_DIR/state/.lock" "$FIXTURE/cap-owner-result" /usr/bin/true &
PIDS+=("$!")
wait_for_path "$HOME_DIR/state/.lock" "owner wrapper did not publish a session lock"
start_runtime
jq '.target_running = "unknown"' "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/bad-config"
mv "$FIXTURE/bad-config" "$HOME_DIR/config/auto-dispatch.json"
if run_once >"$FIXTURE/cap.out" 2>"$FIXTURE/cap.err"; then
  fail "indeterminate cap did not fail closed"
fi
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "indeterminate cap mutated the queue"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "target_running must be an integer" \
  "indeterminate cap did not produce an actionable report"
pass "indeterminate refill caps fail closed before claim"

# Snapshot contradictions and unknown live state stop before claim.
make_fixture snapshot-guard
fixture_env
add_task snapshot-guard
stage_task snapshot-guard
start_runtime
jq '.tasks = [{
  id:"existing",
  kind:"ship",
  current_state:{state:"unknown"},
  endpoint:{exists:true},
  hints:{pending_decision:false,blocked_event:false}
}]' "$SNAPSHOT" > "$FIXTURE/unknown-snapshot"
mv "$FIXTURE/unknown-snapshot" "$SNAPSHOT"
if run_once >"$FIXTURE/snapshot.out" 2>"$FIXTURE/snapshot.err"; then
  fail "unknown fleet state did not stop refill"
fi
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "unknown fleet state reached claim"
pass "ambiguous fleet state stops refill before queue mutation"

# The open cap counts terminal metadata and cannot be exceeded merely because
# running capacity is available.
make_fixture hard-cap
fixture_env
add_task hard-cap
stage_task hard-cap
start_runtime
jq '.terminal_buffer = 0' "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/tight-config"
mv "$FIXTURE/tight-config" "$HOME_DIR/config/auto-dispatch.json"
jq '.tasks = [{
  id:"terminal-open",
  kind:"ship",
  current_state:{state:"done"},
  endpoint:{exists:false},
  hints:{pending_decision:false,blocked_event:false}
}]' "$SNAPSHOT" > "$FIXTURE/full-snapshot"
mv "$FIXTURE/full-snapshot" "$SNAPSHOT"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "terminal open lane was omitted from the hard cap"
pass "running and hard-open capacity are independently bounded"

# The installed queue API may lag this firstmate change.
# That prerequisite is a deduplicated fail-closed report, never a text scrape.
make_fixture missing-api
fixture_env
add_task missing-api
node "$OWNER_JS" "$HOME_DIR/state/.lock" "$FIXTURE/api-owner-result" /usr/bin/true &
PIDS+=("$!")
wait_for_path "$HOME_DIR/state/.lock" "owner wrapper did not publish a session lock"
start_runtime
export FM_FAKE_API_UNSUPPORTED=1
for _ in 1 2; do
  run_once >"$FIXTURE/api.out" 2>"$FIXTURE/api.err" || true
done
unset FM_FAKE_API_UNSUPPORTED
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "missing machine queue API fell back to unsafe mutation"
[ "$(grep -c 'tasks-axi must provide ready --json' "$HOME_DIR/state/auto-dispatch.status")" = 1 ] \
  || fail "missing queue API report was not deduplicated"
pass "missing atomic queue capabilities fail closed without scraping human output"

# The per-home lock and consumed envelope reduce two simultaneous refill passes
# to one atomic claim/reopen/report transaction.
make_fixture concurrent-claim
fixture_env
add_task concurrent-claim
stage_task concurrent-claim
start_runtime
run_once >"$FIXTURE/race-one.out" 2>"$FIXTURE/race-one.err" &
race_one=$!
run_once >"$FIXTURE/race-two.out" 2>"$FIXTURE/race-two.err" &
race_two=$!
wait "$race_one"
wait "$race_two"
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "concurrent refill passes did not produce exactly one atomic claim"
[ "$(jq -r '.tasks[0].state' "$TASKS_STATE")" = queued ] \
  || fail "report-only claim was not reopened"
[ -f "$HOME_DIR/state/auto-dispatch-receipts/concurrent-claim.json" ] \
  || fail "would-dispatch receipt is missing"
[ ! -e "$SPAWN_MARKER" ] \
  || fail "report-only refill invoked fm-spawn"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "would dispatch concurrent-claim" \
  "report-only refill did not report its selection"
pass "concurrent refill passes claim once, reopen, report, and never spawn"

# Restart reconciliation treats worker metadata as open truth and never claims
# the matching queue item again.
make_fixture metadata-reconciliation
fixture_env
add_task metadata-reconciliation
stage_task metadata-reconciliation
start_runtime
printf '%s\n' \
  'window=fm-metadata-reconciliation' \
  'project=alpha' \
  'kind=ship' \
  > "$HOME_DIR/state/metadata-reconciliation.meta"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "metadata-bearing task was claimed again after restart"
pass "restart reconciliation never duplicates a metadata-bearing task"

# Canonical ready ordering is preserved when multiple reports fit the configured
# bounded tick.
make_fixture canonical-order
fixture_env
add_task first-ready
add_task second-ready
stage_task first-ready
stage_task second-ready
start_runtime
jq '.target_running = 2 | .terminal_buffer = 2 | .max_launches_per_tick = 2' \
  "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/order-config"
mv "$FIXTURE/order-config" "$HOME_DIR/config/auto-dispatch.json"
run_once > "$FIXTURE/order.out"
[ "$(jq -r .claim_count "$TASKS_STATE")" = 2 ] \
  || fail "bounded two-item refill did not claim both ready tasks"
[ "$(sed -n '1p' "$FIXTURE/order.out" | jq -r .id)" = first-ready ] \
  || fail "first canonical ready task was not reported first"
[ "$(sed -n '2p' "$FIXTURE/order.out" | jq -r .id)" = second-ready ] \
  || fail "second canonical ready task was not reported second"
pass "report-only refill preserves authoritative ready ordering"

# A disabled or absent config claims nothing and reports nothing, even when a
# fully staged and dispatchable task is waiting.
make_fixture inert-when-disabled
fixture_env
add_task inert-when-disabled
stage_task inert-when-disabled
start_runtime
jq '.enabled = false' "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/disabled-config"
mv "$FIXTURE/disabled-config" "$HOME_DIR/config/auto-dispatch.json"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "disabled auto-dispatch claimed a task"
[ ! -e "$HOME_DIR/state/auto-dispatch.status" ] \
  || fail "disabled auto-dispatch wrote a status event"
rm -f "$HOME_DIR/config/auto-dispatch.json"
run_once
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "absent auto-dispatch config claimed a task"
[ ! -e "$HOME_DIR/state/auto-dispatch.status" ] \
  || fail "absent auto-dispatch config wrote a status event"
[ ! -e "$HOME_DIR/state/auto-dispatch-receipts" ] \
  || fail "inert auto-dispatch produced a receipt"
pass "auto-dispatch remains fully inert when absent or disabled"

# The persisted cadence bounds how often a pass may run at all.
make_fixture cadence
fixture_env
add_task cadence-one
add_task cadence-two
stage_task cadence-one
stage_task cadence-two
start_runtime
run_once >/dev/null
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "the first bounded pass did not claim exactly one task"
run_once_on_cadence >/dev/null
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "a pass inside interval_seconds was not a no-op"
run_once >/dev/null
[ "$(jq -r .claim_count "$TASKS_STATE")" = 2 ] \
  || fail "a forced pass after the cadence no-op did not resume refill"
pass "the persisted cadence suppresses passes inside interval_seconds"

# Per-candidate queue ineligibility skips that candidate only; it never aborts
# refill for unrelated staged work.
make_fixture ready-ineligibility
fixture_env
add_task ineligible-held
add_task eligible-staged
stage_task ineligible-held
stage_task eligible-staged
tmp="${TASKS_STATE}.tmp"
jq '
  (.tasks[] | select(.id == "ineligible-held") | .held) = true
  | (.tasks[] | select(.id == "ineligible-held") | .hold) = {reason:"wait",kind:"external",until:null}
' "$TASKS_STATE" > "$tmp"
mv "$tmp" "$TASKS_STATE"
start_runtime
export FM_FAKE_READY_RAW=1
run_once > "$FIXTURE/ineligible.out"
unset FM_FAKE_READY_RAW
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "an ineligible ready entry blocked the eligible staged task"
[ "$(jq -r .id < "$FIXTURE/ineligible.out")" = eligible-staged ] \
  || fail "refill did not report the eligible staged task"
[ "$(status_verb_count blocked)" = 0 ] \
  || fail "ordinary queue ineligibility produced a captain-actionable stop"
pass "queue-level ineligibility skips one candidate and refill continues"

# A structurally malformed backend record is a different class of problem and
# still stops the pass before any queue mutation.
make_fixture ready-malformed
fixture_env
add_task malformed-record
stage_task malformed-record
start_runtime
tmp="${TASKS_STATE}.tmp"
jq 'del(.tasks[] | select(.id == "malformed-record") | .repo)' "$TASKS_STATE" > "$tmp"
mv "$tmp" "$TASKS_STATE"
if run_once >"$FIXTURE/malformed.out" 2>"$FIXTURE/malformed.err"; then
  fail "a malformed backend record did not fail closed"
fi
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "a malformed backend record reached atomic claim"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "repo must be a non-empty single-line string" \
  "a malformed backend record was not reported as a contract violation"
pass "a malformed backend record is a hard stop, not an ineligible candidate"

# Another queue writer winning the ready-to-claim race is the benign outcome the
# conditional claim exists to produce.
make_fixture claim-race
fixture_env
add_task claim-race
stage_task claim-race
start_runtime
export FM_FAKE_STEAL_AFTER_READY=claim-race
run_once > "$FIXTURE/claim-race.out"
unset FM_FAKE_STEAL_AFTER_READY
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "a stolen ready task was still claimed"
[ ! -s "$FIXTURE/claim-race.out" ] \
  || fail "a lost conditional claim was reported as a would-dispatch selection"
[ ! -e "$HOME_DIR/state/auto-dispatch-receipts/claim-race.json" ] \
  || fail "a lost conditional claim consumed the envelope"
[ "$(status_verb_count blocked)" = 0 ] \
  || fail "a lost conditional claim stopped refill and woke firstmate"
pass "losing a conditional claim skips the candidate without stopping refill"

# A consumed receipt is a permanent record, so restaging that id must refuse
# loudly instead of writing an envelope refill would silently ignore.
make_fixture receipt-restage
fixture_env
add_task receipt-restage
stage_task receipt-restage
start_runtime
run_once >/dev/null
[ -f "$HOME_DIR/state/auto-dispatch-receipts/receipt-restage.json" ] \
  || fail "the report-only pass wrote no receipt"
start_owner "$FIXTURE/restage-result" \
  "$ROOT/bin/fm-dispatch-stage.sh" receipt-restage \
  --repo alpha --kind ship --harness codex --herdr-lifecycle none
[ "$(jq -r .status "$FIXTURE/restage-result")" != 0 ] \
  || fail "staging over an existing receipt succeeded silently"
assert_contains "$(jq -r .stderr "$FIXTURE/restage-result")" \
  "auto-dispatch-receipts/receipt-restage.json" \
  "the restaging refusal did not name the blocking receipt"
[ ! -e "$HOME_DIR/data/receipt-restage/dispatch.json" ] \
  || fail "the refused restaging still wrote an envelope"
pass "staging over an existing receipt refuses and names the receipt path"

# A fleet that merely needs supervision is routine reporting, deduplicated for
# as long as the episode lasts and re-reported after a genuine recovery.
make_fixture capacity-episode
fixture_env
add_task capacity-episode
stage_task capacity-episode
start_runtime
cp "$SNAPSHOT" "$FIXTURE/healthy-snapshot"
jq '.tasks = [{
  id:"parked-crew",
  kind:"ship",
  current_state:{state:"parked"},
  endpoint:{exists:true},
  hints:{pending_decision:true,blocked_event:false}
}]' "$SNAPSHOT" > "$FIXTURE/parked-snapshot"
cp "$FIXTURE/parked-snapshot" "$SNAPSHOT"
for _ in 1 2; do
  run_once >"$FIXTURE/capacity.out" 2>"$FIXTURE/capacity.err" || true
done
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "a fleet needing supervision still reached atomic claim"
[ "$(status_verb_count blocked)" = 0 ] \
  || fail "routine supervision capacity woke firstmate with a blocked event"
[ "$(status_verb_count working)" = 1 ] \
  || fail "supervision capacity was not deduplicated within one episode"
[ -f "$HOME_DIR/state/.last-auto-dispatch-refill" ] \
  || fail "a failing pass did not advance the persisted cadence"
cp "$FIXTURE/healthy-snapshot" "$SNAPSHOT"
run_once >/dev/null
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "refill did not resume once supervision capacity recovered"
cp "$FIXTURE/parked-snapshot" "$SNAPSHOT"
run_once >"$FIXTURE/capacity-again.out" 2>"$FIXTURE/capacity-again.err" || true
[ "$(status_verb_count working)" = 2 ] \
  || fail "a recurrence after recovery was permanently suppressed"
pass "capacity holds report without waking firstmate and re-report after recovery"

# The refill pass reads watcher identity through the same helper that recorded
# it, so a rewritten identity is a supervision failure rather than a match.
make_fixture supervision-identity
fixture_env
add_task supervision-identity
stage_task supervision-identity
start_runtime
recorded_identity=$(cat "$HOME_DIR/state/.watch.lock/pid-identity")
[ -n "$recorded_identity" ] \
  || fail "fm_pid_identity recorded no watcher identity"
printf '%s\n' "$recorded_identity mutated" > "$HOME_DIR/state/.watch.lock/pid-identity"
if run_once >"$FIXTURE/identity.out" 2>"$FIXTURE/identity.err"; then
  fail "a mismatched watcher identity did not stop refill"
fi
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "a mismatched watcher identity reached atomic claim"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "supervision loop is not healthy" \
  "a mismatched watcher identity was not reported"
printf '%s\n' "$recorded_identity" > "$HOME_DIR/state/.watch.lock/pid-identity"
run_once >/dev/null
[ "$(jq -r .claim_count "$TASKS_STATE")" = 1 ] \
  || fail "the identity recorded by fm_pid_identity was not accepted by refill"
pass "watcher identity is compared through its recording helper, not a restatement"

# Being past the hard cap is an invariant breach, not the routine at-capacity
# path, so it keeps its own captain-actionable wording.
make_fixture breached-cap
fixture_env
add_task breached-cap
stage_task breached-cap
start_runtime
jq '.tasks = [
  {id:"open-one",kind:"ship",current_state:{state:"done"},endpoint:{exists:false},hints:{pending_decision:false,blocked_event:false}},
  {id:"open-two",kind:"ship",current_state:{state:"done"},endpoint:{exists:false},hints:{pending_decision:false,blocked_event:false}},
  {id:"open-three",kind:"ship",current_state:{state:"done"},endpoint:{exists:false},hints:{pending_decision:false,blocked_event:false}}
]' "$SNAPSHOT" > "$FIXTURE/breached-snapshot"
mv "$FIXTURE/breached-snapshot" "$SNAPSHOT"
if run_once >"$FIXTURE/breach.out" 2>"$FIXTURE/breach.err"; then
  fail "a breached lane cap did not stop refill"
fi
[ "$(jq -r .claim_count "$TASKS_STATE")" = 0 ] \
  || fail "a breached lane cap reached atomic claim"
[ "$(status_verb_count blocked)" = 1 ] \
  || fail "a breached lane cap was not reported as captain-actionable"
assert_contains "$(cat "$HOME_DIR/state/auto-dispatch.status")" \
  "stopped on a breached lane cap" \
  "a breached lane cap was not distinguished from the routine at-capacity path"
[ "$(status_verb_count working)" = 0 ] \
  || fail "a breached lane cap was downgraded to routine capacity reporting"
pass "a breached lane cap stays loud and distinct from being at capacity"

# Disabling breaks the run of failing passes an episode represents, so the same
# condition reports again after the home is re-enabled.
make_fixture episode-disable
fixture_env
add_task episode-disable
stage_task episode-disable
start_runtime
jq '.tasks = [{
  id:"parked-crew",
  kind:"ship",
  current_state:{state:"parked"},
  endpoint:{exists:true},
  hints:{pending_decision:true,blocked_event:false}
}]' "$SNAPSHOT" > "$FIXTURE/parked-snapshot"
mv "$FIXTURE/parked-snapshot" "$SNAPSHOT"
for _ in 1 2; do
  run_once >"$FIXTURE/episode.out" 2>"$FIXTURE/episode.err" || true
done
[ "$(status_verb_count working)" = 1 ] \
  || fail "the failure episode did not suppress its own repeat"
[ -f "$HOME_DIR/state/.auto-dispatch-episode.json" ] \
  || fail "an active failure episode was not persisted"
jq '.enabled = false' "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/off-config"
mv "$FIXTURE/off-config" "$HOME_DIR/config/auto-dispatch.json"
run_once
[ ! -e "$HOME_DIR/state/.auto-dispatch-episode.json" ] \
  || fail "disabling auto-dispatch left the failure episode active"
jq '.enabled = true' "$HOME_DIR/config/auto-dispatch.json" > "$FIXTURE/on-config"
mv "$FIXTURE/on-config" "$HOME_DIR/config/auto-dispatch.json"
run_once >"$FIXTURE/episode-again.out" 2>"$FIXTURE/episode-again.err" || true
[ "$(status_verb_count working)" = 2 ] \
  || fail "re-enabling a home kept its unchanged condition suppressed"
pass "a disable interval ends the failure episode while a not-due tick preserves it"

# The existing watcher loop owns invocation, with no new daemon entrypoint.
assert_contains "$(cat "$ROOT/bin/fm-watch.sh")" \
  "fm_auto_dispatch_tick" \
  "existing watcher loop does not invoke refill"
if rg -n 'while[[:space:]]+:' "$ROOT/bin/fm-auto-dispatch-once.sh" "$ROOT/bin/fm-auto-dispatch.mjs" >/dev/null; then
  fail "auto-dispatch introduced a second long-lived loop"
fi
pass "the existing supervision loop invokes the one-shot refill"
