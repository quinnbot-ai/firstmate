# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-08-02.
The implementation was verified by the focused behavior suite after the current change.

```sh
tests/fm-link-intake.test.sh
```

Observed guarantees:

```text
ok - lock claims use portable replacement, atomic quarantine, and process-start identity
ok - lock identity is timezone-stable and legacy recovery is upgrade-safe
ok - retrieval dates are real calendar dates and remain path-safe
ok - one process-crash atomic switch survives failures and process death
ok - validation rejects record, index, and transcript divergence
ok - a retrievable link prepares one queued, undispatched ingest scout
ok - repeated intake of one link converges on a single ingest scout
ok - scout preparation is skippable, repairable, and refused for inaccessible records
ok - a failed scout preparation keeps the link record and reports the repair
ok - a manual backlog backend prepares the brief and prints the item to add
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transaction-staged transcripts, an atomic initialized lock claim, UTC-normalized process-start ownership, upgrade-safe legacy lock recovery, stale-lock quarantine, BSD and GNU symlink replacement, real calendar dates, a process-crash atomic state switch, conservative retained state, bidirectional consistency, odd URLs with query slashes, and the one-line `AGENTS.md` trigger.
For ingest-scout preparation it covers the filled brief and its queued backlog item, the absence of any dispatch, convergence on one scout when the same link is recorded again under a different title, `--no-scout` and `prepare-scout`, refusal for an inaccessible record, the exit-3 path that keeps the stored record when preparation fails, the manual backlog backend, and an odd URL that stays data in the scout task id and brief instead of controlling either.
The scout-preparation cases that file a backlog item skip themselves when `tasks-axi` is absent.
Filesystem sync barriers and power-loss durability are explicitly outside this focused process-crash guarantee.
