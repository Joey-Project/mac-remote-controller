import assert from 'node:assert/strict';
import test from 'node:test';
import { RTTBenchmarkAccumulator, ConnectionBenchmark } from '../dist/connection-benchmark.js';

const turn = () => new Promise((resolve) => setImmediate(resolve));

test('native-equivalent groups exclude warmups and use nearest-rank percentiles', () => {
  const model = new RTTBenchmarkAccumulator();
  for (const sample of [null, 2000, 1900]) model.record(sample);
  assert.equal(model.progress, 0);
  for (const sample of [6, 1, 5, 2, 4, 3, null, null]) model.record(sample);
  const report = model.report('cancelled');
  assert.equal(report.attempts, 8);
  assert.equal(report.timeouts, 2);
  assert.deepEqual(
    [report.minimum, report.median, report.p95, report.maximum, report.jitter],
    [1, 3, 6, 6, 3],
  );
  assert.match(report.summary, /Partial · cancelled · 8\/90/);
  assert.match(report.summary, /loss 2 \(25%\)/);
});

test('all 90 measurements fit exactly three groups and ignore excess records', () => {
  const model = new RTTBenchmarkAccumulator();
  for (let index = 0; index < 3; index++) model.record(1000);
  for (let index = 0; index < 90; index++) {
    assert.equal(model.group, Math.floor(index / 30) + 1);
    assert.equal(model.sampleInGroup, (index % 30) + 1);
    model.record(index);
  }
  model.record(null);
  assert.equal(model.complete, true);
  assert.equal(model.progress, 90);
  const report = model.report('complete');
  assert.deepEqual([report.minimum, report.median, report.p95, report.maximum], [0, 44, 85, 89]);
  assert.match(report.summary, /Complete · 90\/90/);
});

test('empty and entirely lost runs show no invented latency values', () => {
  const model = new RTTBenchmarkAccumulator();
  assert.equal(model.report('cancelled').median, null);
  for (let index = 0; index < 93; index++) model.record(null);
  const report = model.report('complete');
  assert.equal(report.attempts, 90);
  assert.equal(report.timeouts, 90);
  assert.match(report.summary, /No successful probes · loss 90 \(100%\)/);
});

test('invalid samples cannot contaminate percentile or progress state', () => {
  const model = new RTTBenchmarkAccumulator();
  for (const value of [-1, NaN, Infinity, 2001]) assert.throws(() => model.record(value));
  assert.equal(model.progress, 0);
});

test('a run sends exactly 93 sequential probes with bounded state', async () => {
  let active = 0;
  let count = 0;
  const model = new ConnectionBenchmark(
    async (signal) => {
      assert.equal(signal.aborted, false);
      active++;
      assert.equal(active, 1);
      await Promise.resolve();
      active--;
      return ++count;
    },
    () => {},
  );
  model.start();
  model.start();
  await turn();
  assert.equal(count, 93);
  assert.equal(model.running, false);
  assert.equal(model.progress, 90);
  assert.equal(model.report.minimum, 4);
  assert.equal(model.report.maximum, 93);
  assert.equal(model.report.ending, 'complete');
});

test('cancel is immediate and an old completion cannot affect a newly started run', async () => {
  const pending = [];
  const model = new ConnectionBenchmark(
    (signal) =>
      new Promise((resolve, reject) => {
        pending.push({ signal, resolve, reject });
      }),
    () => {},
  );
  model.start();
  model.cancel();
  assert.equal(pending[0].signal.aborted, true);
  assert.equal(model.running, false);
  assert.equal(model.report.ending, 'cancelled');
  model.start();
  pending[0].resolve(100);
  await turn();
  assert.equal(model.progress, 0);
  assert.equal(model.running, true);
  assert.equal(model.report, null);
  model.cancel();
  pending[1].reject(new Error('Cancelled old probe.'));
  await turn();
  assert.equal(model.report.ending, 'cancelled');
});

test('transport errors keep a partial interrupted report without retrying', async () => {
  let count = 0;
  const model = new ConnectionBenchmark(
    async () => {
      if (++count === 7) throw new Error('Connection ended.');
      return count;
    },
    () => {},
  );
  model.start();
  await turn();
  assert.equal(count, 7);
  assert.equal(model.running, false);
  assert.equal(model.report.attempts, 3);
  assert.equal(model.report.ending, 'interrupted');
  assert.equal(model.error, 'Connection ended.');
});
