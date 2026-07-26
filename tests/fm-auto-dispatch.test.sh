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
    jq -n --argjson ready "$ready" \
      '{ok:true,action:"ready",count:($ready|length),ready:$ready}'
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

start_owner() {
  local result=$1
  shift
  node "$OWNER_JS" "$HOME_DIR/state/.lock" "$result" "$@" &
  OWNER_PID=$!
  PIDS+=("$OWNER_PID")
  local _
  for _ in {1..100}; do
    [ -f "$result" ] && return 0
    sleep 0.02
  done
  fail "owner wrapper did not finish its command"
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

ORIGINAL_PATH=$PATH

# A task worker cannot invoke the staging authority merely because it can read
# the home, while the lock-owning firstmate can create a sealed envelope.
make_fixture author-boundary
fixture_env
add_task author-boundary
node "$OWNER_JS" "$HOME_DIR/state/.lock" "$FIXTURE/idle-result" /usr/bin/true &
owner=$!
PIDS+=("$owner")
for _ in {1..100}; do
  [ -f "$HOME_DIR/state/.lock" ] && break
  sleep 0.02
done
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
pass "altered dispatch envelopes fail seal verification before claim"

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
for _ in {1..100}; do
  [ -f "$HOME_DIR/state/.lock" ] && break
  sleep 0.02
done
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
for _ in {1..100}; do
  [ -f "$HOME_DIR/state/.lock" ] && break
  sleep 0.02
done
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
for _ in {1..100}; do
  [ -f "$HOME_DIR/state/.lock" ] && break
  sleep 0.02
done
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

# The existing watcher loop owns invocation, with no new daemon entrypoint.
assert_contains "$(cat "$ROOT/bin/fm-watch.sh")" \
  "fm_auto_dispatch_tick" \
  "existing watcher loop does not invoke refill"
if rg -n 'while[[:space:]]+:' "$ROOT/bin/fm-auto-dispatch-once.sh" "$ROOT/bin/fm-auto-dispatch.mjs" >/dev/null; then
  fail "auto-dispatch introduced a second long-lived loop"
fi
pass "the existing supervision loop invokes the one-shot refill"
