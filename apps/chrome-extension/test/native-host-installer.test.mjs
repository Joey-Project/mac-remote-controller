import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import process from 'node:process';

const installer = fileURLToPath(
  new URL('../../../scripts/install-chrome-native-host.sh', import.meta.url),
);

test('writes a private valid manifest for host paths with spaces and JSON escapes', () => {
  const temporaryRoot = mkdtempSync(join(tmpdir(), 'sofa-native-host-test-'));
  const manifestDirectory = join(temporaryRoot, 'Native Messaging Hosts');
  const hostBinary = join(temporaryRoot, 'Sofa Remote "host" \\ binary');

  try {
    writeFileSync(hostBinary, 'fake executable');
    chmodSync(hostBinary, 0o700);
    const result = spawnSync('sh', [installer, hostBinary], {
      encoding: 'utf8',
      env: {
        ...process.env,
        SOFA_REMOTE_NATIVE_HOST_DIRECTORY: manifestDirectory,
      },
    });

    assert.equal(result.status, 0, result.stderr);
    const manifestPath = join(manifestDirectory, 'com.joeyteng.sofaremote.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    assert.equal(manifest.name, 'com.joeyteng.sofaremote');
    assert.equal(manifest.path, hostBinary);
    assert.equal(manifest.type, 'stdio');
    assert.deepEqual(manifest.allowed_origins, [
      'chrome-extension://bjplbbniljmmhclleegdfdonjmjlpnid/',
    ]);
    assert.equal(statSync(manifestPath).mode & 0o777, 0o600);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});
