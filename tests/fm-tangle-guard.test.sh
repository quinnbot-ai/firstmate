#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-lease pane cwd
# (so the spawn's worktree-resolution loop resolves to a path we control), names
# the session on '#S', and swallows window ops. Echoes the fakebin dir.
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
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_LEASED_WORKTREE:-${FM_FAKE_PANE_PATH:?}}" ;;
esac
exit 0
SH
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *".treehouse-lease."*)
    [ -z "${FM_FAKE_TREEHOUSE_HANDOFF_RM_FAIL:-}" ] || exit 19
    ;;
esac
exec /bin/rm "$@"
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@"
if [ -n "${FM_FAKE_META_MV_READY:-}" ] && [ "${2:-}" = "${FM_FAKE_META_MV_DEST:-}" ]; then
  : > "$FM_FAKE_META_MV_READY"
  while [ ! -e "${FM_FAKE_META_MV_CONTINUE:?}" ]; do
    sleep 0.05
  done
fi
SH
  chmod +x "$fakebin/treehouse" "$fakebin/rm" "$fakebin/mv"
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 lease_path
  lease_path=${6:-$pane}
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" FM_FAKE_LEASED_WORKTREE="$lease_path" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin" "$TMP_ROOT/spawn-wt"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin" "$TMP_ROOT/spawn-wt"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn treehouse lease hold --------------------------------

# A meta persists while a task is held for review, including when the pane is
# detached. Older tasks have no treehouse_lease=1 marker, so a new spawn must
# fail before it asks treehouse for any slot rather than risking a destructive
# pool reset of that recorded worktree.
make_spawn_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_spawn_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TREEHOUSE_REC:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_TREEHOUSE_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    case "$*" in
      *"treehouse get --lease"*) bash -c "$4" ;;
    esac
    exit 0
    ;;
  list-windows|has-session|new-session|new-window) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_TREEHOUSE_REC:?}"
case "${1:-}" in
  get)
    if [ -n "${FM_FAKE_TREEHOUSE_GET_READY:-}" ]; then
      : > "$FM_FAKE_TREEHOUSE_GET_READY"
      while [ ! -e "${FM_FAKE_TREEHOUSE_GET_CONTINUE:?}" ]; do
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_LEASED_WORKTREE:?}"
    ;;
  return) [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17 ;;
esac
exit 0
SH
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAIL_TASK_MKTEMP:-0}" = 1 ] && [[ "$*" == *'/tmp/fm-'* ]]; then
  exit 1
fi
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$fakebin/treehouse" "$fakebin/mktemp"
  printf '%s\n' "$fakebin"
}

run_spawn_lease_case() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6 kind=${7:-} lease_path
  lease_path=${8:-$pane}
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  if [ "$kind" = scout ]; then
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
      FM_FAKE_LEASED_WORKTREE="$lease_path" FM_TREEHOUSE_REC="$rec" PATH="$fakebin:$PATH" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --scout 2>&1
  else
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
      FM_FAKE_LEASED_WORKTREE="$lease_path" FM_TREEHOUSE_REC="$rec" PATH="$fakebin:$PATH" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1
  fi
}

test_spawn_refuses_legacy_held_worktree() {
  local home proj held fakebin rec out status
  home="$TMP_ROOT/lease-held-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-held-proj")
  held="$TMP_ROOT/lease-held-wt"
  git -C "$proj" worktree add -q --detach "$held" >/dev/null 2>&1
  fm_write_meta "$home/state/held-ship.meta" \
    "window=firstmate:fm-held-ship" "worktree=$held" "project=$proj" "kind=ship"
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-held-fake")
  rec="$TMP_ROOT/lease-held-treehouse.log"; : > "$rec"

  out=$(run_spawn_lease_case "$home" new-ship-aa1 "$proj" "$held" "$fakebin" "$rec"); status=$?
  expect_code 1 "$status" "spawn must refuse when a live ship meta holds a pre-lease slot"
  assert_contains "$out" "live task held-ship still holds unleased worktree $held" \
    "held ship refusal did not name the protected task and worktree"
  [ ! -s "$rec" ] || fail "held ship refusal invoked treehouse despite the live unleased meta"
  assert_absent "$home/state/new-ship-aa1.meta" "held ship refusal must not create a new task meta"
  pass "fm-spawn: refuses before treehouse allocation when a live ship meta holds an unleased slot"
}

test_spawn_refuses_detached_legacy_held_worktree() {
  local home proj held fakebin rec out status
  home="$TMP_ROOT/lease-detached-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-detached-proj")
  held="$TMP_ROOT/lease-detached-wt"
  git -C "$proj" worktree add -q --detach "$held" >/dev/null 2>&1
  fm_write_meta "$home/state/held-scout.meta" \
    "window_detached_tmux=firstmate:fm-held-scout" "worktree=$held" "project=$proj" "kind=scout"
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-detached-fake")
  rec="$TMP_ROOT/lease-detached-treehouse.log"; : > "$rec"

  out=$(run_spawn_lease_case "$home" new-scout-bb2 "$proj" "$held" "$fakebin" "$rec" scout); status=$?
  expect_code 1 "$status" "spawn must refuse when detached scout metadata holds a pre-lease slot"
  assert_contains "$out" "live task held-scout still holds unleased worktree $held" \
    "detached scout refusal did not protect the recorded worktree"
  [ ! -s "$rec" ] || fail "detached-meta refusal invoked treehouse despite the live unleased meta"
  assert_absent "$home/state/new-scout-bb2.meta" "detached scout refusal must not create a new task meta"
  pass "fm-spawn: detached-window scout metadata receives the same held-slot refusal"
}

test_spawn_leases_normal_treehouse_allocation() {
  local home proj wt fakebin rec out status
  home="$TMP_ROOT/lease-normal-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-normal-proj")
  wt="$TMP_ROOT/lease-normal-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-normal-fake")
  rec="$TMP_ROOT/lease-normal-treehouse.log"; : > "$rec"

  out=$(run_spawn_lease_case "$home" normal-scout-cc3 "$proj" "$wt" "$fakebin" "$rec" scout); status=$?
  expect_code 0 "$status" "normal scout spawn should acquire a treehouse lease"
  assert_contains "$out" "spawned normal-scout-cc3" "normal leased spawn did not report success"
  assert_grep "treehouse get --lease --lease-holder normal-scout-cc3" "$rec" \
    "normal spawn did not request a durable treehouse lease under its task id"
  assert_contains "$(cat "$home/state/normal-scout-cc3.meta")" "treehouse_lease=1" \
    "normal leased spawn did not record its durable pool hold"
  pass "fm-spawn: normal allocation leases its treehouse slot until teardown"
}

test_spawn_rolls_back_lease_after_isolation_failure() {
  local home proj wt invalid fakebin rec out status id
  home="$TMP_ROOT/lease-isolation-rollback-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-isolation-rollback-proj")
  wt="$TMP_ROOT/lease-isolation-rollback-wt"
  invalid="$TMP_ROOT/lease-isolation-rollback-invalid"
  mkdir -p "$invalid"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-isolation-rollback-fake")
  rec="$TMP_ROOT/lease-isolation-rollback-treehouse.log"; : > "$rec"
  id=lease-isolation-rollback-dd4

  out=$(run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must fail when the pane path is not an isolated worktree"
  assert_contains "$out" "did not yield an isolated worktree" "isolation failure did not reach the spawn guard"
  assert_grep "treehouse return --force $wt" "$rec" \
    "isolation failure did not return the leased worktree recorded by the handoff"
  assert_absent "$home/state/$id.meta" "isolation failure must not create a task meta"
  pass "fm-spawn: rolls back a leased slot when isolation validation fails"
}

test_spawn_refuses_to_roll_back_primary_checkout() {
  local home proj invalid fakebin rec out status id handoff
  home="$TMP_ROOT/lease-primary-rollback-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-primary-rollback-proj")
  invalid="$TMP_ROOT/lease-primary-rollback-invalid"
  mkdir -p "$invalid"
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-primary-rollback-fake")
  rec="$TMP_ROOT/lease-primary-rollback-treehouse.log"; : > "$rec"
  id=lease-primary-rollback-dd5

  out=$(run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$proj"); status=$?
  expect_code 1 "$status" "spawn must fail when the pane path is not an isolated worktree"
  assert_contains "$out" "refusing to roll back invalid treehouse lease path '$proj'" \
    "primary-checkout lease rollback was not rejected"
  assert_no_grep "treehouse return --force $proj" "$rec" \
    "rollback must not force-return the primary checkout"
  handoff=$(printf '%s\n' "$home/state/.${id}.treehouse-lease."*)
  assert_present "$handoff" "rejected primary-checkout rollback must retain its handoff"
  pass "fm-spawn: never force-returns a primary checkout from a lease handoff"
}

test_spawn_rolls_back_lease_after_setup_failure() {
  local home proj wt fakebin rec out status id
  home="$TMP_ROOT/lease-setup-rollback-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-setup-rollback-proj")
  wt="$TMP_ROOT/lease-setup-rollback-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-setup-rollback-fake")
  rec="$TMP_ROOT/lease-setup-rollback-treehouse.log"; : > "$rec"
  id="lease-setup-rollback-${RANDOM}${RANDOM}"

  out=$(FM_FAIL_TASK_MKTEMP=1 run_spawn_lease_case "$home" "$id" "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 1 "$status" "spawn must fail when post-lease task temp setup fails"
  assert_grep "treehouse return --force $wt" "$rec" \
    "post-lease setup failure did not return the leased worktree"
  assert_absent "$home/state/$id.meta" "post-lease setup failure must not create a task meta"
  pass "fm-spawn: rolls back a leased slot when later setup fails"
}

test_spawn_recovers_failed_lease_rollback() {
  local home proj wt invalid fakebin rec out status id handoff returns
  home="$TMP_ROOT/lease-recovery-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-recovery-proj")
  wt="$TMP_ROOT/lease-recovery-wt"
  invalid="$TMP_ROOT/lease-recovery-invalid"
  mkdir -p "$invalid"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-recovery-fake")
  rec="$TMP_ROOT/lease-recovery-treehouse.log"; : > "$rec"
  id=lease-recovery-ff6

  out=$(FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must fail when the initial lease rollback fails"
  assert_contains "$out" "handoff retained" "failed lease rollback did not retain its durable handoff"
  handoff=$(printf '%s\n' "$home/state/.${id}.treehouse-lease."*)
  assert_present "$handoff" "failed lease rollback did not leave a recovery handoff"

  out=$(run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "recovery retry should continue to the expected isolation refusal"
  assert_contains "$out" "recovered treehouse lease handoff" "retry did not recover the earlier failed lease rollback"
  for handoff in "$home/state/.${id}.treehouse-lease."*; do
    [ ! -e "$handoff" ] || fail "recovered lease handoff remained at $handoff"
  done
  returns=$(grep -Fc "treehouse return --force $wt" "$rec")
  [ "$returns" -eq 3 ] || fail "expected failed rollback, recovery, and retry rollback returns; got $returns"
  assert_absent "$home/state/$id.meta" "failed rollback recovery must not create task metadata"
  pass "fm-spawn: recovers a retained lease handoff before retrying allocation"
}

test_spawn_tombstones_returned_lease_handoff() {
  local home proj wt invalid fakebin rec out status id retry_id handoff returns
  home="$TMP_ROOT/lease-returned-tombstone-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-returned-tombstone-proj")
  wt="$TMP_ROOT/lease-returned-tombstone-wt"
  invalid="$TMP_ROOT/lease-returned-tombstone-invalid"
  mkdir -p "$invalid"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-returned-tombstone-fake")
  rec="$TMP_ROOT/lease-returned-tombstone-treehouse.log"; : > "$rec"
  id=lease-returned-tombstone-ff7
  retry_id=lease-returned-tombstone-gg8

  out=$(FM_FAKE_TREEHOUSE_HANDOFF_RM_FAIL=1 run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must fail when the post-rollback handoff removal fails"
  handoff=$(printf '%s\n' "$home/state/.${id}.treehouse-lease."*)
  assert_present "$handoff" "returned lease rollback did not retain a tombstone"
  assert_contains "$(cat "$handoff")" "returned=$wt" \
    "returned lease rollback handoff was not tombstoned"
  returns=$(grep -Fc "treehouse return --force $wt" "$rec")
  [ "$returns" -eq 1 ] || fail "expected one completed rollback before tombstone recovery; got $returns"

  out=$(run_spawn_lease_case "$home" "$retry_id" "$proj" "$wt" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 0 "$status" "spawn should clear a returned handoff before allocating"
  assert_contains "$out" "cleared returned treehouse lease handoff" \
    "returned handoff was not cleared without replaying its return"
  assert_absent "$handoff" "cleared returned handoff remained durable"
  returns=$(grep -Fc "treehouse return --force $wt" "$rec")
  [ "$returns" -eq 1 ] || fail "returned handoff recovery replayed a completed return; got $returns returns"
  pass "fm-spawn: tombstones a returned lease before retrying handoff cleanup"
}

test_spawn_keeps_published_lease_on_abort() {
  local home proj wt fakebin rec out status id ready go pid
  home="$TMP_ROOT/lease-published-abort-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-published-abort-proj")
  wt="$TMP_ROOT/lease-published-abort-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-published-abort-fake")
  rec="$TMP_ROOT/lease-published-abort-treehouse.log"; : > "$rec"
  id=lease-published-abort-hh9
  ready="$TMP_ROOT/lease-published-abort-ready"
  go="$TMP_ROOT/lease-published-abort-go"
  out="$TMP_ROOT/lease-published-abort.out"

  FM_FAKE_META_MV_READY="$ready" FM_FAKE_META_MV_CONTINUE="$go" \
    FM_FAKE_META_MV_DEST="$home/state/$id.meta" \
    run_spawn_lease_case "$home" "$id" "$proj" "$wt" "$fakebin" "$rec" > "$out" &
  pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  assert_present "$ready" "spawn did not pause after publishing its task metadata"
  assert_present "$home/state/$id.meta" "published lease metadata was not visible before abort"
  kill -TERM "$pid"
  : > "$go"
  wait "$pid"; status=$?
  expect_code 143 "$status" "spawn should terminate from the post-publish abort signal"
  assert_contains "$(cat "$home/state/$id.meta")" "treehouse_lease=1" \
    "published task metadata lost its durable lease marker"
  assert_no_grep "treehouse return --force $wt" "$rec" \
    "abort cleanup returned a worktree already published in task metadata"
  pass "fm-spawn: abort cleanup recognizes lease metadata published before its in-memory commit flag"
}

test_spawn_refuses_empty_lease_handoff() {
  local home proj wt fakebin rec out status handoff
  home="$TMP_ROOT/lease-empty-handoff-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-empty-handoff-proj")
  wt="$TMP_ROOT/lease-empty-handoff-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-empty-handoff-fake")
  rec="$TMP_ROOT/lease-empty-handoff-treehouse.log"; : > "$rec"
  handoff="$home/state/.crashed.treehouse-lease.token"
  : > "$handoff"

  out=$(run_spawn_lease_case "$home" empty-handoff-jj1 "$proj" "$wt" "$fakebin" "$rec" scout); status=$?
  expect_code 1 "$status" "spawn must refuse an empty lease handoff"
  assert_contains "$out" "refusing to recover empty treehouse lease handoff" \
    "empty lease handoff was not retained for safe inspection"
  assert_present "$handoff" "empty lease handoff must remain durable"
  [ ! -s "$rec" ] || fail "empty lease handoff must block allocation before treehouse runs"
  pass "fm-spawn: retains an empty lease handoff instead of losing an in-flight acquisition"
}

test_spawn_discards_legacy_handoff_writer_temporary() {
  local home proj wt fakebin rec out status writer_temp gets
  home="$TMP_ROOT/lease-writer-temp-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-writer-temp-proj")
  wt="$TMP_ROOT/lease-writer-temp-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-writer-temp-fake")
  rec="$TMP_ROOT/lease-writer-temp-treehouse.log"; : > "$rec"
  writer_temp="$home/state/..interrupted-writer-kk2.treehouse-lease.token.tmp.partial"
  printf 'returning=%s\n' "$wt" > "$writer_temp"

  out=$(run_spawn_lease_case "$home" lease-writer-temp-ll3 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn should ignore an interrupted legacy handoff writer temporary"
  assert_contains "$out" "cleared stale treehouse lease handoff writer temporary" \
    "spawn did not identify the interrupted writer temporary"
  assert_absent "$writer_temp" "spawn retained an interrupted writer temporary"
  gets=$(grep -Fc "treehouse get --lease" "$rec")
  [ "$gets" -eq 1 ] || fail "interrupted writer temporary blocked or altered normal allocation"
  assert_no_grep "treehouse return --force $wt" "$rec" \
    "interrupted writer temporary was mistaken for a durable handoff"
  pass "fm-spawn: discards interrupted legacy handoff writer temporaries"
}

test_spawn_serializes_lease_handoff_publication() {
  local home proj wt fakebin rec first_out second_out ready go first_pid second_pid status gets
  home="$TMP_ROOT/lease-transaction-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-transaction-proj")
  wt="$TMP_ROOT/lease-transaction-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-transaction-fake")
  rec="$TMP_ROOT/lease-transaction-treehouse.log"; : > "$rec"
  first_out="$TMP_ROOT/lease-transaction-first.out"
  second_out="$TMP_ROOT/lease-transaction-second.out"
  ready="$TMP_ROOT/lease-transaction-ready"
  go="$TMP_ROOT/lease-transaction-go"

  FM_FAKE_TREEHOUSE_GET_READY="$ready" FM_FAKE_TREEHOUSE_GET_CONTINUE="$go" \
    run_spawn_lease_case "$home" lease-transaction-first-kk2 "$proj" "$wt" "$fakebin" "$rec" > "$first_out" &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  assert_present "$ready" "first spawn did not reach treehouse acquisition"

  run_spawn_lease_case "$home" lease-transaction-second-ll3 "$proj" "$wt" "$fakebin" "$rec" > "$second_out" &
  second_pid=$!
  sleep 0.2
  kill -0 "$second_pid" 2>/dev/null || fail "second spawn did not wait for the active lease transaction"
  gets=$(grep -Fc "treehouse get --lease" "$rec")
  [ "$gets" -eq 1 ] || fail "second spawn reached treehouse before the first published its lease"
  assert_no_grep "treehouse return --force $wt" "$rec" \
    "second spawn reclaimed the first in-flight lease"

  : > "$go"
  wait "$first_pid"; status=$?
  expect_code 0 "$status" "first spawn should publish its lease metadata"
  wait "$second_pid"; status=$?
  expect_code 0 "$status" "second spawn should proceed after the lease transaction completes"
  pass "fm-spawn: serializes lease handoff recovery until task metadata is published"
}

test_spawn_clears_committed_lease_handoff() {
  local home proj wt fakebin rec out status handoff
  home="$TMP_ROOT/lease-committed-handoff-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-committed-handoff-proj")
  wt="$TMP_ROOT/lease-committed-handoff-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-committed-handoff-fake")
  rec="$TMP_ROOT/lease-committed-handoff-treehouse.log"; : > "$rec"

  out=$(run_spawn_lease_case "$home" lease-committed-first-mm4 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "first spawn should commit its durable lease metadata"
  handoff="$home/state/.stale.treehouse-lease.token"
  printf '%s\n' "$wt" > "$handoff"

  out=$(run_spawn_lease_case "$home" lease-committed-second-nn5 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn should clear a handoff superseded by committed metadata"
  assert_contains "$out" "cleared committed treehouse lease handoff" \
    "committed handoff was not recognized as superseded"
  assert_absent "$handoff" "superseded committed handoff must be removed"
  assert_no_grep "treehouse return --force $wt" "$rec" \
    "committed task worktree must never be reclaimed from a stale handoff"
  pass "fm-spawn: clears stale handoffs without returning committed leased worktrees"
}

test_spawn_refuses_returned_handoff_with_live_metadata() {
  local home proj wt fakebin rec out status handoff gets
  home="$TMP_ROOT/lease-returned-live-meta-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-returned-live-meta-proj")
  wt="$TMP_ROOT/lease-returned-live-meta-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-returned-live-meta-fake")
  rec="$TMP_ROOT/lease-returned-live-meta-treehouse.log"; : > "$rec"

  out=$(run_spawn_lease_case "$home" lease-returned-first-oo6 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "first spawn should commit lease metadata"
  handoff="$home/state/.lease-returned-first-oo6.treehouse-lease.returned"
  printf 'returned=%s\n' "$wt" > "$handoff"

  out=$(run_spawn_lease_case "$home" lease-returned-second-pp7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 1 "$status" "spawn must refuse a returned handoff while its metadata remains"
  assert_contains "$out" "matching task metadata remains" \
    "spawn did not identify the unsafe returned handoff state"
  assert_present "$handoff" "spawn must retain the returned handoff for fm-teardown recovery"
  gets=$(grep -Fc "treehouse get --lease" "$rec")
  [ "$gets" -eq 1 ] || fail "spawn allocated despite a returned handoff with live metadata"
  pass "fm-spawn: refuses returned handoffs until teardown finalizes metadata"
}

test_spawn_recovers_lease_handoff_for_another_task() {
  local home proj wt invalid fakebin rec out status id retry_id handoff returns
  home="$TMP_ROOT/lease-recovery-other-task-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-recovery-other-task-proj")
  wt="$TMP_ROOT/lease-recovery-other-task-wt"
  invalid="$TMP_ROOT/lease-recovery-other-task-invalid"
  mkdir -p "$invalid"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-recovery-other-task-fake")
  rec="$TMP_ROOT/lease-recovery-other-task-treehouse.log"; : > "$rec"
  id=lease-recovery-source-hh8
  retry_id=lease-recovery-retry-ii9

  out=$(FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must retain a failed lease rollback"
  handoff=$(printf '%s\n' "$home/state/.${id}.treehouse-lease."*)
  assert_present "$handoff" "failed rollback did not leave a recovery handoff"

  out=$(run_spawn_lease_case "$home" "$retry_id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "recovery with another task id should continue to the expected isolation refusal"
  assert_contains "$out" "recovered treehouse lease handoff" \
    "different task id did not recover the earlier failed lease rollback"
  [ ! -e "$handoff" ] || fail "recovered lease handoff remained at $handoff"
  returns=$(grep -Fc "treehouse return --force $wt" "$rec")
  [ "$returns" -eq 3 ] || fail "expected failed rollback, recovery, and retry rollback returns; got $returns"
  assert_absent "$home/state/$retry_id.meta" "handoff recovery must not create task metadata"
  pass "fm-spawn: recovers retained same-project leases regardless of retry task id"
}

test_spawn_refuses_cross_project_lease_handoff() {
  local home proj wt invalid other fakebin rec out status id retry_id handoff gets
  home="$TMP_ROOT/lease-cross-project-home"
  mkdir -p "$home/state" "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-cross-project-proj")
  wt="$TMP_ROOT/lease-cross-project-wt"
  invalid="$TMP_ROOT/lease-cross-project-invalid"
  mkdir -p "$invalid"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  other=$(make_repo "$TMP_ROOT/lease-cross-project-other")
  fakebin=$(make_spawn_lease_fakebin "$TMP_ROOT/lease-cross-project-fake")
  rec="$TMP_ROOT/lease-cross-project-treehouse.log"; : > "$rec"
  id=lease-cross-project-gg7
  retry_id=lease-cross-project-retry-jj0

  out=$(FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_spawn_lease_case "$home" "$id" "$proj" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must retain a failed lease rollback before cross-project retry"
  handoff=$(printf '%s\n' "$home/state/.${id}.treehouse-lease."*)
  assert_present "$handoff" "failed lease rollback did not leave a cross-project recovery handoff"
  gets=$(grep -Fc "treehouse get --lease" "$rec")

  out=$(run_spawn_lease_case "$home" "$retry_id" "$other" "$invalid" "$fakebin" "$rec" '' "$wt"); status=$?
  expect_code 1 "$status" "spawn must refuse a different task id with another project's lease handoff"
  assert_contains "$out" "belongs to another project" "cross-project handoff refusal did not identify the ownership mismatch"
  assert_present "$handoff" "cross-project handoff refusal must retain the original lease record"
  [ "$(grep -Fc "treehouse get --lease" "$rec")" -eq "$gets" ] || fail "cross-project handoff refusal allocated another treehouse lease"
  pass "fm-spawn: refuses cross-project lease handoffs before allocation"
}

# --- GUARD 1d: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'treehouse %s\n' "$*" >> "$FM_TMUX_REC"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:?}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_TMUX_REC="$rec" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse lease acquisition records the task id before its stable window enters the worktree.
  assert_grep "treehouse get --lease --lease-holder rec-win-gg7" "$rec" \
    "treehouse acquisition must request a durable lease under the task id"
  assert_grep "send-keys -t @spawnwid cd " "$rec" \
    "the leased worktree cd must target the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_refuses_legacy_held_worktree
test_spawn_refuses_detached_legacy_held_worktree
test_spawn_leases_normal_treehouse_allocation
test_spawn_rolls_back_lease_after_isolation_failure
test_spawn_refuses_to_roll_back_primary_checkout
test_spawn_rolls_back_lease_after_setup_failure
test_spawn_recovers_failed_lease_rollback
test_spawn_tombstones_returned_lease_handoff
test_spawn_keeps_published_lease_on_abort
test_spawn_refuses_empty_lease_handoff
test_spawn_discards_legacy_handoff_writer_temporary
test_spawn_serializes_lease_handoff_publication
test_spawn_clears_committed_lease_handoff
test_spawn_refuses_returned_handoff_with_live_metadata
test_spawn_recovers_lease_handoff_for_another_task
test_spawn_refuses_cross_project_lease_handoff
test_spawn_tmux_window_construction
