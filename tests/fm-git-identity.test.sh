#!/usr/bin/env bash
# Behavior tests for task-worktree git identity pinning and clone auditing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IDENTITY="$ROOT/bin/fm-git-identity.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-identity)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {  # <home> <projects> <worktree> <fakebin> <global-config> <captain-home> <id> <project>
  local home=$1 projects=$2 worktree=$3 fakebin=$4 global_config=$5 captain_home=$6 id=$7 project=$8
  HOME="$captain_home" GIT_CONFIG_GLOBAL="$global_config" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" claude 2>&1
}

make_spawn_fixture() {  # <name> <project>
  local name=$1 project=$2 case_dir home projects worktree captain_home global_config fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  projects="$home/projects"
  worktree="$case_dir/task-worktree"
  captain_home="$case_dir/captain-home"
  global_config="$case_dir/global.gitconfig"
  fakebin=$(make_fakebin "$case_dir/fake")
  id="identity-$name"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$projects" "$captain_home"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  git config --file "$global_config" user.name 'Captain Personal'
  git config --file "$global_config" user.email 'captain@example.invalid'
  fm_git_worktree "$project" "$worktree" "fm/$id"
  git -C "$project" config user.name 'Project Owner'
  git -C "$project" config user.email 'project@example.invalid'
  printf '%s\n' "$case_dir|$home|$projects|$worktree|$captain_home|$global_config|$fakebin|$id"
}

read_fixture() {
  IFS='|' read -r _ HOME_DIR PROJECTS_DIR WORKTREE_DIR CAPTAIN_HOME GLOBAL_CONFIG FAKEBIN ID <<EOF
$1
EOF
}

assert_identity() {  # <worktree> <name> <email>
  local worktree=$1 name=$2 email=$3
  [ "$(git -C "$worktree" config --worktree --get user.name)" = "$name" ] \
    || fail "worktree user.name was not $name"
  [ "$(git -C "$worktree" config --worktree --get user.email)" = "$email" ] \
    || fail "worktree user.email was not $email"
}

test_spawn_pins_fleet_identity_without_changing_other_identity_scopes() {
  local rec project out status
  project="$TMP_ROOT/fleet/home/projects/ordinary"
  rec=$(make_spawn_fixture fleet "$project")
  read_fixture "$rec"

  out=$(run_spawn "$HOME_DIR" "$PROJECTS_DIR" "$WORKTREE_DIR" "$FAKEBIN" "$GLOBAL_CONFIG" "$CAPTAIN_HOME" "$ID" "$project")
  status=$?
  expect_code 0 "$status" "fleet spawn should succeed: $out"
  assert_identity "$WORKTREE_DIR" QuinnBot quinnbot@proton.me
  [ "$(git -C "$project" config --get user.name)" = 'Project Owner' ] \
    || fail 'spawn changed the project shared user.name'
  [ "$(git -C "$project" config --get user.email)" = 'project@example.invalid' ] \
    || fail 'spawn changed the project shared user.email'
  [ "$(git config --file "$GLOBAL_CONFIG" --get user.name)" = 'Captain Personal' ] \
    || fail 'spawn changed the captain global user.name'
  [ "$(git config --file "$GLOBAL_CONFIG" --get user.email)" = 'captain@example.invalid' ] \
    || fail 'spawn changed the captain global user.email'
  pass 'fm-spawn pins QuinnBot only in the task worktree config'
}

test_epstein_directory_gets_dedicated_identity() {
  local rec project out status
  project="$TMP_ROOT/epstein/captain-home/ventures/epstein/research-core"
  rec=$(make_spawn_fixture epstein "$project")
  read_fixture "$rec"

  out=$(run_spawn "$HOME_DIR" "$PROJECTS_DIR" "$WORKTREE_DIR" "$FAKEBIN" "$GLOBAL_CONFIG" "$CAPTAIN_HOME" "$ID" "$project")
  status=$?
  expect_code 0 "$status" "Epstein-directory spawn should succeed: $out"
  assert_identity "$WORKTREE_DIR" 'Epstein Search' noreply@epsteinsearch.info
  pass 'fm-spawn uses the dedicated identity below ventures/epstein'
}

test_registered_epstein_clone_gets_dedicated_identity() {
  local rec project out status
  project="$TMP_ROOT/registered/home/projects/epstein-search"
  rec=$(make_spawn_fixture registered "$project")
  read_fixture "$rec"

  out=$(run_spawn "$HOME_DIR" "$PROJECTS_DIR" "$WORKTREE_DIR" "$FAKEBIN" "$GLOBAL_CONFIG" "$CAPTAIN_HOME" "$ID" "$project")
  status=$?
  expect_code 0 "$status" "registered Epstein clone spawn should succeed: $out"
  assert_identity "$WORKTREE_DIR" 'Epstein Search' noreply@epsteinsearch.info
  pass 'fm-spawn uses the dedicated identity for registered Epstein clones'
}

test_audit_reports_effective_identities_without_rewriting_clones() {
  local projects captain_home ordinary epstein wrong out status before after
  projects="$TMP_ROOT/audit/projects"
  captain_home="$TMP_ROOT/audit/captain-home"
  ordinary="$projects/ordinary"
  epstein="$projects/research-core"
  wrong="$projects/wrong"
  mkdir -p "$captain_home"
  fm_git_init_commit "$ordinary"
  fm_git_init_commit "$epstein"
  fm_git_init_commit "$wrong"
  git -C "$ordinary" config user.name QuinnBot
  git -C "$ordinary" config user.email quinnbot@proton.me
  git -C "$epstein" config user.name 'Epstein Search'
  git -C "$epstein" config user.email noreply@epsteinsearch.info
  git -C "$wrong" config user.name 'Wrong Identity'
  git -C "$wrong" config user.email wrong@example.invalid
  before=$(git -C "$wrong" config --list --local)

  out=$(HOME="$captain_home" "$IDENTITY" audit "$projects" 2>&1)
  status=$?
  expect_code 1 "$status" 'audit should fail when it flags an identity mismatch'
  assert_contains "$out" "ok: $ordinary identity=QuinnBot <quinnbot@proton.me>" \
    'audit did not report the fleet clone effective identity'
  assert_contains "$out" "ok: $epstein identity=Epstein Search <noreply@epsteinsearch.info>" \
    'audit did not report the Epstein clone effective identity'
  assert_contains "$out" "flag: $wrong identity=Wrong Identity <wrong@example.invalid> expected=QuinnBot <quinnbot@proton.me>" \
    'audit did not flag the wrong effective identity'
  after=$(git -C "$wrong" config --list --local)
  [ "$before" = "$after" ] || fail 'audit rewrote clone configuration'
  pass 'git identity audit is report-only and flags unexpected effective identities'
}

test_spawn_pins_fleet_identity_without_changing_other_identity_scopes
test_epstein_directory_gets_dedicated_identity
test_registered_epstein_clone_gets_dedicated_identity
test_audit_reports_effective_identities_without_rewriting_clones

echo '# fm-git-identity.test.sh: all assertions passed'
