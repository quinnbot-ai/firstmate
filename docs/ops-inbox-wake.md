# Operational alert inbox wake

Some machines run an operations runtime that records critical alerts - dead-man timers, tripwires, backup and service health checks - into a durable inbox instead of a chat transport.
An inbox nobody reads disarms every one of those checks silently, because each check still "fires" and still records its alert while no one is told.
This watch closes that gap by turning an unreviewed critical backlog into an ordinary Firstmate wake, so a stalled alert queue reaches the first mate the same way a crew signal or a merged pull request does.

Alerts route to the first mate, never straight to the captain, and never through any external service.
The first mate decides what an alert backlog means and escalates only what the captain actually needs.

## What is watched

The watch reads three paths and writes to none of them:

| Path | Role |
|---|---|
| `<state_dir>/ops-inbox.jsonl` | append-only alert spool, one JSON object per line with `id`, `ts`, `source`, `severity`, and an inline `ack` flag |
| `<state_dir>/ops-inbox-acks.jsonl` | acknowledgement log, one JSON object per line with `event_id` |
| `<state_dir>/ops-inbox-receipt.json` | the runtime's own periodic review receipt, carrying `unacked_critical_count` |

An alert counts as unacked exactly when the spool's own reader counts it: `severity` is `critical`, the inline `ack` flag is `false`, and no acknowledgement entry names its `id`.
Firstmate never acknowledges, rotates, or edits these files; acknowledging remains the operations runtime's own command.

`<state_dir>` defaults to `$HOME/.openclaw/state` and is overridable per home; see [Configuration](#configuration).

## When it wakes

Any one of these conditions makes the backlog wake-worthy:

- more unacked critical alerts than `count` (default 25);
- at least one unacked critical alert older than `age_hours` (default 6);
- the review receipt is stale, missing, or unreadable, because a dead receipt generator is itself the alerting failure, and it is the failure that hides every other one;
- the spool has grown past `max_lines` (default 20000), so it can no longer be read whole inside one check and needs rotating or triaging;
- the watch configuration is malformed, so no threshold can be trusted.

A fresh receipt's own `unacked_critical_count` is the reported total; when the receipt is stale, missing, or unreadable, the total is counted from the spool instead and the wake says which case it is.
The oldest age and the alert classes always come from the spool, since the receipt does not carry them.

The wake is one compact digest line, enough to triage without reading the whole inbox:

```
ops-inbox: 621 unacked critical alerts, oldest 13d, top: routine-scheduler 154, pipeline-verifier 96, scheduled-work-inventory 60
```

```
ops-inbox: alert receipt stale 9h; 3 unacked critical alerts, oldest 8h, top: backup-verify 3
```

Alert class is the spool's `source` field, sanitized and length-capped so a hostile or malformed alert cannot forge extra fields, split the line, or corrupt the durable wake record.

The read itself is bounded: the check samples at most `max_lines + 1` spool lines to detect overflow, then parses only the most recent `max_lines` of the spool and acknowledgement log, so its work stays bounded however large the inbox grows.
Exceeding that cap is reported without claiming the exact spool length, because a capped read understates both the total and the oldest age:

```
ops-inbox: inbox past its 20000-line read cap, so the total and oldest age below are understated; 20000 unacked critical alerts, oldest 6d, top: routine-scheduler 5104
```

## When it stays quiet

A standing backlog must not re-wake on every poll, or the wake becomes noise and gets ignored - the same failure in a different shape.
`state/.ops-inbox-wake` privately records the last wake's total, receipt state, and class set.
After a first wake, a further wake needs one of:

- a total at least `growth` larger than the last wake's total (default 10);
- an alert class that was not present at the last wake;
- a changed receipt state, such as a fresh receipt going stale;
- `remind_hours` elapsed since the last wake (default 24), so an unreviewed backlog is raised again daily rather than once and forgotten.

When the backlog clears, that record is removed, so the next backlog wakes immediately instead of being deduplicated against an already-resolved one.

## How it is armed

The watch is the reserved standing check `state/ops-watch.check.sh`, registered through the ordinary custom-check trust binding in `bin/fm-check-register.sh`.
That shim only exports the home and runs `bin/fm-ops-inbox-poll.sh`; the watcher runs the registered bytes and turns any output into one `check:` wake.
Arming is a session-start bootstrap sweep, so it converges on its own rather than depending on anyone remembering to arm it.

By default a home arms the watch only when the configured alert spool actually exists, so a machine with no operations runtime writes nothing and prints nothing.
Bootstrap disarms it again when the inbox goes away, refuses to arm over a live task holding the reserved `ops-watch` id, and reports an arming failure as an actionable `OPS_INBOX:` line.
Arming and disarming are otherwise silent; `FM_BOOTSTRAP_VERBOSE_FACTS=1` prints them as `BOOTSTRAP_INFO` facts.

An armed watch counts as a supervision need in `bin/fm-supervision-lib.sh`, exactly like an X-mode relay poll.
A standing poll only ever reaches the first mate through a live watcher, so a home that is watching alerts keeps supervision alive even with an empty fleet.

## Configuration

Local, gitignored `config/ops-inbox.json` under the effective home overrides the defaults.
Every key is optional, and an unrecognized key is refused rather than ignored, so a mistyped threshold can never read as a configured one.

```json
{
  "enabled": "auto",
  "state_dir": "/Users/you/.openclaw/state",
  "age_hours": 6,
  "count": 25,
  "remind_hours": 24,
  "growth": 10,
  "receipt_stale_hours": 3,
  "max_lines": 20000
}
```

- `enabled` is `auto` (default: arm only when the spool exists), `true` (always arm, and treat a missing spool or receipt as an alerting failure), or `false` (never arm).
- `state_dir` selects the watched directory; `spool`, `acks`, and `receipt` override those three paths individually.
- `remind_hours: 0` disables re-reminding, and `receipt_stale_hours: 0` disables the staleness condition.
- `max_lines` bounds how many recent spool and acknowledgement lines one check reads (default 20000).
- `FM_OPS_INBOX_STATE_DIR` overrides the default watched directory for tests and specialized setups; an explicit config value always wins over it.

`docs/configuration.md` owns where this file sits among the other local operating choices, and `bin/fm-ops-inbox-lib.sh`'s header owns the exact resolution mechanics.

## Two paths named "ops-inbox"

The JSONL spool above is the alert inbox this watch reads.
A second, unrelated path shares the name: some operations routines drop plain-text `.event` files into `<firstmate-home>/ops-inbox/<source>/`, a spool with no severity field, no acknowledgement model, and no reader on the Firstmate side.

Those two are not two views of one inbox; they are one watched inbox and one unread drop directory.
Firstmate treats the JSONL spool plus its receipt as the single alert surface, and gitignores the drop directory so its machine-local files can never be committed into this shared repo.
Converging the routines that write `.event` files onto the JSONL spool belongs to the operations repository that owns those routines, not here: an alert only reaches this watch once its producer records it in the spool.
Until that convergence lands, an alert written only as an `.event` file is not covered by this watch.
