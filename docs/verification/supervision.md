# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Direct automatic closeout and refill

The direct closeout-and-refill behavior was reverified on 2026-07-27 against current `upstream/main` commit `b29621ba19a4d15b688ae277ca06b67f80baa365`.
That upstream tree has no auto-dispatch implementation, staging envelope, receipt loop, or report-only selector.
Its task lifecycle keeps the primary agent responsible for standing `yolo` authority, guarded merge through `bin/fm-pr-merge.sh`, landed-work cleanup through `bin/fm-teardown.sh`, and ready-queue reevaluation.

The pre-change reproduction passed the old report-only subsystem's own assertions:

```text
ok - concurrent refill passes claim once, reopen, report, and never spawn
ok - auto-dispatch remains fully inert when absent or disabled
```

The home had no `config/auto-dispatch.json`, so the watcher path was inert and could neither close completed work nor replenish the ready queue.
Even with that config present, its regression required that the path never spawn, confirming that it could not provide Kun's direct lifecycle.

The correction makes each mutable wake one primary-agent-owned transaction before the next wait or turn boundary.
It retains the existing guarded merge, teardown, and spawn owners and removes the conflicting report-only path instead of adding another daemon or lifecycle owner.

The deterministic end-to-end regression drives each real guard script through one transaction, selecting `fm-pr-merge.sh` for PR modes and `fm-merge-local.sh` for local-only mode before landed-work teardown and capacity-bound refill:

```sh
tests/fm-direct-lifecycle.test.sh
tests/fm-supervision-instructions.test.sh
```

Observed results:

```text
ok - routine PR work lands on default, cleans safely, and visibly refills in one transaction
ok - local-only yolo work uses its guarded owner and refills to configured capacity
ok - unlanded work fails closed and remains recoverable
ok - captain-gated completed work remains parked without merge or cleanup
ok - every primary harness and fallback render one direct guarded closeout-and-refill transaction
ok - invalid direct lifecycle capacity blocks refill without stranding safe closeout
```

The PR fixture updates the bare origin's default branch and asserts its exact landed commit before accepting teardown.
Refill is invoked inside the same closeout coordinator and reads the rendered `config/supervision-capacity` value, so the regression cannot pass by separately spawning a replacement or by satisfying teardown with a remote task branch.

The supervision renderer was checked for Claude, Codex, OpenCode, Pi, Pi Signed, Grok, Kimi, and the unknown-harness fallback.
Current `upstream/main` also maps `pi-signed` to the Pi protocol, and the new lifecycle instruction is emitted after harness selection so that adapter receives the same transaction on integration.
The current installed tool evidence was Claude Code 2.1.220, Codex CLI 0.145.0, and OpenCode 1.18.0.
Pi, Grok, and Kimi binaries were unavailable in this task environment, so their current verification is deterministic protocol rendering plus the existing dated live evidence below where available.

The tmux, Herdr, Zellij, Orca, and cmux session-provider adapters were source-reviewed.
No session-provider adapter changed because merge and teardown already route through their shared backend owner and refill already routes through `bin/fm-spawn.sh`.
The reference end-to-end fixture uses the tmux adapter, while the existing deterministic backend families cover all five providers.
Herdr was source-reviewed only, and no Herdr lifecycle command was issued because this task's launch brief did not enable the Herdr lab.
The installed provider evidence was tmux 3.6b and Herdr 0.7.3; Zellij and Orca were unavailable, while the installed cmux launcher could not report a supported version and its optional smoke test skipped as older than the verified minimum.

The final local validation used the repository-owned entry points:

```sh
bin/fm-lint.sh
bin/fm-test-run.sh --changed --base upstream/main \
  --exclude-family real-herdr-gated \
  --exclude-family live-harness-optin
tests/fm-documentation-audiences.test.sh
bin/fm-test-run.sh --check-coverage
```

The changed-path run selected 92 tests across every affected contract family.
Ninety-one passed in the initial sweep, with three declared optional-binary skips.
The only initial failure was the documentation audience checker observing the intentionally deleted skill through the still-unstaged Git index; it passed against the exact staged candidate.
The canonical lint passed with ShellCheck 0.11.0, and the coverage owner confirmed that every test remains assigned to the portable or gated lanes.

The focused review-fix validation reran the affected lifecycle, supervision, instruction-owner, and documentation-owner tests plus ShellCheck on the touched shell files:

```sh
bin/fm-test-run.sh \
  tests/fm-direct-lifecycle.test.sh \
  tests/fm-supervision-instructions.test.sh \
  tests/fm-instruction-owners.test.sh \
  tests/fm-documentation-audiences.test.sh &&
shellcheck -x \
  bin/fm-supervision-instructions.sh \
  tests/fm-direct-lifecycle.test.sh \
  tests/fm-supervision-instructions.test.sh \
  tests/fm-instruction-owners.test.sh
```

The four focused test scripts passed with zero failures, and ShellCheck produced no findings.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-captain-translation-contract.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.93 | Passive `Stop` plus bounded resume | Project hook ran under trust, resumed once without inherited bypass permissions, and the environment latch prevented recursion. |

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` and `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, a competing live owner prevented arm or rewake, and the residual active-turn gate allowed recovery commands while refusing an unrelated fleet command. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-continuity-pretool-check.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
