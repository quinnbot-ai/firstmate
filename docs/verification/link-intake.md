# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-07-28.
The implementation was verified by the focused behavior suite after the current change.

```sh
tests/fm-link-intake.test.sh
```

Observed guarantees:

```text
PASS: lock claims use portable replacement, atomic quarantine, and process-start identity
PASS: retrieval dates are real calendar dates and remain path-safe
PASS: one process-crash atomic switch survives failures and process death
PASS: validation rejects record, index, and transcript divergence
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transaction-staged transcripts, an atomic initialized lock claim, portable process-start ownership, stale-lock quarantine, BSD and GNU symlink replacement, real calendar dates, a process-crash atomic state switch, conservative retained state, bidirectional consistency, odd URLs with query slashes, and the one-line `AGENTS.md` trigger.
Filesystem sync barriers and power-loss durability are explicitly outside this focused process-crash guarantee.
