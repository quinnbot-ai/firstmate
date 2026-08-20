# CI test failure receipts

This document owns the credential-free failure-receipt schema for Firstmate's behavior-test lanes.
`bin/fm-test-run.sh` is the only producer and the only consumer of that schema.
`.github/workflows/ci.yml` supplies the GitHub workflow and job identity and uploads every receipt with `if: always()`, so a red lane keeps its evidence.

The receipt answers "what exactly failed, on which candidate, with which runtimes actually available" after the ephemeral job log is gone.
It deliberately does not replace the timing artifact ([fm-test-portable-shards.md](fm-test-portable-shards.md)); the two are colocated per lane.

## Producing a lane receipt

```
bin/fm-test-run.sh --lane portable-serial-1of4 \
  --declare-runtime optional-binary=optional \
  --failure-receipt path/to/receipt.json
```

`--declare-runtime <runtime>=<required|optional>` is repeatable and states how the lane treats one gated runtime.
`<runtime>` must be a gate class printed by `bin/fm-test-run.sh --list-runtimes`; anything else is refused at argument parsing rather than recorded.
A declared runtime always appears in the receipt, even when no selected script exercised it.

CI passes lane identity through `FM_TEST_RECEIPT_WORKFLOW`, `FM_TEST_RECEIPT_RUN_ID`, `FM_TEST_RECEIPT_RUN_ATTEMPT`, `FM_TEST_RECEIPT_JOB`, and `FM_TEST_RECEIPT_LANE`.
Each falls back to `local` (the lane falls back to the runner's own selection), so a local run produces a valid receipt with no CI environment at all.

## Lane receipt schema

Each receipt is JSON with `schema_version: 1`, `kind: "lane"`, and `size_cap_bytes: 32768`.
It carries the exact candidate head from `git rev-parse HEAD`, the workflow name, run id and attempt, the job name, the lane, the runner's own run id and selection, start and finish timestamps, the lane duration, a `summary` of total/failed/gate-skipped counts, one typed record per selected script, declared runtime availability, and a typed `failure` object.
`status` is `passed` or `failed`.

Every script record holds only runner-owned typed fields: path, family, runtime gate class, exit code, duration, and gate outcome.
`gate_outcome` is `exercised` when the script ran to a zero exit, `declared-unavailable` when the script reported its own `skip:` gate line, and `not-confirmed` when it failed before its gate could be established.
No stdout, stderr, environment value, credential, process inventory, or free-form diagnostic text is part of the schema, and the identity strings CI supplies are stripped of control characters and capped at 240 UTF-8 bytes.

Green lanes emit `failure.kind: "none"`, `failure.count: 0`, and an empty `failure.scripts`.
Red lanes emit `failure.kind: "test-failure"` and repeat the same typed record for each failing script, so the failure summary reads on its own.

`runtime_availability` covers every runtime gate class present in the run plus every declared one.
`requirement` is the lane's declared `required` or `optional` value, or `undeclared`.
`availability` is `exercised` when any script of that class ran green, `unavailable` when the class was only ever gate-skipped, and `not-confirmed` otherwise.

## Bounds

The producer emits at most 128 script records and 32 failing-script records, and the whole document must fit the 32768-byte cap.
An oversized document sheds per-script detail first and failing-script detail second, setting `scripts_truncated` or `failure.truncated` and leaving `summary` and `failure.count` exact.
Shedding detail rather than refusing keeps a receipt available on exactly the runs that need one; a document that still exceeds the cap with no detail left to shed is a hard failure.

## Aggregate receipt schema

`bin/fm-test-run.sh --aggregate-failure-receipt <out.json> <lane-receipt.json>...` accepts at most 16 lane receipts sharing one candidate head and emits `kind: "aggregate"` under the same cap.
Each lane entry keeps only the fields an aggregate consumer needs: identity, status, duration, summary, declared runtime availability, and the typed failure summary.
The aggregate status is `failed` when any lane failed, and `failure.lanes` names them.

Unlike the producer, the aggregate consumer refuses malformed, oversized, schema-incompatible, or mixed-head input outright with an agent-readable diagnostic.
Every lane receipt is uploaded independently, so refusing here loses no evidence.
CI keeps the aggregate under an artifact name that does not match the lane download pattern, so re-running the aggregate job cannot feed a previous attempt's aggregate back into it.

## Verification

Run `bin/fm-test-run.sh tests/fm-test-run.test.sh` for producer, bounds, redaction, refusal, and aggregate regressions, including the CI wiring assertions parsed from `.github/workflows/ci.yml`.
