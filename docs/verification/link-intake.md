# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-07-28.
The implementation was verified by the focused behavior suite after the current change.

```sh
tests/fm-link-intake.test.sh
```

Observed guarantees:

```text
PASS: one atomic generation switch survives failures and process death
PASS: validation rejects record, index, and transcript divergence
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transaction-staged transcripts, a crash-safe single state switch, stale-lock recovery, retained recoverable state, bidirectional consistency, odd URLs with query slashes, and the one-line `AGENTS.md` trigger.
