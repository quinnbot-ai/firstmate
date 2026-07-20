# Realigning the primary checkout's local main to fork/main

This runbook is the deliverable for firstmate's own three-way branch-skew cleanup (local main / `fork/main` / `origin/main`).
It exists because the primary checkout's local `main` had fallen behind `fork/main` (the fork where firstmate's own PRs land), which made new branches based on local `main` open PRs with spurious conflicts against `fork/main`.
Firstmate reads the canonical copy of this runbook from `data/fm-main-divergence/runbook.md` in its own home; this tracked copy under `docs/` is the one that ships with the PR and stays in git history.
A crewmate produced and exercised this runbook in an isolated worktree; it does not touch the primary checkout itself.

## Background: what the audit found

Remotes in this repo: `origin` = `kunchenguid/firstmate` (the upstream template repo), `fork` = `quinnbot-ai/firstmate` (this fleet's own fork, where its PRs land and merge).

At audit time (2026-07-20):

- Local `main` (primary checkout): `579f6d9` - `fix: absorb declared pauses at parked gates (#9)`
- `fork/main`: `87b4df4` - `fix(spawn): tolerate transient cwd reads and clean up refused spawns (#15)`
- `origin/main`: `4ab61fa` - `feat(wake): enrich drained signals with bounded status context (#747)`

`git merge-base --is-ancestor main fork/main` returned true, and `git log fork/main..main` was empty: local `main` is a **literal git ancestor of `fork/main`** - every commit on local `main` already exists on `fork/main` by the same hash.
There was no local-only content that had never landed on `fork/main`, so no needs-decision was required before proceeding.

Local `main` had simply fallen behind `fork/main` by four PRs (`#12`, `#13`, `#14`, `#15`) that were merged straight into the fork and never pulled back into the primary checkout.
See "Root cause" below for why: `/updatefirstmate` never looks at the `fork` remote, only `origin`.

`fork/main` and `origin/main` diverged from a common ancestor at `bc1a21b`: `fork/main` carries 16 commits since then (fork-local features - isolated Codex homes, ops-inbox surfacing, pause-absorb fixes, worktree leases, watcher escalation - interleaved with commits also present upstream), while `origin/main` carries a different 8 commits since then (upstream watcher/supervision/x-mode fixes this fleet wants: `3729081`, `b2bf95f`, `7a9b4dd`, `15b0fb9`, `ab8cea6`, `68c6110`, `c12bdea`, `4ab61fa`).

This PR (`fm/fm-main-divergence`) merges `origin/main` into a branch off `fork/main`, preserving both sides, and is the shippable change of this task.
**Do not run the sequence below until that PR has merged into `fork/main`.**

## Pre-checks (copy-paste runnable, exercised against a scratch clone)

Run these from *any* clone of the repo (a scratch clone is safest for a first read) to establish that `fork/main`'s current tip fully contains local `main`'s content before touching the primary checkout.
They were exercised against a disposable `--no-hardlinks` scratch clone during this task (see "Verification" below) and are safe to re-run at any time - they update only remote-tracking refs, never local branches or the working tree.

```sh
# From inside any clone of the firstmate repo:
git fetch fork '+refs/heads/main:refs/remotes/fork/main' \
  || { echo "STOP: could not refresh fork/main"; exit 1; }
git fetch origin '+refs/heads/main:refs/remotes/origin/main' \
  || { echo "STOP: could not refresh origin/main"; exit 1; }

# 1. Prove local main's content is fully contained in fork/main (not just
#    similar - a literal ancestor relationship, the strongest possible proof).
git merge-base --is-ancestor main fork/main \
  && echo "OK: local main is a literal ancestor of fork/main" \
  || echo "STOP: local main has content fork/main does not - do NOT hard-align, escalate first"

# 2. Confirm there is nothing on local main that fork/main lacks (must be empty).
git log --oneline fork/main..main

# 3. (Informational) list what fork/main has beyond local main, and what
#    origin/main has beyond the fork/origin merge-base, so you can see what
#    you are about to pick up.
git log --oneline main..fork/main
git log --oneline "$(git merge-base fork/main origin/main)"..origin/main
```

If check 1 fails or check 2 prints anything, **stop** - that means local `main` has content `fork/main` does not, and a hard reset below would silently discard it.
Escalate instead of proceeding; this mirrors the same equivalence proof this task's audit ran before touching anything.

## The hard-align sequence (run in the PRIMARY checkout only, after the PR merges)

`main` is the branch actually checked out in the primary checkout, so this is **not** a safe place for a ref-only update (`git update-ref refs/heads/main fork/main` alone would desync the index and working tree from the moved ref and corrupt the checkout).
The sequence below updates ref, index, and working tree together in one atomic `reset --hard`, after safely stashing anything uncommitted so nothing unlanded is ever discarded (prime directive #3).

```sh
cd /Users/nick/ventures/agent-ops/firstmate   # the primary checkout - confirm this before running anything

# 0. Re-run the pre-checks above against THIS checkout first.
git fetch fork '+refs/heads/main:refs/remotes/fork/main' \
  || { echo "STOP: could not refresh fork/main"; exit 1; }
git merge-base --is-ancestor main fork/main \
  && echo "OK: proceeding" || { echo "STOP: see pre-checks above"; exit 1; }
git log --oneline fork/main..main   # must be empty

# 1. Confirm you are actually on main (never run this sequence elsewhere).
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "STOP: not on main"; exit 1; }

# 2. Preserve anything uncommitted before the reset - reversible, never discarded.
if [ -n "$(git status --porcelain)" ]; then
  git stash push -u -m "fm-main-divergence-realign-$(date +%Y%m%dT%H%M%S)"
  echo "Stashed uncommitted work - recover it after the reset with: git stash list / git stash pop"
fi

# 3. The coherent ref+index+tree update. fork/main was already fetched in step 0.
git reset --hard fork/main

# 4. Post-checks.
[ -z "$(git status --porcelain)" ] && echo "OK: working tree clean" || echo "FAIL: working tree not clean"
[ "$(git rev-parse HEAD)" = "$(git rev-parse fork/main)" ] \
  && echo "OK: main now matches fork/main ($(git rev-parse --short HEAD))" \
  || echo "FAIL: HEAD does not match fork/main"
test -x bin/fm-session-start.sh && test -x bin/fm-watch.sh \
  && echo "OK: bin/ entry scripts still executable" \
  || echo "FAIL: bin/ executable bits look wrong - inspect git diff --summary fork/main"
```

If a stash was created in step 2, review it afterward (`git stash list`, `git stash show -p stash@{0}`) and either `git stash pop` it back onto the realigned `main` or drop it once you have confirmed it is no longer needed - never drop it automatically.

### Verification

This exact sequence (fetch, dirty-tree stash, `reset --hard`, post-checks) was run end-to-end in a disposable `--no-hardlinks` scratch clone during this task, including simulating uncommitted work (`README.md` edit) and an untracked file before the reset, confirming both were captured by the stash and recoverable afterward (`git stash list` showed the entry; `git stash pop` restores it cleanly).
All post-checks passed: working tree clean, `HEAD` matched `fork/main` exactly, and both `bin/fm-session-start.sh` and `bin/fm-watch.sh` retained their executable bit through the reset.

## Root cause and prevention

**Why this drift happened, and why it will happen again without a further fix (not small - documented here, not implemented in this PR):**

`/updatefirstmate` (`bin/fm-update.sh` -> `bin/fm-ff-lib.sh`) fast-forwards the primary checkout's `main` using `base_mode="origin"`, which resolves to the git remote *literally named* `origin` (`bin/fm-ff-lib.sh`: `git -C "$dir" fetch origin`, `base="origin/$default"`).
In this repo's dual-remote setup that remote is the **upstream template** (`kunchenguid/firstmate`), not the **fork** (`quinnbot-ai/firstmate`) where this fleet's own PRs actually merge.
So the routine self-update path never looks at `fork/main` at all - any PR merged straight into the fork (like `#12`-`#15` here, or via a manual merge because a stale-`main`-based branch conflicted) only reaches the primary checkout's `main` through an explicit fork-sync PR like this one or the earlier `#5` (`fm/fm-fork-sync`).
That is a structural gap, not a one-off: it will keep recurring until `base_mode="origin"` either targets the fork remote when one is configured, or is made configurable per-repo.

Fixing `base_mode` properly means detecting a fork/origin split generically (so single-remote installations, the common case this code was written for, keep working unchanged), which touches shared self-update infrastructure used by every firstmate installation - not a small change, and out of scope for this PR.
**Follow-up:** change `bin/fm-ff-lib.sh`'s origin `base_mode` (or add a new mode) to fast-forward from the remote a repo's own PRs actually land on - falling back to `origin` when no separate fork remote is configured - and update `/updatefirstmate`'s docs and `bin/fm-update.sh` accordingly. File this as a firstmate-repo task rather than folding it into a sync PR.

**What does NOT need a fix:** `treehouse` (the pooled-worktree tool new task worktrees come from) has no base-ref configuration surface at all (`treehouse init`'s generated `treehouse.toml` only exposes `max_trees` and `root`) - it worktrees whatever the repo's own local `main` currently points to.
Once this runbook's hard-align sequence runs, local `main` *is* `fork/main`'s content, so every new pooled worktree is correct again with no treehouse-side change needed.
The recurring-drift risk is entirely the `/updatefirstmate` gap above, not treehouse's worktree pool.
