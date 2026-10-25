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

async function makeHarness({ failedConnectionAttempts = [], deferTabCallbacks = false } = {}) {
  const source = await readFile(new URL('../dist/service-worker.js', import.meta.url), 'utf8');
  const nativeMessages = [];
  const tabMessages = [];
  const tabCallbacks = [];
  const intervals = [];
  const timeouts = new Map();
  const ports = [];
  let timeoutId = 0;
  let connectionAttempts = 0;
  let runtimeLastError;
  const runtimeMessage = makeEvent();
  const tabRemoved = makeEvent();
  const tabUpdated = makeEvent();
  const installed = makeEvent();
  const startup = makeEvent();
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

  function createNativePort() {
    const nativeDisconnected = makeEvent();
    const nativeMessage = makeEvent();
    const sent = [];
    const port = {
      onMessage: nativeMessage,
      onDisconnect: nativeDisconnected,
      sent,
      disconnectCalls: 0,
      disconnect() {
        this.disconnectCalls += 1;
        nativeDisconnected.dispatch();
      },
      postMessage(message) {
        nativeMessages.push(message);
        sent.push(message);
      },
    };
    ports.push(port);
    return port;
  }

  const chrome = {
    runtime: {
      get lastError() {
        return runtimeLastError;
      },
      onMessage: runtimeMessage,
      onInstalled: installed,
      onStartup: startup,
      connectNative(name) {
        assert.equal(name, 'com.joeyteng.sofaremote');
        connectionAttempts += 1;
        if (failedConnectionAttempts.includes(connectionAttempts)) {
          throw new Error('Native messaging host is unavailable.');
        }
        return createNativePort();
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
        if (callback) {
          if (deferTabCallbacks) tabCallbacks.push({ tabId, message, callback });
          else callback();
        }
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
        const id = intervals.length + 1;
        intervals.push({ id, callback, delay, cleared: false });
        return id;
      },
      clearInterval(id) {
        const interval = intervals.find((entry) => entry.id === id);
        if (interval) interval.cleared = true;
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
    tabCallbacks,
    intervals,
    timeouts,
    ports,
    get nativeMessage() {
      return ports.at(-1)?.onMessage;
    },
    get nativeDisconnected() {
      return ports.at(-1)?.onDisconnect;
    },
    get connectAttempts() {
      return connectionAttempts;
    },
    tabRemoved,
    tabUpdated,
    startup,
    installed,
    workerMessageListener,
    sender,
    snapshot,
    fireTimeout(id) {
      const timeout = timeouts.get(id);
      assert.ok(timeout, 'requested timeout must be pending');
      timeouts.delete(id);
      timeout.callback();
    },
    fireTimeoutWithDelay(delay) {
      const entry = [...timeouts.entries()].find(([, timeout]) => timeout.delay === delay);
      assert.ok(entry, 'requested timeout delay must be pending');
      this.fireTimeout(entry[0]);
    },
    pendingTimeoutDelays() {
      return [...timeouts.values()]
        .map((timeout) => timeout.delay)
        .sort((left, right) => left - right);
    },
    activeIntervals() {
      return intervals.filter((interval) => !interval.cleared);
    },
    fireRefresh() {
      for (const interval of this.activeIntervals()) interval.callback();
    },
    setRuntimeLastError(value) {
      runtimeLastError = value;
    },
  };
}

test('startup and installation stay idle until a supported media tab is discovered', async () => {
  const harness = await makeHarness();
  harness.startup.dispatch();
  harness.installed.dispatch();
  assert.equal(harness.connectAttempts, 0);
  assert.equal(harness.ports.length, 0);
  assert.equal(harness.activeIntervals().length, 0);
  assert.equal(harness.pendingTimeoutDelays().length, 0);
});

test('target registration stays bounded while existing tabs refresh and freed slots are reused', async () => {
  const harness = await makeHarness();
  const publish = (tabId) =>
    harness.workerMessageListener(
      { type: 'mediaState', snapshot: harness.snapshot },
      { ...harness.sender, tab: { id: tabId } },
    );
  for (let tabId = 1; tabId <= 80; tabId += 1) publish(tabId);
  const updates = () =>
    harness.nativeMessages.filter((message) => message.type === 'media.targetUpdate');
  assert.equal(updates().length, 64);
  assert.equal(harness.connectAttempts, 1);
  publish(1);
  assert.equal(updates().length, 65);
  harness.tabRemoved.dispatch(1);
  publish(65);
  assert.equal(updates().at(-1).targetId, 'chrome:65');
  assert.equal(updates().length, 66);
  assert.equal(harness.connectAttempts, 1);
});

test('service worker renews registered background targets independently of page timers', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.activeIntervals().length, 1);
  assert.equal(harness.activeIntervals()[0].delay, 2_000);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');

  // Model a hidden page whose own chained timer is throttled: only the worker tick runs.
  harness.fireRefresh();

  assert.equal(harness.tabMessages.length, 1);
  assert.equal(harness.tabMessages[0].tabId, 41);
  assert.equal(harness.tabMessages[0].message.type, 'mediaRefresh');
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  assert.equal(harness.nativeMessages.at(-1).targetId, 'chrome:41');
});

test('last media tab disconnects the host and the next snapshot reconnects lazily', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  const oldPort = harness.ports[0];
  const command = {
    type: 'media.command',
    requestId: 'pending-before-last-close',
    targetId: 'chrome:41',
    action: 'playPause',
  };
  oldPort.onMessage.dispatch(command);
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_500]);
  assert.equal(harness.tabMessages.at(-1).message.type, 'mediaCommand');

  harness.tabRemoved.dispatch(41);

  assert.equal(oldPort.sent.at(-1).type, 'media.targetUnavailable');
  assert.equal(oldPort.disconnectCalls, 1);
  assert.equal(harness.timeouts.size, 0);
  assert.equal(harness.activeIntervals().length, 0);
  assert.equal(harness.connectAttempts, 1);

  const messagesBeforeStaleCallback = harness.nativeMessages.length;
  oldPort.onMessage.dispatch(command);
  oldPort.onDisconnect.dispatch();
  assert.equal(harness.nativeMessages.length, messagesBeforeStaleCallback);
  assert.equal(harness.connectAttempts, 1);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.connectAttempts, 2);
  assert.equal(harness.ports.length, 2);
  assert.equal(harness.activeIntervals().length, 1);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');

  oldPort.onDisconnect.dispatch();
  assert.equal(harness.connectAttempts, 2);
  const nextCommand = { ...command, requestId: 'after-reconnect' };
  harness.ports[1].onMessage.dispatch(nextCommand);
  assert.equal(harness.tabMessages.at(-1).message.type, 'mediaCommand');
  assert.equal(harness.connectAttempts, 2);
});

test('last tab removal cancels a pending reconnect and stale retry cannot reopen the host', async () => {
  const harness = await makeHarness({ failedConnectionAttempts: [1] });
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.connectAttempts, 1);
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_000]);
  const retry = [...harness.timeouts.values()].find((timeout) => timeout.delay === 1_000);
  assert.ok(retry);

  harness.tabRemoved.dispatch(41);
  assert.equal(harness.pendingTimeoutDelays().length, 0);
  assert.equal(harness.activeIntervals().length, 0);
  retry.callback();
  assert.equal(harness.connectAttempts, 1);
  assert.equal(harness.ports.length, 0);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.connectAttempts, 2);
  assert.equal(harness.ports.length, 1);
  assert.equal(harness.activeIntervals().length, 1);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
});

test('unavailable navigation, source removal, and native disconnect stop worker refreshes', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.fireRefresh();
  assert.equal(harness.tabMessages.length, 1);

  harness.tabUpdated.dispatch(41, { url: 'https://example.com/' }, { id: 41 });
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUnavailable');
  assert.equal(harness.ports[0].disconnectCalls, 1);
  assert.equal(harness.activeIntervals().length, 0);
  harness.intervals[0].callback();
  assert.equal(harness.tabMessages.length, 1);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.tabRemoved.dispatch(41);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUnavailable');
  assert.equal(harness.ports[1].disconnectCalls, 1);
  assert.equal(harness.activeIntervals().length, 0);
  harness.intervals[1].callback();
  assert.equal(harness.tabMessages.length, 1);

  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  harness.nativeDisconnected.dispatch();
  harness.fireRefresh();
  assert.equal(harness.tabMessages.length, 1);
});

test('native reconnect restores snapshots and ignores stale commands, callbacks, and ports', async () => {
  const harness = await makeHarness({ deferTabCallbacks: true });
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  const command = {
    type: 'media.command',
    requestId: 'reused-request-id',
    targetId: 'chrome:41',
    action: 'seek',
    value: 1,
  };
  harness.ports[0].onMessage.dispatch(command);
  const oldTabCommand = harness.tabMessages.find(
    ({ message }) => message.type === 'mediaCommand',
  ).message;
  assert.equal(oldTabCommand.dispatchId, 1);
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_500]);

  harness.ports[0].onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_000]);
  harness.fireTimeoutWithDelay(1_000);

  assert.equal(harness.connectAttempts, 2);
  assert.equal(
    harness.tabMessages.filter(({ message }) => message.type === 'mediaRefresh').length,
    1,
  );
  assert.equal(
    harness.tabMessages.filter(({ message }) => message.type === 'mediaCommand').length,
    1,
  );
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  assert.equal(harness.nativeMessages.at(-1).targetId, 'chrome:41');
  assert.equal(
    harness.nativeMessages.some((message) => message.type === 'media.commandResult'),
    false,
  );

  harness.ports[1].onMessage.dispatch(command);
  const tabCommands = harness.tabMessages.filter(({ message }) => message.type === 'mediaCommand');
  const newTabCommand = tabCommands.at(-1).message;
  assert.notEqual(newTabCommand.dispatchId, oldTabCommand.dispatchId);

  // A late disconnect from the old port must not clear the replacement port.
  harness.ports[0].onDisconnect.dispatch();
  const beforeStaleResults = harness.nativeMessages.length;
  harness.workerMessageListener(
    {
      type: 'mediaCommandResult',
      requestId: command.requestId,
      dispatchId: oldTabCommand.dispatchId,
      ok: true,
    },
    harness.sender,
  );
  harness.setRuntimeLastError({ message: 'The old tab request failed.' });
  harness.tabCallbacks.find(({ message }) => message.type === 'mediaCommand').callback();

  assert.equal(harness.nativeMessages.length, beforeStaleResults);
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_500]);

  harness.setRuntimeLastError(undefined);
  harness.workerMessageListener(
    {
      type: 'mediaCommandResult',
      requestId: command.requestId,
      dispatchId: newTabCommand.dispatchId,
      ok: true,
    },
    harness.sender,
  );
  assert.equal(harness.nativeMessages.length, beforeStaleResults + 1);
  assert.equal(harness.ports[1].sent.at(-1).type, 'media.commandResult');
  assert.equal(harness.ports[1].sent.at(-1).requestId, command.requestId);
  assert.equal(harness.ports[1].sent.at(-1).ok, true);
  assert.equal(harness.timeouts.size, 0);
});

test('missing native host uses one bounded exponential retry timer', async () => {
  const failedAttempts = Array.from({ length: 8 }, (_, index) => index + 1);
  const harness = await makeHarness({ failedConnectionAttempts: failedAttempts });
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.connectAttempts, 1);

  const expectedDelays = [1_000, 2_000, 4_000, 8_000, 15_000, 15_000, 15_000];
  for (let index = 0; index < expectedDelays.length; index += 1) {
    const delay = expectedDelays[index];
    assert.deepEqual(harness.pendingTimeoutDelays(), [delay]);
    harness.intervals[0].callback();
    harness.intervals[0].callback();
    harness.workerMessageListener(
      { type: 'mediaState', snapshot: harness.snapshot },
      harness.sender,
    );
    assert.equal(harness.connectAttempts, index + 1);
    assert.deepEqual(harness.pendingTimeoutDelays(), [delay]);

    harness.fireTimeoutWithDelay(delay);
    assert.equal(harness.connectAttempts, index + 2);
  }

  assert.deepEqual(harness.pendingTimeoutDelays(), [15_000]);
});

test('repeated immediate port disconnects keep increasing the retry delay', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);

  harness.ports[0].onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_000]);
  harness.intervals[0].callback();
  assert.equal(harness.connectAttempts, 1);
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_000]);

  harness.fireTimeoutWithDelay(1_000);
  assert.equal(harness.connectAttempts, 2);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  harness.ports[1].onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [2_000]);

  harness.fireTimeoutWithDelay(2_000);
  assert.equal(harness.connectAttempts, 3);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  harness.ports[2].onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [4_000]);
});

test('known tabs recover after several missing-host retries without a page event', async () => {
  const harness = await makeHarness({ failedConnectionAttempts: [1, 2, 3] });
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  assert.equal(harness.connectAttempts, 1);

  for (const delay of [1_000, 2_000, 4_000]) {
    assert.deepEqual(harness.pendingTimeoutDelays(), [delay]);
    harness.fireTimeoutWithDelay(delay);
  }

  assert.equal(harness.connectAttempts, 4);
  assert.equal(harness.ports.length, 1);
  assert.equal(
    harness.tabMessages.filter(({ message }) => message.type === 'mediaRefresh').length,
    1,
  );
  assert.equal(harness.nativeMessages.at(-1).type, 'media.targetUpdate');
  assert.equal(harness.nativeMessages.at(-1).targetId, 'chrome:41');
});

test('confirmed bridge recovery resets reconnect backoff without a media command', async () => {
  const harness = await makeHarness({ failedConnectionAttempts: [1, 2, 3, 4] });
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  for (const delay of [1_000, 2_000, 4_000, 8_000]) harness.fireTimeoutWithDelay(delay);
  const recovered = harness.ports.at(-1);
  assert.equal(recovered.sent.at(-1).type, 'media.targetUpdate');
  recovered.onMessage.dispatch({ type: 'media.ready' });
  recovered.onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [1_000]);
});

test('stale ports and malformed readiness messages cannot reset reconnect backoff', async () => {
  const harness = await makeHarness();
  harness.workerMessageListener({ type: 'mediaState', snapshot: harness.snapshot }, harness.sender);
  const stale = harness.ports[0];
  stale.onDisconnect.dispatch();
  harness.fireTimeoutWithDelay(1_000);
  harness.ports[1].onDisconnect.dispatch();
  harness.fireTimeoutWithDelay(2_000);
  stale.onMessage.dispatch({ type: 'media.ready' });
  harness.ports[2].onMessage.dispatch({ type: 'media.ready', extra: true });
  harness.ports[2].onDisconnect.dispatch();
  assert.deepEqual(harness.pendingTimeoutDelays(), [4_000]);
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
  const firstDispatchId = harness.tabMessages.at(-1).message.dispatchId;

  const firstTimeoutId = [...harness.timeouts.keys()][0];
  assert.equal(harness.timeouts.get(firstTimeoutId).delay, 1_500);
  harness.fireTimeout(firstTimeoutId);
  const afterTimeoutCount = harness.nativeMessages.length;
  assert.equal(harness.nativeMessages.at(-1).type, 'media.commandResult');
  assert.equal(harness.nativeMessages.at(-1).requestId, firstCommand.requestId);
  assert.equal(harness.nativeMessages.at(-1).targetId, firstCommand.targetId);
  assert.equal(harness.nativeMessages.at(-1).ok, false);

  harness.workerMessageListener(
    {
      type: 'mediaCommandResult',
      requestId: firstCommand.requestId,
      dispatchId: firstDispatchId,
      ok: true,
    },
    harness.sender,
  );
  assert.equal(harness.nativeMessages.length, afterTimeoutCount);
  assert.equal(harness.timeouts.size, 0);

  const nextCommand = { ...firstCommand, requestId: 'chrome-request-2' };
  harness.nativeMessage.dispatch(nextCommand);
  const nextDispatchId = harness.tabMessages.at(-1).message.dispatchId;
  assert.equal(harness.timeouts.size, 1);
  harness.workerMessageListener(
    {
      type: 'mediaCommandResult',
      requestId: nextCommand.requestId,
      dispatchId: nextDispatchId,
      ok: true,
    },
    harness.sender,
  );

  assert.equal(harness.timeouts.size, 0);
  assert.equal(harness.nativeMessages.at(-1).type, 'media.commandResult');
  assert.equal(harness.nativeMessages.at(-1).requestId, nextCommand.requestId);
  assert.equal(harness.nativeMessages.at(-1).ok, true);
});
