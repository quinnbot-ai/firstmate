# Firstmate portable test shards (Phase 4)

This document records how the two portable parallel CI shards were balanced from measured evidence.
Composition and execution are owned by `bin/fm-test-run.sh` (`--lane portable-parallel-1` / `portable-parallel-2` / `portable-serial`).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (60 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Current balance durations | GitHub Actions run `30197229441` timing artifacts from main on 2026-07-26 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

The balance uses each script's `duration_ms` from the named run.
This keeps every duration in one workflow-run envelope rather than combining unrelated host conditions.

| duration_ms | script |
|---:|---|
| 107697 | `tests/fm-spawn-dispatch-profile.test.sh` |
| 90426 | `tests/fm-secondmate-harness.test.sh` |
| 67445 | `tests/fm-bearings-snapshot.test.sh` |
| 26043 | `tests/fm-arm-pretool-check.test.sh` |
| 20590 | `tests/fm-backend-herdr.test.sh` |
| 20193 | `tests/fm-secondmate-safety.test.sh` |
| 19694 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19071 | `tests/fm-backend-orca.test.sh` |
| 15967 | `tests/fm-x-mode.test.sh` |
| 13075 | `tests/fm-cd-pretool-check.test.sh` |
| 12265 | `tests/fm-backend.test.sh` |
| 12171 | `tests/fm-secondmate-sync.test.sh` |
| 7594 | `tests/fm-kimi-harness.test.sh` |
| 7588 | `tests/fm-pending-reply.test.sh` |
| 6416 | `tests/fm-fleet-snapshot-view.test.sh` |
| 6237 | `tests/fm-git-identity.test.sh` |
| 6132 | `tests/fm-secondmate-liveness.test.sh` |
| 5718 | `tests/fm-herdr-lab.test.sh` |
| 5396 | `tests/fm-crew-state.test.sh` |
| 4964 | `tests/fm-secondmate-lifecycle-e2e.test.sh` |
| 4926 | `tests/fm-test-run.test.sh` |
| 4764 | `tests/fm-backend-zellij.test.sh` |
| 3055 | `tests/fm-pr-merge.test.sh` |
| 3028 | `tests/fm-backlog-handoff.test.sh` |
| 2783 | `tests/fm-spawn-worktree-settle.test.sh` |
| 2612 | `tests/fm-shared-captain-inheritance.test.sh` |
| 2463 | `tests/fm-dispatch-select.test.sh` |
| 2186 | `tests/fm-send-secondmate-marker.test.sh` |
| 1919 | `tests/fm-grok-harness.test.sh` |
| 1583 | `tests/fm-documentation-audiences.test.sh` |
| 1459 | `tests/fm-unit-economics-ledger.test.sh` |
| 1423 | `tests/fm-send-popup-settle.test.sh` |
| 1396 | `tests/fm-visual-deliverable-check.test.sh` |
| 1300 | `tests/fm-claude-home.test.sh` |
| 1280 | `tests/fm-lint.test.sh` |
| 1135 | `tests/fm-claude-auth.test.sh` |
| 1026 | `tests/fm-review-diff.test.sh` |
| 880 | `tests/fm-subagent-pretool-check.test.sh` |
| 799 | `tests/fm-tmux-submit-busy.test.sh` |
| 747 | `tests/fm-send-strict.test.sh` |
| 723 | `tests/fm-brief.test.sh` |
| 225 | `tests/fm-spawn-batch.test.sh` |
| 207 | `tests/fm-composer-ghost.test.sh` |
| 206 | `tests/fm-send-settle.test.sh` |
| 193 | `tests/fm-operational-input.test.sh` |
| 163 | `tests/fm-pr-capability.test.sh` |
| 162 | `tests/fm-calm-pi-extension.test.sh` |
| 147 | `tests/fm-ensure-agents-md.test.sh` |
| 139 | `tests/fm-instruction-owners.test.sh` |
| 135 | `tests/fm-supervision-instructions.test.sh` |
| 132 | `tests/fm-ask-user-authority.test.sh` |
| 100 | `tests/fm-pi-primary-types.test.sh` |
| 96 | `tests/fm-captain-translation-contract.test.sh` |
| 72 | `tests/fm-nm-test-contract.test.sh` |
| 68 | `tests/fm-install-herdr.test.sh` |
| 60 | `tests/no-mistakes-required-workflow.test.sh` |
| 55 | `tests/fm-transition-lib.test.sh` |
| 41 | `tests/fm-composer-lib.test.sh` |
| 29 | `tests/fm-stow-contract.test.sh` |
| 18 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing history

The current 60-script set uses longest-processing-time assignment onto two workers with the 2026-07-26 durations above.
The refreshed proof admits 31 scripts from the former serial remainder.
They use proof-private fixture roots, fake external tools, or read-only repository inspection and passed the refreshed concurrent isolation proof.
Watcher, wake, lock, AFK, daemon, real tmux, real Herdr, and live-harness tests remain serial.
Do not rebalance alphabetically or by family intuition.
Shard execution order is longest-first within each lane.

| Lane | Script count | Sum of measured durations |
|---|---:|---:|
| `portable-parallel-1` | 30 | 259205 ms (~259.2 s) |
| `portable-parallel-2` | 30 | 259212 ms (~259.2 s) |
| imbalance | | 7 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial remainder

`portable-serial` is every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, bootstrap, live-harness opt-in (default skip), GUI backends, and other live/global-state or unproven work serial.
On 2026-07-26, recent GitHub `FM_TEST_SUMMARY duration_ms` records measured the former 70-script runner at 19:13.511-19:38.870.
One runner completed its tests in 20:00.758 but lost the whole-job deadline race before the job could finish.
Run `30197229441` measured the former serial lane at 19:38.870 and the 31 scripts moved from that lane at 6:34.566 combined.
Removing those exact script records leaves a same-artifact 39-script baseline of 13:04.304 before job setup overhead.
An exact local replay of the workflow's 19-minute GNU `timeout` plus `tee` command on 2026-07-26 completed all 39 scripts in 16:12.965 runner time and 16:13 outer wall time.
That observed replay left 2:47 before the diagnostic deadline and 3:47 before the unchanged 20-minute job tripwire.
Future drift checks should use the uploaded `fm-test-timing-portable-serial` artifact and the job timestamps because the runner duration does not include checkout or dependency installation.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. Union of portable parallel shards + portable serial + real-Herdr family equals the complete `tests/*.test.sh` inventory.
4. Those four partitions are pairwise disjoint (no missing scripts, no duplicates).

CI runs that guard as a required job (`test-coverage`).

## Timing artifacts

Every portable shard, the portable serial lane, and the Herdr lane upload their runner-generated timing JSON when the runner reaches artifact generation.
The dependent aggregate job runs after all four lanes, combines every available lane JSON through `bin/fm-test-run.sh --aggregate-json`, and uploads one summary artifact for critical-path review.
When a cancelled lane never creates its artifact, the aggregate emits `FM_TEST_AGGREGATE_INCOMPLETE`, names the missing lane, and aggregates the remaining inputs without misreporting the missing fact as a timing regression.
The workflow in `.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | Measured shard sum ~4.3 min; hang tripwire with margin |
| portable serial | 20 | 39-script replay completed in 16:13 outer wall, leaving 3:47 for job setup and teardown |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
The portable serial command has a 19-minute diagnostic deadline so it can name the active script and elapsed time before the whole-job cap cancels the runner.
Do not raise them as a substitute for green results, retries, or weaker assertions.

## What this phase does not do

- Does not expand the proven-isolated set without a new concurrent isolation proof.
- Does not parallelize watcher, AFK, real Herdr, real tmux, or other live/global-state tests.
- Does not start rollout verification; that waits until this PR is green and merged.
