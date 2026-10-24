import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import { TextEncoder } from 'node:util';

function makeEvent() {
  const listeners = [];
  return {
    addListener(listener) {
      listeners.push(listener);
    },
    dispatch(...args) {
      for (const listener of listeners) listener(...args);
    },
    firstListener() {
      return listeners[0];
    },
  };
}

async function makeHarness() {
  const source = await readFile(new URL('../dist/service-worker.js', import.meta.url), 'utf8');
  const nativeMessages = [];
  const tabMessages = [];
  const intervals = [];
  const timeouts = new Map();
  let timeoutId = 0;
  const runtimeMessage = makeEvent();
  const tabRemoved = makeEvent();
  const tabUpdated = makeEvent();
  const installed = makeEvent();
  const startup = makeEvent();
  const nativeDisconnected = makeEvent();
  const nativeMessage = makeEvent();
  const sender = { tab: { id: 41 }, frameId: 0, url: 'https://www.youtube.com/watch?v=1' };
  const snapshot = {
    kind: 'youtube',
    name: 'YouTube · Hidden episode',
    capabilities: {
      playPause: true,
      seek: true,
      next: false,
      previous: false,
      playerVolumeMaximum: 1,
    },
    playerVolume: 0.5,
  };
  let workerMessageListener;
  const port = {
    onMessage: nativeMessage,
    onDisconnect: nativeDisconnected,
    postMessage(message) {
      nativeMessages.push(message);
    },
  };
  const chrome = {
    runtime: {
      lastError: undefined,
      onMessage: runtimeMessage,
      onInstalled: installed,
      onStartup: startup,
      connectNative(name) {
        assert.equal(name, 'com.joeyteng.sofaremote');
        return port;
      },
    },
    tabs: {
      onRemoved: tabRemoved,
      onUpdated: tabUpdated,
      sendMessage(tabId, message, callback) {
        tabMessages.push({ tabId, message });
        if (message.type === 'mediaRefresh') {
          workerMessageListener({ type: 'mediaState', snapshot }, sender);
        }
        callback?.();
        return Promise.resolve();
      },
    },
  };
  vm.runInContext(
    source,
    vm.createContext({
      chrome,
      TextEncoder,
      URL,
      setInterval(callback, delay) {
        intervals.push({ callback, delay });
        return intervals.length;
      },
      setTimeout(callback, delay) {
        timeoutId += 1;
        timeouts.set(timeoutId, { callback, delay });
        return timeoutId;
      },
      clearTimeout(id) {
        timeouts.delete(id);
      },
    }),
  );
  workerMessageListener = runtimeMessage.firstListener();

  return {
    nativeMessages,
    tabMessages,
    intervals,
    timeouts,
    nativeMessage,
    nativeDisconnected,
    tabRemoved,
    tabUpdated,
    workerMessageListener,
    sender,
    snapshot,
    fireTimeout(id) {
      const timeout = timeouts.get(id);
      assert.ok(timeout, `timeout ${id} must be pending`);
      timeouts.delete(id);
      timeout.callback();
    },
  };
}

test('service worker renews registered background targets independently of page timers', async () => {
  const harness = await makeHarness();
  assert.equal(harness.intervals.length, 1);
  assert.equal(harness.intervals[0].delay, 2_000);
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');

  // Model a hidden page whose own chained timer is throttled: only the worker tick runs.
  harness.intervals[0].callback();

  assert.equal(harness.tabMessages.length, 1);
  assert.equal(harness.tabMessages[0].tabId, 41);
  assert.equal(harness.tabMessages[0].message.type, 'mediaRefresh');
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  assert.equal(harness.nativeMessages.at(-1).targetId, 'chrome:41');
});

test('unavailable navigation, source removal, and native disconnect stop worker refreshes', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.intervals[0].callback();
  assert.equal(harness.tabMessages.length, 1);

  harness.tabUpdated.dispatch(41, { url: 'https://example.com/' }, { id: 41 });
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUnavailable');
  harness.intervals[0].callback();
  assert.equal(harness.tabMessages.length, 1);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.tabRemoved.dispatch(41);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUnavailable');
  harness.intervals[0].callback();
  assert.equal(harness.tabMessages.length, 1);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.nativeDisconnected.dispatch();
  harness.intervals[0].callback();
  assert.equal(harness.tabMessages.length, 1);
});

test('command timeout retires its result, drops late replies, and frees the next request', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  const firstCommand = {
    type: 'media.command',
    requestId: 'chrome-request-1',
    targetId: 'chrome:41',
    action: 'seek',
    value: 1,
  };
  harness.nativeMessage.dispatch(firstCommand);

  const firstTimeoutId = [...harness.timeouts.keys()][0];
  assert.equal(harness.timeouts.get(firstTimeoutId).delay, 1_500);
  harness.fireTimeout(firstTimeoutId);
  const afterTimeoutCount = harness.nativeMessages.length;
  assert.equal(harness.nativeMessages.at(-1).type, 'media.commandResult');
  assert.equal(harness.nativeMessages.at(-1).requestId, firstCommand.requestId);
  assert.equal(harness.nativeMessages.at(-1).targetId, firstCommand.targetId);
  assert.equal(harness.nativeMessages.at(-1).ok, false);

  harness.workerMessageListener(
    { type: 'mediaCommandResult', requestId: firstCommand.requestId, ok: true },
    harness.sender,
  );
  assert.equal(harness.nativeMessages.length, afterTimeoutCount);
  assert.equal(harness.timeouts.size, 0);

  const nextCommand = { ...firstCommand, requestId: 'chrome-request-2' };
  harness.nativeMessage.dispatch(nextCommand);
  assert.equal(harness.timeouts.size, 1);
  harness.workerMessageListener(
    { type: 'mediaCommandResult', requestId: nextCommand.requestId, ok: true },
    harness.sender,
  );

  assert.equal(harness.timeouts.size, 0);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.commandResult');
  assert.equal(harness.nativeMessages.at(-1).requestId, nextCommand.requestId);
  assert.equal(harness.nativeMessages.at(-1).ok, true);
});
