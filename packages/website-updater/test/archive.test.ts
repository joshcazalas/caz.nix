import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { gzipSync } from 'node:zlib';
import { Header, type HeaderData } from 'tar';
import { unpack } from '../src/archive.ts';
import { hash } from '../src/format.ts';

test('unpacking rejects traversal, links, duplicates, missing files, and mismatched bytes', t => {
  const root = mkdtempSync(join(tmpdir(), 'website-archive-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const expected = { 'sprite.png': { sha256: hash('sprite'), size: 6 } };
  let index = 0;
  const check = (members: (HeaderData & { data?: string })[]) => {
    const destination = join(root, String(++index)); mkdirSync(destination);
    const blocks: Buffer[] = [];
    for (const { data = 'sprite', ...member } of members) {
      const bytes = Buffer.from(member.type && member.type !== 'File' ? '' : data);
      const header = new Header({ mode: 0o777, type: 'File', size: bytes.length, ...member }); header.encode(); assert(header.block);
      blocks.push(header.block, bytes, Buffer.alloc((512 - bytes.length % 512) % 512));
    }
    const archive = join(root, `${index}.tar.gz`); writeFileSync(archive, gzipSync(Buffer.concat([...blocks, Buffer.alloc(1024)])));
    assert.throws(() => unpack(archive, expected, destination));
  };
  for (const path of ['../sprite.png', '/sprite.png', 'a/../sprite.png', 'unexpected.png']) check([{ path }]);
  for (const type of ['SymbolicLink', 'Link'] as const) check([{ path: 'sprite.png', type, linkpath: '../escape' }]);
  check([{ path: 'sprite.png' }, { path: 'sprite.png' }]);
  check([{ path: 'sprite.png', data: 'broken' }]);
  check([{ path: 'sprite.png', data: 'too long' }]); check([]);
});
