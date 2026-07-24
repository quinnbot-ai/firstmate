# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its new PreToolUse continuity gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The existing turn-end guard implementation and adapters are unchanged.
They remain the final backstop rather than the normal continuity mechanism.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Relay leases

While a harness-visible `bin/fm-watch-arm.sh` relay waits for a watcher, it holds a home-scoped lease in `state/.watch-arm.lease` and binds that lease to the exact watcher in `state/.watch-arm.bound`.
The binding records the home, watcher path, watcher PID, and watcher identity, while the lease records the relay PID identity and heartbeat alongside the same home and watcher identity, so a sibling home, stale lock, or recycled PID cannot satisfy it.
`FM_ARM_LEASE_GRACE` bounds heartbeat freshness and defaults to 45 seconds; `FM_ARM_LEASE_TICK` sets the refresh cadence and defaults to 5 seconds.
The watcher checks a lease only after an arm has bound itself to that exact watcher, so direct manual or test watchers remain supported.
The complete lease is published before the binding, so a watcher never treats an in-flight arm claim as a lost relay.
If a bound watcher next reaches its poll boundary without a fresh identity-matched relay, it durably appends `check: watcher arm relay lost` under the `watcher-arm-relay` wake key and then exits through that actionable wake.
An ordinary arm close releases only its own identity-matched lease, while a re-arm may remove only a stale, fully revalidated lease before it claims the successor binding.
Heartbeat refresh and stale reclamation share a short owner-scoped fence, so reclamation rechecks freshness after any in-progress renewal rather than unlinking a live lease.
[`turnend-guard.md`](turnend-guard.md#relay-health-predicate) owns the turn-end implications of this lease.

## Away-mode daemon lease

Away mode holds `state/.supervise-daemon.lock` to the same liveness standard rather than trusting a PID file alone.
The daemon publishes its home, script path, PID identity, and heartbeat, refreshes that heartbeat during its loop, and stops if ownership changes.
It uses the same heartbeat fence as an arm lease when stale reclamation overlaps a refresh.
AFK start and stale-lease reclamation use `FM_DAEMON_LEASE_GRACE`, which defaults to 45 seconds, while turn-boundary freshness uses the guard's own `FM_GUARD_GRACE`.
The turn-end guard requires this daemon lease and a healthy watcher while `state/.afk` is present; it does not require a separate arm relay because the daemon owns that watcher lifecycle.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude and Grok depend on their native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence and exact opt-in commands.
