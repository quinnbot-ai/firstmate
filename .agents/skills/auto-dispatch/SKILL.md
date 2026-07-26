---
name: auto-dispatch
description: Agent-only procedure for staging firstmate-authored tasks and operating the bounded report-only auto-dispatch refill. Use before creating or replacing a dispatch envelope, enabling or changing auto-dispatch config, or responding to an auto-dispatch report or refusal.
user-invocable: false
metadata:
  internal: true
---

# Auto-dispatch

Use this procedure for the report-only auto-dispatch feature.
It does not grant launch authority and never replaces normal intake judgment.

The backlog remains the only task queue.
A dispatch envelope is a firstmate-authored authorization and integrity receipt for one already-ready task.
A crewmate must never invoke the staging helper or edit `data/<id>/dispatch.json`.

## Stage a task

Complete normal intake before staging.
Resolve the project, route, ship or scout kind, delivery mode, authority, and task-specific brief exactly as for a manual dispatch.
Load `harness-adapters` and resolve one concrete harness, model, and effort under `AGENTS.md` section 4.
Do not ask the shell to match a natural-language dispatch rule or choose among quota candidates.

Confirm all of the following before staging:

- The task is queued, unblocked, unheld, and not a public-followup obligation.
- The brief contains the complete task and no `{TASK}` placeholder.
- The brief's project, kind, report path, worktree isolation, and delivery contract are current.
- A task that will drive Herdr lifecycle behavior uses the guarded Herdr-lab scaffold.
- The selected concrete profile is still the profile firstmate intends to use.

From the lock-owning firstmate session, run:

```text
bin/fm-dispatch-stage.sh <id> --repo <repo> --kind <ship|scout> --harness <harness> [--model <model>] [--effort <effort>] --herdr-lifecycle <none|guarded>
```

The helper refuses calls outside the lock-owning firstmate ancestry.
It obtains the authoritative machine-ready task, validates the brief, fingerprints the task and dispatch inputs, seals the concrete profile, and writes `data/<id>/dispatch.json`.
Any later task, brief, project mode, authority, or dispatch-profile configuration change requires firstmate to stage again.
Staging refuses an id that already has a report receipt and names that receipt path, because refill would otherwise skip the new envelope silently.
Retire such a receipt deliberately, only after confirming the earlier report needs superseding.

## Enable report-only refill

Read `docs/configuration.md` "Report-only auto-dispatch" before changing `config/auto-dispatch.json`.
Keep `mode` set to `report-only`.
Choose explicit limits that fit this home's supervision capacity.
An absent or disabled file remains inert.

The existing watcher invokes `bin/fm-auto-dispatch-once.sh`.
Do not start a separate loop or daemon for refill.
Do not call `fm-spawn.sh` in response to a report-only receipt.

The refill refuses manual backlog mode or a `tasks-axi` version without `ready --json` and atomic `claim --if-ready --json`.
Do not work around that refusal by parsing human output, hand-editing backlog state, or replacing the atomic claim with `start`.

## Handle outcomes

A `done: auto-dispatch would dispatch ...` event is an audit result, not evidence that a worker exists.
Inspect the consumed envelope and receipt under `state/auto-dispatch-receipts/` when reviewing the judgment.
A `blocked: auto-dispatch stopped ...` event means refill failed closed before further claims.
Resolve its concrete ownership, fleet, queue, or capacity cause before staging or enabling more work.
A `blocked: auto-dispatch refused the dispatch envelope ...` event means a sealed envelope failed integrity verification, so treat it as tampering or a lost seal key rather than ordinary staleness.
A `working: auto-dispatch is waiting on supervision capacity ...` event is routine and needs no separate captain action beyond the supervision the watcher already surfaces.
An invalid fleet inventory names any stranded `state/auto-dispatch-claims/<id>.json` journal; confirm no worker exists for that id, run `tasks-axi reopen <id>`, then remove the journal file.

Never delete worker metadata, tear down a task, merge work, answer a decision, or alter no-mistakes state to make capacity available.
Only the existing supervised lifecycle may free an open lane.
