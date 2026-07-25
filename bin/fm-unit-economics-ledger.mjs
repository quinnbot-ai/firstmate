#!/usr/bin/env node
// Render the private, read-only unit-economics ledger.
// Usage: fm-unit-economics-ledger.mjs [--config <path>] [--output <path>] [--format json|markdown]
//
// The private config defaults to $FM_HOME/config/unit-economics-ledger.json and
// contains optional lane definitions for weho, content_accounts, trading, and
// kdp. A lane's `sources` are trusted private command arrays. Each command is
// run fresh and must print one JSON object:
//   {"observedAt":"<ISO-8601>","currency":"USD","metrics":{
//     "metric_name":{"amount":12.3,"unit":"USD","status":"measured"}}}
// Financial facts are published only when two fresh sources agree exactly on
// amount and unit. A source can mark a value `estimated`; it remains estimated
// even when corroborated. Missing, stale, malformed, or disagreeing inputs are
// rendered unavailable, never as zero. The fixed fleet_operations lane reads
// quota-axi --json fresh at invocation time; quota windows are measurements,
// not financial facts, and attributable crew/session cost stays unavailable
// unless `fleet_operations.cost_sources` supplies two corroborating private
// helpers. The command writes a durable
// JSON artifact and prints JSON or a captain-readable Markdown rendering.

import { closeSync, fchmodSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const fmHome = process.env.FM_HOME || process.cwd();
const defaults = {
  config: resolve(fmHome, 'config/unit-economics-ledger.json'),
  output: resolve(fmHome, 'data/unit-economics-ledger/latest.json'),
  format: 'markdown',
};
const laneSpecs = {
  weho: { label: 'WeHo', metrics: [['pipeline_cost', 'USD'], ['realized_revenue', 'USD']] },
  content_accounts: { label: 'Content accounts', metrics: [['cost_per_post', 'USD'], ['posts_per_day', 'posts/day'], ['adsense_revenue', 'USD'], ['performance_bonus_revenue', 'USD']] },
  trading: { label: 'Trading', metrics: [['deployed_stake', 'USD'], ['realized_pnl', 'USD'], ['unrealized_pnl', 'USD']] },
  kdp: { label: 'KDP', metrics: [['royalties', 'USD'], ['attributable_costs', 'USD']] },
  fleet_operations: { label: 'Fleet operations', metrics: [['claude_quota_window', 'percent'], ['codex_quota_window', 'percent'], ['attributable_crew_session_cost', 'USD']] },
};

function fail(message) { process.stderr.write(`error: ${message}\n`); process.exit(2); }
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
  if (!source || !Array.isArray(source.command) || source.command.length === 0 || source.command.some((item) => typeof item !== 'string')) return { ok: false, reason: 'source unavailable' };
  const result = spawnSync(source.command[0], source.command.slice(1), { encoding: 'utf8', timeout: source.timeoutMs || 30000, env: process.env });
  if (result.status !== 0 || result.error) return { ok: false, reason: 'source unavailable' };
  const body = parseJson(result.stdout, 'source');
  if (!body || typeof body !== 'object' || !body.metrics) return { ok: false, reason: 'source unavailable' };
  return { ok: true, body };
}
function runSources(definitions) {
  if (!Array.isArray(definitions)) return [];
  const commands = new Set();
  return definitions.flatMap((source) => {
    const identity = Array.isArray(source?.command) ? JSON.stringify(source.command) : null;
    if (identity && commands.has(identity)) return [];
    if (identity) commands.add(identity);
    return [runSource(source)];
  });
}
function sourcesAtPublication(sources, maxAgeSeconds, publicationTime) {
  return sources.map((source) => {
    if (!source.ok || isoFresh(source.body.observedAt, maxAgeSeconds, publicationTime)) return source;
    return { ok: false, reason: source.body.observedAt ? 'stale source refused' : 'source unavailable' };
  });
}
function sourceMetric(source, metric) {
  const value = source.body.metrics?.[metric];
  if (!value || !['measured', 'estimated'].includes(value.status) || !Number.isFinite(value.amount) || typeof value.unit !== 'string') return null;
  return value;
}
function corroboratedMetric(name, unit, sources) {
  const failed = sources.find((source) => !source.ok);
  if (failed || sources.length < 2) return unavailable(name, unit, failed?.reason || 'source unavailable');
  const values = sources.map((source) => sourceMetric(source, name));
  if (values.some((value) => !value)) return unavailable(name, unit);
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
  return { id, sources: runSources(config?.sources) };
}
function financialLane(input, maxAgeSeconds, publicationTime) {
  const { id } = input;
  const spec = laneSpecs[id];
  const sources = sourcesAtPublication(input.sources, maxAgeSeconds, publicationTime);
  const metrics = spec.metrics.map(([name, unit]) => corroboratedMetric(name, unit, sources));
  const sourceFreshness = metrics.find((metric) => metric.source_freshness === 'stale source refused')?.source_freshness
    || metrics.find((metric) => metric.source_freshness === 'source unavailable')?.source_freshness
    || 'fresh';
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
function quotaMetric(name, provider, generatedAt, maxAgeSeconds, publicationTime) {
  if (!provider || !generatedAt) return unavailable(name, 'percent');
  if (!isoFresh(generatedAt, maxAgeSeconds, publicationTime)) return unavailable(name, 'percent', 'stale source refused');
  const state = provider.state;
  if (!state || state.status !== 'fresh' || state.stale === true) {
    return unavailable(name, 'percent', state?.status === 'stale' || state?.stale === true ? 'stale source refused' : 'source unavailable');
  }
  if (state.refreshedAt && !isoFresh(state.refreshedAt, maxAgeSeconds, publicationTime)) return unavailable(name, 'percent', 'stale source refused');
  const windows = provider.windows.filter((window) => Number.isFinite(window?.percentRemaining) && window.percentRemaining >= 0 && window.percentRemaining <= 100);
  if (!windows.length) return unavailable(name, 'percent');
  const amount = Math.min(...windows.map((window) => window.percentRemaining));
  return { name, amount, unit: 'percent', currency: null, status: 'measured', source_freshness: 'fresh', cross_check: 'not-required' };
}
function collectFleetLane(config) {
  const quota = spawnSync(process.env.FM_UNIT_ECONOMICS_QUOTA_AXI || 'quota-axi', ['--json'], { encoding: 'utf8', timeout: 30000, env: process.env });
  const body = quota.status === 0 ? parseJson(quota.stdout, 'quota') : null;
  return { id: 'fleet_operations', body, costSources: runSources(config?.cost_sources) };
}
function fleetLane(input, maxAgeSeconds, publicationTime) {
  const { body } = input;
  const generatedAt = body?.generatedAt;
  const claude = findProvider(body?.providers, ['claude', 'anthropic']);
  const codex = findProvider(body?.providers, ['codex', 'openai']);
  const costSources = sourcesAtPublication(input.costSources, maxAgeSeconds, publicationTime);
  const quotaMetrics = [
    quotaMetric('claude_quota_window', claude, generatedAt, maxAgeSeconds, publicationTime),
    quotaMetric('codex_quota_window', codex, generatedAt, maxAgeSeconds, publicationTime),
  ];
  const metrics = [
    ...quotaMetrics,
    corroboratedMetric('attributable_crew_session_cost', 'USD', costSources),
  ];
  const sourceFreshness = quotaMetrics.find((metric) => metric.source_freshness === 'stale source refused')?.source_freshness
    || quotaMetrics.find((metric) => metric.source_freshness === 'source unavailable')?.source_freshness
    || 'fresh';
  return { id: 'fleet_operations', label: laneSpecs.fleet_operations.label, source_freshness: sourceFreshness, metrics };
}
function markdown(artifact) {
  const lines = [`# Fleet unit-economics ledger`, '', `Generated: ${artifact.generated_at}`, '', '| Lane | Metric | Value | Unit | Status | Freshness | Cross-check |', '| --- | --- | ---: | --- | --- | --- | --- |'];
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
const artifact = {
  schema: 'fleet-unit-economics-ledger.v1',
  generated_at: publicationTime.toISOString(),
  max_age_seconds: maxAgeSeconds,
  lanes: inputs.map((input) => (
    input.id === 'fleet_operations'
      ? fleetLane(input, maxAgeSeconds, publicationTime.getTime())
      : financialLane(input, maxAgeSeconds, publicationTime.getTime())
  )),
};
mkdirSync(dirname(options.output), { recursive: true });
writePrivateFile(options.output, `${JSON.stringify(artifact, null, 2)}\n`);
const rendered = markdown(artifact);
const markdownOutput = options.output.endsWith('.json') ? `${options.output.slice(0, -5)}.md` : `${options.output}.md`;
writePrivateFile(markdownOutput, rendered);
process.stdout.write(options.format === 'json' ? `${JSON.stringify(artifact, null, 2)}\n` : rendered);
