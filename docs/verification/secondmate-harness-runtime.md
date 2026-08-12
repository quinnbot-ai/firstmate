# Secondmate harness test-runtime verification

Audience: maintainer verification.

Verified 2026-08-11 on macOS with Bash 3.2.57.

`tests/fm-secondmate-harness.test.sh` uses only private fake-toolchain seams for submit waits.

Production scripts do not read `FM_TEST_FAST_SEND_SLEEP`, and their retry intervals, timeouts, lifecycle protocol, and configuration surface are unchanged.

The pre-change baseline was 125.89 seconds for a normal suite run and 122.24 seconds with `BASH_XTRACEFD` profiling enabled.

The trace attributed 17.32 seconds to the full 16-generation retry queue plus new-pointer delivery case, about 0.95 seconds per pointer submit, and one explicit one-second mtime assertion plus polling in the concurrent-push fixture.

The post-change repeated wall times were 73.46, 73.78, and 81.36 seconds, giving an observed p95 of 81.36 seconds.

The full retry queue still asserts all 17 pointer deliveries and records at least 17 each of the protected 0.3-second pre-submit and 0.4-second post-submit waits.

The unchanged-inheritance case uses a logging `cp` fake and fails if a no-op re-run copies a file.

The concurrent-push case releases its first pointer only after the second invocation reaches the lock retry, and fails if that lifecycle event is absent.

Run the verification from the repository root:

```console
$ /usr/bin/time -lp bash tests/fm-secondmate-harness.test.sh
# all fm-secondmate-harness tests passed
```
