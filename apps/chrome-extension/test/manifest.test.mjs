import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('MV3 permissions are restricted to the supported media sites and native host', async () => {
  const manifest = JSON.parse(
    await readFile(new URL('../src/manifest.json', import.meta.url), 'utf8'),
  );

  assert.equal(manifest.manifest_version, 3);
  const extensionID = createHash('sha256')
    .update(Buffer.from(manifest.key, 'base64'))
    .digest()
    .subarray(0, 16)
    .toString('hex')
    .replace(/[0-9a-f]/g, (digit) => String.fromCharCode(97 + Number.parseInt(digit, 16)));
  assert.equal(extensionID, 'bjplbbniljmmhclleegdfdonjmjlpnid');
  assert.equal(manifest.background.service_worker, 'service-worker.js');
  assert.equal(manifest.background.type, 'module');
  assert.deepEqual(new Set(manifest.permissions), new Set(['nativeMessaging', 'tabs']));
  assert.deepEqual(manifest.host_permissions, [
    'https://www.youtube.com/*',
    'https://www.bilibili.com/*',
    'https://bilibili.com/*',
  ]);
  assert.deepEqual(manifest.content_scripts[0].matches, manifest.host_permissions);
  assert.equal(manifest.content_scripts[0].run_at, 'document_start');
  assert.equal(manifest.content_scripts[0].all_frames, false);
  assert.equal(manifest.optional_permissions, undefined);
  assert.equal(manifest.optional_host_permissions, undefined);
});

test('built extension includes the installed content and service workers', async () => {
  const manifest = JSON.parse(
    await readFile(new URL('../dist/manifest.json', import.meta.url), 'utf8'),
  );
  for (const path of [manifest.background.service_worker, manifest.content_scripts[0].js[0]]) {
    const source = await readFile(new URL(`../dist/${path}`, import.meta.url), 'utf8');
    assert.ok(source.length > 0, `${path} must be bundled`);
  }
});
