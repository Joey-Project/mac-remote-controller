import { copyFile, mkdir, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const packageDirectory = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceDirectory = resolve(packageDirectory, 'src');
const outputDirectory = resolve(packageDirectory, 'dist');

await rm(outputDirectory, { force: true, recursive: true });
await mkdir(outputDirectory, { recursive: true });
await copyFile(
  resolve(sourceDirectory, 'manifest.json'),
  resolve(outputDirectory, 'manifest.json'),
);
await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'site-controls.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'site-controls.js'),
  platform: 'browser',
  target: 'es2022',
});
await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'service-worker.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'service-worker.js'),
  platform: 'browser',
  target: 'es2022',
});
await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'content-script.ts')],
  format: 'iife',
  outfile: resolve(outputDirectory, 'content-script.js'),
  platform: 'browser',
  target: 'es2022',
});
