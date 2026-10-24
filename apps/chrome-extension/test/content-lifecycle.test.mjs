import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import { TextEncoder } from 'node:util';

function makeContext() {
  const sent = [];
  const windowListeners = new Map();
  const scheduled = new Map();
  let mutationCallback;
  let timeoutId = 0;
  let runtimeMessageListener;
  let title = 'Episode one';
  let currentVideo;
  const playerRoot = {
    ownerDocument: null,
    parentElement: null,
    styles: {},
    hasAttribute() {
      return false;
    },
    matches(selector) {
      return selector === '#movie_player';
    },
    querySelector() {
      return null;
    },
    getClientRects() {
      return [{ width: 640, height: 360 }];
    },
  };
  const document = {
    documentElement: {},
    defaultView: {
      getComputedStyle(element) {
        const style = element.styles ?? {};
        return {
          display: style.display ?? 'inline',
          visibility: style.visibility ?? 'visible',
          opacity: style.opacity ?? '1',
          getPropertyValue(name) {
            return name === 'content-visibility' ? (style.contentVisibility ?? 'visible') : '';
          },
        };
      },
    },
    get title() {
      return title;
    },
    addEventListener() {},
    querySelector(selector) {
      return selector === 'video' ? currentVideo : undefined;
    },
    querySelectorAll(selector) {
      return selector === '#movie_player video.html5-main-video' ? [currentVideo] : [];
    },
  };
  playerRoot.ownerDocument = document;
  function attachVideo(video) {
    video.ownerDocument = document;
    video.parentElement = playerRoot;
    video.isConnected ??= true;
    video.styles ??= {};
    video.hasAttribute ??= () => false;
    video.matches ??= () => false;
    video.getClientRects ??= () => [{ width: 640, height: 360 }];
    return video;
  }
  currentVideo = attachVideo({
    duration: 30,
    seekable: { length: 0 },
    paused: true,
    volume: 0.5,
    muted: false,
    play() {},
    pause() {},
    addEventListener() {},
  });
  const window = {
    addEventListener(name, callback) {
      windowListeners.set(name, callback);
    },
    setTimeout(callback) {
      timeoutId += 1;
      scheduled.set(timeoutId, callback);
      return timeoutId;
    },
    clearTimeout(id) {
      scheduled.delete(id);
    },
    setInterval() {
      return 1;
    },
  };
  class MutationObserver {
    constructor(callback) {
      mutationCallback = callback;
    }
    observe() {}
  }
  const chrome = {
    runtime: {
      sendMessage(message) {
        sent.push(message);
        return Promise.resolve();
      },
      onMessage: {
        addListener(listener) {
          runtimeMessageListener = listener;
        },
      },
    },
  };
  const location = { href: 'https://www.youtube.com/watch?v=1' };
  const context = vm.createContext({
    Object,
    Promise,
    JSON,
    URL,
    TextEncoder,
    document,
    window,
    chrome,
    location,
    MutationObserver,
  });
  return {
    context,
    sent,
    scheduled,
    windowListeners,
    refresh() {
      runtimeMessageListener({ type: 'mediaRefresh' });
    },
    sendCommand(message) {
      runtimeMessageListener(message);
    },
    mutate() {
      mutationCallback();
    },
    setPage({ href = location.href, pageTitle = title, video = currentVideo } = {}) {
      location.href = href;
      title = pageTitle;
      currentVideo = attachVideo(video);
    },
  };
}

test('content script refreshes source after SPA navigation, BFCache restore, and video replacement', async () => {
  const source = await readFile(new URL('../dist/content-script.js', import.meta.url), 'utf8');
  const harness = makeContext();
  vm.runInContext(source, harness.context);
  assert.equal(harness.sent.at(-1).type, 'mediaState');
  assert.match(harness.sent.at(-1).snapshot.name, /Episode one/);

  harness.setPage({ href: 'https://www.youtube.com/watch?v=2', pageTitle: 'Episode two' });
  harness.windowListeners.get('yt-navigate-finish')();
  assert.match(harness.sent.at(-1).snapshot.name, /Episode two/);

  harness.windowListeners.get('pageshow')();
  assert.equal(harness.sent.at(-1).type, 'mediaState');

  const replacementVideo = {
    duration: 30,
    seekable: { length: 0 },
    paused: true,
    play() {},
    pause() {},
    addEventListener() {},
  };
  harness.setPage({
    href: 'https://www.youtube.com/watch?v=3',
    pageTitle: 'Episode three',
    video: replacementVideo,
  });
  harness.mutate();
  const [timerId, callback] = harness.scheduled.entries().next().value;
  harness.scheduled.delete(timerId);
  callback();
  assert.match(harness.sent.at(-1).snapshot.name, /Episode three/);
});

test('content script echoes the dispatch id on its asynchronous command result', async () => {
  const source = await readFile(new URL('../dist/content-script.js', import.meta.url), 'utf8');
  const harness = makeContext();
  vm.runInContext(source, harness.context);

  harness.sendCommand({
    type: 'mediaCommand',
    requestId: 'dispatch-id-check',
    dispatchId: 29,
    action: 'setVolume',
    value: 0.6,
  });
  await Promise.resolve();

  const result = harness.sent.at(-1);
  assert.equal(result.type, 'mediaCommandResult');
  assert.equal(result.requestId, 'dispatch-id-check');
  assert.equal(result.dispatchId, 29);
  assert.equal(result.ok, true);
});

test('service-worker refresh messages report the current tab video without a page timer', async () => {
  const source = await readFile(new URL('../dist/content-script.js', import.meta.url), 'utf8');
  const harness = makeContext();
  vm.runInContext(source, harness.context);
  const initialMessageCount = harness.sent.length;

  harness.setPage({ pageTitle: 'Background episode' });
  harness.refresh();

  assert.equal(harness.sent.length, initialMessageCount + 1);
  assert.equal(harness.sent.at(-1).type, 'mediaState');
  assert.match(harness.sent.at(-1).snapshot.name, /Background episode/);
});
