# Parallel test worker lifetime proposal

Audience: maintainer architecture.

This is decision input for a future `bin/fm-test-run.sh` worker-deadline implementation, not an implementation decision.

## Decision requested

When the shell that leads an isolated worker process group exits but the same PGID still has members, should Firstmate treat that as a passing worker that may drain, or as a process leak that it cleans up and fails?

The recommended answer is: treat it as a process leak, begin cleanup immediately, and report it as a worker failure after the group is proven gone.

The unambiguous invariant under either answer is that a scheduler slot and its `FM_TEST_END` result belong to the whole recorded process group, never merely to the Bash job leader or its exit file.

## What the retired lane established

The preserved reference `fm/fm-test-run-worker-deadlines` at `fed1f3da` established the intended scope without changing the current upstream implementation.

- Per-worker deadlines apply only to `--jobs` execution of the already proven-isolated set, while serial execution remains unchanged.
- Each parallel worker needs a private temporary root and an independently verified process group before it is armed.
- Deadline cleanup must signal that process group, rather than only the script shell, so ordinary background descendants receive `TERM` and then `KILL` if necessary.
- A deadline must remain an aggregate failure with a stable timeout result while unrelated worker results remain visible.

Its fifth review round found the remaining flaw: Bash job control reports the backgrounded leader as done after that leader exits, even when descendants in the recorded PGID continue to run.

The old scheduler could therefore consume an exit file or a missing leader as completion, decrement `active_workers`, and start another test before its owned group had disappeared.

That is an ownership-boundary error, not a reason for a sixth patch round on the retired branch.

Firstmate already uses the correct lifetime pattern for process-event runners: a dead leader with a surviving owned group is not reclaimable, and cleanup or replacement waits for the group to disappear.

This proposal applies that one lifetime boundary to parallel test workers.

## Proposed worker state model

The worker record contains a launch-verified leader PID, its process-group ID, the start time, the script path, and a private result directory.

The launcher may record the script exit code as soon as the script shell returns, but that file is only a pending result and never a completion signal.

```text
launching
  -> running
  -> leader exited, group absent       -> record ordinary result -> terminal
  -> leader exited, group present      -> selected leak policy   -> cleanup -> group absent -> terminal
  -> deadline reached                  -> timeout cleanup        -> group absent -> terminal
  -> cleanup cannot prove group absent -> fatal scheduler error
```

`group absent` means the kernel no longer reports a process group at the recorded PGID, checked with the same negative-PGID probe used for cleanup.

The scheduler decrements `active_workers`, makes the slot available, replays captured output, and emits `FM_TEST_END` only on the terminal transitions in that model.

A leader `wait`, Bash `jobs`, a script exit file, or a deadline signal are all observations or actions before the terminal boundary, not substitutes for it.

The group identity must be captured only after launch verifies that the intended leader is its group leader.

Cleanup may signal a negative PGID only for that verified owned group, and only while the record still establishes the relationship needed to avoid signalling an inherited caller group.

## The captain's choice

| Option | Leader exits while its PGID survives | Result if cleanup works | Cost |
|---|---|---|---|
| A. Leader-complete | Release the slot immediately. | Preserve the leader exit code. | Reject: repeats the known orphan race. |
| B. Passive group drain | Hold the slot until the group ends naturally or reaches its deadline. | Preserve the leader exit code if the group disappears on its own. | Avoids killing short-lived background work, but silently accepts leaked test processes and can consume a slot until the deadline. |
| C. Immediate leak cleanup | Hold the slot, send cleanup immediately, and do not start a replacement until the group is gone. | Record a distinct worker failure after disappearance. | Makes accidental background work visible and can fail tests that intentionally leave same-group helpers running. |

I recommend option C.

A behavior-test script has no legitimate need to leave an unjoined same-group helper alive after its top-level shell exits.

Option C turns that mistake into an actionable test failure, keeps test concurrency honest, and gives a precise invariant that maintainers can verify.

Option B is defensible only if the project deliberately supports post-script same-group helpers and is willing to document their lifecycle and capacity cost.

Option A should not be selected because it reintroduces the exact round-five hard stop.

## Cleanup and failure semantics

On a deadline, the worker enters cleanup immediately, emits the existing timeout diagnostic, sends `TERM` to the recorded group, waits a bounded grace interval, then sends `KILL` if the group remains.

Under option C, the same sequence begins when the leader exits but the group remains, with a distinct leak diagnostic that names the script and PGID.

The runner must continue to probe the group after `wait` reaps the leader, because reaping the leader does not reap unrelated descendants.

Only a failed negative-PGID probe closes cleanup.

If the bounded post-`KILL` confirmation cannot prove disappearance, the runner must fail closed: stop scheduling replacements, attempt the same owned cleanup for its other live groups, and exit with a distinct fatal runner status rather than emitting a normal worker completion or success summary.

This is deliberately stricter than logging a warning and continuing, because a warning would release scheduler capacity without proving that the capacity is free.

For distinguishable aggregate output, use exit `124` for a deadline whose group was cleaned up, a separate nonzero code such as `125` for the option-C post-leader leak, and a fatal runner error for unconfirmed cleanup.

The exact marker spelling, grace durations, and command mechanics remain the future script header's responsibility.

## Scope boundary

This model owns descendants that remain in the verified worker PGID.

A test can intentionally escape that scope with a new session or process group, and a process-group runner cannot safely discover or kill that escaped process without a broader ownership mechanism.

The implementation must state this boundary plainly and must not claim that process-group cleanup reaches `setsid` or separately grouped descendants.

That limitation does not weaken the round-five decision because the observed defect is a same-PGID survivor.

## Focused acceptance proof

Extend `tests/fm-test-run.test.sh` with fixture workers rather than running the complete suite.

The key regression fixture starts a same-PGID child that ignores `TERM`, writes its PID and PGID to the private fixture evidence, and lets the top-level test shell exit `0` immediately.

The proof must show all of the following.

- The leader exit and the script exit file do not release the slot or start a queued replacement while `kill -0 -- -PGID` still succeeds.
- Option C emits the leak diagnostic, sends group `TERM`, escalates to group `KILL`, and reports the chosen nonzero leak result only after the group is absent.
- The existing deadline fixture still reports `124`, cleans its entire same-PGID group, and preserves independent passing and failing results.
- A normal worker whose leader and group both disappear retains its ordinary exit status.
- Serial execution remains outside the worker deadline model.
- A fixture that prevents post-`KILL` disappearance reaches the fatal no-replacement path rather than falsely recording completion.

The test should assert group disappearance directly, not only that a remembered child PID is gone.

The existing timeout test's remembered-PID assertion remains useful secondary evidence, but it cannot by itself prove the slot-lifetime invariant.

## Non-decision implementation sequence

After the captain chooses an option, implement the lifecycle owner in `bin/fm-test-run.sh`, extend the focused contract test, update the script header for user-visible flags and markers, and record the resulting behavior in the appropriate current verification surface.

Do not revive or extend `fed1f3da`.
