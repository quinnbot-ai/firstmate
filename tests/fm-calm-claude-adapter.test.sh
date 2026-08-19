#!/usr/bin/env bash
# Regression for the shared Calm preference command and the Claude Calm
# session-start adapter, including its separation from the operational digest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-calm-claude-adapter)
CALM="$ROOT/bin/fm-calm.sh"
NUDGE="$ROOT/bin/fm-claude-calm-nudge.sh"
CALM_ON='Firstmate Calm presentation is active for this home. Keep captain-facing updates outcome-first, concise, and free of incidental progress narration while preserving every operational instruction, safety boundary, and technical fact that matters.'
CALM_OFF='Firstmate Calm presentation is inactive for this home. This supersedes any earlier Calm-active instruction in the transcript; use ordinary captain-facing presentation.'
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local root=$1
  mkdir -p "$root/bin" "$root/state" "$root/config"
  git init -q "$root"
  git -C "$root" commit -q --allow-empty -m init
  : > "$root/AGENTS.md"
}

run_calm() {
  local config=$1
  shift
  FM_CONFIG_OVERRIDE="$config" "$CALM" "$@"
}

run_nudge() {
  local root=$1
  FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_CONFIG_OVERRIDE="$root/config" "$NUDGE"
}

test_preference_commands() {
  local config="$TMP_ROOT/preference/config" home="$TMP_ROOT/preference/home" out status=0
  out=$(run_calm "$config" status 2>&1) || status=$?
  expect_code 0 "$status" "absent preference status"
  [ "$out" = off ] || fail "absent preference must read off with no noise, got: $out"

  mkdir -p "$config"
  printf 'not-a-preference\n' > "$config/calm"
  [ "$(run_calm "$config" status)" = off ] || fail "unrecognized preference must read off"
  printf 'max\n' > "$config/calm"
  [ "$(run_calm "$config" status)" = on ] || fail "legacy max preference must still read on"

  printf 'off\n' > "$config/calm"
  [ "$(run_calm "$config" toggle)" = on ] || fail "toggle did not activate Calm"
  [ "$(od -An -tx1 "$config/calm" | tr -d ' \n')" = 6f6e0a ] || fail "active preference was not persisted exactly"
  [ "$(run_calm "$config" toggle)" = off ] || fail "toggle did not deactivate Calm"
  [ "$(od -An -tx1 "$config/calm" | tr -d ' \n')" = 6f66660a ] || fail "inactive preference was not persisted exactly"
  [ "$(run_calm "$config" on)" = on ] || fail "on command did not activate Calm"
  [ "$(run_calm "$config" off)" = off ] || fail "off command did not deactivate Calm"

  out=$(FM_HOME="$home" "$CALM" on) || status=$?
  expect_code 0 "$status" "FM_HOME preference write"
  [ "$out" = on ] || fail "FM_HOME preference write did not report on"
  [ "$(od -An -tx1 "$home/config/calm" | tr -d ' \n')" = 6f6e0a ] || fail "FM_HOME preference was not persisted exactly"

  "$CALM" bogus >/dev/null 2>&1 && status=0 || status=$?
  expect_code 2 "$status" "invalid preference command"
  "$CALM" status extra >/dev/null 2>&1 && status=0 || status=$?
  expect_code 2 "$status" "over-applied preference command"
  pass "fm-calm: reads default off, honors the legacy value, persists exact bytes, and rejects invalid input"
}

test_claude_nudge_scope_and_preference() {
  local root="$TMP_ROOT/primary" linked="$TMP_ROOT/linked" out status=0
  make_primary "$root"

  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm-off nudge"
  [ "$out" = "$CALM_OFF" ] || fail "Calm-off Claude nudge changed unexpectedly: $out"

  run_calm "$root/config" on > /dev/null
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm-on nudge"
  [ "$out" = "$CALM_ON" ] || fail "Calm-on Claude nudge changed unexpectedly: $out"

  run_calm "$root/config" off > /dev/null
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "Calm on-to-off nudge"
  [ "$out" = "$CALM_OFF" ] || fail "Calm on-to-off nudge did not supersede stale active context: $out"

  run_calm "$root/config" on > /dev/null
  out=$(FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=1 run_nudge "$root") || status=$?
  expect_code 0 "$status" "gate nudge"
  [ -z "$out" ] || fail "a gate agent must get no Calm nudge: $out"

  git -C "$root" worktree add -q -b fm/calm-linked "$linked" HEAD
  mkdir -p "$linked/bin" "$linked/state" "$linked/config"
  : > "$linked/AGENTS.md"
  run_calm "$linked/config" on > /dev/null
  out=$(run_nudge "$linked") || status=$?
  expect_code 0 "$status" "linked worktree nudge"
  [ -z "$out" ] || fail "a linked task worktree must get no Calm nudge: $out"
  pass "Claude Calm nudge follows the persisted preference and stays silent outside a genuine primary home"
}

# The Calm adapter must be its own SessionStart grouping: the tracked digest
# registration keeps running exactly as before, and both hooks fire per session
# open. A merged grouping would couple Calm to the digest's timeout and ordering.
test_claude_sessionstart_registration() {
  local settings="$ROOT/.claude/settings.json" dir groups calm_groups digest_group cmd ran
  command -v jq > /dev/null 2>&1 || fail "test host must provide jq"

  groups=$(jq '.hooks.SessionStart | length' "$settings")
  calm_groups=$(jq '[.hooks.SessionStart[] | select([.hooks[].command | test("fm-claude-calm-nudge\\.sh")] | any)] | length' "$settings")
  [ "$calm_groups" = 1 ] || fail "Calm must occupy exactly one SessionStart grouping, saw $calm_groups"
  [ "$(jq -r '[.hooks.SessionStart[] | select([.hooks[].command | test("fm-claude-calm-nudge\\.sh")] | any) | .hooks | length] | add' "$settings")" = 1 ] \
    || fail "the Calm SessionStart grouping must register only the Calm adapter"
  digest_group=$(jq -r '[.hooks.SessionStart[] | select([.hooks[].command | test("fm-sessionstart-run\\.sh")] | any) | .hooks[].command] | length' "$settings")
  [ "$digest_group" = 1 ] || fail "the digest SessionStart grouping must still register exactly one command, saw $digest_group"
  [ "$groups" -ge 2 ] || fail "Calm did not add a separate SessionStart grouping"

  dir="$TMP_ROOT/sessionstart"
  mkdir -p "$dir/bin"
  for script in fm-sessionstart-run.sh fm-claude-calm-nudge.sh; do
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n %q >> %q\n' "$script" "$dir/ran" > "$dir/bin/$script"
    chmod +x "$dir/bin/$script"
  done
  : > "$dir/ran"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$dir" \
      bash -c "$cmd" < /dev/null > /dev/null 2>&1 \
      || fail "a tracked SessionStart command failed: $cmd"
  done < <(jq -r '.hooks.SessionStart[].hooks[].command' "$settings")
  ran=$(sort "$dir/ran" | tr '\n' ' ')
  [ "$ran" = 'fm-claude-calm-nudge.sh fm-sessionstart-run.sh ' ] \
    || fail "one Claude session open must run the digest and the Calm adapter exactly once each, saw: $ran"
  pass "the Claude Calm adapter is a separate SessionStart grouping and leaves the session-start digest registration intact"
}

test_preference_commands
test_claude_nudge_scope_and_preference
test_claude_sessionstart_registration
