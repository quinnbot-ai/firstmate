# Unit-economics source readiness

This maintainer-verification record captures the live-home source audit performed on 2026-07-26.
The ledger source and status contract is owned by [`bin/fm-unit-economics-ledger.mjs`](../bin/fm-unit-economics-ledger.mjs), and its private configuration schema is owned by [`docs/configuration.md`](configuration.md#unit-economics-ledger-configunit-economics-ledgerjson).

## Result

The live home's private `$FM_HOME/config/unit-economics-ledger.json` contains only `maxAgeSeconds` and an empty `lanes` object.
Exact local artifact paths stay in private PR evidence; this record names artifacts by role so it carries no operator machine layout.
Every non-quota metric is therefore category (a), `source configuration absent`.
No configured source was present to classify as category (b), missing or unreadable, or category (c), real but unmappable by the generator.
The generator now reports those states distinctly when configuration is added, rather than collapsing them into `source unavailable`.

The machine has several useful local artifacts, but none supplies the two fresh and independent readings needed to publish a financial fact today.
They remain unavailable by design.

## Classification key

- (a) No source is named in the private lane configuration.
- (b) A named source is missing or cannot be read or executed.
- (c) A named source is readable but its output does not satisfy the helper schema or omits the requested metric.
- (d) No authoritative underlying data exists locally for the metric, even though a future source may be known.

## Metric intake list

Each row names the exact source pair required before a follow-up adds two trusted read-only helper commands to the ignored configuration.
The pairs must have independent provenance and must emit matching fresh values in the generator's helper schema.

| Lane | Metric | Current diagnosis | Existing local evidence | Exact source required | Required supply |
| --- | --- | --- | --- | --- | --- |
| WeHo | `pipeline_cost` | (a); the only candidate is stale and single-source. | The WeHo prospect lead database's `budget_ledger` table has one `gplaces` entry dated 2026-04-19. | A fresh Google Cloud Billing usage or cost export for the WeHo project, plus a separately maintained `budget_ledger` daily reconciliation row keyed to the same day. | A follow-up must refresh the billing export, write the reconciliation row, and install two read-only normalizers. |
| WeHo | `realized_revenue` | (a) and (d); the SQLite studio schema records proposals and outcomes, not settled payments. | No local payment, invoice, or settlement record was found. | The processor's settled-charge or invoice export, plus a bank or payout-settlement export reconciled by processor transaction ID. | The captain must grant read-only access or export both records, and a follow-up must implement the two normalizers. |
| Content accounts | `cost_per_post` | (a) and (d); posting artifacts contain no spend fields. | The current `posts-ledger.jsonl` and `postbridge-ledger.jsonl` expose post identity and timestamps only. | A per-post production or API-cost allocation ledger, plus the provider invoice or usage export that backs each allocation. | A follow-up must create the attribution ledger from actual provider charges and configure the two readers. |
| Content accounts | `posts_per_day` | (a); current local evidence is usable for a future pair but is not configured. | The clip-engine account's `posts-ledger.jsonl` was updated 2026-07-26, and its `postbridge-ledger.jsonl` was updated 2026-07-25. | A daily successful-post count from `posts-ledger.jsonl`, plus the independently recorded successful target count from `postbridge-ledger.jsonl` or the Postbridge API export. | A follow-up must define the date window and account scope, prove both counts agree, and install normalizers. |
| Content accounts | `adsense_revenue` | (a) and (d); no local AdSense or YouTube payout record was found. | Current analytics contain platform post metrics but no AdSense amount. | A YouTube Studio estimated-revenue export for the selected accounts, plus the AdSense payment or bank-settlement export. | The captain must provide read-only export or access, then a follow-up must normalize both sources. |
| Content accounts | `performance_bonus_revenue` | (a) and (d); no local bonus or settlement record was found. | No payout field exists in the current Postbridge or clip ledgers. | The partner or Postbridge performance-bonus statement, plus the matching payout or bank-settlement record. | The captain must provide the statement and settlement access or exports. |
| Trading | `deployed_stake` | (a); the fresh bankroll is balance, not deployed stake. | The live trading bankroll state file was updated 2026-07-26, while `auto-trader-state.json` is from 2026-04-15. | A live VPS `tournament.db` open-position total, plus a live Polymarket wallet or portfolio position export for the same snapshot time. | A follow-up must expose the VPS snapshot read-only and add a live portfolio reader. |
| Trading | `realized_pnl` | (a); the only local P&L field is stale. | `auto-trader-state.json` has `realized_pnl` but is dated 2026-04-15, and the current live trade files are empty or stale. | A live closed-fill or settlement export from the VPS database, plus a Polymarket trade-history or wallet-settlement export. | A follow-up must refresh both sources and reconcile by trade or transaction ID. |
| Trading | `unrealized_pnl` | (a) and (d); no current marked-position P&L is persisted locally. | The fresh bankroll file has only `actual_usdc`. | A live open-position snapshot from the VPS database, plus a same-time Polymarket market-price or portfolio mark export. | A follow-up must define the valuation timestamp and produce two matching mark-to-market readers. |
| KDP | `royalties` | (a); fresh local summaries exist but share one provenance and cannot corroborate each other. | The KDP analytics summary and the finance vault's current KDP summary were refreshed on 2026-07-26, but the tracker states that both import the monthly finance reports. | A direct KDP Reports royalty CSV or dashboard export, plus the Amazon payout or bank-settlement export for the same payment period. | The captain must make KDP Reports available or export it, and a follow-up must add the independent settlement reader. |
| KDP | `attributable_costs` | (a) and (d); no KDP-tagged expense ledger exists locally. | The finance vault has narrative cost documents, not a title or KDP-attributable expense record. | A KDP-tagged receipt or invoice ledger, plus the accounting or bank-card transaction export with matching receipt IDs. | The captain or a follow-up must establish cost attribution before helpers can be configured. |
| Fleet operations | `attributable_crew_session_cost` | (a) and (d); quota windows are not monetary costs and crew sessions are not priced. | `quota-axi --json` reports fresh quota windows only. | A provider billing or usage-cost export by account and day, plus an internal crew-session allocation ledger keyed to task and session identifiers. | A follow-up must define allocation policy from actual invoices and generate both independent helper readings. |
| Daily fleet line | per-crew session cost | (a) and (d); the home has session histories but no priced session allocation. | Task-private Codex session files exist under `data/codex-crewmate/`, but no record assigns provider cost to a crew session. | The daily provider usage-cost export, plus an independent internal session-allocation ledger covering the identical crew roster. | A follow-up must define the roster and allocation policy and write fresh daily evidence. |
| Daily fleet line | validation-run volume | (a); task and validation records are not normalized into a daily, per-crew count. | Firstmate task metadata and task-private no-mistakes evidence exist, but no canonical per-crew run ledger exists. | The no-mistakes run record for each task, plus a GitHub Actions workflow-run export or `gh run list --json` result reconciled to the same commits. | A follow-up must define which validations count, write the daily run ledger, and add both readers. |

## Existing artifacts that must not be misrepresented

The 2026-04-19 WeHo budget row is historical and cannot satisfy the 900-second freshness window.
The fresh trading bankroll is neither deployed stake nor P&L.
The current content ledgers can corroborate posting activity only after a scope and daily-window definition, and they cannot produce cost or revenue.
The KDP payment ledger, KDP analytics file, current feed, and finance dashboard are derived from the same monthly finance-report import, so they are one provenance rather than an independent pair.
Quota percentages remain provider-reported capacity measurements and must not be converted to monetary crew-session cost.

## Verification

The audit used these read-only commands on 2026-07-26.
Each variable stands for a local artifact whose concrete path stays in private PR evidence.

```sh
jq . "$FM_HOME/config/unit-economics-ledger.json"
sqlite3 "$WEHO_LEADS_DB" 'SELECT * FROM budget_ledger ORDER BY day DESC, source;'
stat -f '%N %Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$TRADING_BANKROLL_JSON" "$AUTO_TRADER_STATE_JSON"
jq '.payment_summary' "$KDP_ANALYTICS_JSON"
bash tests/fm-unit-economics-ledger.test.sh
```

The test suite proves that missing configuration, malformed configuration, unreadable commands, malformed source output, unmapped metrics, an insufficient independent source count, and a ledger date no helper covers stay unavailable with distinct reasons.
