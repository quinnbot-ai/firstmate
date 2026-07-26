# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It requires a privacy-safe topic scoped to the repository and refuses a second hold with the same topic, including when the earlier hold came from another origin.
The topic is an explicit semantic identity supplied by the agent, not a title-similarity heuristic.
It cannot catch a paraphrased duplicate whose caller chooses a different topic, and it deliberately does not guess from report prose because a false match could suppress a real captain choice.
The topic scan covers every kind `captain` record of that repository wherever it sits in the live backlog, including the In flight and Done sections, and in `done-archive.md`, and `resolve` carries the topic into the resolution record it writes, so a decision answered through the tool stays matchable after it is archived.
Only a hold whose body never carried a topic, such as one written before this contract, is invisible to the topic scan.
For that claim to hold, the scan reads the same backlog grammar as the canonical parser in `bin/fm-fleet-snapshot.sh`: a metadata key opens a group with `(` or continues one after `, ` and its value ends at the next `,` or `)`, a row may be bulleted with `-` or `*` and carry an emphasized `**id**` or a `[ ]`, `[x]`, or `[X]` marker, and a blank line inside a body continues that record rather than ending it.
Requiring `(` or `, ` immediately before a key is also what keeps `hold-kind` from being read as `kind`.
The scan does not exempt the requested identity itself, because `tasks-axi show` cannot see the archive and `tasks-axi add` re-adds an archived id as fresh queued work, so the original origin and key re-asking their own answered decision is the easiest way to resurrect it.
For untagged legacy holds, it also flags only an exact repository-and-title match, which is a migration aid rather than semantic matching.
That refusal names the manual `tasks-axi update` body edit that gives the legacy hold a topic, because the script mints identities from an origin and key and cannot address an arbitrary legacy id.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, a changed topic on a retry whose hold already carries one, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

The read-only `audit` subcommand reports active captain holds whose own hold reason has an explicit recorded-answer signal.
It never closes a hold because only `resolve` can prove the durable decision record and routed work exist.
It recognizes an `answered:` marker that carries a value and reasons that say the captain answered, chose, selected, decided, approved, or said something.
A bare `answer:` or `decision:` label is deliberately not a signal, because a pending question labels itself the same way and a recurring false flag would train the reader to skim the section.
It cannot recognize unmarked answers or every natural-language paraphrase, so agents must still record answers with `resolve`.
Session start runs the audit inside its fleet-state digest and prints a section only for flagged items, or for an audit that failed, so an answered-but-open decision cannot silently blend into ordinary pending choices.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Cross-origin topic and answered-open audit verification date: 2026-07-25.
Repo-less scan, labelled-pending audit, and resolved-topic carry verification date: 2026-07-25.
Complete-regression inventory re-verification date: 2026-07-26.
Canonical backlog-grammar scan verification date: 2026-07-26.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The current regressions also reject a duplicate repository-scoped topic from a second origin and surface an answered-but-open hold without closing it.
They further refuse an already-answered topic from both the backlog Done section and `done-archive.md`, and confirm that a topic matches on its full value rather than on a prefix shared with a longer topic.
One regression drives the whole session-start digest so the flagged decision is proven to reach the reader, while a genuinely pending choice keeps that section silent.
Three further regressions hold the guards to their weakest cases: a captain hold with no repo group still reaches the audit, a pending question that labels itself `decision:` or `captain answer:` stays out of it, and a decision answered through `resolve` still blocks a re-ask once it has been archived, from its own origin and key as well as from a second origin.
A later regression drives the canonical backlog grammar directly, so a comma-continued `(repo: sample, since ...)` group, an uppercase `[X]` marker, an emphasized `**id**` row, and an archived record whose topic sits below a blank body line each still refuse the duplicate they would otherwise mint.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - repository-scoped decision topics reject cross-origin duplicates
ok - answered decision topics are refused from both the Done section and the archive
ok - decision topics match on full value, not on a shared prefix
ok - untagged legacy exact-title matches are clearly flagged
ok - captain holds without a repo group still reach the answered-open audit
ok - pending questions labelled decision or answer stay out of the audit
ok - resolve carries the decision topic into the archived resolution record
ok - answered-open captain holds are surfaced without heuristic closure
ok - session start prints answered-open decisions and stays quiet for pending ones
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```

That `ALL 71 TEST SCRIPTS PASSED` line is left exactly as its own dated run reported it and is superseded by the re-verification below.
It was already stale when it merged: the line entered the repo in `cd218f2` on 2026-07-15, and that commit's own tree already carried 73 `tests/*.test.sh` scripts.
Nothing synchronizes a hand-written total, so read each recorded count as evidence from its own dated run rather than as the current inventory.
`bin/fm-test-run.sh --check-coverage` is the current inventory owner because it derives the total from the tree and fails when the lanes stop partitioning it.

## Complete-regression re-verification, 2026-07-26

```text
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=101 parallel=30 serial=62 herdr=9

$ bin/fm-test-run.sh --all
FM_TEST_SUMMARY total=101 failed=1 skipped_gate=10 duration_ms=2246698
FM_TEST_SUMMARY_FAMILY family=real-herdr-gated count=9 duration_ms=290477 failed=1
FM_TEST_END 2026-07-26T06:34:00Z tests/fm-backend-herdr-presentation-e2e.test.sh exit=1 duration_ms=187949 gate_skip=false
not ok - concurrent primary recovery failed: error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume

$ bash tests/fm-backend-herdr-presentation-e2e.test.sh
ok - real Herdr lab validation completed on Herdr 0.7.3 with the default-session tripwire intact
(exit 0)
```

The walk collected 101 scripts, and every script named in the verification record above passed inside it, including `tests/fm-decision-hold-lifecycle.test.sh`.
The one failure is host contention rather than a defect: the `real-herdr-gated` family serializes on a single Herdr session lock, and another firstmate checkout on the same machine was exercising real-Herdr scripts during the walk.
The standalone rerun above passed while that live fleet was still running; the only thing that had changed was that no competing real-Herdr test held the single host lock at that moment.

## Coverage and focused re-verification, 2026-07-26T21:00Z

This block is a separate, later run from the 101-script walk recorded above, not a correction of it.
It re-derives the collected count from the current tree and re-runs the regression that owns the changed code, after the duplicate scanner was widened to the canonical backlog grammar.

```text
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=103 parallel=30 serial=64 herdr=9

$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - the hold scan accepts the canonical backlog row, group, and body grammar
(19 cases, all ok; the other 18 are the case list recorded above)

$ shellcheck -x bin/fm-decision-hold.sh tests/fm-decision-hold-lifecycle.test.sh
(no output)
```

The current tree therefore collects 103 scripts, two more than the 101 the earlier walk collected, which is why each dated block is read as evidence from its own run rather than as the standing inventory.
The complete `--all` walk was not repeated here, so the only full-suite result on record remains the contended 101-script run above.

## Suite-evidence standing, 2026-07-26

This entry states where the suite evidence stands for this change. It records no new run and replaces no earlier block; every count above stays as its own dated run reported it.

The shipped, rebased tree measures 104 `tests/*.test.sh` scripts, measured today with `bin/fm-test-run.sh --check-coverage`, which reports `FM_TEST_COVERAGE ok total=104 parallel=30 serial=65 herdr=9`. That is an inventory measurement, not a pass result: `--check-coverage` only derives the total from the tree and checks that the lanes still partition it, and it executes no test.

The 103-script figure recorded in the `2026-07-26T21:00Z` block above is a pre-rebase historical measurement and is superseded here: it measured a different tree, one commit behind the rebased tree this change ships, so it no longer describes the current inventory.

The most recent full-suite result on record is the earlier 101-script walk, which reported one failure: `tests/fm-backend-herdr-presentation-e2e.test.sh` exited 1 on `concurrent primary recovery`, unable to acquire the single real-Herdr session lock.

That failure is diagnosed as active-fleet environment contention rather than a code defect. The captain attests, as the owner of the operational evidence, that three serial standalone real-Herdr presentation runs passed while the fleet remained active, including the concurrent cross-home recovery case that failed inside the walk. The `real-herdr-gated` family serializes on one host lock, so a competing real-Herdr run is sufficient on its own to produce that exact refusal without any code being wrong.

A single uninterrupted full-suite pass was deliberately not re-verified inside this change, because that wide-fleet walk exceeds the fix-round budget available on a machine that is simultaneously running a live fleet.

No passing full-suite result is claimed for this tree. The only full-suite result on record remains the contended 101-script run recorded above, and the authoritative pass or fail verdict for the 104-script tree belongs to this pipeline's dedicated test step.
