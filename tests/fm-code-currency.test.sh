#!/usr/bin/env bash
# Behavior tests for the landed-versus-live currency signal.
#
# Merging a change to the default branch does not make it run: firstmate never
# updates itself, so a home keeps its checked-out commit until the captain
# approves an update. The unlocked worktree can still differ from that commit,
# so the signal reports the commit gap without claiming which bytes are live.
#
# Three things are pinned here, because they fail for different reasons:
#   SIGNAL  - a code root behind the branch it follows reports the gap.
#   SILENCE - clean non-behind states stay quiet, so each line keeps its meaning.
#   NAMING  - the gap names guard paths when it carries them, and says so plainly
#             when it does not.
# Plus the boundary that makes the signal safe to run unattended: it reports and
# never advances the checkout it is reporting on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-code-currency-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-code-currency)
fm_git_identity fmtest fmtest@example.invalid

# A repo on `main` with a local bare origin and a fetched origin/main, so the
# check has a remote-tracking ref to compare against. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  git -C "$dir" fetch -q origin
  printf '%s\n' "$dir"
}

# land <repo> <file> <message>: commit a change to <file> and publish it to the
# repo's own origin, mirroring a merge landing on the default branch.
land() {
  local repo=$1 file=$2 message=$3
  mkdir -p "$repo/$(dirname "$file")"
  printf '%s\n' "$message" >> "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q -m "$message"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
}

# land_elsewhere <repo> <file> <message>: land a commit on the shared origin from
# a different clone, leaving <repo>'s own remote-tracking ref pointing at the
# older tip. A check that fetches would move that ref; a check that only reads
# cannot, which is what makes the read-only boundary observable.
land_elsewhere() {
  local repo=$1 file=$2 message=$3
  local side="$repo.side"
  rm -rf "$side"
  git clone -q "$repo.origin.git" "$side"
  mkdir -p "$side/$(dirname "$file")"
  printf '%s\n' "$message" >> "$side/$file"
  git -C "$side" add "$file"
  git -C "$side" commit -q -m "$message"
  git -C "$side" push -q origin HEAD:main
}

# hold_back <repo> <n>: move the checkout back <n> commits without touching
# origin, leaving the checked-out commit behind the default branch. This is the
# deliberate hold between landed work and the commit present in the checkout.
hold_back() {
  local repo=$1 n=$2
  git -C "$repo" reset -q --hard "HEAD~$n"
}

# --- SIGNAL and SILENCE: which states speak ---------------------------------

# One code root walked through every state the check can see. The behind states
# must report; every other state must stay silent, including the two that are
# easy to get wrong - a checkout that is AHEAD of its branch, and one that has no
# remote-tracking ref to compare against at all.
test_states() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/states")

  # Nothing to compare against yet: a repo with no origin remote at all.
  local bare="$TMP_ROOT/no-origin"
  git init -q -b main "$bare"
  git -C "$bare" commit -q --allow-empty -m init
  out=$(fm_code_currency_line "$bare" || true)
  [ -z "$out" ] || fail "reported a gap for a checkout with no branch to follow: $out"

  # A non-git directory must not report and must not error.
  out=$(fm_code_currency_line "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "reported a gap for a non-git directory: $out"

  # Current: HEAD is the tip of the branch it follows.
  out=$(fm_code_currency_line "$repo" || true)
  [ -z "$out" ] || fail "reported a gap while the checkout was current: $out"

  # Ahead only: local work not yet landed is not staleness.
  git -C "$repo" commit -q --allow-empty -m "local work"
  out=$(fm_code_currency_line "$repo" || true)
  [ -z "$out" ] || fail "reported a gap while the checkout was only ahead: $out"
  git -C "$repo" reset -q --hard origin/main

  # Behind: three commits landed, none of them present in checked-out HEAD.
  land "$repo" docs/one.md one
  land "$repo" docs/two.md two
  land "$repo" docs/three.md three
  hold_back "$repo" 3
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE:" "a checkout three commits behind reported nothing"
  assert_contains "$out" "3 commit(s) behind" "the gap did not name how many commits are missing"
  assert_contains "$out" "origin/main" "the gap did not name the branch the code root follows"
  assert_contains "$out" "$(git -C "$repo" rev-parse --short=7 HEAD)" "the gap did not name the checked-out commit"
  assert_contains "$out" "$(git -C "$repo" rev-parse --short=7 origin/main)" "the gap did not name the commit that landed"

  # Diverged: local work on top of a held-back base is still behind by three.
  git -C "$repo" commit -q --allow-empty -m "local work on the held base"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "3 commit(s) behind" "a diverged checkout mis-stated the missing commits"

  pass "fm_code_currency_line: behind and diverged report the gap; current, ahead-only, unfollowed, and non-git stay silent"
}

# --- NAMING: guard paths in the gap -----------------------------------------

# The count alone cannot tell a reader whether a refusal they believe is
# protecting them is among what is missing. These cases pin that the line names
# guard paths when the gap carries them, collapses a long list rather than
# running away, and says plainly when the gap carries none.
test_guard_naming() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guards")

  # A gap of ordinary documentation carries no guard change, and must say so
  # rather than leaving the reader to infer it from an absent clause.
  land "$repo" docs/notes.md notes
  hold_back "$repo" 1
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE:" "a documentation-only gap reported nothing"
  assert_contains "$out" "no guard path changes" "a documentation-only gap did not say the guard paths are untouched"

  # A gap carrying refusal machinery names those files.
  git -C "$repo" reset -q --hard origin/main
  land "$repo" bin/fm-pr-merge.sh "refuse an untested pull request"
  land "$repo" bin/fm-teardown.sh "refuse a recycled pool slot"
  hold_back "$repo" 2
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "changing guard paths" "a gap carrying refusal machinery did not name guard paths"
  assert_contains "$out" "bin/fm-pr-merge.sh" "the gap did not name the merge refusal it is missing"
  assert_contains "$out" "bin/fm-teardown.sh" "the gap did not name the teardown refusal it is missing"
  assert_not_contains "$out" "no guard path changes" "a gap with guard changes claimed there were none"

  # More guard paths than the line will name collapses into a remainder count,
  # so one broad update cannot turn the signal into an unreadable file dump.
  git -C "$repo" reset -q --hard origin/main
  land "$repo" bin/fm-guard.sh guard
  land "$repo" bin/fm-lock.sh lock
  land "$repo" bin/fm-spawn.sh spawn
  hold_back "$repo" 5
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "more)" "a gap with more guard paths than the line names did not collapse the remainder"

  # Documentation next to a guard change must not be counted as one.
  git -C "$repo" reset -q --hard origin/main
  land "$repo" docs/architecture.md architecture
  hold_back "$repo" 1
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "no guard path changes" "a docs path was wrongly counted as a guard path"

  # A guard file that the missing commits ADD is the case most worth naming and
  # the easiest to lose: it does not exist in the checkout doing the reporting,
  # so any matching that consults the current directory instead of the gap will
  # quietly skip it.
  git -C "$repo" reset -q --hard origin/main
  land "$repo" bin/fm-newly-added-lock.sh "a lock guard that does not exist here yet"
  hold_back "$repo" 1
  [ ! -e "$repo/bin/fm-newly-added-lock.sh" ] || fail "fixture failed: the added guard file is present in the reporting checkout"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "bin/fm-newly-added-lock.sh" \
    "a guard path added by the missing commits was not named"

  pass "fm_code_currency_line: guard paths are named, bounded, and never claimed when the gap has none"
}

test_ignored_landed_path_is_unproven() {
  local repo out side
  repo=$(make_repo "$TMP_ROOT/ignored-landed")
  printf '%s\n' 'bin/fm-ignored-helper.sh' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m "ignore optional helper"
  git -C "$repo" push -q origin main
  side="$repo.side"
  git clone -q "$repo.origin.git" "$side"
  mkdir -p "$side/bin"
  printf '%s\n' '#!/usr/bin/env bash' > "$side/bin/fm-ignored-helper.sh"
  git -C "$side" add -f bin/fm-ignored-helper.sh
  git -C "$side" commit -q -m "land ignored helper"
  git -C "$side" push -q origin HEAD:main
  git -C "$repo" fetch -q origin
  mkdir -p "$repo/bin"
  git -C "$repo" show origin/main:bin/fm-ignored-helper.sh > "$repo/bin/fm-ignored-helper.sh"

  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" "an ignored landed file was treated as provably inactive"
  assert_contains "$out" "bin/fm-ignored-helper.sh" "the ignored landed path was not identified"
  pass "ignored landed bytes make live-code status unproven"
}

# --- BOUNDARY: reports, never updates ---------------------------------------

# Holding at an older commit is a captain decision, so the check must be safe to
# run on every session start without ever closing the gap it reports. Anything
# that advanced the checkout would silently convert a deliberate hold into an
# update nobody approved.
test_never_updates() {
  local repo before_head before_base before_status out after_head after_base after_status
  repo=$(make_repo "$TMP_ROOT/readonly")
  land "$repo" bin/fm-pr-merge.sh "refuse an untested pull request"
  hold_back "$repo" 1
  # A further commit lands on the shared origin that this repo has not fetched,
  # so the remote-tracking ref is now behind the remote as well. Anything that
  # fetched would visibly move it.
  land_elsewhere "$repo" docs/landed-later.md "landed after this checkout last looked"
  printf 'uncommitted\n' > "$repo/scratch.txt"

  before_head=$(git -C "$repo" rev-parse HEAD)
  before_base=$(git -C "$repo" rev-parse origin/main)
  before_status=$(git -C "$repo" status --porcelain)

  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE:" "the held-back checkout reported nothing to preserve"
  # The gap is reported from the ref this checkout already has, so it is a floor:
  # one commit, not the two the remote has actually moved by.
  assert_contains "$out" "1 commit(s) behind" \
    "the gap was not read from the already-present ref, so it is not the floor it claims to be"

  after_head=$(git -C "$repo" rev-parse HEAD)
  after_base=$(git -C "$repo" rev-parse origin/main)
  after_status=$(git -C "$repo" status --porcelain)
  [ "$before_head" = "$after_head" ] || fail "the check moved HEAD: $before_head -> $after_head"
  [ "$before_base" = "$after_base" ] || fail "the check moved the remote-tracking ref: $before_base -> $after_base"
  [ "$before_status" = "$after_status" ] || fail "the check disturbed the working tree"

  pass "fm_code_currency_line: reports the gap without advancing HEAD, the tracked branch, or the working tree"
}

test_dirty_tracked_checkout_is_unproven() {
  local repo out current_guard
  repo=$(make_repo "$TMP_ROOT/dirty")
  land "$repo" bin/fm-guard.sh "guard version one"
  land "$repo" bin/fm-guard.sh "guard version two"

  printf 'locally reverted\n' > "$repo/bin/fm-guard.sh"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_DRIFT: UNPROVEN live code" \
    "a current dirty checkout produced no live-code uncertainty"
  assert_contains "$out" "bin/fm-guard.sh" \
    "the current checkout-drift diagnostic did not name the changed guard"
  assert_not_contains "$out" "CODE_STALE:" \
    "a current dirty checkout was mislabeled stale"

  git -C "$repo" reset -q --hard origin/main
  current_guard=$(git -C "$repo" show origin/main:bin/fm-guard.sh)
  hold_back "$repo" 1
  printf '%s\n' "$current_guard" > "$repo/bin/fm-guard.sh"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "a stale HEAD with locally restored tracked code was called inactive"
  assert_contains "$out" "1 commit(s) behind" \
    "the unproven stale checkout lost its branch gap"
  assert_not_contains "$out" "inactive here" \
    "a dirty checkout made an unproven inactivity claim"

  pass "fm_code_currency_line: tracked checkout drift is surfaced as unproven"
}

test_current_snapshot_change_uses_drift_diagnostic() {
  local repo out real_git shim count_file current_head current_base
  repo=$(make_repo "$TMP_ROOT/current-snapshot-change")
  land "$repo" bin/fm-runtime.sh "current runtime"
  printf 'local drift\n' > "$repo/bin/fm-runtime.sh"

  real_git=$(command -v git)
  shim="$TMP_ROOT/current-snapshot-change-bin"
  count_file="$TMP_ROOT/current-snapshot-change.count"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" hash-object --no-filters -- "*)
    output=$("$FM_REAL_GIT" "$@")
    status=$?
    printf '%s\n' "$output"
    [ "$status" -eq 0 ] || exit "$status"
    count=0
    [ ! -f "$FM_RACE_COUNT" ] || read -r count < "$FM_RACE_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_RACE_COUNT"
    if [ "$count" -eq 2 ]; then
      "$FM_REAL_GIT" -C "$FM_RACE_REPO" commit -q --allow-empty -m "advance current snapshot"
      new_oid=$("$FM_REAL_GIT" -C "$FM_RACE_REPO" rev-parse HEAD)
      "$FM_REAL_GIT" -C "$FM_RACE_REPO" update-ref refs/remotes/origin/main "$new_oid"
    fi
    exit 0
    ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" FM_RACE_REPO="$repo" \
    FM_RACE_COUNT="$count_file" fm_code_currency_line "$repo" || true)
  current_head=$(git -C "$repo" rev-parse HEAD)
  current_base=$(git -C "$repo" rev-parse origin/main)
  [ "$current_head" = "$current_base" ] \
    || fail "fixture failed: HEAD and origin/main did not advance together"
  assert_contains "$out" "CODE_DRIFT: UNPROVEN live code" \
    "a changing current snapshot did not retain the current-checkout diagnostic"
  assert_contains "$out" "changed during current-checkout inspection" \
    "the current snapshot race did not explain its uncertainty"
  assert_not_contains "$out" "CODE_STALE:" \
    "a changing current snapshot was mislabeled stale"

  pass "current snapshot races remain checkout drift"
}

test_untracked_landed_path_is_unproven() {
  local repo out landed_helper
  repo=$(make_repo "$TMP_ROOT/untracked-landed")
  land "$repo" bin/fm-new-helper.sh "landed helper"
  landed_helper=$(git -C "$repo" show origin/main:bin/fm-new-helper.sh)
  hold_back "$repo" 1
  mkdir -p "$repo/bin"
  printf '%s\n' "$landed_helper" > "$repo/bin/fm-new-helper.sh"

  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "an untracked landed helper was called inactive"
  assert_contains "$out" "bin/fm-new-helper.sh" \
    "the unproven diagnostic did not name the untracked landed path"
  assert_not_contains "$out" "inactive here" \
    "an untracked landed helper made an unproven inactivity claim"

  rm "$repo/bin/fm-new-helper.sh"
  printf 'scratch\n' > "$repo/unrelated.tmp"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" \
    "an unlocked checkout was called proven after an unrelated scratch file"
  assert_contains "$out" "Tracked bytes matched HEAD during inspection" \
    "unrelated scratch state was confused with tracked runtime drift"
  assert_not_contains "$out" "inactive here" \
    "an unlocked checkout produced an inactivity claim"

  pass "fm_code_currency_line: untracked landed paths make live code unproven"
}

test_non_ascii_untracked_landed_path_is_unproven() {
  local repo out path landed_helper
  repo=$(make_repo "$TMP_ROOT/non-ascii-untracked-landed")
  path='bin/fm-café.sh'
  land "$repo" "$path" "landed non-ASCII helper"
  landed_helper=$(git -C "$repo" show "origin/main:$path")
  hold_back "$repo" 1
  mkdir -p "$repo/bin"
  printf '%s\n' "$landed_helper" > "$repo/$path"

  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "an untracked non-ASCII landed helper was called inactive"
  assert_contains "$out" "$path" \
    "the unproven diagnostic did not name the non-ASCII landed path"
  assert_not_contains "$out" "inactive here" \
    "an untracked non-ASCII landed helper made an unproven inactivity claim"

  pass "non-ASCII landed paths preserve live-code uncertainty"
}

test_index_hints_cannot_hide_landed_path_drift() {
  local repo out landed_helper diff_status
  repo=$(make_repo "$TMP_ROOT/index-hints")
  land "$repo" bin/fm-hidden-helper.sh "helper version one"
  land "$repo" bin/fm-hidden-helper.sh "helper version two"
  landed_helper=$(git -C "$repo" show origin/main:bin/fm-hidden-helper.sh)
  hold_back "$repo" 1
  printf '%s\n' "$landed_helper" > "$repo/bin/fm-hidden-helper.sh"
  git -C "$repo" update-index --assume-unchanged bin/fm-hidden-helper.sh

  git -C "$repo" diff --quiet HEAD --
  diff_status=$?
  expect_code 0 "$diff_status" "fixture failed: Git did not hide the changed worktree bytes"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" \
    "index hints allowed differing landed bytes to be called inactive"
  assert_contains "$out" "bin/fm-hidden-helper.sh" \
    "the hidden landed path was not identified"
  assert_not_contains "$out" "inactive here" \
    "hidden worktree bytes produced a proven inactivity claim"

  pass "landed path bytes are checked independently of index hints"
}

test_unrelated_index_hint_prevents_running_claim() {
  local repo out diff_status
  repo=$(make_repo "$TMP_ROOT/unrelated-index-hint")
  land "$repo" bin/fm-runtime.sh "runtime version one"
  land "$repo" docs/landed.md "landed documentation"
  hold_back "$repo" 1
  printf '%s\n' "locally changed runtime" > "$repo/bin/fm-runtime.sh"
  git -C "$repo" update-index --assume-unchanged bin/fm-runtime.sh

  git -C "$repo" diff --quiet HEAD --
  diff_status=$?
  expect_code 0 "$diff_status" "fixture failed: Git did not hide the unrelated runtime change"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" \
    "an unrelated index hint allowed worktree bytes to be called running code"
  assert_contains "$out" "bin/fm-runtime.sh" \
    "the unproven diagnostic did not identify the hinted runtime path"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "hidden unrelated runtime bytes produced a running-code claim"
  assert_not_contains "$out" "inactive here" \
    "hidden unrelated runtime bytes produced an inactivity claim"

  pass "index hints anywhere make checked-out runtime bytes unproven"
}

test_stat_cache_cannot_hide_tracked_runtime_drift() {
  local repo out diff_status stamp
  repo=$(make_repo "$TMP_ROOT/stat-cache")
  land "$repo" bin/fm-runtime.sh "runtime-old"
  land "$repo" docs/landed.md "landed documentation"
  hold_back "$repo" 1
  touch -t 200001010000 "$repo/bin/fm-runtime.sh"
  git -C "$repo" update-index --refresh
  stamp="$repo/runtime.stamp"
  touch -r "$repo/bin/fm-runtime.sh" "$stamp"
  git -C "$repo" config core.trustctime false
  git -C "$repo" config core.checkStat minimal
  printf '%s\n' "runtime-new" > "$repo/bin/fm-runtime.sh"
  touch -r "$stamp" "$repo/bin/fm-runtime.sh"

  git -C "$repo" diff --quiet HEAD --
  diff_status=$?
  expect_code 0 "$diff_status" "fixture failed: Git did not trust the unchanged stat cache"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" \
    "cached stat fields allowed changed runtime bytes to be called running code"
  assert_contains "$out" "bin/fm-runtime.sh" \
    "the byte-level proof did not identify the hidden runtime path"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "hidden runtime bytes produced a running-code claim"
  assert_not_contains "$out" "inactive here" \
    "hidden runtime bytes produced an inactivity claim"
  pass "tracked runtime bytes are proven independently of Git's stat cache"
}

test_tracked_byte_proof_batches_regular_files() {
  local repo out real_git shim log hash_calls i
  repo=$(make_repo "$TMP_ROOT/hash-batch")
  mkdir -p "$repo/bin"
  i=1
  while [ "$i" -le 8 ]; do
    printf 'runtime %s\n' "$i" > "$repo/bin/runtime-$i.sh"
    i=$((i + 1))
  done
  git -C "$repo" add bin
  git -C "$repo" commit -q -m "add runtime files"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin
  land "$repo" docs/landed.md landed
  hold_back "$repo" 1

  real_git=$(command -v git)
  shim="$TMP_ROOT/hash-batch-bin"
  log="$TMP_ROOT/hash-batch.calls"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" hash-object "*) printf '%s\n' "$*" >> "$FM_HASH_LOG" ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" FM_HASH_LOG="$log" \
    fm_code_currency_line "$repo" || true)
  assert_contains "$out" "1 commit(s) behind" \
    "the stale checkout did not exercise tracked-byte proof: $out"
  hash_calls=$(wc -l < "$log" | tr -d ' ')
  [ "$hash_calls" -eq 2 ] \
    || fail "the tracked-byte proof spawned $hash_calls regular-file hash processes"
  pass "tracked regular files are byte-proven in two stable hash snapshots"
}

test_tree_inventory_failure_is_unproven() {
  local repo out real_git shim
  repo=$(make_repo "$TMP_ROOT/tree-inventory-failure")
  mkdir -p "$repo/bin"
  printf '%s\n' runtime > "$repo/bin/fm-runtime.sh"
  git -C "$repo" add bin/fm-runtime.sh
  git -C "$repo" commit -q -m "add runtime"
  git -C "$repo" push -q origin main
  land "$repo" docs/landed.md landed
  hold_back "$repo" 1

  real_git=$(command -v git)
  shim="$TMP_ROOT/tree-inventory-failure-bin"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-tree -rz "*) exit 7 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" \
    fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "a failed tracked-tree inventory suppressed the currency diagnostic"
  assert_contains "$out" "inspection could not prove" \
    "a failed tracked-tree inventory was not diagnosed"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "a failed tracked-tree inventory produced a running-code claim"
  pass "tracked-tree inventory failures remain visible and unproven"
}

test_changing_worktree_snapshot_is_unproven() {
  local repo out real_git shim count_file early late i
  repo=$(make_repo "$TMP_ROOT/worktree-snapshot-change")
  mkdir -p "$repo/bin"
  i=0
  while [ "$i" -lt 129 ]; do
    printf 'runtime %03d\n' "$i" > "$repo/bin/runtime-$(printf '%03d' "$i").sh"
    i=$((i + 1))
  done
  git -C "$repo" add bin
  git -C "$repo" commit -q -m "add runtime files"
  git -C "$repo" push -q origin main
  land "$repo" docs/landed.md landed
  hold_back "$repo" 1
  early="$repo/bin/runtime-000.sh"
  late="$repo/bin/runtime-128.sh"
  printf '%s\n' changing > "$late"

  real_git=$(command -v git)
  shim="$TMP_ROOT/worktree-snapshot-change-bin"
  count_file="$TMP_ROOT/worktree-snapshot-change.count"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" hash-object --no-filters -- "*)
    count=0
    [ ! -f "$FM_HASH_COUNT" ] || count=$(cat "$FM_HASH_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_HASH_COUNT"
    if [ "$count" -eq 1 ]; then
      "$FM_REAL_GIT" "$@"
      rc=$?
      printf '%s\n' changing > "$FM_EARLY_PATH"
      exit "$rc"
    fi
    if [ "$count" -eq 2 ]; then
      "$FM_REAL_GIT" -C "$FM_MUTATE_REPO" show HEAD:bin/runtime-128.sh > "$FM_LATE_PATH"
    fi
    ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" FM_HASH_COUNT="$count_file" \
    FM_EARLY_PATH="$early" FM_LATE_PATH="$late" FM_MUTATE_REPO="$repo" \
    fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "a changing tracked-byte scan produced no live-code uncertainty"
  assert_contains "$out" "worktree bytes changed during" \
    "a changing tracked-byte scan was not diagnosed"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "a mixed tracked-byte scan produced a running-code claim"
  pass "currency reporting requires two stable worktree byte snapshots"
}

test_worktree_change_after_inspection_is_unproven() {
  local repo out real_git shim count_file runtime
  repo=$(make_repo "$TMP_ROOT/worktree-post-inspection-change")
  runtime="$repo/bin/fm-runtime.sh"
  land "$repo" bin/fm-runtime.sh old
  land "$repo" bin/fm-runtime.sh landed
  hold_back "$repo" 1

  real_git=$(command -v git)
  shim="$TMP_ROOT/worktree-post-inspection-change-bin"
  count_file="$TMP_ROOT/worktree-post-inspection-change.count"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" rev-list --count "*)
    count=0
    [ ! -f "$FM_REV_LIST_COUNT" ] || count=$(cat "$FM_REV_LIST_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_REV_LIST_COUNT"
    if [ "$count" -eq 2 ]; then
      "$FM_REAL_GIT" -C "$FM_MUTATE_REPO" show origin/main:bin/fm-runtime.sh > "$FM_RUNTIME_PATH"
    fi
    ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" FM_REV_LIST_COUNT="$count_file" \
    FM_MUTATE_REPO="$repo" FM_RUNTIME_PATH="$runtime" \
    fm_code_currency_line "$repo" || true)
  assert_contains "$(cat "$runtime")" "landed" \
    "fixture did not change the worktree after byte inspection"
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "a post-inspection worktree change produced no live-code uncertainty"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "a post-inspection worktree change produced a running-code claim"
  assert_not_contains "$out" "inactive here" \
    "a post-inspection worktree change produced an inactivity claim"
  pass "unlocked post-inspection changes keep live-code status unproven"
}

test_diverged_equivalent_landed_bytes_are_unproven() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/diverged-equivalent")
  mkdir -p "$repo/bin"
  printf '%s\n' 'equivalent behavior' > "$repo/bin/fm-equivalent.sh"
  git -C "$repo" add bin/fm-equivalent.sh
  git -C "$repo" commit -q -m "implement behavior locally"
  land_elsewhere "$repo" bin/fm-equivalent.sh "equivalent behavior"
  git -C "$repo" fetch -q origin

  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "UNPROVEN live code" \
    "a divergent checkout with equivalent landed bytes was called inactive"
  assert_contains "$out" "not in origin/main" \
    "the diagnostic did not identify the divergent local history"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "divergent equivalent bytes produced a running-code claim"
  assert_not_contains "$out" "inactive here" \
    "divergent equivalent bytes produced an inactivity claim"
  pass "divergent equivalent landed bytes keep live-code status unproven"
}

test_ref_change_during_inspection_is_unproven() {
  local repo out real_git shim marker
  repo=$(make_repo "$TMP_ROOT/ref-change")
  mkdir -p "$repo/bin"
  printf '%s\n' runtime > "$repo/bin/fm-runtime.sh"
  git -C "$repo" add bin/fm-runtime.sh
  git -C "$repo" commit -q -m "add runtime"
  git -C "$repo" push -q origin main
  land "$repo" docs/landed.md landed
  hold_back "$repo" 1

  real_git=$(command -v git)
  shim="$TMP_ROOT/ref-change-bin"
  marker="$TMP_ROOT/ref-change-triggered"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" diff --cached --quiet "*)
    if [ ! -e "$FM_MUTATE_MARKER" ]; then
      : > "$FM_MUTATE_MARKER"
      "$FM_REAL_GIT" -C "$FM_MUTATE_REPO" reset -q --hard origin/main
    fi
    ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" FM_MUTATE_REPO="$repo" \
    FM_MUTATE_MARKER="$marker" fm_code_currency_line "$repo" || true)
  assert_present "$marker" "fixture did not change HEAD during inspection"
  assert_contains "$out" "UNPROVEN live code" \
    "a changing checkout produced no live-code uncertainty"
  assert_contains "$out" "changed during landed-versus-live inspection" \
    "the diagnostic did not identify its invalidated snapshot"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "a stale snapshot described the updated checkout as behind"
  assert_not_contains "$out" "inactive here" \
    "a stale snapshot described landed code as inactive"
  pass "currency reporting refuses a checkout snapshot that changes mid-inspection"
}

test_byte_inspection_failure_is_unproven() {
  local repo out real_git shim
  repo=$(make_repo "$TMP_ROOT/inspection-failure")
  mkdir -p "$repo/bin"
  printf '%s\n' runtime > "$repo/bin/fm-runtime.sh"
  git -C "$repo" add bin/fm-runtime.sh
  git -C "$repo" commit -q -m "add runtime"
  git -C "$repo" push -q origin main
  land "$repo" docs/landed.md landed
  hold_back "$repo" 1

  real_git=$(command -v git)
  shim="$TMP_ROOT/inspection-failure-bin"
  mkdir -p "$shim"
  cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" hash-object "*) exit 7 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$shim/git"

  out=$(PATH="$shim:$PATH" FM_REAL_GIT="$real_git" \
    fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "a tracked-byte inspection failure suppressed the currency diagnostic"
  assert_contains "$out" "inspection could not prove" \
    "the inspection failure was not identified"
  assert_not_contains "$out" "CODE_STALE: running code" \
    "an inspection failure produced a running-code claim"
  assert_not_contains "$out" "inactive here" \
    "an inspection failure produced an inactivity claim"
  pass "tracked-byte inspection failures keep live-code status visible and unproven"
}

test_dirty_submodule_checkout_is_unproven() {
  local repo sub out
  sub="$TMP_ROOT/submodule-source"
  git init -q -b main "$sub"
  mkdir -p "$sub/bin"
  printf '%s\n' old > "$sub/bin/runtime.sh"
  git -C "$sub" add bin/runtime.sh
  git -C "$sub" commit -q -m old
  fm_git_add_origin "$sub" "$sub.origin.git"

  repo=$(make_repo "$TMP_ROOT/dirty-submodule")
  git -c protocol.file.allow=always -C "$repo" submodule add -q "$sub.origin.git" modules/runtime
  git -C "$repo" commit -q -m "add runtime submodule"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin

  printf '%s\n' landed > "$sub/bin/runtime.sh"
  git -C "$sub" add bin/runtime.sh
  git -C "$sub" commit -q -m landed
  git -C "$sub" push -q origin main
  git -C "$repo/modules/runtime" fetch -q origin
  git -C "$repo/modules/runtime" checkout -q origin/main
  git -C "$repo" add modules/runtime
  git -C "$repo" commit -q -m "advance runtime submodule"
  git -C "$repo" push -q origin main
  git -C "$repo" fetch -q origin

  hold_back "$repo" 1
  git -c protocol.file.allow=always -C "$repo" submodule update -q --init --recursive
  printf '%s\n' landed > "$repo/modules/runtime/bin/runtime.sh"
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE: UNPROVEN live code" \
    "dirty submodule bytes produced no live-code uncertainty"
  assert_contains "$out" "modules/runtime" \
    "dirty submodule bytes did not identify the unproven path"
  assert_not_contains "$out" "inactive here" \
    "dirty submodule bytes were called inactive"
  pass "dirty submodule bytes keep landed code status unproven"
}

# --- SESSION START: the line reaches the digest -----------------------------

# The library is only useful if a session start actually prints it, and only
# trustworthy if a clean current home still starts silent.
run_bootstrap() {
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap")

  out=$(run_bootstrap "$repo" | grep -E '^CODE_(STALE|DRIFT):' || true)
  [ -z "$out" ] || fail "session start reported code drift for a clean current home: $out"

  land "$repo" bin/fm-current-guard.sh "current guard"
  printf 'locally changed\n' > "$repo/bin/fm-current-guard.sh"
  out=$(run_bootstrap "$repo" | grep -E '^CODE_(STALE|DRIFT):' || true)
  assert_contains "$out" "CODE_DRIFT: UNPROVEN live code" \
    "session start did not surface current tracked checkout drift"
  assert_contains "$out" "bin/fm-current-guard.sh" \
    "session-start checkout drift did not name the changed tracked path"
  assert_not_contains "$out" "CODE_STALE:" \
    "session start mislabeled a current dirty checkout as stale"
  git -C "$repo" reset -q --hard origin/main

  land "$repo" bin/fm-pr-merge.sh "refuse an untested pull request"
  hold_back "$repo" 1
  out=$(run_bootstrap "$repo" | grep '^CODE_STALE:' || true)
  assert_contains "$out" "1 commit(s) behind" "session start did not report the gap on a stale home"
  assert_contains "$out" "bin/fm-pr-merge.sh" "session start did not name the guard path in the gap"
  assert_contains "$out" "installed code cannot be proven" \
    "session start overclaimed the live bytes in an unlocked checkout"

  pass "fm-bootstrap: code gaps and current checkout drift reach session start distinctly"
}

test_states
test_guard_naming
test_never_updates
test_dirty_tracked_checkout_is_unproven
test_current_snapshot_change_uses_drift_diagnostic
test_untracked_landed_path_is_unproven
test_non_ascii_untracked_landed_path_is_unproven
test_index_hints_cannot_hide_landed_path_drift
test_unrelated_index_hint_prevents_running_claim
test_stat_cache_cannot_hide_tracked_runtime_drift
test_tracked_byte_proof_batches_regular_files
test_tree_inventory_failure_is_unproven
test_changing_worktree_snapshot_is_unproven
test_worktree_change_after_inspection_is_unproven
test_diverged_equivalent_landed_bytes_are_unproven
test_ref_change_during_inspection_is_unproven
test_byte_inspection_failure_is_unproven
test_dirty_submodule_checkout_is_unproven
test_ignored_landed_path_is_unproven
test_bootstrap_line
