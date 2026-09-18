import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import type { TestContext } from 'node:test';
import * as tar from 'tar';
import { ARTIFACTS, BUNDLES, fileDigest, type Inventory, type Manifest } from '../src/format.ts';
import type { Config } from '../src/deployment.ts';

export function workspace(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'website-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const config: Config = { mode: 'preview', stateDirectory: join(root, 'state'), healthUrl: 'http://127.0.0.1:8088/', retain: 3, minimumAgeDays: 30 };
  return { root, config };
}
export function bundle(root: string, digit: string, signed = false) {
  const commit = digit.repeat(40), tag = `website-2026.09.18-g${commit.slice(0, 12)}`;
  const directory = join(root, digit), site = join(root, `site-${digit}`);
  mkdirSync(directory); mkdirSync(site);
  const assetBase = `/releases/${commit}/`;
  const content = {
    'index.html': `<script type="module" src="${assetBase}assets/app.js"></script>`,
    'release.json': JSON.stringify({ schema: 1, commit, assetBase }),
    'assets/app.js': `console.log('${digit}');`,
    'factorio/sprite.png': `sprite-${digit}`,
    'factorio/sound/note.ogg': `sound-${digit}`,
  };
  for (const [name, data] of Object.entries(content)) { mkdirSync(dirname(join(site, name)), { recursive: true }); writeFileSync(join(site, name), data); }
  const files: Inventory = Object.fromEntries(Object.keys(content).map(name => [name, fileDigest(join(site, name))]));
  tar.create({ file: join(directory, 'website.tar.gz'), cwd: site, sync: true, gzip: true, portable: true, mtime: new Date(0), noPax: true }, Object.keys(files));
  const json = (name: string, value: unknown) => writeFileSync(join(directory, name), JSON.stringify(value) + '\n');
  json('site-inventory.json', files);
  json('asset-inventory.json', { files: Object.fromEntries(Object.entries(files).filter(([name]) => name.startsWith('factorio/')).map(([name, info]) => [name.slice(9), info])) });
  for (const scope of ['runtime', 'build']) json(`sbom-${scope}.cdx.json`, { bomFormat: 'CycloneDX', specVersion: '1.6' });
  const manifest: Manifest = { schema: 2, repository: 'joshcazalas/website', commit, tag, source_ref: 'refs/heads/main', source_date: '2026-09-18T00:00:00Z', asset_base: assetBase,
    files: Object.fromEntries(ARTIFACTS.filter(name => name !== 'manifest.json' && name !== 'SHA256SUMS').map(name => [name, fileDigest(join(directory, name))])) };
  json('manifest.json', manifest);
  writeFileSync(join(directory, 'SHA256SUMS'), ARTIFACTS.filter(name => name !== 'SHA256SUMS').map(name => `${fileDigest(join(directory, name)).sha256}  ${name}\n`).join(''));
  if (signed) for (const name of BUNDLES) json(name, { test: true });
  return { directory, commit, tag, manifest, files, site };
}
