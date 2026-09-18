import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { Deployment, type State } from '../src/deployment.ts';
import { ARTIFACTS, BUNDLES, fileDigest } from '../src/format.ts';
import { provenancePolicy, verifyAttestations, type Release } from '../src/github.ts';
import { bundle, workspace } from './fixture.ts';

const healthy = async () => {};

test('activation switches atomically, keeps older assets, and rollback holds updates', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a'), b = bundle(root, 'b');
  const seen: string[] = [];
  const deployment = new Deployment(config, { health: async manifest => {
    seen.push(readlinkSync(join(config.stateDirectory, 'current')));
    assert.equal(seen.at(-1), `public/releases/${manifest.commit}`);
  }});
  await deployment.preview(a.directory, a.commit); await deployment.preview(b.directory, b.commit);
  assert.equal(deployment.state.current?.commit, b.commit); assert.equal(deployment.state.previous?.commit, a.commit);
  assert.equal(readFileSync(join(config.stateDirectory, 'public/releases', a.commit, 'factorio/sound/note.ogg'), 'utf8'), 'sound-a');
  await deployment.rollback();
  assert.equal(deployment.state.current?.commit, a.commit); assert(deployment.state.held);
  deployment.resume(); assert.equal(deployment.state.held, false);
  assert.equal(seen.length, 3);
});

test('a failed health check restores and verifies the prior version, then quarantines the failure', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a'), b = bundle(root, 'b');
  const checked: string[] = [];
  const deployment = new Deployment(config, { health: async manifest => {
    checked.push(manifest.commit); if (manifest.commit === b.commit) throw new Error('Missing sprite');
  }});
  await deployment.preview(a.directory, a.commit);
  await assert.rejects(deployment.preview(b.directory, b.commit), /previous release restored/);
  assert.equal(deployment.state.current?.commit, a.commit);
  assert.equal(readlinkSync(join(config.stateDirectory, 'current')), `public/releases/${a.commit}`);
  assert.deepEqual(checked, [a.commit, b.commit, a.commit]);
  assert.match(deployment.state.quarantined[b.tag], /Missing sprite/);
  assert(!existsSync(join(config.stateDirectory, 'public/releases', b.commit)));
  assert(!existsSync(join(config.stateDirectory, 'metadata', b.commit)));
  await assert.rejects(deployment.preview(b.directory, b.commit), /quarantined/);
});

test('a failed first deployment leaves no current website', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a');
  const deployment = new Deployment(config, { health: async () => { throw new Error('Unhealthy'); } });
  await assert.rejects(deployment.preview(a.directory, a.commit), /previous release restored/);
  assert.equal(deployment.state.current, null); assert(!existsSync(join(config.stateDirectory, 'current')));
});

test('an interrupted activation is rolled back on the next operation', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a'), b = bundle(root, 'b');
  const deployment = new Deployment(config, { health: healthy });
  await deployment.preview(a.directory, a.commit);
  const pending = { commit: b.commit, tag: b.tag, releaseId: null, manifestHash: fileDigest(join(b.directory, 'manifest.json')).sha256, installedAt: Date.now() };
  const state: State = { ...deployment.state, pending: { candidate: pending, previous: deployment.state.current } };
  cpSync(b.site, join(config.stateDirectory, 'public/releases', b.commit), { recursive: true });
  rmSync(join(config.stateDirectory, 'current'));
  symlinkSync('public/releases/' + b.commit, join(config.stateDirectory, 'current'));
  writeFileSync(join(config.stateDirectory, 'state.json'), JSON.stringify(state));
  const recovered = new Deployment(config, { health: healthy });
  await recovered.recover();
  assert.equal(readlinkSync(join(config.stateDirectory, 'current')), 'public/releases/' + a.commit);
  assert(!existsSync(join(config.stateDirectory, 'public/releases', b.commit)));
  assert.equal(recovered.state.current?.commit, a.commit); assert.equal(recovered.state.pending, null); assert(recovered.state.quarantined[b.tag]);
});

test('corrupt bundles, unexpected files, symlinks, and mismatched commits never change current', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a'), b = bundle(root, 'b');
  const deployment = new Deployment(config, { health: healthy }); await deployment.preview(a.directory, a.commit);
  await assert.rejects(deployment.preview(b.directory, a.commit), /requested commit/);
  const changed = join(root, 'corrupt'); cpSync(b.directory, changed, { recursive: true });
  writeFileSync(join(changed, 'website.tar.gz'), 'corrupt');
  await assert.rejects(deployment.preview(changed, b.commit), /Checksum mismatch/);
  const extra = join(root, 'extra'); cpSync(b.directory, extra, { recursive: true }); writeFileSync(join(extra, 'unknown'), '');
  await assert.rejects(deployment.preview(extra, b.commit), /Unexpected/);
  const linked = join(root, 'linked'); mkdirSync(linked);
  for (const name of ARTIFACTS) symlinkSync(join(b.directory, name), join(linked, name));
  await assert.rejects(deployment.preview(linked, b.commit), /regular file/);
  assert.equal(deployment.state.current?.commit, a.commit);
});

test('automatic mode cannot import unsigned previews or reuse preview state', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a');
  const signed = new Deployment({ ...config, mode: 'release' }, { health: healthy });
  await assert.rejects(signed.preview(a.directory, a.commit), /Unsigned imports/);
  assert.throws(() => new Deployment(config), /cannot be shared/);
});

test('automatic updates require verification before extraction and preserve the active site on signature failure', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a', true), b = bundle(root, 'b', true);
  let selected = a, id = 1, verificationFails = false; const verified: string[] = [];
  const deployment = new Deployment({ ...config, mode: 'release' }, {
    health: healthy,
    discover: async () => ({ id, tag: selected.tag, commit: selected.commit, assets: [] }),
    download: async (_release, directory) => cpSync(selected.directory, directory, { recursive: true }),
    verifyAttestations: async (_directory, manifest) => {
      verified.push(manifest.commit);
      assert(!existsSync(join(config.stateDirectory, 'public/releases', manifest.commit)), 'Verification must precede extraction');
      if (verificationFails) throw new Error('Invalid signature');
    },
  });
  await deployment.update(); assert.equal(deployment.state.current?.commit, a.commit);
  selected = b; id = 2; verificationFails = true;
  await assert.rejects(deployment.update(), /Invalid signature/);
  assert.equal(deployment.state.current?.commit, a.commit); assert(!existsSync(join(config.stateDirectory, 'public/releases', b.commit)));
  assert.deepEqual(verified, [a.commit, b.commit]);
});

test('latest cannot automatically downgrade, while a declared pin can select an older signed release', async t => {
  const { root, config } = workspace(t), a = bundle(root, 'a', true), b = bundle(root, 'b', true);
  let selected = b, id = 2;
  const dependencies = { health: healthy, discover: async () => ({ id, tag: selected.tag, commit: selected.commit, assets: [] }),
    download: async (_release: Release, directory: string) => cpSync(selected.directory, directory, { recursive: true }), verifyAttestations: healthy };
  const deployment = new Deployment({ ...config, mode: 'release' }, dependencies); await deployment.update();
  selected = a; id = 1; await assert.rejects(deployment.update(), /downgrade/);
  const pinned = new Deployment({ ...config, mode: 'release', pinnedTag: a.tag }, dependencies);
  await pinned.update(); assert.equal(pinned.state.current?.commit, a.commit);
});

test('retention protects current, previous, the minimum count, and the grace period', async t => {
  const { root, config } = workspace(t); let now = Date.now();
  const deployment = new Deployment(config, { health: healthy, now: () => now });
  const versions = ['a', 'b', 'c', 'd', 'e'].map(digit => bundle(root, digit));
  for (const version of versions.slice(0, 4)) await deployment.preview(version.directory, version.commit);
  assert.equal(deployment.state.generations.length, 4, 'Grace period protects all recent releases');
  now += 31 * 86_400_000; await deployment.preview(versions[4].directory, versions[4].commit);
  assert.equal(deployment.state.generations.length, 3);
  assert(!existsSync(join(config.stateDirectory, 'public/releases', versions[0].commit)));
  assert(existsSync(join(config.stateDirectory, 'public/releases', versions[3].commit)));
});

test('verification pins certificate identity, commit, main, issuer, hosted runners, and the SBOM predicate', async t => {
  const { root } = workspace(t), a = bundle(root, 'a', true);
  const calls: string[][] = [];
  await verifyAttestations(a.directory, a.manifest, async (program, args, env) => {
    assert.equal(program, 'gh'); assert.equal(env.GH_TOKEN, undefined); assert.equal(env.GITHUB_TOKEN, undefined); calls.push(args);
  });
  assert.equal(calls.length, ARTIFACTS.length + 1);
  for (const args of calls) {
    const policy = provenancePolicy(a.commit); for (const item of policy) assert(args.includes(item));
    assert(args.includes('--deny-self-hosted-runners'));
    assert(args.includes('https://github.com/joshcazalas/website/.github/workflows/release.yml@refs/heads/main'));
    assert(args.includes(a.commit)); assert(args.includes('refs/heads/main'));
  }
  assert(calls.at(-1)?.includes('https://cyclonedx.org/bom'));
  assert(calls.at(-1)?.includes(join(a.directory, BUNDLES[1])));
  await assert.rejects(verifyAttestations(a.directory, { ...a.manifest, source_ref: 'refs/pull/1/merge' }, async () => {}), /Only main/);
  await assert.rejects(verifyAttestations(a.directory, a.manifest, async () => { throw new Error('gh refused attestation'); }), /refused/);
});
