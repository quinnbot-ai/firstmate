#!/usr/bin/env bash
# Behavior tests for the "landed is not running" currency signal.
#
# Merging a change to the default branch does not make it run: firstmate never
# updates itself, so a home keeps executing whatever commit its code root is
# checked out at until the captain approves an update. Nothing else in the
# session-start digest separates "merged" from "running here", which is exactly
# how a merged refusal can read as protection it is not yet providing.
#
# Three things are pinned here, because they fail for different reasons:
#   SIGNAL  - a code root behind the branch it follows reports the gap.
#   SILENCE - every other state stays quiet, so the line keeps its meaning.
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
  local repo=$1 file=$2 message=$3 side="$repo.side"
  rm -rf "$side"
  git clone -q "$repo.origin.git" "$side"
  mkdir -p "$side/$(dirname "$file")"
  printf '%s\n' "$message" >> "$side/$file"
  git -C "$side" add "$file"
  git -C "$side" commit -q -m "$message"
  git -C "$side" push -q origin HEAD:main
}

# hold_back <repo> <n>: move the checkout back <n> commits without touching
# origin, leaving the repo running code the default branch has moved past. This
# is the deliberate hold - landed work that is not live.
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

  # Behind: three commits landed, none of them running here.
  land "$repo" docs/one.md one
  land "$repo" docs/two.md two
  land "$repo" docs/three.md three
  hold_back "$repo" 3
  out=$(fm_code_currency_line "$repo" || true)
  assert_contains "$out" "CODE_STALE:" "a checkout three commits behind reported nothing"
  assert_contains "$out" "3 commit(s) behind" "the gap did not name how many commits are missing"
  assert_contains "$out" "origin/main" "the gap did not name the branch the code root follows"
  assert_contains "$out" "$(git -C "$repo" rev-parse --short=7 HEAD)" "the gap did not name the commit actually running"
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

# --- SESSION START: the line reaches the digest -----------------------------

# The library is only useful if a session start actually prints it, and only
# trustworthy if a current home still starts silent.
run_bootstrap() {
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap")

  out=$(run_bootstrap "$repo" | grep '^CODE_STALE:' || true)
  [ -z "$out" ] || fail "session start reported a gap for a current home: $out"

  land "$repo" bin/fm-pr-merge.sh "refuse an untested pull request"
  hold_back "$repo" 1
  out=$(run_bootstrap "$repo" | grep '^CODE_STALE:' || true)
  assert_contains "$out" "1 commit(s) behind" "session start did not report the gap on a stale home"
  assert_contains "$out" "bin/fm-pr-merge.sh" "session start did not name the guard path in the gap"
  assert_contains "$out" "until the captain approves an update" \
    "session start did not say the gap stays until the captain approves an update"

  pass "fm-bootstrap: CODE_STALE reaches session start for a stale code root and stays silent for a current one"
}

test_states
test_guard_naming
test_never_updates
test_bootstrap_line
