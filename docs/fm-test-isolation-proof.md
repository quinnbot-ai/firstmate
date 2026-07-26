# Firstmate test isolation proof

This document archives the concurrent isolation proof for the portable parallel candidate set.
It is the human-readable companion to `bin/fm-test-isolation-proof.sh`.
Production portable shards and bounded local `fm-test-run.sh --jobs` for this exact set are owned by `bin/fm-test-run.sh` and documented in [fm-test-portable-shards.md](fm-test-portable-shards.md).
The archived flags record that the proof harness itself did not use production sharding or `fm-test-run.sh --jobs`; the proven set is consumed by those production paths after the proof succeeds.

## Owner

- Harness: `bin/fm-test-isolation-proof.sh`
- Contract tests: `tests/fm-test-isolation-proof.test.sh`
- Production partition: `bin/fm-test-run.sh`
- Timing evidence used for the partition: GitHub Actions run `30197229441` timing artifacts from main on 2026-07-26

## Proof posture

| Field | Value |
|---|---|
| `run_id` | `fm-isolation-1785087395037-49030` |
| `started_at` | `2026-07-26T17:36:35Z` |
| `finished_at` | `2026-07-26T17:46:13Z` |
| concurrency | **4** |
| candidates | **60** |
| failed | **0** |
| wall duration_ms | **578806** (~578.8s) |
| `production_sharding_enabled` | `False` |
| `fm_test_run_jobs_enabled` | `False` |
| host proof date | 2026-07-26 (UTC day of archive write) |

Isolation checks that passed with this run:

- Distinct mode-`0700` temporary roots per worker under a proof-owned parent
- Per-worker `TMPDIR` and `TMP` so `mktemp` and `fm_test_tmproot` stay private
- Ambient `FM_HOME` and `FM_*_OVERRIDE` cleared for each worker
- Global Git configuration unchanged before and after the matrix
- Aggregate failure reporting with no retry-until-green behavior

## Exact candidate set

Sorted paths as selected by `bin/fm-test-isolation-proof.sh --list` at proof time:

- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-ask-user-authority.test.sh`
- `tests/fm-backend-herdr.test.sh`
- `tests/fm-backend-orca.test.sh`
- `tests/fm-backend-zellij.test.sh`
- `tests/fm-backend.test.sh`
- `tests/fm-backlog-handoff.test.sh`
- `tests/fm-bearings-snapshot.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-calm-pi-extension.test.sh`
- `tests/fm-captain-translation-contract.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-claude-auth.test.sh`
- `tests/fm-claude-home.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-composer-lib.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-decision-hold-lifecycle.test.sh`
- `tests/fm-dispatch-select.test.sh`
- `tests/fm-documentation-audiences.test.sh`
- `tests/fm-ensure-agents-md.test.sh`
- `tests/fm-fleet-snapshot-view.test.sh`
- `tests/fm-git-identity.test.sh`
- `tests/fm-grok-harness.test.sh`
- `tests/fm-herdr-lab.test.sh`
- `tests/fm-install-herdr.test.sh`
- `tests/fm-instruction-owners.test.sh`
- `tests/fm-kimi-harness.test.sh`
- `tests/fm-lint.test.sh`
- `tests/fm-nm-test-contract.test.sh`
- `tests/fm-no-mistakes-ownership.test.sh`
- `tests/fm-operational-input.test.sh`
- `tests/fm-pending-reply.test.sh`
- `tests/fm-pi-primary-types.test.sh`
- `tests/fm-pr-capability.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-review-diff.test.sh`
- `tests/fm-secondmate-harness.test.sh`
- `tests/fm-secondmate-lifecycle-e2e.test.sh`
- `tests/fm-secondmate-liveness.test.sh`
- `tests/fm-secondmate-safety.test.sh`
- `tests/fm-secondmate-sync.test.sh`
- `tests/fm-send-popup-settle.test.sh`
- `tests/fm-send-secondmate-marker.test.sh`
- `tests/fm-send-settle.test.sh`
- `tests/fm-send-strict.test.sh`
- `tests/fm-shared-captain-inheritance.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-spawn-dispatch-profile.test.sh`
- `tests/fm-spawn-worktree-settle.test.sh`
- `tests/fm-stow-contract.test.sh`
- `tests/fm-subagent-pretool-check.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-unit-economics-ledger.test.sh`
- `tests/fm-visual-deliverable-check.test.sh`
- `tests/fm-x-mode.test.sh`
- `tests/no-mistakes-required-workflow.test.sh`

## Per-candidate durations (concurrent run)

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 171099 | 0 | 49 | `tests/fm-spawn-dispatch-profile.test.sh` |
| 114647 | 0 | 38 | `tests/fm-secondmate-harness.test.sh` |
| 99474 | 0 | 41 | `tests/fm-secondmate-safety.test.sh` |
| 75197 | 0 | 8 | `tests/fm-bearings-snapshot.test.sh` |
| 55287 | 0 | 3 | `tests/fm-backend-herdr.test.sh` |
| 41111 | 0 | 59 | `tests/fm-x-mode.test.sh` |
| 36408 | 0 | 4 | `tests/fm-backend-orca.test.sh` |
| 34611 | 0 | 18 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 28542 | 0 | 6 | `tests/fm-backend.test.sh` |
| 27473 | 0 | 40 | `tests/fm-secondmate-liveness.test.sh` |
| 26124 | 0 | 1 | `tests/fm-arm-pretool-check.test.sh` |
| 24685 | 0 | 42 | `tests/fm-secondmate-sync.test.sh` |
| 21717 | 0 | 17 | `tests/fm-crew-state.test.sh` |
| 20344 | 0 | 5 | `tests/fm-backend-zellij.test.sh` |
| 18328 | 0 | 12 | `tests/fm-cd-pretool-check.test.sh` |
| 12506 | 0 | 57 | `tests/fm-unit-economics-ledger.test.sh` |
| 12310 | 0 | 28 | `tests/fm-kimi-harness.test.sh` |
| 11382 | 0 | 23 | `tests/fm-git-identity.test.sh` |
| 10520 | 0 | 39 | `tests/fm-secondmate-lifecycle-e2e.test.sh` |
| 9894 | 0 | 25 | `tests/fm-herdr-lab.test.sh` |
| 9064 | 0 | 54 | `tests/fm-test-run.test.sh` |
| 8830 | 0 | 22 | `tests/fm-fleet-snapshot-view.test.sh` |
| 8532 | 0 | 33 | `tests/fm-pending-reply.test.sh` |
| 6391 | 0 | 36 | `tests/fm-pr-merge.test.sh` |
| 6123 | 0 | 19 | `tests/fm-dispatch-select.test.sh` |
| 5548 | 0 | 43 | `tests/fm-send-popup-settle.test.sh` |
| 5185 | 0 | 47 | `tests/fm-shared-captain-inheritance.test.sh` |
| 5112 | 0 | 44 | `tests/fm-send-secondmate-marker.test.sh` |
| 5000 | 0 | 37 | `tests/fm-review-diff.test.sh` |
| 4985 | 0 | 29 | `tests/fm-lint.test.sh` |
| 4265 | 0 | 50 | `tests/fm-spawn-worktree-settle.test.sh` |
| 3828 | 0 | 24 | `tests/fm-grok-harness.test.sh` |
| 3071 | 0 | 46 | `tests/fm-send-strict.test.sh` |
| 2825 | 0 | 13 | `tests/fm-claude-auth.test.sh` |
| 2544 | 0 | 15 | `tests/fm-composer-ghost.test.sh` |
| 2534 | 0 | 45 | `tests/fm-send-settle.test.sh` |
| 2422 | 0 | 14 | `tests/fm-claude-home.test.sh` |
| 2387 | 0 | 55 | `tests/fm-tmux-submit-busy.test.sh` |
| 2123 | 0 | 7 | `tests/fm-backlog-handoff.test.sh` |
| 1969 | 0 | 58 | `tests/fm-visual-deliverable-check.test.sh` |
| 1858 | 0 | 52 | `tests/fm-subagent-pretool-check.test.sh` |
| 1408 | 0 | 9 | `tests/fm-brief.test.sh` |
| 1202 | 0 | 35 | `tests/fm-pr-capability.test.sh` |
| 777 | 0 | 20 | `tests/fm-documentation-audiences.test.sh` |
| 369 | 0 | 48 | `tests/fm-spawn-batch.test.sh` |
| 327 | 0 | 53 | `tests/fm-supervision-instructions.test.sh` |
| 326 | 0 | 21 | `tests/fm-ensure-agents-md.test.sh` |
| 289 | 0 | 32 | `tests/fm-operational-input.test.sh` |
| 281 | 0 | 27 | `tests/fm-instruction-owners.test.sh` |
| 201 | 0 | 10 | `tests/fm-calm-pi-extension.test.sh` |
| 191 | 0 | 2 | `tests/fm-ask-user-authority.test.sh` |
| 190 | 0 | 11 | `tests/fm-captain-translation-contract.test.sh` |
| 121 | 0 | 30 | `tests/fm-nm-test-contract.test.sh` |
| 98 | 0 | 56 | `tests/fm-transition-lib.test.sh` |
| 97 | 0 | 60 | `tests/no-mistakes-required-workflow.test.sh` |
| 93 | 0 | 26 | `tests/fm-install-herdr.test.sh` |
| 64 | 0 | 16 | `tests/fm-composer-lib.test.sh` |
| 60 | 0 | 51 | `tests/fm-stow-contract.test.sh` |
| 37 | 0 | 31 | `tests/fm-no-mistakes-ownership.test.sh` |
| 31 | 0 | 34 | `tests/fm-pi-primary-types.test.sh` |

## Audit notes (why this set)

The pool contains pure contract tests plus fixture-heavy tests whose state is confined to proof-private temporary roots.
The expanded candidates use fake runtime backends and transports, private Git fixtures, private homes, or read-only repository inspection.
The concurrent run above proves this exact 60-script set at concurrency four; it does not automatically admit future tests or later changes to the listed scripts.
A candidate-set change requires a fresh audit and a new concurrent proof archive.

Representative expanded candidates:

| Class | Examples | Isolation basis |
|---|---|---|
| Fake runtime backends | `fm-backend`, `fm-backend-orca`, `fm-backend-zellij` | Stub commands and proof-private runtime roots |
| Persistent-home fixtures | `fm-secondmate-harness`, `fm-secondmate-safety`, `fm-secondmate-sync` | Private `FM_HOME`, fake endpoints, and private Git fixtures |
| Credential and dispatch fixtures | `fm-claude-auth`, `fm-dispatch-select`, `fm-kimi-harness` | Fixture credentials and stubbed quota or harness commands |
| Read-only contracts | `fm-documentation-audiences`, `fm-install-herdr`, `no-mistakes-required-workflow` | Repository inspection without shared mutable state |
| Local data transforms | `fm-unit-economics-ledger`, `fm-visual-deliverable-check` | Inputs and outputs confined to worker roots |

### Deliberately serial

Run `bin/fm-test-isolation-proof.sh --list-exclusions` for the machine-readable list.
Live or global-state classes remain outside this pool:

| Class | Examples | Reason |
|---|---|---|
| Watcher, wake, and locks | `fm-watcher-lock`, `fm-wake-queue`, `fm-watch-triage` | Intentional process locks and daemon races |
| AFK lifecycle | `fm-afk-inject-e2e`, `fm-afk-return` | Daemon lifecycle and pane control |
| Real Herdr | `fm-backend-herdr-smoke`, presentation end-to-end tests | Named labs and session-global locks |
| Real tmux smoke | `fm-backend-tmux-smoke` | Real multiplexer server |
| Live harness opt-ins | `fm-*-live-e2e` | Real interactive agents |
| GUI and optional backend smoke | cmux and zellij smoke tests | Shared applications or real servers |
| Lock and migration security | `fm-pr-check-security`, `fm-teardown` | Poll, migration, teardown, and lock-race surfaces |
| Self | `fm-test-isolation-proof.test.sh` | Must not re-enter the concurrent matrix |

## Failures

None.
Every candidate exited 0 at concurrency four.

A script that fails only under concurrency is removed from the candidate set and investigated.
It is never retried into green, skipped more broadly, or weakened in assertions.

## How to re-run

```sh
bin/fm-test-isolation-proof.sh --list
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json
bash tests/fm-test-isolation-proof.test.sh
```
