# CI test failure receipts

This document owns the credential-free failure-receipt schema for Firstmate's Ubuntu behavior-test lanes.
`bin/fm-test-run.sh` is the only producer and consumer of the schema.
`.github/workflows/ci.yml` supplies GitHub workflow and job identity and uploads each receipt with `if: always()`.

## Lane receipt schema

Each receipt is JSON with `schema_version: 1`, `kind: "lane"`, and a `size_cap_bytes` value of `32768`.
The producer rejects a receipt that exceeds the cap, has more than 128 script records, more than 32 failing scripts, or a string field longer than 240 UTF-8 bytes.
The receipt contains the exact candidate Git head, workflow name/run/attempt, job name, lane, runner selection and run ID, timestamps, duration, each runner-owned script classification, declared runtime availability, and a typed `failure` object.
`status` is `passed` or `failed`.
Green lanes emit `failure.kind: "none"`, `failure.count: 0`, and `failure.scripts: []`.
Red test lanes emit `failure.kind: "test-failure"` and only typed fields from the runner's script record: path, family, runtime gate, gate requirement, exit code, duration, and gate outcome.
No stdout, stderr, environment value, credential, process inventory, or free-form diagnostic text is part of the schema.

`runtime_availability` uses the runner's declared gate outcomes only.
Its `availability` is `exercised`, `unavailable`, or `not-confirmed`, and its `requirement` is the lane's declared `required` or `optional` value.

## Aggregate receipt schema

`bin/fm-test-run.sh --aggregate-failure-receipt` accepts at most 16 bounded lane receipts with the same candidate head and emits `kind: "aggregate"` under the same 32768-byte cap.
Its lane entries retain only the lane schema fields needed for consumption: identity, status, duration, declared runtime availability, and typed failure summary.
The aggregate status is failed when any lane failed, otherwise passed.
Malformed, oversized, schema-incompatible, or mixed-head inputs fail closed with an agent-readable diagnostic.

## Verification

Run `bin/fm-test-run.sh tests/fm-test-run.test.sh` for producer and aggregate regressions.
Run `bin/fm-test-run.sh tests/fm-workflow-scheduling.test.sh` for CI artifact wiring and unchanged Ubuntu scheduling coverage.
