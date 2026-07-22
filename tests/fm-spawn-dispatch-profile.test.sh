#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
TEST_SECURITY_BIN="$TMP_ROOT/security-bin"
mkdir -p "$TEST_SECURITY_BIN"
cat > "$TEST_SECURITY_BIN/security" <<'SH'
#!/usr/bin/env bash
exit 44
SH
chmod 700 "$TEST_SECURITY_BIN/security"
PATH="$TEST_SECURITY_BIN:$PATH"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*)
    [ "${FM_FAKE_TARGET_QUERY_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_TARGET_QUERY_STATUS}"
    if [ "$(cat "${FM_FAKE_TARGET_STATE:?}" 2>/dev/null)" != live ]; then
      printf '%s\n' "can't find window: ${3:-unknown}" >&2
      exit 1
    fi
    printf '%s\n' '@1'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_BACKEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_BACKEND_LOG"
    status=${FM_FAKE_BACKEND_KILL_STATUS:-0}
    [ "$status" -ne 0 ] || [ "${FM_FAKE_BACKEND_CLOSE_EFFECT:-gone}" != gone ] || printf '%s\n' gone > "${FM_FAKE_TARGET_STATE:?}"
    exit "$status"
    ;;
  has-session|new-session|new-window)
    [ -z "${FM_FAKE_BACKEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_BACKEND_LOG"
    exit 0
    ;;
  send-keys)
    literal=
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
          literal=$a
        fi
        prev=$a
      done
    fi
    case "$literal" in
      *'--create-activate '*)
        data=$(printf '%s\n' "$literal" | sed -n "s/.*--data '\\([^']*\\)'.*/\\1/p")
        home=$(printf '%s\n' "$literal" | sed -n "s/.*--home '\\([^']*\\)'.*/\\1/p")
        token=$(printf '%s\n' "$literal" | sed -n "s/.*--result-token '\\([0-9a-f]*\\)'.*/\\1/p")
        if [ -n "$data" ] && [ -n "$home" ]; then
          result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
          mkdir -p "$data/codex-crewmate"
          umask 077
          printf '%s %s\n' "${FM_FAKE_ACTIVATION_RESULT:-ready}" "$token" > "$result"
          chmod 600 "$result"
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_BACKEND_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_BACKEND_LOG"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:?}" ;;
  return)
    [ "${FM_FAKE_TREEHOUSE_CLOSE_EFFECT:-none}" != gone ] || printf '%s\n' gone > "${FM_FAKE_TARGET_STATE:?}"
    exit "${FM_FAKE_TREEHOUSE_RETURN_STATUS:-0}"
    ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_MKTEMP_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_MKTEMP_LOG"
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$fakebin/mktemp"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 target_state
  shift 4
  target_state="$(dirname "$launchlog")/target-state"
  : > "$launchlog"
  printf '%s\n' live > "$target_state"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_BACKEND_LOG="$(dirname "$launchlog")/backend.log" \
    FM_FAKE_TREEHOUSE_RETURN_STATUS="${FM_FAKE_TREEHOUSE_RETURN_STATUS:-0}" \
    FM_FAKE_BACKEND_KILL_STATUS="${FM_FAKE_BACKEND_KILL_STATUS:-0}" \
    FM_FAKE_BACKEND_CLOSE_EFFECT="${FM_FAKE_BACKEND_CLOSE_EFFECT:-gone}" \
    FM_FAKE_TREEHOUSE_CLOSE_EFFECT="${FM_FAKE_TREEHOUSE_CLOSE_EFFECT:-none}" \
    FM_FAKE_TARGET_QUERY_STATUS="${FM_FAKE_TARGET_QUERY_STATUS:-0}" \
    FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_ACTIVATION_RESULT="${FM_FAKE_ACTIVATION_RESULT:-ready}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    HOME="$CASE_DIR/user" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

codex_home_from_launch() {
  printf '%s\n' "$1" | sed -n "s/.*--home '\\([^']*\\)'.*/\\1/p"
}

codex_source_from_launch() {
  printf '%s\n' "$1" | sed -n "s/.*--source '\\([^']*\\)'.*/\\1/p"
}

codex_activation_result_from_launch() {
  local home
  home=$(codex_home_from_launch "$1")
  [ -z "$home" ] || printf '%s/.fm-codex-activation.%s\n' "$(dirname "$home")" "${home##*/}"
}

assert_private_activation_result() {  # <task-id> <result-path> <message>
  local id=$1 result=$2 message=$3 base
  base=${result%/*}
  case "$result" in
    */data/codex-crewmate/.fm-codex-activation..fm-codex-home.*) : ;;
    *) fail "$message: $result" ;;
  esac
  [ -d "$base" ] && [ ! -L "$base" ] || fail "$message: unsafe parent $base"
}

materialize_codex_home() {  # <home> <data> <source> <profile> <worktree>
  python3 "$ROOT/bin/fm-codex-home.py" --create-activate --data "$2" --source "$3" \
    --profile "$4" --worktree "$5" --home "$1" \
    --result-token 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef -- /bin/sh -c 'sleep 2' >/dev/null
  python3 "$ROOT/bin/fm-codex-home.py" --remove-activation-result --data "$2" --home "$1"
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_launch_unchanged() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and keeps the claude launch byte-identical"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_crewmate_home_excludes_mcp_and_plugins() {
  local rec ship scout out status launch crew_home source_home activation_result worktree_link worktree_real
  ship=profile-codex-home-ship-z17
  scout=profile-codex-home-scout-z18
  rec=$(make_spawn_case profile-codex-home codex "$ship" "$scout")
  read_case_record "$rec"
  worktree_link="$CASE_DIR/worktree-link"
  ln -s "$WT_DIR" "$worktree_link"
  worktree_real=$(cd "$worktree_link" && pwd -P)
  source_home="$CASE_DIR/user/.codex"
  mkdir -p "$source_home/plugins"
  printf '%s\n' '{"auth_mode":"chatgpt"}' > "$source_home/auth.json"
  printf '%s\n' '{"models":[]}' > "$source_home/models_cache.json"
  cat > "$source_home/config.toml" <<'EOF'
[mcp_servers.shared_memory]
command = "broken-memory-server"
[plugins."computer-use@openai-bundled"]
enabled = true
EOF
  mkdir -p "$WT_DIR/.codex"
  cat > "$WT_DIR/.codex/config.toml" <<'EOF'
[mcp_servers.project_memory]
command = "still-broken-memory-server"
[plugins."project-plugin@local"]
enabled = true
EOF

  out=$(run_spawn "$HOME_DIR" "$worktree_link" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ship" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex ship spawn should succeed with an isolated home"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  activation_result=$(codex_activation_result_from_launch "$launch")
  [ -n "$crew_home" ] || fail "Codex ship launch did not expose an isolated CODEX_HOME"
  assert_private_activation_result "$ship" "$activation_result" "Codex ship launch did not use a private activation result"
  assert_contains "$launch" "--home '$crew_home' --result-token '" \
    "Codex ship launch did not authenticate the isolated-home activation"
  assert_contains "$launch" "-- codex --profile 'fm-crewmate-$ship' --disable plugins" \
    "Codex ship launch did not activate the isolated CODEX_HOME"
  assert_contains "$launch" "--worktree '$worktree_real'" \
    "Codex ship launch did not use the physical worktree for its trust profile"
  assert_not_contains "$launch" "--worktree '$worktree_link'" \
    "Codex ship launch used the logical worktree for its trust profile"
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$source_home" "fm-crewmate-$ship" "$worktree_real"
  assert_contains "$out" "warning: Codex crewmate ignores project config" \
    "Codex ship launch did not warn that project Codex config was ignored"
  assert_contains "$out" "$worktree_real/.codex/config.toml to keep MCPs and plugins disabled" \
    "Codex ship launch did not warn that project Codex config was ignored"
  assert_present "$crew_home/config.toml" "isolated Codex config was not created"
  assert_grep "codex_crewmate_home=$crew_home" "$HOME_DIR/state/$ship.meta" \
    "Codex ship metadata did not retain its isolated home for cleanup"
  assert_no_grep 'mcp_servers' "$crew_home/config.toml" \
    "isolated Codex config retained MCP server entries"
  assert_grep 'plugins = false' "$crew_home/config.toml" \
    "isolated Codex config did not disable plugins"
  assert_no_grep '[plugins.' "$crew_home/config.toml" \
    "isolated Codex config retained plugin registrations"
  assert_grep "trust_level = \"untrusted\"" "$crew_home/config.toml" \
    "isolated Codex base config did not persist project trust"
  assert_grep "$worktree_real" "$crew_home/config.toml" \
    "isolated Codex base config did not scope untrusted trust to the worktree"
  assert_grep "trust_level = \"untrusted\"" "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile did not disable project config trust"
  assert_grep '[projects.' "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile did not scope untrusted trust to the project"
  assert_grep "$worktree_real" "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile did not scope untrusted trust to the worktree"
  assert_no_grep "$PROJ_DIR" "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile must not scope untrusted trust to the primary project"
  [ ! -e "$crew_home/plugins" ] || fail "isolated Codex home retained a plugins directory"
  cmp -s "$source_home/auth.json" "$crew_home/auth.json" \
    || fail "isolated Codex home did not refresh authentication"
  cmp -s "$source_home/models_cache.json" "$crew_home/models_cache.json" \
    || fail "isolated Codex home did not refresh the model catalog"
  [ ! -L "$crew_home/auth.json" ] || fail "isolated Codex auth must not point into the captain home"

  mkdir -p "$HOME_DIR/data/codex-crewmate/fm-crewmate-$scout/plugins/stale-plugin"
  out=$(run_spawn "$HOME_DIR" "$worktree_link" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$scout" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "Codex scout spawn should use the isolated home"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  activation_result=$(codex_activation_result_from_launch "$launch")
  [ -n "$crew_home" ] || fail "Codex scout launch did not expose an isolated CODEX_HOME"
  assert_private_activation_result "$scout" "$activation_result" "Codex scout launch did not use a private activation result"
  assert_contains "$launch" "--home '$crew_home' --result-token '" \
    "Codex scout launch did not authenticate the isolated-home activation"
  assert_contains "$launch" "-- codex --profile 'fm-crewmate-$scout' --disable plugins" \
    "Codex scout launch did not activate the isolated CODEX_HOME"
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$source_home" "fm-crewmate-$scout" "$worktree_real"
  assert_no_grep 'mcp_servers' "$crew_home/config.toml" \
    "Codex scout refresh reintroduced MCP server entries"
  assert_grep 'plugins = false' "$crew_home/config.toml" \
    "Codex scout refresh did not disable plugins"
  assert_no_grep '[plugins.' "$crew_home/config.toml" \
    "Codex scout refresh reintroduced plugin registrations"
  [ ! -e "$crew_home/plugins" ] || fail "Codex scout home retained plugins"
  pass "Codex ship and scout launches use fresh MCP-free homes"
}

test_codex_crewmate_home_honors_codex_home_override() {
  local rec id out status launch source_home
  id=profile-codex-home-override-z69
  rec=$(make_spawn_case profile-codex-home-override codex "$id")
  read_case_record "$rec"
  source_home="$CASE_DIR/explicit-codex-home"
  mkdir -p "$source_home"

  out=$(CODEX_HOME="$source_home" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should honor an explicit CODEX_HOME"
  launch=$(cat "$LAUNCH_LOG")
  [ "$(codex_source_from_launch "$launch")" = "$source_home" ] \
    || fail "Codex launch did not source its isolated home from explicit CODEX_HOME"
  pass "Codex isolated home honors an explicit CODEX_HOME source"
}

test_codex_crewmate_home_uses_fresh_private_directory() {
  local rec id out status source_home legacy_home crew_home launch home_base home_parent
  id=profile-codex-home-fresh-z19
  rec=$(make_spawn_case profile-codex-home-fresh codex "$id")
  read_case_record "$rec"
  source_home="$CASE_DIR/user/.codex"
  legacy_home="$HOME_DIR/data/codex-crewmate/fm-crewmate-$id"
  mkdir -p "$source_home" "$legacy_home/plugins/stale-plugin" "$legacy_home/config.toml"
  printf '%s\n' 'legacy-config' > "$legacy_home/auth.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should not reuse a legacy isolated home"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  [ -n "$crew_home" ] || fail "Codex launch did not expose a fresh isolated CODEX_HOME"
  [ "$crew_home" != "$legacy_home" ] || fail "Codex launch reused the legacy isolated home"
  home_base=$(cd "$HOME_DIR/data/codex-crewmate" && pwd -P)
  home_parent=$(cd "$(dirname "$crew_home")" && pwd -P)
  case "${crew_home##*/}" in .fm-codex-home.*) : ;; *) fail "Codex launch did not use a private per-task home: $crew_home" ;; esac
  [ "$home_parent" = "$home_base" ] || fail "Codex launch did not use a private per-task home: $crew_home"
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$source_home" "fm-crewmate-$id" "$WT_DIR"
  [ ! -e "$crew_home/plugins" ] || fail "fresh Codex home inherited legacy plugins"
  assert_not_contains "$(cat "$crew_home/auth.json" 2>/dev/null || true)" "legacy-config" \
    "fresh Codex home inherited legacy authentication"
  pass "Codex spawn uses a fresh private isolated home"
}

test_codex_crewmate_home_is_removed_at_teardown() {
  local rec id out status launch crew_home target_state
  id=profile-codex-home-teardown-z30
  rec=$(make_spawn_case profile-codex-home-teardown codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a private home before teardown"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  [ -d "$crew_home" ] || fail "Codex spawn did not create the private home to be torn down"
  target_state="$CASE_DIR/target-state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should remove a recorded Codex private home"
  [ ! -e "$crew_home" ] || fail "teardown left the credential-bearing Codex private home behind"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown should remove metadata only after private-home cleanup"
  pass "teardown removes the recorded private Codex home"
}

test_codex_teardown_preserves_home_referenced_by_another_task() {
  local rec id sibling out status launch crew_home sibling_home target_state meta
  id=profile-codex-home-owner-z80
  sibling=profile-codex-home-owner-z81
  rec=$(make_spawn_case profile-codex-home-owner codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a private home ownership case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  sibling_home="$HOME_DIR/data/codex-crewmate/.fm-codex-home.sibling$RANDOM"
  materialize_codex_home "$sibling_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$sibling" "$WT_DIR"
  meta="$HOME_DIR/state/$id.meta"
  sed "s|^codex_crewmate_home=.*|codex_crewmate_home=$sibling_home|" "$meta" > "$meta.next" && mv "$meta.next" "$meta"
  fm_write_meta "$HOME_DIR/state/$sibling.meta" \
    "window=fm-$sibling" "worktree=$WT_DIR" "project=$PROJ_DIR" "harness=codex" \
    "kind=ship" "mode=no-mistakes" "codex_crewmate_home=$sibling_home"
  target_state="$CASE_DIR/target-state"
  printf 'gone\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must reject another task's Codex home"
  assert_contains "$out" "referenced by another active task" \
    "teardown did not explain the conflicting Codex-home metadata"
  [ -d "$sibling_home" ] || fail "teardown removed the sibling task's credential home"
  [ -f "$meta" ] || fail "teardown discarded metadata after rejecting a sibling Codex home"
  [ ! -e "$crew_home" ] || fail "test setup unexpectedly materialized the original Codex home"
  pass "teardown preserves a Codex home referenced by another task"
}

test_codex_teardown_refuses_home_owned_by_another_task() {
  local rec id sibling out status launch sibling_home target_state meta
  id=profile-codex-home-profile-z83
  sibling=profile-codex-home-profile-z84
  rec=$(make_spawn_case profile-codex-home-profile codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a private home profile case"
  launch=$(cat "$LAUNCH_LOG")
  sibling_home="$HOME_DIR/data/codex-crewmate/.fm-codex-home.sibling$RANDOM"
  materialize_codex_home "$sibling_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$sibling" "$WT_DIR"
  meta="$HOME_DIR/state/$id.meta"
  sed "s|^codex_crewmate_home=.*|codex_crewmate_home=$sibling_home|" "$meta" > "$meta.next" && mv "$meta.next" "$meta"
  target_state="$CASE_DIR/target-state"
  printf 'gone\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must reject a Codex home owned by another task"
  assert_contains "$out" "does not belong to task $id" \
    "teardown did not explain the mismatched Codex-home profile"
  [ -d "$sibling_home" ] || fail "teardown removed the sibling task's credential home"
  [ -f "$meta" ] || fail "teardown discarded metadata after rejecting a mismatched Codex home"
  pass "teardown verifies the Codex home belongs to its task"
}

test_codex_teardown_preserves_home_when_normal_endpoint_close_fails() {
  local rec id out status launch crew_home target_state
  id=profile-codex-normal-endpoint-z84
  rec=$(make_spawn_case profile-codex-normal-endpoint codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a normal teardown endpoint case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  target_state="$CASE_DIR/target-state"
  printf 'live\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" FM_FAKE_BACKEND_KILL_STATUS=75 PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "normal Codex teardown must retain state when endpoint close fails"
  assert_contains "$out" "preserving recovery metadata" \
    "normal Codex teardown did not explain retained recovery state"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "normal Codex teardown discarded recovery metadata"
  [ -d "$crew_home" ] || fail "normal Codex teardown removed the credential home before close confirmation"
  pass "normal Codex teardown retains its home until the endpoint is confirmed absent"
}

test_codex_teardown_accepts_an_already_absent_endpoint() {
  local rec id out status launch crew_home target_state
  id=profile-codex-absent-endpoint-z85
  rec=$(make_spawn_case profile-codex-absent-endpoint codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare an already-absent endpoint case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  target_state="$CASE_DIR/target-state"
  printf 'gone\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" FM_FAKE_BACKEND_KILL_STATUS=75 PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should accept an endpoint already confirmed absent"
  assert_no_grep "kill-window" "$CASE_DIR/backend.log" \
    "teardown should not strictly close an already absent endpoint"
  [ ! -e "$crew_home" ] || fail "teardown retained the credential home after confirming endpoint absence"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown retained metadata after confirming endpoint absence"
  pass "Codex teardown accepts a confirmed already-absent endpoint"
}

test_codex_crewmate_home_refuses_symlink_escape() {
  local rec id out status source_home crew_root
  id=profile-codex-home-symlink-z21
  rec=$(make_spawn_case profile-codex-home-symlink codex "$id")
  read_case_record "$rec"
  source_home="$CASE_DIR/user/.codex"
  crew_root="$HOME_DIR/data/codex-crewmate"
  mkdir -p "$source_home/plugins"
  printf '%s\n' 'captain-config' > "$source_home/config.toml"
  ln -s "$source_home" "$crew_root"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must reject a symlinked isolated home"
  assert_contains "$out" "could not prepare isolated Codex crewmate home" \
    "Codex spawn did not report the symlink escape"
  assert_grep 'captain-config' "$source_home/config.toml" \
    "symlink rejection must not overwrite the captain Codex config"
  [ -d "$source_home/plugins" ] || fail "symlink rejection must not remove captain plugins"
  assert_absent "$HOME_DIR/state/$id.meta" "symlink rejection must not create task metadata"
  assert_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "symlink rejection did not return its worktree"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "symlink rejection did not remove its task endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "symlink rejection must not launch Codex"
  pass "Codex spawn refuses isolated-home symlink escapes"
}

test_codex_crewmate_home_refuses_symlinked_data_root() {
  local rec id out status data_root real_data
  id=profile-codex-data-root-symlink-z36
  rec=$(make_spawn_case profile-codex-data-root-symlink codex "$id")
  read_case_record "$rec"
  data_root="$HOME_DIR/data"
  real_data="$CASE_DIR/real-data"
  mv "$data_root" "$real_data"
  ln -s "$real_data" "$data_root"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must reject a symlinked data root"
  assert_contains "$out" "could not prepare isolated Codex crewmate home" \
    "Codex spawn did not report the data-root symlink escape"
  assert_absent "$real_data/codex-crewmate" "data-root symlink rejection must not create a Codex home"
  assert_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "data-root symlink rejection did not return its worktree"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "data-root symlink rejection did not remove its task endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "data-root symlink rejection must not launch Codex"
  pass "Codex spawn refuses a symlinked data root"
}

test_codex_crewmate_profile_rejects_toml_control_characters() {
  local data source out status worktree
  data="$CASE_DIR/control-data"
  source="$CASE_DIR/control-source"
  worktree=$'safe\n[mcp_servers.injected]'
  mkdir -p "$data" "$source"

  out=$(python3 "$ROOT/bin/fm-codex-home.py" --data "$data" --source "$source" \
    --profile fm-crewmate-control-z37 --worktree "$worktree" 2>&1)
  status=$?
  expect_code 1 "$status" "Codex home creation must reject TOML control characters"
  assert_contains "$out" "TOML control character" \
    "Codex home creation did not explain the unsafe TOML path"
  assert_absent "$data/codex-crewmate" "unsafe TOML path must not create a Codex home"
  pass "Codex profile rejects TOML control characters"
}

test_codex_crewmate_home_fails_when_private_home_creation_fails() {
  local rec id out status
  id=profile-codex-home-create-z23
  rec=$(make_spawn_case profile-codex-home-create codex "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/python3" <<'SH'
#!/usr/bin/env bash
exit 74
SH
  chmod +x "$FAKEBIN_DIR/python3"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when its private home cannot be created"
  assert_contains "$out" "could not prepare isolated Codex crewmate home" \
    "Codex spawn did not report private-home preparation failure"
  assert_absent "$HOME_DIR/state/$id.meta" "private-home preparation failure must not create task metadata"
  assert_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "private-home preparation failure did not return its worktree"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "private-home preparation failure did not remove its task endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "private-home preparation failure must not launch Codex"
  pass "Codex spawn cleans up a failed private-home allocation"
}

test_raw_codex_launch_is_normalized() {
  local command case_name rec id out status launch crew_home activation_result n=0
  for case_name in mixed-case absolute-mixed-case env-wrapper absolute-env-wrapper command-wrapper nested-wrapper exec-wrapper; do
    n=$((n + 1))
    id="profile-raw-codex-$n-z24"
    rec=$(make_spawn_case "profile-raw-codex-$n" codex "$id")
    read_case_record "$rec"
    case "$case_name" in
      mixed-case) command='CODEX_HOME=/unsafe Codex' ;;
      absolute-mixed-case) command='CODEX_HOME=/unsafe /opt/firstmate/Codex' ;;
      env-wrapper) command='env CODEX_HOME=/unsafe codex' ;;
      absolute-env-wrapper) command='CODEX_HOME=/unsafe /usr/bin/env codex' ;;
      command-wrapper) command='command codex CODEX_HOME=/unsafe' ;;
      nested-wrapper) command='command env CODEX_HOME=/unsafe codex' ;;
      exec-wrapper) command='exec codex CODEX_HOME=/unsafe' ;;
    esac

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command")
    status=$?
    expect_code 0 "$status" "$case_name raw Codex launch should be normalized"
    assert_contains "$out" "spawned $id harness=codex" "$case_name raw Codex launch did not report Codex"
    launch=$(cat "$LAUNCH_LOG")
    crew_home=$(codex_home_from_launch "$launch")
    activation_result=$(codex_activation_result_from_launch "$launch")
    [ -n "$crew_home" ] || fail "$case_name raw Codex launch did not expose an isolated CODEX_HOME"
    assert_private_activation_result "$id" "$activation_result" "$case_name raw Codex launch did not use a private activation result"
    assert_contains "$launch" "--home '$crew_home' --result-token '" \
      "$case_name raw Codex launch did not authenticate the isolated-home activation"
    assert_contains "$launch" "-- codex --profile 'fm-crewmate-$id' --disable plugins" \
      "$case_name raw Codex launch did not enforce the isolated profile"
    assert_not_contains "$launch" '/unsafe' "$case_name raw CODEX_HOME assignment survived normalization"
  done
  pass "raw Codex launch is normalized to the isolated profile"
}

test_raw_codex_execution_wrappers_fail_closed() {
  local command case_name rec id out status n=0
  for case_name in nice nice-option shell shell-multicommand shell-script sourced-script script-path sudo-user timeout-duration script find xargs unknown-wrapper eval builtin-eval interpreter; do
    n=$((n + 1))
    id="profile-raw-codex-wrapper-$n-z31"
    rec=$(make_spawn_case "profile-raw-codex-wrapper-$n" codex "$id")
    read_case_record "$rec"
    case "$case_name" in
      nice) command='nice codex' ;;
      nice-option) command='nice -n 1 env CODEX_HOME=/unsafe codex' ;;
      shell) command='sh -c codex' ;;
      shell-multicommand) command="sh -c 'true; CODEX_HOME=/unsafe codex'" ;;
      shell-script) command='sh -c ./launch-worker' ;;
      sourced-script) command='source ./launch-worker' ;;
      script-path) command='./launch-worker.sh --background' ;;
      sudo-user) command='sudo -u crew CODEX_HOME=/unsafe codex' ;;
      timeout-duration) command='timeout 5 CODEX_HOME=/unsafe codex' ;;
      script) command='script -q /dev/null codex' ;;
      find) command='find . -exec codex {} \;' ;;
      xargs) command='xargs -a jobs codex' ;;
      unknown-wrapper) command='custom-wrapper codex' ;;
      eval) command="eval \"\$COMMAND\"" ;;
      builtin-eval) command="builtin eval \"\$COMMAND\"" ;;
      interpreter) command="python3 -c 'os.execvp(\"codex\", [\"codex\"])'" ;;
    esac

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command")
    status=$?
    expect_code 1 "$status" "$case_name raw Codex wrapper must fail closed"
    assert_contains "$out" "unsafe raw launch command" \
      "$case_name raw Codex wrapper did not explain the refusal"
    assert_absent "$HOME_DIR/state/$id.meta" "$case_name raw Codex wrapper must fail before task allocation"
    if [ -e "$CASE_DIR/backend.log" ]; then
      assert_no_grep "new-window -t firstmate" "$CASE_DIR/backend.log" \
        "$case_name raw Codex wrapper must not allocate an endpoint"
    fi
    [ ! -s "$LAUNCH_LOG" ] || fail "$case_name raw Codex wrapper must not launch Codex"
  done
  pass "raw Codex execution wrappers fail closed"
}

test_raw_codex_late_home_assignment_is_normalized() {
  local rec id out status launch crew_home
  id=profile-raw-codex-unsafe-z25
  rec=$(make_spawn_case profile-raw-codex-unsafe codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "codex CODEX_HOME=/unsafe")
  status=$?
  expect_code 0 "$status" "raw Codex launch with a late CODEX_HOME assignment should normalize"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  [ -n "$crew_home" ] || fail "late CODEX_HOME assignment bypassed the isolated home"
  assert_not_contains "$launch" '/unsafe' "late raw CODEX_HOME assignment survived normalization"
  pass "late raw CODEX_HOME assignments cannot bypass the isolated home"
}

test_raw_codex_options_fail_closed() {
  local rec id out status
  id=profile-raw-codex-options-z46
  rec=$(make_spawn_case profile-raw-codex-options codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "codex --model gpt-5")
  status=$?
  expect_code 1 "$status" "raw Codex options must fail closed rather than being dropped"
  assert_contains "$out" "raw Codex launch options are not supported" \
    "raw Codex options did not explain the refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "raw Codex option refusal must happen before task allocation"
  [ ! -s "$LAUNCH_LOG" ] || fail "raw Codex options must not launch a default Codex command"
  pass "raw Codex options fail closed instead of being dropped"
}

test_quoted_or_escaped_raw_codex_launch_fails_closed() {
  local command case_name rec id out status n=0
  for case_name in quoted escaped; do
    n=$((n + 1))
    id="profile-raw-codex-shell-$n-z27"
    rec=$(make_spawn_case "profile-raw-codex-shell-$n" codex "$id")
    read_case_record "$rec"
    case "$case_name" in
      quoted) command="CODEX_HOME=/unsafe 'codex'" ;;
      escaped) command='CODEX_HOME=/unsafe co\de\x' ;;
    esac

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command")
    status=$?
    expect_code 1 "$status" "$case_name raw Codex launch must fail closed"
    assert_contains "$out" "unsafe raw launch command" \
      "$case_name raw Codex launch did not explain the refusal"
    assert_absent "$HOME_DIR/state/$id.meta" "$case_name raw Codex launch must fail before task allocation"
    if [ -e "$CASE_DIR/backend.log" ]; then
      assert_no_grep "new-window -t firstmate" "$CASE_DIR/backend.log" \
        "$case_name raw Codex launch must fail before endpoint allocation"
    fi
    [ ! -s "$LAUNCH_LOG" ] || fail "$case_name raw Codex launch must not launch Codex"
  done
  pass "quoted and escaped raw Codex launches fail closed"
}

test_quoted_raw_custom_launch_remains_supported() {
  local command case_name rec id out status launch n=0
  for case_name in quoted shell-variable env-option env-s shell-command builtin codex-model; do
    n=$((n + 1))
    id="profile-raw-custom-$n-z29"
    rec=$(make_spawn_case "profile-raw-custom-$n" claude "$id")
    read_case_record "$rec"
    case "$case_name" in
      quoted) command="custom-agent --prompt 'review this'" ;;
      shell-variable) command="custom-agent --prompt \"\$PROMPT\"" ;;
      env-option) command='env -i custom-agent --prompt review' ;;
      env-s) command="env -S 'custom-agent --prompt review'" ;;
      shell-command) command="sh -c 'custom-agent --prompt review'" ;;
      builtin) command='builtin printf review' ;;
      codex-model) command='custom-agent --model codex' ;;
    esac
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command" )
    status=$?
    expect_code 0 "$status" "$case_name raw custom launch should remain supported"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "$command" \
      "$case_name raw custom launch was not preserved"
    assert_not_contains "$launch" "CODEX_HOME=" \
      "$case_name raw custom launch was incorrectly normalized as Codex"
  done
  pass "quoted raw custom launches retain their existing behavior"
}

test_raw_custom_dynamic_execution_fails_closed() {
  local command case_name rec id out status n=0
  for case_name in command-substitution backticks process-substitution; do
    n=$((n + 1))
    id="profile-raw-custom-dynamic-$n-z59"
    rec=$(make_spawn_case "profile-raw-custom-dynamic-$n" claude "$id")
    read_case_record "$rec"
    case "$case_name" in
      command-substitution) command="custom-agent \"\$(CODEX_HOME=/unsafe codex)\"" ;;
      backticks) command="custom-agent \"\`CODEX_HOME=/unsafe codex\`\"" ;;
      process-substitution) command='custom-agent <(CODEX_HOME=/unsafe codex)' ;;
    esac
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command")
    status=$?
    expect_code 1 "$status" "$case_name raw custom launch must fail closed"
    assert_contains "$out" "unsafe raw launch command" \
      "$case_name raw custom launch did not explain the refusal"
    assert_absent "$HOME_DIR/state/$id.meta" "$case_name raw custom launch must fail before task allocation"
    [ ! -s "$LAUNCH_LOG" ] || fail "$case_name raw custom launch must not run Codex"
  done
  pass "raw custom dynamic execution fails closed"
}

test_raw_script_dispatches_fail_closed() {
  local command case_name rec id out status n=0
  for case_name in shell-multicommand relative-extensionless; do
    n=$((n + 1))
    id="profile-raw-script-$n-z75"
    rec=$(make_spawn_case "profile-raw-script-$n" claude "$id")
    read_case_record "$rec"
    case "$case_name" in
      shell-multicommand) command="sh -c 'true; CODEX_HOME=/unsafe codex'" ;;
      relative-extensionless) command='./launch-worker --run' ;;
    esac

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command")
    status=$?
    expect_code 1 "$status" "$case_name raw script dispatch must fail closed"
    assert_contains "$out" "unsafe raw launch command" \
      "$case_name raw script dispatch did not explain the refusal"
    assert_absent "$HOME_DIR/state/$id.meta" "$case_name raw script dispatch must fail before task allocation"
    [ ! -s "$LAUNCH_LOG" ] || fail "$case_name raw script dispatch must not launch"
  done
  pass "raw script dispatches fail closed"
}

test_codex_crewmate_home_uses_private_directory() {
  local rec id out status crew_home launch staging
  id=profile-codex-home-staging-z28
  rec=$(make_spawn_case profile-codex-home-staging codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should create an isolated private home"
  assert_grep 'O_NOFOLLOW' "$ROOT/bin/fm-codex-home.py" \
    "Codex home construction must use no-follow file descriptors"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  [ -n "$crew_home" ] || fail "Codex launch did not expose its private home"
  assert_contains "$launch" "exec python3 '$ROOT/bin/fm-codex-home.py' --create-activate" \
    "Codex launch must activate its home through the descriptor-safe helper"
  assert_not_contains "$launch" "CODEX_HOME=" \
    "Codex launch must not pass a mutable CODEX_HOME pathname"
  staging=
  if [ -d "$HOME_DIR/data/codex-crewmate" ]; then
    staging=$(find "$HOME_DIR/data/codex-crewmate" -maxdepth 1 -type d -name '.fm-codex-stage.*' -print -quit)
  fi
  [ -z "$staging" ] || fail "Codex home refresh left stale staging behind: $staging"
  pass "Codex home refresh uses a private per-task directory"
}

test_codex_home_activation_uses_open_descriptor() {
  local data source home result token out
  data="$TMP_ROOT/codex-activation-data"
  source="$TMP_ROOT/codex-activation-source"
  mkdir -p "$data" "$source"
  home="$data/codex-crewmate/$(python3 "$ROOT/bin/fm-codex-home.py" --data "$data" --new-home-name)"
  result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
  token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  out=$(python3 "$ROOT/bin/fm-codex-home.py" --create-activate --data "$data" --source "$source" \
    --profile fm-crewmate-activation-z42 --worktree /tmp/fm-codex-activation --home "$home" --result-token "$token" -- /bin/sh -c "printf 'CODEX_HOME=%s\\n' \"\$CODEX_HOME\"; sleep 2")
  codex_home_value=$(printf '%s\n' "$out" | sed -n 's/^CODEX_HOME=//p' | head -n 1)
  [ -n "$codex_home_value" ] || fail "Codex activation must export CODEX_HOME to the child"
  case "$codex_home_value" in
    /dev/fd/*) fail "Codex activation must not hand the child an fd-shaped CODEX_HOME (macOS cannot open it as a directory): $codex_home_value" ;;
  esac
  [ -d "$codex_home_value" ] || fail "Codex activation must hand the child an openable real home directory: $codex_home_value"
  [ "${codex_home_value##*/}" = "${home##*/}" ] || fail "Codex activation CODEX_HOME must resolve to the managed home: $codex_home_value"
  assert_contains "$(cat "$result")" ready "Codex activation must report readiness before launch"
  python3 "$ROOT/bin/fm-codex-home.py" --remove-activation-result --data "$data" --home "$home"
  mkdir -p "$(dirname "$data")/state"
  python3 "$ROOT/bin/fm-codex-home.py" --remove --data "$data" --state "$(dirname "$data")/state" --task-id activation-z42 --home "$home"
  assert_absent "$home" "descriptor-activated Codex home must remain removable"
  pass "Codex activation passes a real-path home resolved from the retained descriptor"
}

test_codex_home_removal_preserves_a_replacement_after_validation() {
  local data state home status
  data="$TMP_ROOT/codex-remove-replaced-data"
  state="$TMP_ROOT/codex-remove-replaced-state"
  home="$data/codex-crewmate/.fm-codex-home.0123456789abcdef0123456789abcdef"
  mkdir -p "$home" "$state"
  : > "$home/fm-crewmate-owner.config.toml"

  python3 - "$ROOT/bin/fm-codex-home.py" "$data" "$state" "$home" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
from types import SimpleNamespace

helper, data, state, home = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_codex_home", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_open = module.open_directory
original_close = module.os.close
target = {"fd": None, "replaced": False}

def open_directory(name, directory_fd=None):
    fd = original_open(name, directory_fd)
    if name == os.path.basename(home) and target["fd"] is None:
        target["fd"] = fd
    return fd

def close(fd):
    original_close(fd)
    if fd == target["fd"] and not target["replaced"]:
        target["replaced"] = True
        os.rename(home, home + ".validated")
        os.mkdir(home, 0o700)
        with open(os.path.join(home, "replacement"), "w", encoding="utf-8") as file:
            file.write("preserve")

module.open_directory = open_directory
module.os.close = close
with contextlib.redirect_stderr(io.StringIO()):
    try:
        module.remove_home(
            SimpleNamespace(data=data, state=state, task_id="owner", home=home, create_activate=False)
        )
    except SystemExit as error:
        if error.code != 1:
            raise
    else:
        raise AssertionError("removal accepted a replacement home")
if not os.path.isfile(os.path.join(home, "replacement")):
    raise AssertionError("removal deleted the replacement home")
PY
  status=$?
  expect_code 0 "$status" "Codex removal must preserve a home replaced after ownership validation"
  [ -f "$home/replacement" ] || fail "Codex removal deleted a replacement home"
  pass "Codex removal preserves a replacement after ownership validation"
}

test_codex_home_activation_reports_exec_failure() {
  local data source home result token out status
  data="$TMP_ROOT/codex-activation-exec-failure-data"
  source="$TMP_ROOT/codex-activation-exec-failure-source"
  mkdir -p "$data" "$source"
  home="$data/codex-crewmate/$(python3 "$ROOT/bin/fm-codex-home.py" --data "$data" --new-home-name)"
  result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
  token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  out=$(python3 "$ROOT/bin/fm-codex-home.py" --create-activate --data "$data" --source "$source" \
    --profile fm-crewmate-exec-failure-z44 --worktree /tmp/fm-codex-exec-failure --home "$home" --result-token "$token" -- /definitely/missing/codex 2>&1)
  status=$?
  expect_code 1 "$status" "Codex activation must fail when its launch command cannot exec"
  assert_contains "$(cat "$result")" failed "Codex activation must report exec failures as failed"
  assert_absent "$home" "Codex activation must remove a home after an exec failure"
  pass "Codex activation reports exec failures before ready"
}

test_codex_home_activation_refuses_replaced_path() {
  local data source name home result token out status
  data="$TMP_ROOT/codex-activation-race-data"
  source="$TMP_ROOT/codex-activation-race-source"
  mkdir -p "$data" "$source"
  name=$(python3 "$ROOT/bin/fm-codex-home.py" --data "$data" --new-home-name)
  home="$data/codex-crewmate/$name"
  result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
  token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  mkdir -p "$home"
  out=$(python3 "$ROOT/bin/fm-codex-home.py" --create-activate --data "$data" --source "$source" \
    --profile fm-crewmate-race-z43 --worktree /tmp/fm-codex-race --home "$home" --result-token "$token" -- /usr/bin/env 2>&1)
  status=$?
  expect_code 1 "$status" "Codex activation must reject a replaced planned home"
  assert_contains "$out" "already exists" "Codex activation did not reject the replaced planned home"
  assert_contains "$(cat "$result")" failed "Codex activation failure must report failure"
  pass "Codex activation rejects replaced planned homes"
}

test_codex_home_activation_result_refuses_symlink() {
  local data home result target token out status
  data=$(mktemp -d "$TMP_ROOT/codex-activation-result.XXXXXXXX")
  home="$data/codex-crewmate/.fm-codex-home.0123456789abcdef0123456789abcdef"
  result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
  target="$data/codex-crewmate/target"
  mkdir -p "$data/codex-crewmate"
  token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  printf 'ready %s\n' "$token" > "$target"
  chmod 600 "$target"
  ln -s target "$result"
  out=$(python3 "$ROOT/bin/fm-codex-home.py" --read-activation-result --data "$data" --home "$home" --result-token "$token" 2>&1)
  status=$?
  expect_code 1 "$status" "Codex activation must reject a symlinked result"
  assert_contains "$out" "result is unsafe" "Codex activation result reader accepted a symlink"
  pass "Codex activation result reader rejects symlinks"
}

test_codex_home_activation_refuses_existing_result() {
  local data source home result token out status
  data=$(mktemp -d "$TMP_ROOT/codex-activation-existing-result.XXXXXXXX")
  source="$TMP_ROOT/codex-activation-existing-result-source"
  mkdir -p "$data/codex-crewmate" "$source"
  home="$data/codex-crewmate/.fm-codex-home.0123456789abcdef0123456789abcdef"
  result="$data/codex-crewmate/.fm-codex-activation.${home##*/}"
  token=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  printf 'ready %s\n' "$token" > "$result"
  chmod 600 "$result"
  out=$(python3 "$ROOT/bin/fm-codex-home.py" --create-activate --data "$data" --source "$source" \
    --profile fm-crewmate-existing-result-z68 --worktree /tmp/fm-codex-existing-result --home "$home" --result-token "$token" -- /usr/bin/env 2>&1)
  status=$?
  expect_code 1 "$status" "Codex activation must refuse an existing result"
  assert_contains "$out" "could not record isolated Codex home activation" \
    "Codex activation did not report an existing result safely"
  assert_absent "$home" "existing activation result must not create a Codex home"
  pass "Codex activation refuses an existing managed result"
}

test_codex_home_activation_failure_aborts_spawn() {
  local rec id out status task_tmp
  id=profile-codex-home-activation-z45
  rec=$(make_spawn_case profile-codex-home-activation codex "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_ACTIVATION_RESULT=failed run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when terminal activation fails"
  assert_contains "$out" "isolated Codex home activation failed" \
    "Codex spawn did not report terminal activation failure"
  assert_grep 'failed_spawn=1' "$HOME_DIR/state/$id.meta" \
    "terminal activation failure did not retain recovery metadata"
  assert_grep 'treehouse_lease=1' "$HOME_DIR/state/$id.meta" \
    "terminal activation failure did not retain its committed lease"
  assert_no_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "terminal activation failure must not return a committed lease implicitly"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "terminal activation failure did not remove its task endpoint"
  for task_tmp in "/tmp/fm-$id".*; do
    [ ! -e "$task_tmp" ] || fail "terminal activation failure left task temporary root: $task_tmp"
  done
  pass "Codex spawn retains terminal activation failures for safe teardown"
}

test_codex_activation_uses_managed_data_root() {
  local rec id out status target legacy_path launch activation_result
  id=profile-codex-activation-parent-z67
  rec=$(make_spawn_case profile-codex-activation-parent codex "$id")
  read_case_record "$rec"
  target="$CASE_DIR/activation-target"
  legacy_path="/tmp/fm-$id"
  mkdir -p "$target"
  rm -f "$legacy_path"
  ln -s "$target" "$legacy_path" || fail "could not create predictable task-temp symlink"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  rm -f "$legacy_path"
  expect_code 0 "$status" "Codex spawn must not follow a predictable task-temp symlink"
  launch=$(cat "$LAUNCH_LOG")
  activation_result=$(codex_activation_result_from_launch "$launch")
  assert_private_activation_result "$id" "$activation_result" "Codex activation did not use the managed data root"
  assert_not_contains "$launch" "--result-file" \
    "Codex activation must not pass a mutable task-temporary result path"
  [ ! -e "$target/result" ] || fail "Codex activation followed the predictable task-temp symlink"
  pass "Codex activation uses the descriptor-validated managed data root"
}

test_codex_teardown_preserves_failed_endpoint_metadata() {
  local rec id out status launch crew_home target_state
  id=profile-codex-failed-endpoint-z40
  rec=$(make_spawn_case profile-codex-failed-endpoint codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a failed-endpoint recovery case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  printf 'failed_spawn=1\nendpoint_cleanup_pending=1\n' >> "$HOME_DIR/state/$id.meta"
  target_state="$CASE_DIR/target-state"
  printf 'live\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" FM_FAKE_BACKEND_KILL_STATUS=75 PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must retain failed-spawn metadata when endpoint close fails"
  assert_contains "$out" "preserving recovery metadata" \
    "teardown did not explain the retained failed-spawn recovery state"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "failed endpoint teardown discarded recovery metadata"
  [ -d "$crew_home" ] || fail "failed endpoint teardown removed the credential home before close confirmation"
  pass "failed endpoint teardown retains recovery metadata until close succeeds"
}

test_codex_teardown_preserves_metadata_when_successful_close_leaves_endpoint_live() {
  local rec id out status launch crew_home target_state
  id=profile-codex-unconfirmed-endpoint-z68
  rec=$(make_spawn_case profile-codex-unconfirmed-endpoint codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare an unconfirmed-endpoint recovery case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  printf 'failed_spawn=1\nendpoint_cleanup_pending=1\n' >> "$HOME_DIR/state/$id.meta"
  target_state="$CASE_DIR/target-state"
  printf 'live\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" FM_FAKE_BACKEND_CLOSE_EFFECT=none PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must retain failed-spawn metadata when close reports success but endpoint remains live"
  assert_contains "$out" "remains live after cleanup" \
    "teardown did not explain the unconfirmed endpoint cleanup"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "unconfirmed endpoint teardown discarded recovery metadata"
  [ -d "$crew_home" ] || fail "unconfirmed endpoint teardown removed the credential home"
  pass "failed endpoint teardown verifies successful cleanup removed the endpoint"
}

test_codex_teardown_preserves_metadata_when_endpoint_query_is_unavailable() {
  local rec id out status launch crew_home target_state
  id=profile-codex-unqueryable-endpoint-z76
  rec=$(make_spawn_case profile-codex-unqueryable-endpoint codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare an unqueryable-endpoint recovery case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  printf 'failed_spawn=1\nendpoint_cleanup_pending=1\n' >> "$HOME_DIR/state/$id.meta"
  target_state="$CASE_DIR/target-state"
  printf 'live\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_TARGET_QUERY_STATUS=75 FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must retain failed-spawn metadata when endpoint absence is unqueryable"
  assert_contains "$out" "could not be confirmed absent" \
    "teardown did not explain the unqueryable endpoint state"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "unqueryable endpoint teardown discarded recovery metadata"
  [ -d "$crew_home" ] || fail "unqueryable endpoint teardown removed the credential home"
  pass "failed endpoint teardown requires confirmed absence"
}

test_codex_teardown_refuses_malformed_task_temp_metadata() {
  local rec id out status launch crew_home unsafe_task_tmp meta
  id=profile-codex-unsafe-tasktmp-z69
  rec=$(make_spawn_case profile-codex-unsafe-tasktmp codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a task-temp metadata case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  unsafe_task_tmp="$CASE_DIR/not-a-task-temp"
  mkdir -p "$unsafe_task_tmp"
  printf 'keep\n' > "$unsafe_task_tmp/sentinel"
  meta="$HOME_DIR/state/$id.meta"
  sed "s|^tasktmp=.*|tasktmp=$unsafe_task_tmp|" "$meta" > "$meta.next" && mv "$meta.next" "$meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$CASE_DIR/target-state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must refuse malformed task temporary metadata"
  assert_contains "$out" "unsafe task temporary directory" \
    "teardown did not explain the malformed task temporary metadata"
  [ -f "$unsafe_task_tmp/sentinel" ] || fail "teardown removed a path supplied by task metadata"
  [ -f "$meta" ] || fail "teardown discarded metadata after refusing an unsafe task temporary path"
  [ -d "$crew_home" ] || fail "teardown performed cleanup after refusing unsafe task temporary metadata"
  pass "teardown refuses malformed task temporary metadata"
}

test_codex_teardown_accepts_legacy_task_temp_metadata() {
  local rec id out status launch crew_home legacy_task_tmp meta
  id=profile-codex-legacy-tasktmp-z82
  rec=$(make_spawn_case profile-codex-legacy-tasktmp codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a legacy task-temp metadata case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  legacy_task_tmp="/tmp/fm-$id"
  mkdir -p "$legacy_task_tmp"
  meta="$HOME_DIR/state/$id.meta"
  sed "s|^tasktmp=.*|tasktmp=$legacy_task_tmp|" "$meta" > "$meta.next" && mv "$meta.next" "$meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$CASE_DIR/target-state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should accept a legacy exact task temporary directory"
  [ ! -e "$legacy_task_tmp" ] || fail "teardown retained the legacy task temporary directory"
  [ ! -e "$crew_home" ] || fail "teardown retained the Codex home after legacy task-temp cleanup"
  assert_absent "$meta" "teardown retained metadata after legacy task-temp cleanup"
  pass "teardown accepts the legacy exact task temporary directory"
}

test_codex_teardown_refuses_symlinked_data_root() {
  local rec id out status launch crew_home data_root real_data target_state
  id=profile-codex-teardown-data-symlink-z41
  rec=$(make_spawn_case profile-codex-teardown-data-symlink codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex spawn should prepare a teardown data-root case"
  launch=$(cat "$LAUNCH_LOG")
  crew_home=$(codex_home_from_launch "$launch")
  materialize_codex_home "$crew_home" "$HOME_DIR/data" "$CASE_DIR/user/.codex" "fm-crewmate-$id" "$WT_DIR"
  data_root="$HOME_DIR/data"
  real_data="$CASE_DIR/real-data"
  mv "$data_root" "$real_data"
  ln -s "$real_data" "$data_root"
  target_state="$CASE_DIR/target-state"
  printf 'gone\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$data_root" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must reject a symlinked data root"
  [ -d "$crew_home" ] || fail "symlinked data-root cleanup deleted the managed home"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "symlinked data-root cleanup discarded metadata"
  pass "Codex teardown rejects symlinked data roots"
}

test_codex_crewmate_home_records_failed_worktree_return() {
  local rec id out status handoff
  id=profile-codex-home-return-z22
  rec=$(make_spawn_case profile-codex-home-return codex "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/python3" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$FAKEBIN_DIR/python3"

  out=$(FM_FAKE_TREEHOUSE_RETURN_STATUS=75 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when private-home creation and return fail"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "failed spawn cleanup did not close its endpoint before returning the lease"
  assert_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "failed isolated-home cleanup did not attempt to return its worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "failed lease return must not retain a task after its endpoint is closed"
  handoff=$(find "$HOME_DIR/state" -name ".${id}.treehouse-lease.*" -type f -print -quit)
  [ -n "$handoff" ] || fail "failed lease return did not retain a recovery handoff"
  assert_contains "$(cat "$handoff")" "leased=$WT_DIR" \
    "failed lease return did not restore its handoff to leased state"
  pass "Codex spawn retains a closed-endpoint lease handoff for recovery"
}

test_codex_spawn_abort_accepts_an_already_absent_endpoint() {
  local rec id out status
  id=profile-codex-home-absent-z27
  rec=$(make_spawn_case profile-codex-home-absent codex "$id")
  read_case_record "$rec"

  out=$(FM_FAKE_TREEHOUSE_RETURN_STATUS=0 FM_FAKE_TREEHOUSE_CLOSE_EFFECT=gone \
    FM_FAKE_BACKEND_KILL_STATUS=76 FM_FAKE_ACTIVATION_RESULT=failed \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn should report the isolated-home activation failure"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "failed spawn cleanup should close a live endpoint before releasing its lease"
  assert_grep 'failed_spawn=1' "$HOME_DIR/state/$id.meta" \
    "failed spawn cleanup did not retain recovery metadata after endpoint closure"
  assert_grep 'treehouse_lease=1' "$HOME_DIR/state/$id.meta" \
    "failed spawn cleanup did not retain its committed lease"
  pass "Codex spawn abort retains a committed lease after endpoint closure"
}

test_codex_crewmate_home_records_failed_endpoint_removal() {
  local rec id out status project
  id=profile-codex-home-kill-z26
  rec=$(make_spawn_case profile-codex-home-kill codex "$id")
  read_case_record "$rec"
  project=$(cd "$PROJ_DIR" && pwd)
  cat > "$FAKEBIN_DIR/python3" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod +x "$FAKEBIN_DIR/python3"

  out=$(FM_FAKE_TREEHOUSE_RETURN_STATUS=0 FM_FAKE_BACKEND_KILL_STATUS=76 FM_FAKE_TARGET_QUERY_STATUS=77 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when private-home creation and endpoint removal fail"
  assert_no_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "failed endpoint removal must not return a lease that still has a live endpoint"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "failed endpoint removal was not attempted"
  assert_grep "window=firstmate:fm-$id" "$HOME_DIR/state/$id.meta" \
    "failed endpoint removal did not record the task endpoint"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "failed endpoint removal did not record the worktree"
  assert_grep "project=$project" "$HOME_DIR/state/$id.meta" \
    "failed endpoint removal did not record the project"
  assert_grep 'treehouse_lease=1' "$HOME_DIR/state/$id.meta" \
    "failed endpoint removal did not hold its treehouse lease for teardown"
  [ ! -s "$LAUNCH_LOG" ] || fail "failed endpoint removal must not launch Codex"
  pass "Codex spawn records failed endpoint removals for normal teardown"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$(cat " \
    "grok launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$(cat " \
    "grok launch did not preserve the model flag when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  pass "pi receives --model and --thinking max profile flags"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CODEX_HOME=" \
    "secondmate Codex launch must keep its existing CODEX_HOME behavior"
  pass "active crew-dispatch profile does not block secondmate launches"
}

# --- Claude crewmate second-account profile isolation ----------------------
#
# Unlike Codex, the isolated home is created synchronously by fm-spawn.sh
# itself (bin/fm-claude-home.py) before the launch command is sent, so no
# fake-tmux activation dance is needed: by the time run_spawn returns, the
# task-private home already exists on disk with real content.

write_fake_claude_cli() {  # <fakebin-dir>
  local fakebin=$1
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
set -u
if [ "\$1 \$2 \$3" = "auth status --json" ]; then
  if [ -f "\${CLAUDE_CONFIG_DIR:-}/.credentials.json" ]; then
    printf '%s\n' '{"loggedIn":true}'
    exit 0
  fi
  printf '%s\n' '{"loggedIn":false}'
  exit 1
fi
printf 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude fake session\n'
exit 0
SH
  chmod +x "$fakebin/claude"
}

claude_config_dir_from_launch() {
  printf '%s\n' "$1" | sed -n "s/^CLAUDE_CONFIG_DIR='\\([^']*\\)'.*/\\1/p"
}

make_claude_crew_profile() {  # <home-dir> [ready=1]
  local home=$1 ready=${2:-1} crew_profile
  crew_profile="$home/data/claude-crewmate/profile"
  mkdir -p "$crew_profile"
  [ "$ready" -eq 0 ] || {
    printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"crew@example.invalid"}}\n' > "$crew_profile/.claude.json"
    printf '{"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh"}}\n' > "$crew_profile/.credentials.json"
  }
  printf '%s\n' "$crew_profile"
}

test_claude_crewmate_home_used_when_profile_ready() {
  local rec ship scout out status launch crew_profile home_dir
  ship=claude-crew-home-ship-z90
  scout=claude-crew-home-scout-z91
  rec=$(make_spawn_case claude-crew-home-ready claude "$ship" "$scout")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  crew_profile=$(make_claude_crew_profile "$HOME_DIR")
  printf '%s\n' 'noise' > "$crew_profile/backups-marker"
  mkdir -p "$crew_profile/backups"
  printf '%s\n' 'b' > "$crew_profile/backups/entry.json"
  cat > "$crew_profile/settings.json" <<'EOF'
{"mcpServers":{"shared_memory":{"command":"broken-memory-server"}}}
EOF
  mkdir -p "$crew_profile/hooks"
  printf '%s\n' 'h' > "$crew_profile/hooks/x.sh"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ship" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude ship spawn should succeed with a ready crew profile"
  launch=$(cat "$LAUNCH_LOG")
  home_dir=$(claude_config_dir_from_launch "$launch")
  [ -n "$home_dir" ] || fail "Claude ship launch did not carry an isolated CLAUDE_CONFIG_DIR"
  case "${home_dir##*/}" in .fm-claude-home.*) : ;; *) fail "Claude launch did not use a private per-task home: $home_dir" ;; esac
  [ -d "$home_dir" ] || fail "Claude ship spawn did not materialize the private home synchronously"
  assert_grep "claude_crewmate_home=$home_dir" "$HOME_DIR/state/$ship.meta" \
    "Claude ship metadata did not retain its isolated home for cleanup"
  assert_present "$home_dir/.claude.json" "isolated Claude home did not copy the profile's credential file"
  assert_grep '"hasCompletedOnboarding":true' "$home_dir/.claude.json" \
    "isolated Claude home did not retain completed onboarding state"
  assert_present "$home_dir/.credentials.json" "isolated Claude home did not copy the file credential fixture"
  assert_present "$home_dir/backups/entry.json" "isolated Claude home did not copy nested profile content"
  [ ! -e "$home_dir/settings.json" ] || fail "isolated Claude home retained the profile's settings.json"
  [ ! -e "$home_dir/hooks" ] || fail "isolated Claude home retained the profile's hooks directory"
  [ ! -L "$home_dir/.claude.json" ] || fail "isolated Claude credential file must not point into the captain profile"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$scout" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "Claude scout spawn should also use the isolated home"
  launch=$(cat "$LAUNCH_LOG")
  home_dir=$(claude_config_dir_from_launch "$launch")
  [ -n "$home_dir" ] || fail "Claude scout launch did not expose an isolated CLAUDE_CONFIG_DIR"
  pass "Claude ship and scout launches use a fresh crew-profile home, excluding customization surface"
}

test_claude_crewmate_home_absent_profile_matches_default_behavior() {
  local rec id out status launch expected
  id=claude-crew-home-absent-z92
  rec=$(make_spawn_case claude-crew-home-absent claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude spawn without a crew profile should succeed unchanged"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "absent-profile claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_no_grep 'claude_crewmate_home=' "$HOME_DIR/state/$id.meta" \
    "absent-profile claude spawn should not record claude_crewmate_home="
  [ ! -e "$HOME_DIR/data/claude-crewmate" ] || fail "absent-profile claude spawn should not create data/claude-crewmate"
  pass "an absent claude crew profile keeps the launch and meta byte-identical to today"
}

test_claude_crewmate_home_credential_less_profile_refuses_spawn() {
  local rec id out status launch expected crew_profile
  id=claude-crew-home-noauth-z93
  rec=$(make_spawn_case claude-crew-home-noauth claude "$id")
  read_case_record "$rec"
  crew_profile=$(make_claude_crew_profile "$HOME_DIR" 0)
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/never-ready"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Claude spawn with a credential-less crew profile must refuse before launch"
  assert_contains "$out" "cannot authenticate a task-private home" \
    "credential-less Claude profile did not explain its readiness refusal"
  [ ! -s "$LAUNCH_LOG" ] || fail "credential-less Claude profile launched a pane"
  if [ -f "$HOME_DIR/state/$id.meta" ]; then
    assert_no_grep 'claude_crewmate_home=' "$HOME_DIR/state/$id.meta" \
      "credential-less Claude profile recorded an unprovisioned credential home"
  fi
  [ -d "$crew_profile" ] || fail "test setup lost the credential-less profile directory"
  pass "a present but credential-less claude crew profile refuses before launching a pane"
}

test_claude_crewmate_home_uses_fresh_private_directory() {
  local rec id out status legacy_home home_dir launch home_base home_parent
  id=claude-crew-home-fresh-z94
  rec=$(make_spawn_case claude-crew-home-fresh claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null
  legacy_home="$HOME_DIR/data/claude-crewmate/.fm-claude-home.legacy0000000000000000000000000"
  mkdir -p "$legacy_home"
  printf '{"oauthAccount":{"emailAddress":"legacy@example.invalid"}}\n' > "$legacy_home/.claude.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude spawn should not reuse a legacy isolated home"
  launch=$(cat "$LAUNCH_LOG")
  home_dir=$(claude_config_dir_from_launch "$launch")
  [ -n "$home_dir" ] || fail "Claude launch did not expose a fresh isolated CLAUDE_CONFIG_DIR"
  [ "$home_dir" != "$legacy_home" ] || fail "Claude launch reused the legacy isolated home"
  home_base=$(cd "$HOME_DIR/data/claude-crewmate" && pwd -P)
  home_parent=$(cd "$(dirname "$home_dir")" && pwd -P)
  [ "$home_parent" = "$home_base" ] || fail "Claude launch did not use a private per-task home: $home_dir"
  assert_not_contains "$(cat "$home_dir/.claude.json" 2>/dev/null || true)" "legacy@example.invalid" \
    "fresh Claude home inherited legacy authentication"
  pass "Claude spawn uses a fresh private isolated home, never a legacy one"
}

test_claude_crewmate_home_is_removed_at_teardown() {
  local rec id out status launch home_dir target_state
  id=claude-crew-home-teardown-z95
  rec=$(make_spawn_case claude-crew-home-teardown claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude spawn should prepare a private home before teardown"
  launch=$(cat "$LAUNCH_LOG")
  home_dir=$(claude_config_dir_from_launch "$launch")
  [ -d "$home_dir" ] || fail "Claude spawn did not create the private home to be torn down"
  target_state="$CASE_DIR/target-state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should remove a recorded Claude private home"
  [ ! -e "$home_dir" ] || fail "teardown left the credential-bearing Claude private home behind"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown should remove metadata only after private-home cleanup"
  pass "teardown removes the recorded private Claude home"
}

test_claude_crewmate_home_preserved_when_referenced_by_another_task() {
  local rec id sibling out status launch home_dir sibling_home target_state meta
  id=claude-crew-home-owner-z96
  sibling=claude-crew-home-owner-z97
  rec=$(make_spawn_case claude-crew-home-owner claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Claude spawn should prepare a private home ownership case"
  launch=$(cat "$LAUNCH_LOG")
  home_dir=$(claude_config_dir_from_launch "$launch")
  sibling_home=$(python3 "$ROOT/bin/fm-claude-home.py" --data "$HOME_DIR/data" --source "$HOME_DIR/data/claude-crewmate/profile" \
    --task-id "$sibling" --create)
  meta="$HOME_DIR/state/$id.meta"
  sed "s|^claude_crewmate_home=.*|claude_crewmate_home=$sibling_home|" "$meta" > "$meta.next" && mv "$meta.next" "$meta"
  fm_write_meta "$HOME_DIR/state/$sibling.meta" \
    "window=fm-$sibling" "worktree=$WT_DIR" "project=$PROJ_DIR" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "claude_crewmate_home=$sibling_home"
  target_state="$CASE_DIR/target-state"
  printf 'gone\n' > "$target_state"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TARGET_STATE="$target_state" \
    FM_FAKE_BACKEND_LOG="$CASE_DIR/backend.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force 2>&1)
  status=$?
  expect_code 1 "$status" "teardown must reject another task's Claude home"
  assert_contains "$out" "referenced by another active task" \
    "teardown did not explain the conflicting Claude-home metadata"
  [ -d "$sibling_home" ] || fail "teardown removed the sibling task's credential home"
  [ -f "$meta" ] || fail "teardown discarded metadata after rejecting a sibling Claude home"
  [ -d "$home_dir" ] || fail "test setup unexpectedly removed the original Claude home"
  pass "teardown preserves a Claude home referenced by another task"
}

test_claude_crewmate_home_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=claude-crew-home-secondmate-z98
  rec=$(make_spawn_case claude-crew-home-secondmate claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "Claude secondmate spawn should not require or use a crew profile"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_no_grep 'claude_crewmate_home=' "$HOME_DIR/state/$id.meta" \
    "Claude secondmate launch must keep its existing CLAUDE_CONFIG_DIR behavior"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR=" \
    "Claude secondmate launch must keep its existing CLAUDE_CONFIG_DIR behavior"
  pass "a ready claude crew profile does not affect secondmate launches"
}

test_claude_crewmate_home_refuses_symlink_escape() {
  local rec id out status crew_root
  id=claude-crew-home-symlink-z99
  rec=$(make_spawn_case claude-crew-home-symlink claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null
  crew_root="$HOME_DIR/data/claude-crewmate-real"
  mv "$HOME_DIR/data/claude-crewmate" "$crew_root"
  ln -s "$crew_root" "$HOME_DIR/data/claude-crewmate"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Claude spawn must reject a symlinked isolated-home base"
  assert_contains "$out" "could not prepare isolated Claude crewmate home" \
    "Claude spawn did not report the symlink escape"
  assert_absent "$HOME_DIR/state/$id.meta" "symlink rejection must not create task metadata"
  assert_grep "treehouse return --force $WT_DIR" "$CASE_DIR/backend.log" \
    "symlink rejection did not return its worktree"
  assert_grep "kill-window -t firstmate:fm-$id" "$CASE_DIR/backend.log" \
    "symlink rejection did not remove its task endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "symlink rejection must not launch Claude"
  pass "Claude spawn refuses a symlinked isolated-home base directory"
}

test_claude_crewmate_home_refuses_symlinked_data_root() {
  local rec id out status data_root real_data
  id=claude-crew-home-data-symlink-z100
  rec=$(make_spawn_case claude-crew-home-data-symlink claude "$id")
  read_case_record "$rec"
  write_fake_claude_cli "$FAKEBIN_DIR" "$HOME_DIR/data/claude-crewmate/profile"
  make_claude_crew_profile "$HOME_DIR" >/dev/null
  data_root="$HOME_DIR/data"
  real_data="$CASE_DIR/real-data"
  mv "$data_root" "$real_data"
  ln -s "$real_data" "$data_root"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Claude spawn must reject a symlinked data root"
  assert_contains "$out" "could not prepare isolated Claude crewmate home" \
    "Claude spawn did not report the data-root symlink escape"
  find "$real_data/claude-crewmate" -maxdepth 1 -name '.fm-claude-home.*' 2>/dev/null | grep -q . \
    && fail "data-root symlink rejection must not create a Claude home"
  [ ! -s "$LAUNCH_LOG" ] || fail "data-root symlink rejection must not launch Claude"
  pass "Claude spawn refuses a symlinked data root"
}

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_crewmate_home_excludes_mcp_and_plugins
test_codex_crewmate_home_honors_codex_home_override
test_codex_crewmate_home_uses_fresh_private_directory
test_codex_crewmate_home_is_removed_at_teardown
test_codex_teardown_preserves_home_referenced_by_another_task
test_codex_teardown_refuses_home_owned_by_another_task
test_codex_teardown_preserves_home_when_normal_endpoint_close_fails
test_codex_teardown_accepts_an_already_absent_endpoint
test_codex_crewmate_home_refuses_symlink_escape
test_codex_crewmate_home_refuses_symlinked_data_root
test_codex_crewmate_profile_rejects_toml_control_characters
test_codex_crewmate_home_fails_when_private_home_creation_fails
test_raw_codex_launch_is_normalized
test_raw_codex_late_home_assignment_is_normalized
test_raw_codex_options_fail_closed
test_raw_codex_execution_wrappers_fail_closed
test_quoted_or_escaped_raw_codex_launch_fails_closed
test_quoted_raw_custom_launch_remains_supported
test_raw_custom_dynamic_execution_fails_closed
test_raw_script_dispatches_fail_closed
test_codex_crewmate_home_uses_private_directory
test_codex_home_activation_uses_open_descriptor
test_codex_home_removal_preserves_a_replacement_after_validation
test_codex_home_activation_reports_exec_failure
test_codex_home_activation_refuses_replaced_path
test_codex_home_activation_result_refuses_symlink
test_codex_home_activation_refuses_existing_result
test_codex_home_activation_failure_aborts_spawn
test_codex_activation_uses_managed_data_root
test_codex_teardown_preserves_failed_endpoint_metadata
test_codex_teardown_preserves_metadata_when_successful_close_leaves_endpoint_live
test_codex_teardown_preserves_metadata_when_endpoint_query_is_unavailable
test_codex_teardown_refuses_malformed_task_temp_metadata
test_codex_teardown_accepts_legacy_task_temp_metadata
test_codex_teardown_refuses_symlinked_data_root
test_codex_crewmate_home_records_failed_worktree_return
test_codex_spawn_abort_accepts_an_already_absent_endpoint
test_codex_crewmate_home_records_failed_endpoint_removal
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch
test_claude_crewmate_home_used_when_profile_ready
test_claude_crewmate_home_absent_profile_matches_default_behavior
test_claude_crewmate_home_credential_less_profile_refuses_spawn
test_claude_crewmate_home_uses_fresh_private_directory
test_claude_crewmate_home_is_removed_at_teardown
test_claude_crewmate_home_preserved_when_referenced_by_another_task
test_claude_crewmate_home_does_not_block_secondmate_launch
test_claude_crewmate_home_refuses_symlink_escape
test_claude_crewmate_home_refuses_symlinked_data_root

echo "# all fm-spawn-dispatch-profile tests passed"
