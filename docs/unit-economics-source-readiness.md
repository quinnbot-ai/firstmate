# Unit-economics source readiness

The ledger source and status contract is owned by [`bin/fm-unit-economics-ledger.mjs`](../bin/fm-unit-economics-ledger.mjs), and its private configuration schema is owned by [`docs/configuration.md`](configuration.md#unit-economics-ledger-configunit-economics-ledgerjson).

## Current contract

No financial lane source is currently configured in the active home's private `config/unit-economics-ledger.json`.
The operator-specific readiness audit and supporting evidence live only in the active home's ignored `data/unit-economics-source-readiness.md` file.
It is not a tracked repository artifact.

## Classification key

- (a) No source is named in the private lane configuration.
- (b) A named source is missing or cannot be read or executed.
- (c) A named source is readable but its output does not satisfy the helper schema or omits the requested metric.
- (d) No authoritative underlying data exists locally for the metric, even though a future source may be known.

## Source requirement

Every published financial metric requires two distinct trusted read-only helpers with independent provenance.
The helpers must emit matching fresh values in the generator's schema before the ledger may publish a measured or estimated value.
Any missing, unreadable, malformed, incomplete, stale, or disagreeing source remains unavailable rather than being inferred or replaced with zero.
