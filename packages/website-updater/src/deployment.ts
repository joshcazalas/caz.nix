import { chmodSync, closeSync, copyFileSync, existsSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readdirSync, readlinkSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { randomUUID } from 'node:crypto';
import { unpack, verifySite } from './archive.ts';
import { ARTIFACTS, fileDigest, hash, isCommit, isTag, parseInventory, parseManifest, readJson, record, requireValue, verifyBundle, type Inventory, type Manifest } from './format.ts';
import { discover, download, verifyAttestations, type Release } from './github.ts';

export type Config = { mode: 'preview' | 'release'; stateDirectory: string; healthUrl: string; pinnedTag?: string; retain: number; minimumAgeDays: number };
export type Generation = { commit: string; tag: string; releaseId: number | null; manifestHash: string; installedAt: number };
export type State = {
  schema: 1; mode: Config['mode']; current: Generation | null; previous: Generation | null;
  pending: { candidate: Generation; previous: Generation | null } | null;
  generations: Generation[]; quarantined: Record<string, string>; held: boolean;
};
export type HealthCheck = (manifest: Manifest, files: Inventory) => Promise<void>;
export type Dependencies = {
  discover: typeof discover; download: typeof download; verifyAttestations: typeof verifyAttestations;
  health: HealthCheck; now: () => number;
};
export function parseConfig(value: unknown): Config {
  record(value);
  requireValue(value.mode === 'preview' || value.mode === 'release', 'Invalid deployment mode');
  requireValue(typeof value.stateDirectory === 'string' && isAbsolute(value.stateDirectory) && value.stateDirectory !== '/', 'State directory must be absolute');
  requireValue(typeof value.healthUrl === 'string', 'Missing health URL');
  const url = new URL(value.healthUrl);
  requireValue(url.protocol === 'http:' && url.hostname === '127.0.0.1' && url.pathname === '/' && !url.username && !url.password && !url.search && !url.hash, 'Health URL must be the loopback HTTP listener');
  requireValue(value.pinnedTag === undefined || isTag(value.pinnedTag), 'Invalid pinned release');
  requireValue(typeof value.retain === 'number' && Number.isSafeInteger(value.retain) && value.retain >= 2 && value.retain <= 100, 'Retain at least two releases');
  requireValue(typeof value.minimumAgeDays === 'number' && Number.isSafeInteger(value.minimumAgeDays) && value.minimumAgeDays >= 1 && value.minimumAgeDays <= 365, 'Invalid retention grace period');
  return value as Config;
}
function generation(value: unknown): asserts value is Generation {
  record(value);
  requireValue(isCommit(value.commit) && isTag(value.tag) && value.tag.endsWith(`-g${value.commit.slice(0, 12)}`), 'Invalid stored generation');
  requireValue((value.releaseId === null || (Number.isSafeInteger(value.releaseId) && Number(value.releaseId) > 0)) && Number.isSafeInteger(value.installedAt), 'Invalid stored release metadata');
  requireValue(typeof value.manifestHash === 'string' && /^[a-f0-9]{64}$/.test(value.manifestHash), 'Invalid stored manifest checksum');
}
function parseState(value: unknown, mode: Config['mode']): State {
  record(value);
  requireValue(value.schema === 1 && value.mode === mode && typeof value.held === 'boolean', 'State cannot be shared between preview and signed releases');
  if (value.current !== null) generation(value.current);
  if (value.previous !== null) generation(value.previous);
  if (value.pending !== null) { record(value.pending); generation(value.pending.candidate); if (value.pending.previous !== null) generation(value.pending.previous); }
  requireValue(Array.isArray(value.generations), 'Missing stored generations'); value.generations.forEach(generation);
  record(value.quarantined);
  for (const [tag, reason] of Object.entries(value.quarantined)) requireValue(isTag(tag) && typeof reason === 'string', 'Invalid quarantine record');
  return value as State;
}
function syncDirectory(path: string): void {
  const fd = openSync(path, 'r'); try { fsyncSync(fd); } finally { closeSync(fd); }
}
function syncTree(path: string): void {
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) syncTree(child);
    else { const fd = openSync(child, 'r'); try { fsyncSync(fd); } finally { closeSync(fd); } }
  }
  syncDirectory(path);
}
function atomicJson(path: string, value: unknown): void {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const fd = openSync(temporary, 'wx', 0o640);
  try { writeFileSync(fd, JSON.stringify(value, null, 2) + '\n'); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temporary, path); syncDirectory(dirname(path));
}
export function httpHealth(base: string): HealthCheck {
  return async (manifest, files) => {
    let failure: unknown;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        for (const [name, info] of Object.entries(files)) {
          const path = name === 'index.html' ? '/' : name === 'release.json' ? '/release.json' : `${manifest.asset_base}${name}`;
          const response = await fetch(new URL(path, base), { redirect: 'error', signal: AbortSignal.timeout(10_000), headers: { 'Cache-Control': 'no-cache' } });
          requireValue(response.ok && response.body, `Health request failed: ${path} (${response.status})`);
          const chunks: Uint8Array[] = []; let size = 0;
          for await (const chunk of response.body) { size += chunk.length; requireValue(size <= info.size, `Unexpected HTTP body: ${path}`); chunks.push(chunk); }
          requireValue(size === info.size && hash(Buffer.concat(chunks)) === info.sha256, `HTTP content differs from release: ${path}`);
        }
        return;
      } catch (error) { failure = error; if (attempt < 3) await delay(1_000); }
    }
    throw failure;
  };
}
export class Deployment {
  readonly config: Config;
  readonly dependencies: Dependencies;
  state: State;
  constructor(config: Config, dependencies: Partial<Dependencies> = {}) {
    this.config = parseConfig(config);
    this.dependencies = { discover, download, verifyAttestations, health: httpHealth(config.healthUrl), now: Date.now, ...dependencies };
    for (const path of [config.stateDirectory, this.path('public'), this.path('public/releases'), this.path('metadata'), this.path('staging')]) mkdirSync(path, { recursive: true, mode: 0o750 });
    this.state = existsSync(this.path('state.json')) ? parseState(readJson(this.path('state.json')), config.mode)
      : { schema: 1, mode: config.mode, current: null, previous: null, pending: null, generations: [], quarantined: {}, held: false };
    this.save();
  }
  private path(...parts: string[]): string { return join(this.config.stateDirectory, ...parts); }
  private save(): void { atomicJson(this.path('state.json'), this.state); }
  private switchTo(target: Generation | null): void {
    const link = this.path('current');
    if (target === null) { rmSync(link, { force: true }); syncDirectory(this.config.stateDirectory); return; }
    generation(target);
    const temporary = this.path(`current.${randomUUID()}`);
    symlinkSync(`public/releases/${target.commit}`, temporary);
    renameSync(temporary, link); syncDirectory(this.config.stateDirectory);
  }
  private stored(target: Generation): { manifest: Manifest; files: Inventory } {
    generation(target);
    const directory = this.path('metadata', target.commit);
    requireValue(fileDigest(join(directory, 'manifest.json')).sha256 === target.manifestHash, 'Stored release metadata changed');
    const manifest = parseManifest(readJson(join(directory, 'manifest.json')));
    const files = parseInventory(readJson(join(directory, 'site-inventory.json')));
    requireValue(fileDigest(join(directory, 'site-inventory.json')).sha256 === manifest.files['site-inventory.json'].sha256, 'Stored site inventory changed');
    requireValue(manifest.commit === target.commit && manifest.tag === target.tag, 'Stored release identity changed');
    verifySite(this.path('public/releases', target.commit), files, manifest);
    return { manifest, files };
  }
  private discardUnaccepted(candidate: Generation): void {
    if (this.state.generations.some(item => item.commit === candidate.commit)) return;
    rmSync(this.path('public/releases', candidate.commit), { recursive: true, force: true });
    rmSync(this.path('metadata', candidate.commit), { recursive: true, force: true });
  }
  async recover(): Promise<void> {
    const pending = this.state.pending;
    if (pending) {
      if (pending.previous) this.stored(pending.previous);
      this.switchTo(pending.previous);
      this.state.current = pending.previous;
      this.state.quarantined[pending.candidate.tag] = 'Interrupted before health checks were accepted';
      this.state.pending = null; this.save();
      this.discardUnaccepted(pending.candidate);
      if (pending.previous) { const { manifest, files } = this.stored(pending.previous); await this.dependencies.health(manifest, files); }
    }
    const current = this.path('current');
    if (this.state.current) requireValue(lstatSync(current).isSymbolicLink() && readlinkSync(current) === `public/releases/${this.state.current.commit}`, 'Current symlink differs from accepted state');
    else requireValue(!existsSync(current), 'Untracked deployment at current');
  }
  private async activate(candidate: Generation, manifest: Manifest, files: Inventory): Promise<void> {
    const previous = this.state.current;
    this.state.pending = { candidate, previous }; this.save();
    try {
      this.switchTo(candidate);
      await this.dependencies.health(manifest, files);
    } catch (error) {
      this.switchTo(previous);
      this.state.pending = null;
      this.state.quarantined[candidate.tag] = error instanceof Error ? error.message : String(error);
      this.save();
      this.discardUnaccepted(candidate);
      if (previous) {
        const old = this.stored(previous);
        try { await this.dependencies.health(old.manifest, old.files); }
        catch (rollbackError) { throw new AggregateError([error, rollbackError], 'Deployment failed and the restored release failed its health check'); }
      }
      throw new Error(`Deployment rejected and previous release restored: ${candidate.tag}`, { cause: error });
    }
    this.state.current = candidate; this.state.previous = previous; this.state.pending = null;
    this.state.generations = [...this.state.generations.filter(item => item.commit !== candidate.commit), candidate];
    this.save(); this.prune();
    console.log(`Accepted ${this.config.mode} deployment: ${candidate.tag}`);
  }
  private async install(directory: string, expectedCommit: string, release?: Release): Promise<void> {
    const signed = this.config.mode === 'release';
    const { manifest, files } = verifyBundle(directory, signed);
    requireValue(manifest.commit === expectedCommit, 'Bundle differs from the requested commit');
    if (release) requireValue(manifest.tag === release.tag && manifest.commit === release.commit, 'Bundle differs from GitHub release identity');
    if (signed) await this.dependencies.verifyAttestations(directory, manifest);
    requireValue(!Object.hasOwn(this.state.quarantined, manifest.tag), 'Release is quarantined; inspect state before explicitly retrying');
    const candidate: Generation = { commit: manifest.commit, tag: manifest.tag, releaseId: release?.id ?? null, manifestHash: fileDigest(join(directory, 'manifest.json')).sha256, installedAt: this.dependencies.now() };
    const final = this.path('public/releases', candidate.commit);
    if (existsSync(final)) {
      requireValue(fileDigest(this.path('metadata', candidate.commit, 'manifest.json')).sha256 === candidate.manifestHash, 'A commit namespace cannot be overwritten');
      verifySite(final, files, manifest);
    } else {
      const staging = mkdtempSync(this.path('staging', 'site-'));
      try {
        const site = join(staging, 'site'); mkdirSync(site, { mode: 0o750 });
        unpack(join(directory, 'website.tar.gz'), files, site); verifySite(site, files, manifest);
        // Persist both trees before publishing their names. Metadata may be
        // orphaned by a crash before the site rename; with no site it is safe
        // to replace on retry, since no accepted pointer can reference it.
        const metadata = join(staging, 'metadata'); mkdirSync(metadata, { mode: 0o750 });
        for (const name of ['manifest.json', 'site-inventory.json']) {
          copyFileSync(join(directory, name), join(metadata, name)); chmodSync(join(metadata, name), 0o640);
        }
        syncTree(site); syncTree(metadata);
        const finalMetadata = this.path('metadata', candidate.commit);
        rmSync(finalMetadata, { recursive: true, force: true });
        renameSync(metadata, finalMetadata); syncDirectory(this.path('metadata'));
        renameSync(site, final); syncDirectory(this.path('public/releases'));
      } finally { rmSync(staging, { recursive: true, force: true }); }
    }
    if (this.state.current?.commit === candidate.commit) { await this.dependencies.health(manifest, files); return; }
    await this.activate(candidate, manifest, files);
  }
  async preview(directory: string, commit: string): Promise<void> {
    requireValue(this.config.mode === 'preview', 'Unsigned imports are restricted to the separate LAN preview');
    requireValue(isCommit(commit), 'Specify the full expected preview commit');
    await this.recover();
    // Copy into our own staging area to avoid a source directory changing while
    // it is being checked. Links and extra files are rejected before copying.
    verifyBundle(directory, false);
    const scratch = mkdtempSync(this.path('staging', 'preview-'));
    try { for (const name of ARTIFACTS) copyFileSync(join(directory, name), join(scratch, name)); await this.install(scratch, commit); }
    finally { rmSync(scratch, { recursive: true, force: true }); }
  }
  async update(): Promise<void> {
    requireValue(this.config.mode === 'release', 'Automatic updates require signed release mode');
    await this.recover();
    if (this.state.held) { console.log('Automatic updates are held after a manual rollback'); return; }
    const release = await this.dependencies.discover(this.config.pinnedTag);
    if (Object.hasOwn(this.state.quarantined, release.tag)) { console.log(`Skipping quarantined release: ${release.tag}`); return; }
    if (!this.config.pinnedTag && this.state.current?.releaseId !== null && this.state.current?.releaseId !== undefined) requireValue(release.id >= this.state.current.releaseId, 'Refusing an automatic downgrade');
    if (this.state.current?.commit === release.commit) { const current = this.stored(this.state.current); await this.dependencies.health(current.manifest, current.files); return; }
    const scratch = mkdtempSync(this.path('staging', 'release-'));
    try { await this.dependencies.download(release, scratch); await this.install(scratch, release.commit, release); }
    finally { rmSync(scratch, { recursive: true, force: true }); }
  }
  async rollback(): Promise<void> {
    await this.recover();
    const target = this.state.previous; requireValue(target, 'No previous accepted release is retained');
    const { manifest, files } = this.stored(target);
    this.state.held = true; this.save();
    await this.activate(target, manifest, files);
  }
  resume(): void { this.state.held = false; this.save(); }
  retry(tag: string): void { requireValue(isTag(tag), 'Invalid quarantine tag'); delete this.state.quarantined[tag]; this.save(); }
  private prune(): void {
    const ordered = [...this.state.generations].reverse().sort((a, b) => b.installedAt - a.installedAt);
    const protectedCommits = new Set([this.state.current?.commit, this.state.previous?.commit, ...ordered.slice(0, this.config.retain).map(item => item.commit)]);
    const cutoff = this.dependencies.now() - this.config.minimumAgeDays * 86_400_000;
    this.state.generations = this.state.generations.filter(item => {
      if (protectedCommits.has(item.commit) || item.installedAt >= cutoff) return true;
      rmSync(this.path('public/releases', item.commit), { recursive: true, force: true });
      rmSync(this.path('metadata', item.commit), { recursive: true, force: true }); return false;
    });
    this.save();
  }
}
