#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { Deployment, parseConfig } from './deployment.ts';
import { readJson, requireValue } from './format.ts';

try {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    config: { type: 'string' }, locked: { type: 'boolean', default: false }, commit: { type: 'string' },
  }});
  requireValue(values.config, 'Usage: caz-website-updater --config FILE update|preview DIRECTORY --commit SHA|rollback|resume|retry TAG|status');
  const config = parseConfig(readJson(values.config));
  mkdirSync(config.stateDirectory, { recursive: true, mode: 0o750 });
  if (!values.locked) {
    // The kernel releases this lock even if Node or the system crashes.
    const result = spawnSync('flock', ['--exclusive', '--nonblock', '--conflict-exit-code', '75', join(config.stateDirectory, 'update.lock'),
      process.execPath, fileURLToPath(import.meta.url), '--locked', ...process.argv.slice(2)], { stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status === 75) console.error('Another website operation is already running');
    process.exit(result.status ?? 1);
  }
  const deployment = new Deployment(config);
  const [action, argument] = positionals;
  requireValue(positionals.length <= 2, 'Unexpected command arguments');
  switch (action) {
    case 'update': await deployment.update(); break;
    case 'preview': requireValue(argument && values.commit, 'Preview requires a bundle directory and --commit SHA'); await deployment.preview(resolve(argument), values.commit); break;
    case 'rollback': await deployment.rollback(); break;
    case 'resume': await deployment.recover(); deployment.resume(); break;
    case 'retry': requireValue(argument, 'Retry requires a quarantined release tag'); await deployment.recover(); deployment.retry(argument); break;
    case 'status': console.log(JSON.stringify(deployment.state, null, 2)); break;
    default: throw new Error('Expected update, preview, rollback, resume, retry, or status');
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  if (error instanceof Error && error.cause) console.error(error.cause);
  process.exitCode = 1;
}
