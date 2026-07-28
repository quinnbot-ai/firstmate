# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-07-27.
The implementation was verified by the focused behavior suite after the current change.

```sh
tests/fm-link-intake.test.sh
```

Observed guarantees:

```text
PASS: record and index publication failures restore the prior state
PASS: validation rejects divergence in both index-to-record directions
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transcript metadata, publication rollback, bidirectional consistency, odd URLs, and the one-line `AGENTS.md` trigger.
