import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync } from 'node:fs';
import { join, posix } from 'node:path';

export const REPOSITORY = 'joshcazalas/website';
export const WORKFLOW = `${REPOSITORY}/.github/workflows/release.yml`;
export const ARTIFACTS = ['SHA256SUMS', 'asset-inventory.json', 'manifest.json', 'sbom-build.cdx.json', 'sbom-runtime.cdx.json', 'site-inventory.json', 'website.tar.gz'] as const;
export const BUNDLES = ['provenance.sigstore.json', 'sbom.sigstore.json'] as const;
export const MAX_ARCHIVE = 64 * 1024 * 1024;
export const MAX_SITE = 128 * 1024 * 1024;
export type FileDigest = { sha256: string; size: number };
export type Inventory = Record<string, FileDigest>;
export type Manifest = {
  schema: 2; repository: typeof REPOSITORY; tag: string; commit: string; source_ref: string;
  source_date: string; asset_base: string; files: Inventory;
};
export class InvalidRelease extends Error {}
export function requireValue(condition: unknown, message: string): asserts condition {
  if (!condition) throw new InvalidRelease(message);
}
export function record(value: unknown): asserts value is Record<string, unknown> {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value), 'Expected an object');
}
export const hash = (data: Uint8Array | string): string => createHash('sha256').update(data).digest('hex');
export const isCommit = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
export const isTag = (value: unknown): value is string => typeof value === 'string' && /^website-\d{4}\.\d{2}\.\d{2}-g[a-f0-9]{12}$/.test(value);
export const safePath = (name: string): boolean => /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(name) && posix.normalize(name) === name && !name.split('/').some(part => part === '..' || part === '.');
export const sameKeys = (left: string[], right: readonly string[]): boolean => JSON.stringify([...left].sort()) === JSON.stringify([...right].sort());
export function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, 'utf8')) as unknown;
}
export function fileDigest(path: string, max = MAX_ARCHIVE): FileDigest {
  const info = lstatSync(path);
  requireValue(info.isFile() && info.size <= max, `Expected a bounded regular file: ${path}`);
  return { size: info.size, sha256: hash(readFileSync(path)) };
}
export function parseInventory(value: unknown): Inventory {
  record(value);
  requireValue(Object.keys(value).length > 0 && Object.keys(value).length <= 512, 'Invalid inventory size');
  let total = 0;
  for (const [name, info] of Object.entries(value)) {
    requireValue(safePath(name), `Unsafe inventory path: ${name}`);
    record(info);
    requireValue(typeof info.sha256 === 'string' && /^[a-f0-9]{64}$/.test(info.sha256), `Invalid checksum: ${name}`);
    requireValue(typeof info.size === 'number' && Number.isSafeInteger(info.size) && info.size >= 0 && info.size <= MAX_ARCHIVE, `Invalid size: ${name}`);
    total += info.size;
  }
  requireValue(total <= MAX_SITE, 'Inventory exceeds deployment size limit');
  return value as Inventory;
}
export function parseManifest(value: unknown): Manifest {
  record(value);
  requireValue(value.schema === 2 && value.repository === REPOSITORY, 'Unsupported release format or repository');
  requireValue(isCommit(value.commit) && isTag(value.tag) && value.tag.endsWith(`-g${value.commit.slice(0, 12)}`), 'Release tag and commit differ');
  requireValue(typeof value.source_ref === 'string' && typeof value.source_date === 'string' && Number.isFinite(Date.parse(value.source_date)), 'Missing source identity');
  requireValue(value.asset_base === `/releases/${value.commit}/`, 'Asset namespace differs from release identity');
  const files = parseInventory(value.files);
  requireValue(sameKeys(Object.keys(files), ARTIFACTS.filter(name => name !== 'manifest.json' && name !== 'SHA256SUMS')), 'Incomplete release manifest');
  return value as Manifest;
}
export function verifyDigest(path: string, expected: FileDigest): void {
  const actual = fileDigest(path);
  requireValue(actual.size === expected.size && actual.sha256 === expected.sha256, `Checksum mismatch: ${path}`);
}
export function verifyBundle(directory: string, signed: boolean): { manifest: Manifest; files: Inventory } {
  requireValue(sameKeys(readdirSync(directory), signed ? [...ARTIFACTS, ...BUNDLES] : ARTIFACTS), 'Unexpected or missing release files');
  for (const name of readdirSync(directory)) fileDigest(join(directory, name));
  const manifest = parseManifest(readJson(join(directory, 'manifest.json')));
  for (const [name, expected] of Object.entries(manifest.files)) verifyDigest(join(directory, name), expected);
  const lines = readFileSync(join(directory, 'SHA256SUMS'), 'utf8').trimEnd().split('\n');
  const sums = new Map<string, string>();
  for (const line of lines) {
    const match = /^([a-f0-9]{64})  ([A-Za-z0-9.-]+)$/.exec(line);
    requireValue(match && !sums.has(match[2]), 'Invalid or duplicate checksum entry');
    sums.set(match[2], match[1]);
  }
  requireValue(sameKeys([...sums.keys()], ARTIFACTS.filter(name => name !== 'SHA256SUMS')), 'Incomplete checksum list');
  for (const [name, expected] of sums) requireValue(fileDigest(join(directory, name)).sha256 === expected, `Checksum mismatch: ${name}`);
  const files = parseInventory(readJson(join(directory, 'site-inventory.json')));
  requireValue('index.html' in files && 'release.json' in files && Object.keys(files).some(name => /^assets\/[^/]+\.js$/.test(name)), 'Incomplete static site');
  for (const name of Object.keys(files)) requireValue(name === 'index.html' || name === 'release.json' || /^assets\/[^/]+\.(js|css)$/.test(name) || name === 'branding/josh-cazalas.png' || name.startsWith('factorio/'), `Unexpected site file: ${name}`);
  const assets = readJson(join(directory, 'asset-inventory.json'));
  record(assets);
  const media = parseInventory(assets.files);
  requireValue(sameKeys(Object.keys(files).filter(name => name.startsWith('factorio/')), Object.keys(media).map(name => `factorio/${name}`)), 'Unexpected game assets');
  for (const [name, info] of Object.entries(media)) requireValue(files[`factorio/${name}`].sha256 === info.sha256 && files[`factorio/${name}`].size === info.size, `Asset inventory mismatch: ${name}`);
  for (const scope of ['runtime', 'build']) {
    const sbom = readJson(join(directory, `sbom-${scope}.cdx.json`));
    record(sbom); requireValue(sbom.bomFormat === 'CycloneDX', 'Unsupported SBOM format');
  }
  return { manifest, files };
}
