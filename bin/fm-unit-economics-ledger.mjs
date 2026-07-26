#!/usr/bin/env node
// Render the private, daily fleet unit-economics ledger.
// Usage: fm-unit-economics-ledger.mjs [--config <path>] [--output <path>] [--format json|markdown]
//
// The private config defaults to $FM_HOME/config/unit-economics-ledger.json and
// contains optional lane definitions for weho, content_accounts, trading, and
// kdp, plus an optional `maxAgeSeconds` freshness window (default 900). A
// lane's `sources` are trusted private command arrays, each with an optional
// `timeoutMs` (default 30000). Each command is run fresh with $FM_HOME as its
// working directory - the current directory stands in only when FM_HOME is
// unset - so a relative helper path resolves against $FM_HOME itself, never
// against the invoker's cwd or the directory holding --config, and must print
// one JSON object:
//   {"observedAt":"<ISO-8601>","currency":"USD","metrics":{
//     "metric_name":{"amount":12.3,"unit":"USD","status":"measured"}}}
// A financial fact is published only when every source configured for its lane
// returned a fresh reading, at least two of them ran distinct commands
// (identical command arrays collapse to one and corroborate nothing), and they
// agree exactly on amount, unit, and top-level currency. Freshness is judged
// against the artifact's own publication timestamp, so a parsable `observedAt`
// in the future or older than the window says `stale source refused`, while
// output whose `observedAt` is absent or unparsable is malformed rather than
// stale. A source can mark a value
// `estimated`; it remains estimated even when corroborated. Missing, stale,
// malformed, or disagreeing inputs are rendered unavailable, never as zero.
// A lane without any configured sources says `source configuration absent`, a
// `sources` container that is not an array, or an entry without a non-empty
// array of string command words, or one whose optional `timeoutMs` is present
// but not a positive number, says `source configuration malformed`, and fewer
// than two surviving distinct commands says `independent source count
// insufficient`.
// A configured command that cannot be read says `source unreadable`, malformed
// command output says `source malformed`, and a valid source which omits the
// requested metric says `source metric missing`. A diagnosed source failure is
// reported ahead of an insufficient source count, so a single broken helper
// stays distinguishable from an unconfigured pair.
// The fixed fleet_operations lane reads quota-axi --json fresh at invocation
// time and publishes the lowest in-range (0-100) percentRemaining of a provider
// whose own reported state is fresh; a provider without a `state.refreshedAt`
// is source unavailable and one whose `refreshedAt` falls outside the window is
// a stale source refused. Quota windows are measurements, not financial facts,
// and attributable crew/session cost stays unavailable unless
// `fleet_operations.cost_sources` supplies two corroborating private helpers.
// The daily fleet line also records the accepted fields from every fresh
// quota-axi provider window as a windowed provider report, rather than treating
// it as an exact monetary cost.
// Its `fleet_operations.daily_sources` are two or more distinct trusted private
// command arrays that each print one JSON object with a non-empty `source`,
// `observedAt`, the ledger `date` (YYYY-MM-DD), `currency`, and `crewSessions`
// rows:
//   {"crew":"<id>","sessionCost":{"amount":1,"unit":"USD","status":"measured"},
//    "validationRuns":{"amount":1,"unit":"runs","status":"measured"}}
// The helpers must agree on the complete crew roster, on a single top-level
// `USD` currency, and on every amount before a per-crew cost, validation-run
// volume, or fleet total is published under `daily_attributable_crew_session_cost`;
// a readable, corroborated non-USD currency is refused rather than converted,
// and where corroborating helpers label one agreed amount differently the
// weakest label wins, so a `measured`/`estimated` pair publishes as estimated.
// An explicit corroborated empty roster is a rendered zero, while every missing
// or unreadable source is unavailable. Readable helpers that disagree on the
// crew roster, on the top-level currency, or on any amount all say `source
// disagreement refused`. A daily helper whose own `date` is a
// valid calendar date other than the ledger date says `ledger date not
// covered`, so a backfill can tell an uncovered day from broken helper output.
// The ledger date is today in UTC unless
// `FM_UNIT_ECONOMICS_LEDGER_DATE` overrides it with a valid `YYYY-MM-DD` date
// for tests and backfills; any other value is rejected before anything is
// written. Because quota-axi only ever reports the present, a ledger date other
// than today in UTC refuses every quota window and quota metric as a backfilled
// window rather than filling that day with present-day evidence. The command
// writes two durable owner-only (0600) ledgers at the
// dated default output `data/unit-economics-ledger/YYYY-MM-DD.json` and adjacent
// Markdown file, or at --output and its adjacent Markdown file when overridden.
// It prints whichever one --format selects (default markdown).

import { closeSync, fchmodSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const fmHome = process.env.FM_HOME || process.cwd();
const ledgerDate = process.env.FM_UNIT_ECONOMICS_LEDGER_DATE || new Date().toISOString().slice(0, 10);
if (!isCalendarDate(ledgerDate)) fail(`FM_UNIT_ECONOMICS_LEDGER_DATE must be a valid YYYY-MM-DD date, got: ${ledgerDate}`);
const defaults = {
  config: resolve(fmHome, 'config/unit-economics-ledger.json'),
  output: resolve(fmHome, `data/unit-economics-ledger/${ledgerDate}.json`),
  format: 'markdown',
};
const laneSpecs = {
  weho: { label: 'WeHo', metrics: [['pipeline_cost', 'USD'], ['realized_revenue', 'USD']] },
  content_accounts: { label: 'Content accounts', metrics: [['cost_per_post', 'USD'], ['posts_per_day', 'posts/day'], ['adsense_revenue', 'USD'], ['performance_bonus_revenue', 'USD']] },
  trading: { label: 'Trading', metrics: [['deployed_stake', 'USD'], ['realized_pnl', 'USD'], ['unrealized_pnl', 'USD']] },
  kdp: { label: 'KDP', metrics: [['royalties', 'USD'], ['attributable_costs', 'USD']] },
  fleet_operations: { label: 'Fleet operations', metrics: [['claude_quota_window', 'percent'], ['codex_quota_window', 'percent'], ['attributable_crew_session_cost', 'USD']] },
};

const BACKFILLED_WINDOW_REFUSED = 'backfilled window refused';
const SOURCE_CONFIGURATION_ABSENT = 'source configuration absent';
const SOURCE_CONFIGURATION_MALFORMED = 'source configuration malformed';
const SOURCE_UNREADABLE = 'source unreadable';
const SOURCE_MALFORMED = 'source malformed';
const SOURCE_METRIC_MISSING = 'source metric missing';
const INDEPENDENT_SOURCE_COUNT_INSUFFICIENT = 'independent source count insufficient';
const LEDGER_DATE_NOT_COVERED = 'ledger date not covered';
const SOURCE_DISAGREEMENT_REFUSED = 'source disagreement refused';

function fail(message) { process.stderr.write(`error: ${message}\n`); process.exit(2); }
function isCalendarDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
function args() {
  const result = { ...defaults };
  const values = process.argv.slice(2);
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === '--config' || value === '--output' || value === '--format') {
      if (!values[index + 1]) fail(`${value} requires a value`);
      result[value.slice(2)] = values[++index];
    } else if (value === '--help' || value === '-h') {
      process.stdout.write('Usage: fm-unit-economics-ledger.mjs [--config <path>] [--output <path>] [--format json|markdown]\n');
      process.exit(0);
    } else fail(`unknown argument: ${value}`);
  }
  if (!['json', 'markdown'].includes(result.format)) fail('--format must be json or markdown');
  return result;
}
function parseJson(text, context) { try { return JSON.parse(text); } catch { return null; } }
function isoFresh(value, maxAgeSeconds, referenceTime) {
  const parsed = Date.parse(value || '');
  return Number.isFinite(parsed) && parsed <= referenceTime && referenceTime - parsed <= maxAgeSeconds * 1000;
}
function unavailable(name, unit, reason = 'source unavailable') {
  return { name, amount: null, unit, currency: unit === 'USD' ? 'USD' : null, status: 'unavailable', source_freshness: reason, cross_check: 'unavailable' };
}
function runSource(source) {
  if (!source || !Array.isArray(source.command) || source.command.length === 0 || source.command.some((item) => typeof item !== 'string')) return { ok: false, reason: SOURCE_CONFIGURATION_MALFORMED };
  if (source.timeoutMs !== undefined && (!Number.isFinite(source.timeoutMs) || source.timeoutMs <= 0)) return { ok: false, reason: SOURCE_CONFIGURATION_MALFORMED };
  let result;
  try {
    result = spawnSync(source.command[0], source.command.slice(1), { cwd: fmHome, encoding: 'utf8', timeout: source.timeoutMs || 30000, env: process.env });
  } catch {
    return { ok: false, reason: SOURCE_UNREADABLE };
  }
  if (result.status !== 0 || result.error) return { ok: false, reason: SOURCE_UNREADABLE };
  const body = parseJson(result.stdout, 'source');
  if (!body || typeof body !== 'object') return { ok: false, reason: SOURCE_MALFORMED };
  return { ok: true, body };
}
function runSources(definitions) {
  if (definitions === undefined) return { sources: [], reason: SOURCE_CONFIGURATION_ABSENT };
  if (!Array.isArray(definitions)) return { sources: [], reason: SOURCE_CONFIGURATION_MALFORMED };
  const commands = new Set();
  const sources = definitions.flatMap((source) => {
    const identity = Array.isArray(source?.command) ? JSON.stringify(source.command) : null;
    if (identity && commands.has(identity)) return [];
    if (identity) commands.add(identity);
    return [runSource(source)];
  });
  return { sources, reason: sources.length ? null : SOURCE_CONFIGURATION_ABSENT };
}
function sourcesAtPublication(sources, maxAgeSeconds, publicationTime) {
  return sources.map((source) => {
    if (!source.ok || isoFresh(source.body.observedAt, maxAgeSeconds, publicationTime)) return source;
    return { ok: false, reason: Number.isFinite(Date.parse(source.body.observedAt || '')) ? 'stale source refused' : SOURCE_MALFORMED };
  });
}
function sourceMetric(source, metric) {
  const value = source.body.metrics?.[metric];
  if (!value || !['measured', 'estimated'].includes(value.status) || !Number.isFinite(value.amount) || typeof value.unit !== 'string') return null;
  return value;
}
function corroboratedMetric(name, unit, sources, missingReason) {
  const failed = sources.find((source) => !source.ok);
  if (failed || sources.length < 2) return unavailable(name, unit, failed?.reason || missingReason || INDEPENDENT_SOURCE_COUNT_INSUFFICIENT);
  const values = sources.map((source) => sourceMetric(source, name));
  if (values.some((value) => !value)) return unavailable(name, unit, SOURCE_METRIC_MISSING);
  const [first, ...rest] = values;
  const currency = sources[0].body.currency;
  if (typeof currency !== 'string' || rest.some((value, index) => value.amount !== first.amount || value.unit !== first.unit || sources[index + 1].body.currency !== currency)) {
    return { ...unavailable(name, unit, 'fresh'), cross_check: 'failed' };
  }
  const estimated = values.some((value) => value.status === 'estimated');
  return {
    name, amount: first.amount, unit: first.unit, currency: first.unit === currency ? currency : null,
    status: estimated ? 'estimated' : 'independently_cross_checked', source_freshness: 'fresh', cross_check: 'passed',
  };
}
function collectFinancialLane(id, config) {
  const configured = runSources(config?.sources);
  return { id, sources: configured.sources, sourceFailure: configured.reason };
}
function financialLane(input, maxAgeSeconds, publicationTime) {
  const { id, sourceFailure } = input;
  const spec = laneSpecs[id];
  const sources = sourcesAtPublication(input.sources, maxAgeSeconds, publicationTime);
  const metrics = spec.metrics.map(([name, unit]) => corroboratedMetric(name, unit, sources, sourceFailure));
  const sourceFreshness = metrics.find((metric) => metric.source_freshness !== 'fresh')?.source_freshness || 'fresh';
  return { id, label: spec.label, source_freshness: sourceFreshness, metrics };
}
function findProvider(value, wanted) {
  if (Array.isArray(value)) return value.map((item) => findProvider(item, wanted)).find(Boolean);
  if (!value || typeof value !== 'object') return null;
  const name = String(value.provider || value.name || value.id || '').toLowerCase();
  if (wanted.some((needle) => name.includes(needle)) && Array.isArray(value.windows)) return value;
  for (const [key, item] of Object.entries(value)) {
    if (wanted.some((needle) => key.toLowerCase().includes(needle)) && item && typeof item === 'object' && Array.isArray(item.windows)) return item;
    const found = findProvider(item, wanted); if (found) return found;
  }
  return null;
}
function quotaProviderWindows(provider, generatedAt, maxAgeSeconds, publicationTime, dateIsToday) {
  if (!dateIsToday) return { ok: false, reason: BACKFILLED_WINDOW_REFUSED };
  if (!provider || !generatedAt) return { ok: false, reason: 'source unavailable' };
  if (!isoFresh(generatedAt, maxAgeSeconds, publicationTime)) return { ok: false, reason: 'stale source refused' };
  const state = provider.state;
  if (!state || state.status !== 'fresh' || state.stale === true) {
    return { ok: false, reason: state?.status === 'stale' || state?.stale === true ? 'stale source refused' : 'source unavailable' };
  }
  if (typeof state.refreshedAt !== 'string' || !state.refreshedAt) return { ok: false, reason: 'source unavailable' };
  if (!isoFresh(state.refreshedAt, maxAgeSeconds, publicationTime)) return { ok: false, reason: 'stale source refused' };
  const windows = Array.isArray(provider.windows) ? provider.windows.filter((window) => Number.isFinite(window?.percentRemaining) && window.percentRemaining >= 0 && window.percentRemaining <= 100) : [];
  if (!windows.length) return { ok: false, reason: 'source unavailable' };
  return { ok: true, windows };
}
function quotaMetric(name, provider, generatedAt, maxAgeSeconds, publicationTime, dateIsToday) {
  const gated = quotaProviderWindows(provider, generatedAt, maxAgeSeconds, publicationTime, dateIsToday);
  if (!gated.ok) return unavailable(name, 'percent', gated.reason);
  const amount = Math.min(...gated.windows.map((window) => window.percentRemaining));
  return { name, amount, unit: 'percent', currency: null, status: 'measured', source_freshness: 'fresh', cross_check: 'not-required' };
}
function quotaWindows(body, maxAgeSeconds, publicationTime, dateIsToday) {
  if (!dateIsToday) return [{ provider: 'quota-axi', status: 'unavailable', source_freshness: BACKFILLED_WINDOW_REFUSED, windows: [] }];
  if (!Array.isArray(body?.providers) || !body.providers.length) return [{ provider: 'quota-axi', status: 'unavailable', source_freshness: 'source unavailable', windows: [] }];
  return body.providers.map((provider) => {
    const providerName = typeof provider?.provider === 'string' && provider.provider ? provider.provider : 'unknown provider';
    const gated = quotaProviderWindows(provider, body.generatedAt, maxAgeSeconds, publicationTime, dateIsToday);
    if (!gated.ok) return { provider: providerName, status: 'unavailable', source_freshness: gated.reason, windows: [] };
    return {
      provider: providerName,
      status: 'reported_window',
      source_freshness: 'fresh',
      caveat: 'quota-axi provider-reported, windowed quota measurement; not an exact monetary cost',
      windows: gated.windows.map((window) => ({
        id: typeof window.id === 'string' ? window.id : 'unknown',
        label: typeof window.label === 'string' ? window.label : 'unknown',
        kind: typeof window.kind === 'string' ? window.kind : 'unknown',
        percent_remaining: window.percentRemaining,
        percent_used: Number.isFinite(window.percentUsed) ? window.percentUsed : null,
        resets_at: typeof window.resetsAt === 'string' ? window.resetsAt : null,
      })),
    };
  });
}
function dailyMetric(row, name, unit) {
  const value = row?.[name];
  if (!value || !['measured', 'estimated'].includes(value.status) || !Number.isFinite(value.amount) || value.unit !== unit) return null;
  return value;
}
function dailyCrewSource(source, date) {
  if (!source.ok) return { ok: false, reason: source.reason || SOURCE_UNREADABLE };
  if (typeof source.body.source !== 'string' || !source.body.source || !isCalendarDate(source.body.date) || typeof source.body.currency !== 'string' || !Array.isArray(source.body.crewSessions)) return { ok: false, reason: SOURCE_MALFORMED };
  if (source.body.date !== date) return { ok: false, reason: LEDGER_DATE_NOT_COVERED };
  const rows = new Map();
  for (const row of source.body.crewSessions) {
    if (typeof row?.crew !== 'string' || !row.crew || rows.has(row.crew)) return { ok: false, reason: SOURCE_MALFORMED };
    const sessionCost = dailyMetric(row, 'sessionCost', 'USD');
    const validationRuns = dailyMetric(row, 'validationRuns', 'runs');
    if (!sessionCost || !validationRuns) return { ok: false, reason: SOURCE_METRIC_MISSING };
    rows.set(row.crew, { sessionCost, validationRuns });
  }
  return { ok: true, source: source.body.source, currency: source.body.currency, rows };
}
function unavailableDaily(reason = 'source unavailable') {
  return {
    crew_sessions: [],
    session_cost: unavailable('daily_attributable_crew_session_cost', 'USD', reason),
    validation_run_volume: unavailable('validation_run_volume', 'runs', reason),
    sources: [],
    source_freshness: reason,
  };
}
function dailyFleetLine(sources, date, missingReason) {
  const parsed = sources.map((source) => dailyCrewSource(source, date));
  const failed = parsed.find((source) => !source.ok);
  if (failed || sources.length < 2) return unavailableDaily(failed?.reason || missingReason || INDEPENDENT_SOURCE_COUNT_INSUFFICIENT);
  const currency = parsed[0].currency;
  if (parsed.some((source) => source.currency !== currency)) return unavailableDaily(SOURCE_DISAGREEMENT_REFUSED);
  if (currency !== 'USD') return unavailableDaily('unsupported currency refused');
  const roster = [...parsed[0].rows.keys()].sort();
  if (parsed.some((source) => source.rows.size !== roster.length || roster.some((crew) => !source.rows.has(crew)))) return unavailableDaily(SOURCE_DISAGREEMENT_REFUSED);
  const crewSessions = [];
  for (const crew of roster) {
    const rows = parsed.map((source) => source.rows.get(crew));
    const sessionCost = rows.map((row) => row.sessionCost);
    const validationRuns = rows.map((row) => row.validationRuns);
    const sameCost = sessionCost.every((value) => value.amount === sessionCost[0].amount);
    const sameRuns = validationRuns.every((value) => value.amount === validationRuns[0].amount);
    if (!sameCost || !sameRuns) return unavailableDaily(SOURCE_DISAGREEMENT_REFUSED);
    crewSessions.push({
      crew,
      session_cost: { ...sessionCost[0], status: sessionCost.some((value) => value.status === 'estimated') ? 'estimated' : 'independently_cross_checked', cross_check: 'passed' },
      validation_runs: { ...validationRuns[0], status: validationRuns.some((value) => value.status === 'estimated') ? 'estimated' : 'independently_cross_checked', cross_check: 'passed' },
    });
  }
  const costEstimated = crewSessions.some((crew) => crew.session_cost.status === 'estimated');
  const runsEstimated = crewSessions.some((crew) => crew.validation_runs.status === 'estimated');
  return {
    crew_sessions: crewSessions,
    session_cost: { name: 'daily_attributable_crew_session_cost', amount: crewSessions.reduce((total, crew) => total + crew.session_cost.amount, 0), unit: 'USD', currency, status: costEstimated ? 'estimated' : 'independently_cross_checked', source_freshness: 'fresh', cross_check: 'passed' },
    validation_run_volume: { name: 'validation_run_volume', amount: crewSessions.reduce((total, crew) => total + crew.validation_runs.amount, 0), unit: 'runs', currency: null, status: runsEstimated ? 'estimated' : 'independently_cross_checked', source_freshness: 'fresh', cross_check: 'passed' },
    sources: parsed.map((source) => source.source),
    source_freshness: 'fresh',
  };
}
function collectFleetLane(config) {
  const quota = spawnSync(process.env.FM_UNIT_ECONOMICS_QUOTA_AXI || 'quota-axi', ['--json'], { cwd: fmHome, encoding: 'utf8', timeout: 30000, env: process.env });
  const body = quota.status === 0 ? parseJson(quota.stdout, 'quota') : null;
  const costSources = runSources(config?.cost_sources);
  const dailySources = runSources(config?.daily_sources);
  return {
    id: 'fleet_operations',
    body,
    costSources: costSources.sources,
    costSourceFailure: costSources.reason,
    dailySources: dailySources.sources,
    dailySourceFailure: dailySources.reason,
  };
}
function fleetLane(input, maxAgeSeconds, publicationTime, date, dateIsToday) {
  const { body } = input;
  const generatedAt = body?.generatedAt;
  const claude = findProvider(body?.providers, ['claude', 'anthropic']);
  const codex = findProvider(body?.providers, ['codex', 'openai']);
  const costSources = sourcesAtPublication(input.costSources, maxAgeSeconds, publicationTime);
  const dailySources = sourcesAtPublication(input.dailySources, maxAgeSeconds, publicationTime);
  const quotaMetrics = [
    quotaMetric('claude_quota_window', claude, generatedAt, maxAgeSeconds, publicationTime, dateIsToday),
    quotaMetric('codex_quota_window', codex, generatedAt, maxAgeSeconds, publicationTime, dateIsToday),
  ];
  const metrics = [
    ...quotaMetrics,
    corroboratedMetric('attributable_crew_session_cost', 'USD', costSources, input.costSourceFailure),
  ];
  const sourceFreshness = quotaMetrics.find((metric) => metric.source_freshness === BACKFILLED_WINDOW_REFUSED)?.source_freshness
    || quotaMetrics.find((metric) => metric.source_freshness === 'stale source refused')?.source_freshness
    || quotaMetrics.find((metric) => metric.source_freshness === 'source unavailable')?.source_freshness
    || 'fresh';
  return { id: 'fleet_operations', label: laneSpecs.fleet_operations.label, source_freshness: sourceFreshness, metrics, daily_fleet_line: { date, quota_windows: quotaWindows(body, maxAgeSeconds, publicationTime, dateIsToday), ...dailyFleetLine(dailySources, date, input.dailySourceFailure) } };
}
function markdown(artifact) {
  const fleet = artifact.lanes.find((lane) => lane.id === 'fleet_operations');
  const daily = fleet.daily_fleet_line;
  const quotas = daily.quota_windows.map((provider) => provider.status === 'reported_window' ? `${provider.provider}: ${provider.windows.map((window) => `${window.id} ${window.percent_remaining}% remaining`).join(', ')}` : `${provider.provider}: unavailable (${provider.source_freshness})`).join('; ');
  const crews = daily.session_cost.status === 'unavailable'
    ? `unavailable (${daily.session_cost.source_freshness})`
    : daily.crew_sessions.length
      ? daily.crew_sessions.map((crew) => `${crew.crew}: ${crew.session_cost.amount} USD (${crew.session_cost.status})`).join('; ')
      : `${daily.session_cost.amount} ${daily.session_cost.unit} (${daily.session_cost.status}); no crews reported`;
  const runs = daily.validation_run_volume.amount === null ? `unavailable (${daily.validation_run_volume.source_freshness})` : `${daily.validation_run_volume.amount} runs (${daily.validation_run_volume.status})`;
  const dailySources = daily.sources.length ? daily.sources.join(', ') : 'unavailable';
  const lines = [`# Fleet unit-economics ledger`, '', `Generated: ${artifact.generated_at}`, '', '## Daily fleet line', '', '| Date | Quota windows | Per-crew session cost | Validation-run volume | Evidence |', '| --- | --- | --- | --- | --- |', `| ${daily.date} | ${quotas} | ${crews} | ${runs} | quota-axi --json; daily sources: ${dailySources}. Quota windows are provider-reported and windowed, not exact monetary costs; source failures remain unavailable. |`, '', '| Lane | Metric | Value | Unit | Status | Freshness | Cross-check |', '| --- | --- | ---: | --- | --- | --- | --- |'];
  for (const lane of artifact.lanes) for (const metric of lane.metrics) lines.push(`| ${lane.label} | ${metric.name} | ${metric.amount === null ? 'unavailable' : metric.amount} | ${metric.unit} | ${metric.status} | ${metric.source_freshness} | ${metric.cross_check} |`);
  return `${lines.join('\n')}\n`;
}
function writePrivateFile(path, contents) {
  const file = openSync(path, 'w', 0o600);
  try {
    fchmodSync(file, 0o600);
    writeFileSync(file, contents);
  } finally {
    closeSync(file);
  }
}
const options = args();
let config = {};
try { config = parseJson(readFileSync(options.config, 'utf8'), 'config') || {}; } catch { config = {}; }
const maxAgeSeconds = Number.isFinite(config.maxAgeSeconds) && config.maxAgeSeconds >= 0 ? config.maxAgeSeconds : 900;
const inputs = Object.keys(laneSpecs).map((id) => (
  id === 'fleet_operations' ? collectFleetLane(config.lanes?.[id]) : collectFinancialLane(id, config.lanes?.[id])
));
const publicationTime = new Date();
const ledgerDateIsToday = ledgerDate === publicationTime.toISOString().slice(0, 10);
const artifact = {
  schema: 'fleet-unit-economics-ledger.v2',
  generated_at: publicationTime.toISOString(),
  max_age_seconds: maxAgeSeconds,
  lanes: inputs.map((input) => (
    input.id === 'fleet_operations'
      ? fleetLane(input, maxAgeSeconds, publicationTime.getTime(), ledgerDate, ledgerDateIsToday)
      : financialLane(input, maxAgeSeconds, publicationTime.getTime())
  )),
};
mkdirSync(dirname(options.output), { recursive: true });
writePrivateFile(options.output, `${JSON.stringify(artifact, null, 2)}\n`);
const rendered = markdown(artifact);
const markdownOutput = options.output.endsWith('.json') ? `${options.output.slice(0, -5)}.md` : `${options.output}.md`;
writePrivateFile(markdownOutput, rendered);
process.stdout.write(options.format === 'json' ? `${JSON.stringify(artifact, null, 2)}\n` : rendered);
