# Upstream sync guard audit

Audience: maintainer verification.

This audit covers the merge of upstream `4d6992a293bc584381b4c746023a6d49a94b12cf` into current fork main `485ae998dbdf3cd91059dd55ec3b38ba42c4ce40`.

## Mechanical preservation checks

- `git diff --name-status 485ae998dbdf3cd91059dd55ec3b38ba42c4ce40 -- bin` reports no deleted fork-side `bin/` path in the merged tree.
- A sorted shell-function inventory compared every fork-base `bin/` file with the merged worktree and found no removed function except `harness_pid` and `holder_alive` from `bin/fm-lock.sh`.
- The two lock functions were preserved under the shared names `fm_harness_ancestry_pid` and `fm_harness_pid_alive` in upstream's new `bin/fm-session-lock-lib.sh`.
- The merged lock path adds atomic acquisition, malformed-path refusal, write probes, and ownership verification without weakening the fork's live-harness ownership test.

## Conflict guard review

- `bin/fm-spawn.sh` retains task-brief validation, isolated-worktree validation, credential-isolated Codex and Claude homes, profile attestation, git-identity setup, and guarded abort cleanup while adding Kimi launch, readiness, delivery, and hook registration.
- `bin/fm-teardown.sh` retains dirty-worktree refusal, landed-work proof including PR 35's patch-equivalence handling, unresolved-decision checks, endpoint-absence proof, treehouse lease handoff recovery, and task-private credential cleanup while adding Kimi token cleanup and Herdr session cleanup.
- `bin/fm-turnend-guard.sh` retains the complete watcher plus relay or AFK-daemon continuity requirement and the Codex checkpoint requirement while adding Claude Stop auto-arm, X-only work detection, synchronization waiting, and bounded blocker handling.
- `bin/fm-test-run.sh` retains every fork-side test family and serial safety exclusion while adding every upstream test family, the new Kimi and Herdr coverage, PR 35's `fm-merge-local` coverage, and PR 36's `fm-pr-capability` coverage.
- `AGENTS.md` retains the selector-mechanics owner, credential-isolation contracts, watcher state, and quota-aware selection guarantees while adding Kimi and upstream lifecycle ownership.

## Current-main preservation

- The rebased merge contains all 111 test files from current fork main and all 106 test files from upstream for an exact 116-file union.
- `tests/fm-merge-local.test.sh` remains present as the regression proof for landed PR 35.
- `tests/fm-pr-capability.test.sh` remains present as the regression proof for landed PR 36.
- `bin/fm-pr-capability.sh` and its early no-mistakes delivery gate remain present.

## Deferred upstream deletions

- Per this task's firstmate-provided authority, `bin/fm-continuity-command-policy.mjs` remains present and Kun's deletion is deferred to `fm-fork-delta-reckoning`.
- Per this task's firstmate-provided authority, `bin/fm-dispatch-select.sh` remains present and Kun's deletion is deferred to `fm-fork-delta-reckoning` because `AGENTS.md` section 4 still names it as the selector-mechanics owner.
- The fork-side `bin/fm-continuity-pretool-check.sh` and its test remain present so this synchronization does not discard the established continuity guard.
