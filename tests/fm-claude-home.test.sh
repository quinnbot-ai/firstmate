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
TEST_SECURITY_BIN="$TMP_ROOT/security-bin"
mkdir -p "$TEST_SECURITY_BIN"
cat > "$TEST_SECURITY_BIN/security" <<'SH'
#!/usr/bin/env bash
exit 44
SH
chmod 700 "$TEST_SECURITY_BIN/security"
PATH="$TEST_SECURITY_BIN:$PATH"

make_profile() {  # <dir>
  mkdir -p "$1"
  printf '{"oauthAccount":{"emailAddress":"crew@example.invalid"}}\n' > "$1/.claude.json"
}

# Portable file mode in octal. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch-triage.test.sh).
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f '%Lp' "$1" 2>/dev/null; else stat -c '%a' "$1" 2>/dev/null; fi
}

test_create_excludes_customization_surface_and_copies_credentials() {
  local case_dir data source home
  case_dir="$TMP_ROOT/create-excludes"
  data="$case_dir/data"
  source="$data/claude-crewmate/profile"
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
  [ "$(file_mode "$home")" = 700 ] \
    || fail "isolated home directory must be mode 0700"
  pass "create copies credentials and nested content while excluding customization surface"
}

test_managed_keychain_credential_is_cloned_and_removed() {
  local case_dir data source state
  case_dir="$TMP_ROOT/keychain-clone"
  data="$case_dir/data"
  source="$data/claude-crewmate/profile"
  state="$case_dir/state"
  mkdir -p "$data" "$state"
  make_profile "$source"

  python3 - "$HELPER" "$data" "$source" "$state" <<'PY'
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
from types import SimpleNamespace

helper, data, source, state = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_claude_home", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
calls = []

def fake_security(arguments, input_bytes=None):
    calls.append((arguments, input_bytes))
    if arguments[0] == "find-generic-password":
        return subprocess.CompletedProcess(arguments, 0, stdout=b"test-only-secret\n")
    return subprocess.CompletedProcess(arguments, 0, stdout=b"")

module.is_macos = lambda: True
module.run_security = fake_security
out = io.StringIO()
with contextlib.redirect_stdout(out):
    module.create_home(SimpleNamespace(data=data, source=source, task_id="keychain"))
home = out.getvalue().strip()
expected_source = module.keychain_service(source)
expected_target = module.keychain_service(home)
if calls[0][0][-1] != expected_source:
    raise AssertionError("create did not read the profile-derived Keychain service")
if calls[1][0][-2] != expected_target:
    raise AssertionError("create did not write the task-home-derived Keychain service")
if calls[1][1] != b"test-only-secret\n":
    raise AssertionError("create did not transfer the mocked credential through stdin")
module.remove_home(SimpleNamespace(data=data, state=state, task_id="keychain", home=home))
if calls[-1][0][0] != "delete-generic-password" or calls[-1][0][-1] != expected_target:
    raise AssertionError("remove did not delete the task-home-derived Keychain service")
PY
  expect_code 0 "$?" "managed Keychain credentials must be cloned and removed without real Keychain access"
  pass "managed Keychain credentials are cloned into and removed with task homes"
}

test_readiness_requires_a_logged_in_copy() {
  local case_dir data profile state fakebin out result
  case_dir="$TMP_ROOT/copy-readiness"
  data="$case_dir/data"
  profile="$data/claude-crewmate/profile"
  state="$case_dir/state"
  fakebin="$case_dir/fakebin"
  mkdir -p "$profile" "$state" "$fakebin"
  printf '{"hasCompletedOnboarding":true}\n' > "$profile/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"test-access"}}\n' > "$profile/.credentials.json"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
if [ -f "${CLAUDE_CONFIG_DIR:-}/.credentials.json" ]; then
  printf '%s\n' '{"loggedIn":true}'
  exit 0
fi
printf '%s\n' '{"loggedIn":false}'
exit 1
SH
  cat > "$fakebin/security" <<'SH'
#!/usr/bin/env bash
exit 44
SH
  chmod 700 "$fakebin/claude" "$fakebin/security"

  out=$(PATH="$fakebin:$PATH" FM_CLAUDE_CREW_CLI="$fakebin/claude" bash -c '
    source "$1"
    fm_claude_crew_profile_ready "$2" "$3" "$4"
  ' _ "$ROOT/bin/fm-claude-crew-lib.sh" "$profile" "$data" "$state" 2>&1)
  result=$?
  expect_code 0 "$result" "readiness should accept a logged-in copy-shaped fixture"
  [ -z "$out" ] || fail "readiness should not print credential data"
  find "$data/claude-crewmate" -maxdepth 1 -name '.fm-claude-home.*' | grep -q . \
    && fail "readiness probe left a managed home behind"

  rm "$profile/.credentials.json"
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$profile" ]; then
  printf '%s\\n' '{"loggedIn":true}'
  exit 0
fi
printf '%s\\n' '{"loggedIn":false}'
exit 1
SH
  chmod 700 "$fakebin/claude"
  PATH="$fakebin:$PATH" FM_CLAUDE_CREW_CLI="$fakebin/claude" bash -c '
    source "$1"
    fm_claude_crew_profile_ready "$2" "$3" "$4"
  ' _ "$ROOT/bin/fm-claude-crew-lib.sh" "$profile" "$data" "$state"
  result=$?
  expect_code 1 "$result" "readiness must reject a profile whose private copy is logged out"
  find "$data/claude-crewmate" -maxdepth 1 -name '.fm-claude-home.*' | grep -q . \
    && fail "failed readiness probe left a managed home behind"
  pass "readiness validates a disposable private copy instead of only the profile path"
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

test_remove_preserves_a_replacement_after_validation() {
  local case_dir data source state home status
  case_dir="$TMP_ROOT/remove-replaced"
  data="$case_dir/data"
  source="$case_dir/profile"
  state="$case_dir/state"
  mkdir -p "$data" "$state"
  make_profile "$source"
  home=$(python3 "$HELPER" --data "$data" --source "$source" --task-id owner --create)

  python3 - "$HELPER" "$data" "$state" "$home" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
from types import SimpleNamespace

helper, data, state, home = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_claude_home", helper)
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
        module.remove_home(SimpleNamespace(data=data, state=state, task_id="owner", home=home))
    except SystemExit as error:
        if error.code != 1:
            raise
    else:
        raise AssertionError("removal accepted a replacement home")
if not os.path.isfile(os.path.join(home, "replacement")):
    raise AssertionError("removal deleted the replacement home")
PY
  status=$?
  expect_code 0 "$status" "remove must preserve a home replaced after ownership validation"
  [ -f "$home/replacement" ] || fail "remove deleted a replacement home"
  pass "remove preserves a replacement after ownership validation"
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

test_create_abort_cleanup_survives_keychain_failure() {
  local case_dir data source out
  case_dir="$TMP_ROOT/abort-keychain"
  data="$case_dir/data"
  source="$data/claude-crewmate/profile"
  mkdir -p "$data"
  make_profile "$source"

  out=$(python3 - "$HELPER" "$data" "$source" 2>&1 <<'PY'
import importlib.util
import os
import subprocess
import sys
from types import SimpleNamespace

helper, data, source = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_claude_home", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def fake_security(arguments, input_bytes=None):
    if arguments[0] == "find-generic-password":
        return subprocess.CompletedProcess(arguments, 0, stdout=b"test-only-secret\n")
    if arguments[0] == "delete-generic-password":
        return subprocess.CompletedProcess(arguments, 25, stdout=b"")
    return subprocess.CompletedProcess(arguments, 0, stdout=b"")

def failing_write_file(*a, **kw):
    raise OSError(28, "No space left on device")

module.is_macos = lambda: True
module.run_security = fake_security
module.write_file = failing_write_file
try:
    module.create_home(SimpleNamespace(data=data, source=source, task_id="abort"))
except SystemExit:
    pass
else:
    raise AssertionError("create must fail when the ownership marker cannot be written")
base = os.path.join(data, "claude-crewmate")
leftovers = [n for n in os.listdir(base) if n.startswith(".fm-claude-home.")]
if leftovers:
    raise AssertionError(f"abort cleanup left a partial home behind: {leftovers}")
PY
)
  expect_code 0 "$?" "abort cleanup must still delete the partial home when Keychain removal fails"
  assert_contains "$out" "No space left on device" \
    "the original creation failure must survive the abort cleanup"
  pass "create abort cleanup removes the partial home even when Keychain removal fails"
}

test_remove_deletes_keychain_entry_for_absent_home() {
  local case_dir data source state
  case_dir="$TMP_ROOT/remove-absent-keychain"
  data="$case_dir/data"
  source="$data/claude-crewmate/profile"
  state="$case_dir/state"
  mkdir -p "$data" "$state"
  make_profile "$source"

  python3 - "$HELPER" "$data" "$source" "$state" <<'PY'
import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
from types import SimpleNamespace

helper, data, source, state = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_claude_home", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
calls = []

def fake_security(arguments, input_bytes=None):
    calls.append(arguments)
    if arguments[0] == "find-generic-password":
        return subprocess.CompletedProcess(arguments, 0, stdout=b"test-only-secret\n")
    return subprocess.CompletedProcess(arguments, 0, stdout=b"")

module.is_macos = lambda: True
module.run_security = fake_security
out = io.StringIO()
with contextlib.redirect_stdout(out):
    module.create_home(SimpleNamespace(data=data, source=source, task_id="gone"))
home = out.getvalue().strip()
expected_target = module.keychain_service(home)
shutil.rmtree(home)
module.remove_home(SimpleNamespace(data=data, state=state, task_id="gone", home=home))
deletes = [c for c in calls if c[0] == "delete-generic-password"]
if not deletes or deletes[-1][-1] != expected_target:
    raise AssertionError("remove did not delete the Keychain entry for an already-absent home")
PY
  expect_code 0 "$?" "removing an already-absent home must still delete its Keychain entry"
  pass "remove deletes the task-home Keychain entry even when the home is already gone"
}

test_create_excludes_customization_surface_and_copies_credentials
test_managed_keychain_credential_is_cloned_and_removed
test_create_abort_cleanup_survives_keychain_failure
test_remove_deletes_keychain_entry_for_absent_home
test_readiness_requires_a_logged_in_copy
test_create_refuses_symlink_in_profile
test_remove_refuses_when_owned_by_another_task
test_remove_preserves_home_referenced_by_another_task
test_remove_is_a_no_op_when_already_absent
test_remove_preserves_a_replacement_after_validation
test_create_generates_fresh_names_across_calls

echo "# all fm-claude-home tests passed"
