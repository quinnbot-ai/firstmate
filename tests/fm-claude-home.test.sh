#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-home.py, the private per-task home helper
# behind Claude crewmate second-account isolation. fm-spawn.sh's launch-time
# integration (byte-identical absent/credential-less behavior, meta, symlink
# escapes on the base directory) is covered in
# tests/fm-spawn-dispatch-profile.test.sh; this file exercises the helper
# directly for the properties that do not need a full spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-claude-home.py"
TMP_ROOT=$(fm_test_tmproot fm-claude-home-tests)

make_profile() {  # <dir>
  mkdir -p "$1"
  printf '{"oauthAccount":{"emailAddress":"crew@example.invalid"}}\n' > "$1/.claude.json"
}

test_create_excludes_customization_surface_and_copies_credentials() {
  local case_dir data source home
  case_dir="$TMP_ROOT/create-excludes"
  data="$case_dir/data"
  source="$case_dir/profile"
  mkdir -p "$data"
  make_profile "$source"
  mkdir -p "$source/backups" "$source/hooks" "$source/commands"
  printf '%s\n' 'b' > "$source/backups/entry.json"
  printf '%s\n' 'h' > "$source/hooks/x.sh"
  printf '{}' > "$source/settings.json"
  printf '{}' > "$source/.mcp.json"

  home=$(python3 "$HELPER" --data "$data" --source "$source" --task-id t1 --create)
  [ -d "$home" ] || fail "create did not print a directory path"
  assert_present "$home/.claude.json" "isolated home did not copy the credential file"
  assert_present "$home/backups/entry.json" "isolated home did not copy nested profile content"
  [ ! -e "$home/hooks" ] || fail "isolated home retained the profile's hooks directory"
  [ ! -e "$home/commands" ] || fail "isolated home retained the profile's commands directory"
  [ ! -e "$home/settings.json" ] || fail "isolated home retained the profile's settings.json"
  [ ! -e "$home/.mcp.json" ] || fail "isolated home retained the profile's .mcp.json"
  [ "$(stat -f '%Lp' "$home" 2>/dev/null || stat -c '%a' "$home")" = 700 ] \
    || fail "isolated home directory must be mode 0700"
  pass "create copies credentials and nested content while excluding customization surface"
}

test_create_refuses_symlink_in_profile() {
  local case_dir data source out status
  case_dir="$TMP_ROOT/create-symlink-source"
  data="$case_dir/data"
  source="$case_dir/profile"
  mkdir -p "$data"
  make_profile "$source"
  ln -s /etc/passwd "$source/evil-link"

  out=$(python3 "$HELPER" --data "$data" --source "$source" --task-id t2 --create 2>&1)
  status=$?
  expect_code 1 "$status" "create must refuse a symlink inside the profile"
  assert_contains "$out" "is not a file or directory" "create did not explain the symlink refusal"
  find "$data/claude-crewmate" -maxdepth 1 -name '.fm-claude-home.*' 2>/dev/null | grep -q . \
    && fail "a symlink refusal must not leave a partially created home behind"
  pass "create refuses a profile directory containing a symlink"
}

test_remove_refuses_when_owned_by_another_task() {
  local case_dir data source state home out status
  case_dir="$TMP_ROOT/remove-wrong-owner"
  data="$case_dir/data"
  source="$case_dir/profile"
  state="$case_dir/state"
  mkdir -p "$data" "$state"
  make_profile "$source"
  home=$(python3 "$HELPER" --data "$data" --source "$source" --task-id owner-a --create)

  out=$(python3 "$HELPER" --data "$data" --state "$state" --task-id owner-b --home "$home" --remove 2>&1)
  status=$?
  expect_code 1 "$status" "remove must refuse a home owned by a different task"
  assert_contains "$out" "does not belong to task owner-b" "remove did not explain the ownership refusal"
  [ -d "$home" ] || fail "a rejected removal must not delete the home"

  out=$(python3 "$HELPER" --data "$data" --state "$state" --task-id owner-a --home "$home" --remove 2>&1)
  status=$?
  expect_code 0 "$status" "remove should succeed for the owning task"
  [ ! -e "$home" ] || fail "remove did not delete a home owned by the requesting task"
  pass "remove enforces per-task ownership before deleting a private home"
}

test_remove_preserves_home_referenced_by_another_task() {
  local case_dir data source state home out status
  case_dir="$TMP_ROOT/remove-referenced"
  data="$case_dir/data"
  source="$case_dir/profile"
  state="$case_dir/state"
  mkdir -p "$data" "$state"
  make_profile "$source"
  home=$(python3 "$HELPER" --data "$data" --source "$source" --task-id ref-a --create)
  printf 'claude_crewmate_home=%s\n' "$home" > "$state/ref-b.meta"

  out=$(python3 "$HELPER" --data "$data" --state "$state" --task-id ref-a --home "$home" --remove 2>&1)
  status=$?
  expect_code 1 "$status" "remove must refuse a home another task's meta still references"
  assert_contains "$out" "referenced by another active task" "remove did not explain the reference refusal"
  [ -d "$home" ] || fail "a rejected removal must not delete the referenced home"
  pass "remove preserves a home still referenced by another task's meta"
}

test_remove_is_a_no_op_when_already_absent() {
  local case_dir data state out status
  case_dir="$TMP_ROOT/remove-absent"
  data="$case_dir/data"
  state="$case_dir/state"
  mkdir -p "$data" "$state"

  out=$(python3 "$HELPER" --data "$data" --state "$state" --task-id gone \
    --home "$data/claude-crewmate/.fm-claude-home.0123456789abcdef0123456789abcdef" --remove 2>&1)
  status=$?
  expect_code 0 "$status" "removing an already-absent home should be a silent no-op"
  [ -z "$out" ] || fail "an already-absent home removal should print nothing, got: $out"
  pass "remove is a no-op when the home is already absent"
}

test_create_generates_fresh_names_across_calls() {
  local case_dir data source home1 home2
  case_dir="$TMP_ROOT/create-fresh-names"
  data="$case_dir/data"
  source="$case_dir/profile"
  mkdir -p "$data"
  make_profile "$source"
  home1=$(python3 "$HELPER" --data "$data" --source "$source" --task-id a --create)
  home2=$(python3 "$HELPER" --data "$data" --source "$source" --task-id b --create)
  [ "$home1" != "$home2" ] || fail "two creations produced the same private home name"
  case "${home1##*/}" in .fm-claude-home.*) : ;; *) fail "unexpected home name shape: $home1" ;; esac
  pass "create generates a fresh, uniquely named private home on every call"
}

test_create_excludes_customization_surface_and_copies_credentials
test_create_refuses_symlink_in_profile
test_remove_refuses_when_owned_by_another_task
test_remove_preserves_home_referenced_by_another_task
test_remove_is_a_no_op_when_already_absent
test_create_generates_fresh_names_across_calls

echo "# all fm-claude-home tests passed"
