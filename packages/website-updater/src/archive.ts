import { chmodSync, mkdirSync, readFileSync, readdirSync, lstatSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import * as tar from 'tar';
import { hash, requireValue, safePath, verifyDigest, type Inventory, type Manifest } from './format.ts';

/** Never hand archive-supplied paths, links, permissions, or owners to an extractor. */
export function unpack(archive: string, files: Inventory, destination: string): void {
  const seen = new Set<string>();
  const completed = new Set<string>();
  tar.list({ file: archive, sync: true, strict: true, onReadEntry(entry) {
    const name = entry.path;
    requireValue(entry.type === 'File' && safePath(name) && Object.hasOwn(files, name) && !seen.has(name), `Unexpected archive entry: ${name}`);
    requireValue(entry.size === files[name].size, `Archive size mismatch: ${name}`);
    seen.add(name);
    const chunks: Buffer[] = [];
    entry.on('data', (chunk: Buffer) => chunks.push(chunk));
    entry.on('end', () => {
      const bytes = Buffer.concat(chunks);
      requireValue(bytes.length === files[name].size && hash(bytes) === files[name].sha256, `Archive checksum mismatch: ${name}`);
      const path = join(destination, name);
      mkdirSync(dirname(path), { recursive: true, mode: 0o750 });
      writeFileSync(path, bytes, { flag: 'wx', mode: 0o640 });
      completed.add(name);
    });
  }});
  requireValue(completed.size === Object.keys(files).length, 'Archive is missing files');
}
export function verifySite(directory: string, files: Inventory, manifest: Manifest): void {
  const actual: string[] = [];
  function walk(path: string): void {
    for (const name of readdirSync(path)) {
      const child = join(path, name), info = lstatSync(child);
      requireValue(!info.isSymbolicLink(), 'A deployed site cannot contain symlinks');
      if (info.isDirectory()) walk(child);
      else { requireValue(info.isFile(), 'A deployed site must contain regular files'); actual.push(relative(directory, child)); }
    }
  }
  walk(directory);
  requireValue(JSON.stringify(actual.sort()) === JSON.stringify(Object.keys(files).sort()), 'Deployed files differ from inventory');
  for (const [name, expected] of Object.entries(files)) verifyDigest(join(directory, name), expected);
  const identity = JSON.parse(readFileSync(join(directory, 'release.json'), 'utf8')) as { schema?: unknown; commit?: unknown; assetBase?: unknown };
  requireValue(identity.schema === 1 && identity.commit === manifest.commit && identity.assetBase === manifest.asset_base, 'Site identity differs from release');
  const html = readFileSync(join(directory, 'index.html'), 'utf8');
  requireValue(html.includes(`${manifest.asset_base}assets/`), 'Page does not reference versioned assets');
  chmodSync(directory, 0o750);
}
