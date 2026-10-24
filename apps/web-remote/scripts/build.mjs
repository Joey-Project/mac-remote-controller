import { copyFile, mkdir, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const packageDirectory = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceDirectory = resolve(packageDirectory, 'src');
const outputDirectory = resolve(packageDirectory, 'dist');

await rm(outputDirectory, { force: true, recursive: true });
await mkdir(outputDirectory, { recursive: true });
await copyFile(resolve(packageDirectory, 'index.html'), resolve(outputDirectory, 'index.html'));

await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'main.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'app.js'),
  platform: 'browser',
  target: ['es2022'],
});

await build({
  entryPoints: [resolve(sourceDirectory, 'preview-model.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'preview-model.js'),
  platform: 'node',
  target: ['node22'],
});
