# Backlog prune dangling references diagnosis

Date: 2026-08-20.

Scope: installed `tasks-axi` 0.2.5 and the primary Firstmate home at `/Users/nick/.treehouse/firstmate-8bf1b0/5/firstmate`.

This report is an evidence artifact rather than an implementation.

## Finding

The unsafe dependency result is a `tasks-axi` defect in its active-backlog model.

The correct fix shape is a combination of lightweight completion tombstones and fail-closed unresolved-dependency evaluation.

A tombstone is necessary to distinguish a completed blocker that was pruned from an id that was never resolvable.

Fail-closed evaluation is necessary even with tombstones because an unknown id must never become dispatchable by omission.

The Firstmate inactive-terminal reconciler is a separate, deliberately backlog-independent path that already protects terminal endpoint reporting.

Therefore the original conclusion needs narrowing: all three manifestations share loss of the live backlog record, but only manifestations 1 and 2 originate in `tasks-axi` dependency and retention semantics.

## Exact tasks-axi code paths

`tasks-axi prune` dispatches to `MarkdownStore.prune` in `/Users/nick/.local/share/mise/installs/node/22.22.2/lib/node_modules/tasks-axi/dist/src/backends/markdown.js`, lines 885-929 in the inspected 0.2.5 installation.

That method loads only the configured active backlog, selects surplus entries from the requested section, removes them from `section.entries`, and appends their original lines to the archive path.

It returns only `archived` and `ids` and writes no compact completion record back into the active backlog.

The archive is consequently outside later active-backlog reads unless a caller separately parses it.

`tasks-axi ready` dispatches through `readyCommand` in `dist/src/commands/state.js` to `readyTasks` in `dist/src/derive.js`.

`readyTasks` obtains the blocked id set from `blockedIds(tasks)` and returns queued, non-held tasks absent from that set.

`blockedIds` builds its `byId` map exclusively from the supplied active task list.

For each `blocked-by` edge it adds the dependent only when `byId.get(dep.id)` exists and is not done.

A missing blocker therefore adds nothing to the blocked set and makes the dependent ready unless it has an independent hold.

`activeBlockers`, used by `list --fields blocked_by`, has the same missing-id default and renders that dependency as `none` even while `deps` still shows the raw `blocked-by:<id>` edge.

The mutation-time guard does not save this case.

`MarkdownStore.requireExistingDeps` rejects a new dependency whose blocker is absent, but `prune` can remove a blocker after that valid edge has been created.

## Reproduction of the readiness split

The active primary backlog currently contains `fm-test-run-signal-closeout` with `deps=blocked-by:fm-test-run-worker-deadlines`.

`tasks-axi list --file <primary>/data/backlog.md --fields blocked_by,deps,hold_kind,hold_reason,closed` renders its `blocked_by` field as `none` while retaining that raw dependency in `deps`.

The blocker is absent from the active backlog and present in `<primary>/data/done-archive.md` under `Archived 2026-08-20` as a done task carrying `hold-kind: captain` and the process-group-lifetime redesign hold.

This is the completed-and-pruned case that cannot be identified from the active `byId` map alone.

The closeout task no longer appears in the current `ready` output because a later manual captain hold was added directly to its live backlog record.

That hold is a mitigation added after the unsafe readiness observation, not evidence that dependency evaluation can see the archived blocker.

The counterfactual is exact: remove that independent hold while leaving the archived blocker absent, and `blockedIds` will not add closeout to the blocked set, so `readyTasks` will return it.

## Manifestation 1 - dependency edge pointing at nothing

Initiating trigger: `MarkdownStore.prune` removed `fm-test-run-worker-deadlines` from the active Done section while preserving the dependent's raw `blocked-by` edge in the active backlog.

Masking condition: the dependency had been valid at mutation time and the archived record still existed, so a human could find its meaning while `ready` could not.

Visible symptom: `fm-test-run-signal-closeout` was rendered ready before its later manual hold despite depending on the unresolved worker-lifetime decision.

The archived record says the old task is done, but also preserves a captain hold describing the unresolved redesign, so `done` alone is not a safe implication that its dependent is semantically ready.

The primary status log independently preserves the same unresolved decision.

`status_open_decisions` folds `fm-test-run-worker-deadlines.status` to the still-open default-key `needs-decision` for the round-5 hard stop.

The later `resolved [key=worker-lifetime-model]` event does not close that unkeyed default decision, and later `paused` events do not close any decision by design.

The filing's phrase "captain-held" accurately describes the operational gate but is not the literal last status verb in the current log.

The durable evidence is an archived captain hold plus the still-open default decision, not an active blocker object available to `tasks-axi`.

## Manifestation 2 - sweep silently finds nothing

Initiating trigger: pruning removes the old record from the only collection that `tasks-axi list`, `ready`, and active dependency derivation inspect.

Masking condition: the complete historical record survives in `done-archive.md`, but there is no active tombstone, archive index, or archive-aware query in the normal live-backlog path.

Visible symptom: a sweep limited to the active queue can return no candidates and cannot distinguish "nothing matched" from "the relevant historical records were pruned."

This is not solved by fail-closed readiness alone because the sweep needs a bounded historical identity and terminal state to evaluate preserved lanes.

## Manifestation 3 - terminal outcome with nowhere to attach

The first two manifestations do not imply that Firstmate misses terminal endpoints.

`bin/fm-inactive-reconcile.sh` scans `state/*.meta` in `scan_pass`, reads each eligible worker's `state/<id>.status` and current state through `fm-crew-state.sh`, and writes a `terminal-outcomes/<fingerprint>.pending` receipt before queueing a presentation wake.

It never reads `data/backlog.md` and never invokes `tasks-axi`.

The focused `tests/fm-inactive-reconcile.test.sh` suite passed on this branch and its fixtures create terminal child metadata with no backlog record, proving the endpoint-outlives-record reporting path remains independent.

The observed delayed failure was therefore an attachment and presentation gap, not a failure of the inactive reconciler to discover the terminal endpoint.

The reconciler has nowhere to restore the pruned task's historical backlog context because it intentionally carries only state metadata, status, incarnation, and optional PR evidence.

This shares the record-retention symptom but is mechanically a separate boundary from `tasks-axi ready`.

## Resolution of the apparent contradiction

My earlier statement that Firstmate endpoint reconciliation "covers pruned records" was too broad.

It covers manifestation 3 only by reporting a terminal endpoint without consulting the backlog.

It does not create a dependency tombstone, mutate `tasks-axi`'s active task list, examine archived holds for readiness, or block a queued dependent.

That is why manifestation 1 happened despite the reconciler working as designed.

The current live `ready` output no longer reproduces the original visible symptom only because the closeout task now has its own explicit captain hold.

The archive, raw dependency projection, status decision fold, and inspected derivation code together establish the prior unsafe path without conflating that mitigation with a fix.

## Recommended ownership and bounded design

`tasks-axi` should own the dependency-graph contract because it owns parsing, prune, `list`, and `ready` for every supported backend.

It should retain a compact tombstone only when a pruned record remains referenced by an active dependency, durable hold relation, or an explicitly supplied external reference.

The tombstone need retain only immutable id, terminal state, closed date, and any information required to distinguish a completed reference from an unresolved one, not title or body text.

`ready` and `activeBlockers` should treat a tombstoned done blocker as satisfied and any id missing from both active records and tombstones as unresolved.

Firstmate retains ownership of endpoint metadata and terminal-outcome receipts.

If endpoint or hold references must themselves keep task tombstones, Firstmate needs an explicit integration contract to declare those references to `tasks-axi`; the CLI cannot infer `state/*.meta` from another application's private home.

This keeps retention bounded while preserving the distinction required for safe dependency evaluation.

## Verification performed

`tasks-axi --version` returned `0.2.5`.

The installed source paths named above were inspected directly.

The primary home's active backlog, done archive, worker status log, and open-decision fold were inspected read-only.

`tests/fm-inactive-reconcile.test.sh` passed in 18.7 seconds with `all inactive reconciliation tests passed`.

No project behavior was modified by this diagnosis.
