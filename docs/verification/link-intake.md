# Link-intake verification

This record owns active empirical verification for private durable link intake.

Verification date: 2026-07-27.
The implementation was verified by the focused behavior suite, documentation-audience check, and pinned ShellCheck lint after the current change.

```sh
bin/fm-test-run.sh tests/fm-link-intake.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

Observed summary:

```text
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1526
FM_TEST_SUMMARY_FAMILY family=unclassified count=1 duration_ms=1462 failed=0
fm-doc-audience-check: ok surfaces=57 local_links=155
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

The focused suite covers canonical duplicate convergence, searchable title and summary fields, inaccessible records, transcript metadata, atomic update rejection, odd URLs, and the one-line `AGENTS.md` trigger.
The documentation check verifies that the public, operator-current, and maintainer-verification surfaces remain classified and locally linked.
