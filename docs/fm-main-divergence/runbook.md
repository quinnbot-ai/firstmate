# Realigning the primary checkout's local main to origin/main

This runbook is the deliverable for firstmate's own three-way branch-skew cleanup (local `main` / `origin/main` / `upstream/main`).
In the current remote layout, `origin` is `quinnbot-ai/firstmate` (this fleet's fork and PR target) and `upstream` is `kunchenguid/firstmate` (Kun's template repository).
It exists because the primary checkout's local `main` had fallen behind the fork's `main`, which made new branches based on local `main` open PRs with spurious conflicts against the PR target.
Firstmate reads the canonical copy of this runbook from `data/fm-main-divergence/runbook.md` in its own home; this tracked copy under `docs/` is the one that ships with the PR and stays in git history.
A crewmate produced and exercised this runbook in an isolated worktree; it does not touch the primary checkout itself.

## Background: what the audit found

The audit predated the current remote names.
This section uses the current names so every ref remains unambiguous and copyable.

At audit time (2026-07-22), after an explicit `git fetch --prune` of both remotes:

- Local `main` (primary checkout): `324d729` - `feat(spawn): isolate Claude crewmates on a second Anthropic account (#19)`
- `origin/main`: `cdf71f4` - `fix: batch expired watcher stale rechecks into one wake (#22)`
- `upstream/main`: `5549834` - `fix: preserve trustworthy Bearings data in partial snapshots (#875)`

`git merge-base --is-ancestor main origin/main` returned true, `git log origin/main..main` was empty, and `git cherry -v origin/main main` was empty.
The patch-id audit of the empty `origin/main..main` range likewise found no local-only patch.
Local `main` was therefore a **literal git ancestor of `origin/main`** - every local-main change had already landed on the fork by the same hash.
There was no local-only content that had never landed on `origin/main`, so no needs-decision was required before proceeding.

Local `main` was four commits behind `origin/main` at that audit point.
See "Root cause and prevention" below for why the historical remote layout caused that drift.

`origin/main` and `upstream/main` diverged at `bc1a21b`.
At audit time, `git rev-list --left-right --count origin/main...upstream/main` reported `23 30`.
This sync merges the complete current upstream tip, including the original watcher, supervision, and X-mode fixes (`3729081` through `4ab61fa`) plus the 22 later upstream commits.

The earlier `fm/fm-main-divergence` PR merged `upstream/main` at `5549834` into a branch refreshed through `origin/main` at `cdf71f4`, preserving both sides.
`git merge-base --is-ancestor 5549834 HEAD` confirms that the complete audited upstream tip is present in the resulting branch.
**Do not run the hard-align sequence below until the corresponding sync PR has merged into `origin/main`.**

## Upstream-to-fork resync (2026-07-24)

To adopt a new upstream tip, branch from `origin/main`, then merge `upstream/main` with a merge commit.

```sh
git checkout -b fm/fm-upstream-resync origin/main
git merge --no-ff upstream/main -m 'merge: sync upstream/main into fork main'
git merge-base --is-ancestor upstream/main HEAD
```

Resolve an overlapping implementation in upstream's shape.
Retain a fork-only safety property only when the upstream rewrite genuinely lacks it, with focused regression coverage.
Run the full test suite and `bin/fm-lint.sh`, then ship through the normal no-mistakes pipeline.
The resulting PR must be merged with a **merge commit**.
Never squash or rebase this PR, because either operation removes the adopted upstream ancestry and makes the fork diverge again.

`/updatefirstmate` remains intentionally origin-only through `base_mode="origin"`.
In this remote layout that keeps the primary checkout current with the fork after the resync PR lands, but it cannot adopt `upstream/main` into the fork.
The recurring upstream-sync operation is therefore this reviewed merge PR, not a self-update change.

## Pre-checks (copy-paste runnable, exercised against a scratch clone)

Run these from *any* clone of the repo (a scratch clone is safest for a first read) to establish that `origin/main`'s current tip fully contains local `main`'s content before touching the primary checkout.
They were exercised against a disposable `--no-hardlinks` scratch clone during this task (see "Verification" below) and are safe to re-run at any time - they update only remote-tracking refs, never local branches or the working tree.

```sh
# From inside any clone of the firstmate repo:
git fetch origin '+refs/heads/main:refs/remotes/origin/main' \
  || { echo "STOP: could not refresh origin/main"; exit 1; }
git fetch upstream '+refs/heads/main:refs/remotes/upstream/main' \
  || { echo "STOP: could not refresh upstream/main"; exit 1; }

# 1. Prove local main's content is fully contained in origin/main (not just
#    similar - a literal ancestor relationship, the strongest possible proof).
git merge-base --is-ancestor main origin/main \
  && echo "OK: local main is a literal ancestor of origin/main" \
  || echo "STOP: local main has content origin/main does not - do NOT hard-align, escalate first"

# 2. Confirm there is nothing on local main that origin/main lacks (must be empty).
git log --oneline origin/main..main

# 3. (Informational) list what origin/main has beyond local main, and what
#    upstream/main has beyond the origin/upstream merge-base, so you can see what
#    you are about to pick up.
git log --oneline main..origin/main
git log --oneline "$(git merge-base origin/main upstream/main)"..upstream/main
```

If check 1 fails or check 2 prints anything, **stop** - that means local `main` has content `origin/main` does not, and a hard reset below would silently discard it.
Escalate instead of proceeding; this mirrors the same equivalence proof this task's audit ran before touching anything.

## The hard-align sequence (run in the PRIMARY checkout only, after the PR merges)

`main` is the branch actually checked out in the primary checkout, so this is **not** a safe place for a ref-only update (`git update-ref refs/heads/main origin/main` alone would desync the index and working tree from the moved ref and corrupt the checkout).
The sequence below updates ref, index, and working tree together in one atomic `reset --hard`, after safely stashing anything uncommitted so nothing unlanded is ever discarded (prime directive #3).

```sh
cd /Users/nick/ventures/agent-ops/firstmate \
  || { echo "STOP: primary checkout not found - refusing to run anywhere else"; exit 1; }

# 0. Re-run the pre-checks above against THIS checkout first.
git fetch origin '+refs/heads/main:refs/remotes/origin/main' \
  || { echo "STOP: could not refresh origin/main"; exit 1; }
git merge-base --is-ancestor main origin/main \
  && echo "OK: proceeding" || { echo "STOP: see pre-checks above"; exit 1; }
git log --oneline origin/main..main   # must be empty

# 1. Confirm you are actually on main (never run this sequence elsewhere).
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "STOP: not on main"; exit 1; }

# 2. Preserve anything uncommitted before the reset - reversible, never discarded.
dirty="$(git status --porcelain)" \
  || { echo "STOP: could not read working tree status - refusing to reset"; exit 1; }
if [ -n "$dirty" ]; then
  git stash push -u -m "fm-main-divergence-realign-$(date +%Y%m%dT%H%M%S)" \
    || { echo "STOP: git stash failed - refusing to reset over uncommitted work"; exit 1; }
  echo "Stashed uncommitted work - recover it after the reset with: git stash list / git stash pop"
  [ -z "$(git status --porcelain)" ] \
    || { echo "STOP: working tree still dirty after stash - refusing to reset"; exit 1; }
fi

# 3. The coherent ref+index+tree update. origin/main was already fetched in step 0.
git reset --hard origin/main

# 4. Post-checks.
[ -z "$(git status --porcelain)" ] && echo "OK: working tree clean" || echo "FAIL: working tree not clean"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  && echo "OK: main now matches origin/main ($(git rev-parse --short HEAD))" \
  || echo "FAIL: HEAD does not match origin/main"
test -x bin/fm-session-start.sh && test -x bin/fm-watch.sh \
  && echo "OK: bin/ entry scripts still executable" \
  || echo "FAIL: bin/ executable bits look wrong - inspect git diff --summary origin/main"
```

If a stash was created in step 2, review it afterward (`git stash list`, `git stash show -p stash@{0}`) and either `git stash pop` it back onto the realigned `main` or drop it once you have confirmed it is no longer needed - never drop it automatically.

### Verification

The equivalent sequence under the historical remote names was run end-to-end in a disposable `--no-hardlinks` scratch clone during this task.
The exercise simulated an uncommitted `README.md` edit and an untracked file before the reset, confirming both were captured by the stash and recoverable afterward.
All post-checks passed: the working tree was clean, `HEAD` matched the fork's remote-tracking `main` exactly, and both `bin/fm-session-start.sh` and `bin/fm-watch.sh` retained their executable bit through the reset.

## Root cause and prevention

The drift happened because the historical remote layout named Kun's template `origin` and this fleet's fork `fork`.
`/updatefirstmate` (`bin/fm-update.sh` -> `bin/fm-ff-lib.sh`) fast-forwards the primary checkout's `main` using `base_mode="origin"`, so it followed the template instead of the repository where this fleet's PRs merged.
The current remote layout fixes that ownership mismatch by naming the fork `origin` and the template `upstream`.
`/updatefirstmate` remains intentionally origin-only and now keeps local `main` aligned with the fork's `origin/main`.
It must not merge or fast-forward from `upstream/main`; upstream adoption remains the reviewed merge-commit workflow above.

**What does NOT need a fix:** `treehouse` (the pooled-worktree tool new task worktrees come from) has no base-ref configuration surface at all (`treehouse init`'s generated `treehouse.toml` only exposes `max_trees` and `root`) - it worktrees whatever the repo's own local `main` currently points to.
Once this runbook's hard-align sequence runs, local `main` matches `origin/main`, so every new pooled worktree is correct again with no treehouse-side change needed.
