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
await mkdir(resolve(outputDirectory, 'live'), { recursive: true });
await copyFile(resolve(packageDirectory, 'live.html'), resolve(outputDirectory, 'live/index.html'));

await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'main.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'app.js'),
  platform: 'browser',
  target: ['es2022'],
});

await build({
  bundle: true,
  entryPoints: [resolve(sourceDirectory, 'live-main.ts')],
  format: 'esm',
  outfile: resolve(outputDirectory, 'live/app.js'),
  platform: 'browser',
  target: ['es2022'],
});

await build({
  entryPoints: [
    resolve(sourceDirectory, 'preview-model.ts'),
    resolve(sourceDirectory, 'remote-input.ts'),
    resolve(sourceDirectory, 'web-connection.ts'),
    resolve(sourceDirectory, 'web-lifecycle.ts'),
    resolve(sourceDirectory, 'media-model.ts'),
    resolve(sourceDirectory, 'desktop-controls.ts'),
    resolve(sourceDirectory, 'session-controls.ts'),
    resolve(sourceDirectory, 'pinch-gesture.ts'),
    resolve(sourceDirectory, 'preferences.ts'),
    resolve(sourceDirectory, 'keyboard-controls.ts'),
    resolve(sourceDirectory, 'live-touchpad.ts'),
  ],
  format: 'esm',
  outdir: outputDirectory,
  platform: 'node',
  target: ['node22'],
});
