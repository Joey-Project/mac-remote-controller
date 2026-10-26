import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = resolve(root, 'dist');
const plugin = resolve(dist, 'SofaRemote.iinaplugin');
await rm(dist, { recursive: true, force: true });
await mkdir(plugin, { recursive: true });
await cp(resolve(root, 'Info.json'), resolve(plugin, 'Info.json'));
await cp(resolve(root, 'preferences.html'), resolve(plugin, 'preferences.html'));
await build({
  bundle: true,
  entryPoints: [resolve(root, 'src/iina-controls.ts')],
  format: 'esm',
  outfile: resolve(dist, 'iina-controls.js'),
  platform: 'browser',
  target: 'es2022',
});
await build({
  bundle: true,
  entryPoints: [resolve(root, 'src/main.ts')],
  format: 'iife',
  outfile: resolve(plugin, 'main.js'),
  platform: 'browser',
  target: 'es2022',
});
