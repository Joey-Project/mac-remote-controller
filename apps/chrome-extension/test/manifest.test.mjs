import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('the MV3 placeholder does not request browser or website permissions', async () => {
  const manifest = JSON.parse(
    await readFile(new URL('../src/manifest.json', import.meta.url), 'utf8'),
  );

  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.service_worker, 'service-worker.js');
  assert.equal(manifest.background.type, 'module');

  for (const key of [
    'permissions',
    'host_permissions',
    'optional_permissions',
    'optional_host_permissions',
    'content_scripts',
  ]) {
    assert.equal(manifest[key], undefined, `${key} must remain absent from the placeholder`);
  }
});
