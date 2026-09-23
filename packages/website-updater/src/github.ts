import { request } from './http.ts';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ARTIFACTS, BUNDLES, MAX_ARCHIVE, REPOSITORY, WORKFLOW, hash, isCommit, isTag, record, requireValue, type Manifest } from './format.ts';

export type Release = { id: number; tag: string; commit: string; assets: { name: string; size: number; sha256: string }[] };
export type Command = (program: string, args: string[], env: NodeJS.ProcessEnv) => Promise<void>;
export const runCommand: Command = (program, args, env) => new Promise((resolve, reject) => {
  const child = spawn(program, args, { env, stdio: ['ignore', 'inherit', 'inherit'], timeout: 120_000 });
  child.on('error', reject);
  child.on('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`${program} failed (${signal ?? code})`)));
});
async function api(path: string): Promise<unknown> {
  return JSON.parse((await request(`https://api.github.com/repos/${REPOSITORY}/${path}`, 2 * 1024 * 1024)).toString('utf8')) as unknown;
}
export async function discover(tag?: string): Promise<Release> {
  requireValue(tag === undefined || isTag(tag), 'Invalid pinned release tag');
  const value = await api(tag ? `releases/tags/${tag}` : 'releases/latest');
  record(value);
  requireValue(value.draft === false && value.prerelease === false && value.immutable === true, 'Release must be published, stable, and immutable');
  requireValue(isTag(value.tag_name) && (tag === undefined || value.tag_name === tag) && Number.isSafeInteger(value.id) && Number(value.id) > 0, 'Invalid GitHub release identity');
  requireValue(Array.isArray(value.assets), 'Missing release assets');
  const assets = value.assets.map((asset: unknown) => {
    record(asset);
    requireValue(typeof asset.name === 'string' && typeof asset.size === 'number' && Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= MAX_ARCHIVE, 'Invalid asset metadata');
    requireValue(typeof asset.digest === 'string' && /^sha256:[a-f0-9]{64}$/.test(asset.digest), 'Missing GitHub asset checksum');
    return { name: asset.name, size: asset.size, sha256: asset.digest.slice(7) };
  });
  const expected = [...ARTIFACTS, ...BUNDLES].sort();
  requireValue(JSON.stringify(assets.map(asset => asset.name).sort()) === JSON.stringify(expected), 'Unexpected published asset set');
  const ref = await api(`git/ref/tags/${value.tag_name}`); record(ref); record(ref.object);
  let object = ref.object;
  for (let depth = 0; object.type === 'tag' && depth < 5; depth++) {
    requireValue(isCommit(object.sha), 'Invalid tag object');
    const annotated = await api(`git/tags/${object.sha}`); record(annotated); record(annotated.object); object = annotated.object;
  }
  requireValue(object.type === 'commit' && isCommit(object.sha), 'Release tag does not resolve to a commit');
  requireValue(value.tag_name.endsWith(`-g${object.sha.slice(0, 12)}`), 'Release tag and commit differ');
  return { id: Number(value.id), tag: value.tag_name, commit: object.sha, assets };
}
export async function download(release: Release, directory: string): Promise<void> {
  // Bound concurrency while overlapping the small metadata and signature downloads.
  const pending = [...release.assets];
  const results = await Promise.allSettled(Array.from({ length: 3 }, async () => {
    for (let asset = pending.shift(); asset; asset = pending.shift()) {
      const bytes = await request(`https://github.com/${REPOSITORY}/releases/download/${release.tag}/${asset.name}`, asset.size);
      requireValue(bytes.length === asset.size && hash(bytes) === asset.sha256, `GitHub asset checksum mismatch: ${asset.name}`);
      writeFileSync(join(directory, asset.name), bytes, { flag: 'wx', mode: 0o640 });
    }
  }));
  const failed = results.find(result => result.status === 'rejected');
  if (failed?.status === 'rejected') throw failed.reason;
}
export function provenancePolicy(commit: string): string[] {
  requireValue(isCommit(commit), 'Invalid provenance commit');
  // gh accepts only one signer selector; the exact certificate identity pins
  // both the workflow path and ref without a second --signer-workflow flag.
  return ['--hostname', 'github.com', '--repo', REPOSITORY,
    '--cert-identity', `https://github.com/${WORKFLOW}@refs/heads/main`,
    '--cert-oidc-issuer', 'https://token.actions.githubusercontent.com',
    '--source-ref', 'refs/heads/main', '--source-digest', commit, '--signer-digest', commit,
    '--deny-self-hosted-runners'];
}
export async function verifyAttestations(directory: string, manifest: Manifest, execute: Command = runCommand): Promise<void> {
  requireValue(manifest.source_ref === 'refs/heads/main', 'Only main releases may be installed automatically');
  const scratch = mkdtempSync(join(tmpdir(), 'website-verifier-'));
  try {
    const env: NodeJS.ProcessEnv = { ...process.env, GH_HOST: 'github.com', GH_CONFIG_DIR: scratch, GH_PROMPT_DISABLED: '1', GH_NO_UPDATE_NOTIFIER: '1' };
    delete env.GH_TOKEN; delete env.GITHUB_TOKEN;
    for (const name of ARTIFACTS) await execute('gh', ['attestation', 'verify', join(directory, name), '--bundle', join(directory, BUNDLES[0]), ...provenancePolicy(manifest.commit)], env);
    await execute('gh', ['attestation', 'verify', join(directory, 'website.tar.gz'), '--bundle', join(directory, BUNDLES[1]),
      '--predicate-type', 'https://cyclonedx.org/bom', ...provenancePolicy(manifest.commit)], env);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}
