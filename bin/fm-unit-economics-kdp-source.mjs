#!/usr/bin/env node
// Emit one read-only KDP royalty observation for fm-unit-economics-ledger.mjs.
// Usage: fm-unit-economics-kdp-source.mjs <artifact|finance-reports> [--current <path>] [--finance-vault <path>]
//
// `artifact` reads the current KDP payment-telemetry artifact, while
// `finance-reports` independently reads the KDP rows from the monthly finance
// reports. Neither mode contacts an account, uses a credential, or writes a
// file. Both emit the ledger source schema with lifetime confirmed royalties.

import { readFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const defaults = {
  current: join(homedir(), '.openclaw', 'vault', 'finance', 'kdp-current.json'),
  financeVault: join(homedir(), '.openclaw', 'vault', 'finance'),
};

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function parseArgs() {
  const values = process.argv.slice(2);
  const mode = values.shift();
  const options = { ...defaults };
  while (values.length) {
    const value = values.shift();
    if (value === '--current' && values[0]) options.current = values.shift();
    else if (value === '--finance-vault' && values[0]) options.financeVault = values.shift();
    else fail('usage: fm-unit-economics-kdp-source.mjs <artifact|finance-reports> [--current <path>] [--finance-vault <path>]');
  }
  if (!['artifact', 'finance-reports'].includes(mode)) fail('source must be artifact or finance-reports');
  return { mode, options };
}

function json(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    fail('KDP source is unavailable');
  }
}

function amount(value) {
  if (!Number.isFinite(value) || value < 0) fail('KDP source is unavailable');
  return value;
}

function artifactObservation(path) {
  const body = json(path);
  const observedAt = body.ts;
  if (!Number.isFinite(Date.parse(observedAt)) || body.payment_summary?.status !== 'LIVE') fail('KDP source is unavailable');
  return { observedAt, royalties: amount(body.payment_summary.lifetime_confirmed_usd) };
}

function reportFiles(vault) {
  const folders = [join(vault, 'monthly'), vault];
  return folders.flatMap((folder) => {
    try {
      return readdirSync(folder)
        .filter((name) => (folder.endsWith('/monthly') ? name.endsWith('.md') : /^monthly-.*\.md$/.test(name)))
        .map((name) => join(folder, name));
    } catch {
      return [];
    }
  });
}

function reportAmount(path) {
  let revenue = false;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line === '### Revenue') revenue = true;
    else if (revenue && line.startsWith('### ')) return null;
    else if (revenue && line.startsWith('| KDP / Amazon |')) {
      if (/unconfirmed/i.test(line)) return null;
      const match = line.match(/\*\*\$([\d,]+(?:\.\d{2})?)\*\*/);
      return match ? Number(match[1].replaceAll(',', '')) : null;
    }
  }
  return null;
}

function financeReportObservation(vault) {
  const values = reportFiles(vault).map(reportAmount).filter((value) => Number.isFinite(value));
  if (!values.length) fail('KDP source is unavailable');
  return { observedAt: new Date().toISOString(), royalties: amount(values.reduce((sum, value) => sum + value, 0)) };
}

const { mode, options } = parseArgs();
const observation = mode === 'artifact'
  ? artifactObservation(options.current)
  : financeReportObservation(options.financeVault);
process.stdout.write(`${JSON.stringify({
  observedAt: observation.observedAt,
  currency: 'USD',
  metrics: {
    royalties: { amount: observation.royalties, unit: 'USD', status: 'measured' },
  },
})}\n`);
