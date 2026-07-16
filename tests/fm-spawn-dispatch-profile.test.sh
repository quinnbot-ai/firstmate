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
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window)
    [ -z "${FM_FAKE_BACKEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_BACKEND_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_BACKEND_LOG="$(dirname "$launchlog")/backend.log" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    HOME="$CASE_DIR/user" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
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
  local rec ship scout out status launch crew_home source_home
  ship=profile-codex-home-ship-z17
  scout=profile-codex-home-scout-z18
  rec=$(make_spawn_case profile-codex-home codex "$ship" "$scout")
  read_case_record "$rec"
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
  mkdir -p "$PROJ_DIR/.codex"
  cat > "$PROJ_DIR/.codex/config.toml" <<'EOF'
[mcp_servers.project_memory]
command = "still-broken-memory-server"
[plugins."project-plugin@local"]
enabled = true
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$ship" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "Codex ship spawn should succeed with an isolated home"
  crew_home=$(cd "$HOME_DIR/data/codex-crewmate/fm-crewmate-$ship" && pwd -P)
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CODEX_HOME='$crew_home' codex --profile 'fm-crewmate-$ship' --disable plugins" \
    "Codex ship launch did not set the isolated CODEX_HOME"
  assert_contains "$out" "warning: Codex crewmate ignores project config" \
    "Codex ship launch did not warn that project Codex config was ignored"
  assert_contains "$out" "project/.codex/config.toml to keep MCPs and plugins disabled" \
    "Codex ship launch did not warn that project Codex config was ignored"
  assert_present "$crew_home/config.toml" "isolated Codex config was not created"
  assert_no_grep 'mcp_servers' "$crew_home/config.toml" \
    "isolated Codex config retained MCP server entries"
  assert_no_grep 'plugins' "$crew_home/config.toml" \
    "isolated Codex config retained plugin registrations"
  assert_grep "trust_level = \"untrusted\"" "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile did not disable project config trust"
  assert_grep '[projects.' "$crew_home/fm-crewmate-$ship.config.toml" \
    "isolated Codex profile did not scope untrusted trust to the project"
  [ ! -e "$crew_home/plugins" ] || fail "isolated Codex home retained a plugins directory"
  cmp -s "$source_home/auth.json" "$crew_home/auth.json" \
    || fail "isolated Codex home did not refresh authentication"
  cmp -s "$source_home/models_cache.json" "$crew_home/models_cache.json" \
    || fail "isolated Codex home did not refresh the model catalog"
  [ ! -L "$crew_home/auth.json" ] || fail "isolated Codex auth must not point into the captain home"

  crew_home="$HOME_DIR/data/codex-crewmate/fm-crewmate-$scout"
  mkdir -p "$crew_home/plugins/stale-plugin"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$scout" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "Codex scout spawn should use the isolated home"
  crew_home=$(cd "$crew_home" && pwd -P)
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CODEX_HOME='$crew_home' codex --profile 'fm-crewmate-$scout' --disable plugins" \
    "Codex scout launch did not set the isolated CODEX_HOME"
  assert_no_grep 'mcp_servers' "$crew_home/config.toml" \
    "Codex scout refresh reintroduced MCP server entries"
  assert_no_grep 'plugins' "$crew_home/config.toml" \
    "Codex scout refresh reintroduced plugin registrations"
  [ ! -e "$crew_home/plugins" ] || fail "Codex scout refresh retained stale plugins"
  pass "Codex ship and scout launches use a firstmate-owned MCP-free home"
}

test_codex_crewmate_home_fails_when_plugin_cleanup_fails() {
  local rec id out status source_home crew_home
  id=profile-codex-home-cleanup-z19
  rec=$(make_spawn_case profile-codex-home-cleanup codex "$id")
  read_case_record "$rec"
  source_home="$CASE_DIR/user/.codex"
  crew_home="$HOME_DIR/data/codex-crewmate/fm-crewmate-$id"
  mkdir -p "$source_home" "$crew_home/plugins/stale-plugin"
  cat > "$FAKEBIN_DIR/rm" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"plugins"*) exit 73 ;;
  *) exec /bin/rm "$@" ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/rm"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when isolated-home plugin cleanup fails"
  assert_contains "$out" "could not prepare isolated Codex crewmate home" \
    "Codex spawn did not report isolated-home cleanup failure"
  assert_absent "$HOME_DIR/state/$id.meta" "failed isolated-home preparation must not create task metadata"
  [ ! -s "$CASE_DIR/backend.log" ] || fail "failed isolated-home preparation must not allocate a task backend"
  [ ! -s "$LAUNCH_LOG" ] || fail "failed isolated-home preparation must not launch Codex"
  pass "Codex spawn fails closed when isolated-home plugin cleanup fails"
}

test_codex_crewmate_home_fails_when_stale_catalog_cleanup_fails() {
  local rec id out status crew_home
  id=profile-codex-home-catalog-cleanup-z20
  rec=$(make_spawn_case profile-codex-home-catalog-cleanup codex "$id")
  read_case_record "$rec"
  crew_home="$HOME_DIR/data/codex-crewmate/fm-crewmate-$id"
  mkdir -p "$crew_home"
  printf '%s\n' '{"models":["stale"]}' > "$crew_home/models_cache.json"
  cat > "$FAKEBIN_DIR/rm" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"models_cache.json"*) exit 74 ;;
  *) exec /bin/rm "$@" ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/rm"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Codex spawn must fail when stale model-catalog cleanup fails"
  assert_contains "$out" "could not prepare isolated Codex crewmate home" \
    "Codex spawn did not report stale model-catalog cleanup failure"
  assert_absent "$HOME_DIR/state/$id.meta" "failed model-catalog cleanup must not create task metadata"
  [ ! -s "$CASE_DIR/backend.log" ] || fail "failed isolated-home preparation must not allocate a task backend"
  [ ! -s "$LAUNCH_LOG" ] || fail "failed model-catalog cleanup must not launch Codex"
  pass "Codex spawn fails closed when stale model-catalog cleanup fails"
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
  assert_contains "$out" "isolated Codex home must not be a symlink" \
    "Codex spawn did not report the symlink escape"
  assert_grep 'captain-config' "$source_home/config.toml" \
    "symlink rejection must not overwrite the captain Codex config"
  [ -d "$source_home/plugins" ] || fail "symlink rejection must not remove captain plugins"
  assert_absent "$HOME_DIR/state/$id.meta" "symlink rejection must not create task metadata"
  [ ! -s "$CASE_DIR/backend.log" ] || fail "symlink rejection must not allocate a task backend"
  [ ! -s "$LAUNCH_LOG" ] || fail "symlink rejection must not launch Codex"
  pass "Codex spawn refuses isolated-home symlink escapes"
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

test_pi_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should not pass an invalid flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi sonnet max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'sonnet' -e" "pi launch did not thread model"
  assert_not_contains "$launch" "--thinking" "pi launch must omit --thinking max because the CLI rejects it"
  pass "pi threads model and omits unsupported max effort"
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

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_crewmate_home_excludes_mcp_and_plugins
test_codex_crewmate_home_fails_when_plugin_cleanup_fails
test_codex_crewmate_home_fails_when_stale_catalog_cleanup_fails
test_codex_crewmate_home_refuses_symlink_escape
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_omits_invalid_max_effort
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
