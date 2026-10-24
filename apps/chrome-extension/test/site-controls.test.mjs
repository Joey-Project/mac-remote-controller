import assert from 'node:assert/strict';
import test from 'node:test';
import { executeMediaAction, readMediaTarget } from '../dist/site-controls.js';

const youtubeShortsSelector = 'ytd-reel-video-renderer[is-active] video';
const youtubeMainSelector = '#movie_player video.html5-main-video';
const bilibiliVideoSelector = '.bpx-player-video-wrap video';

class StubVideo {
  constructor({
    paused = true,
    duration = 30,
    currentTime = 10,
    volume = 0.5,
    muted = false,
    connected = true,
    hidden = false,
    style = {},
    parentElement = null,
    rectWidth = 320,
    rectHeight = 180,
  } = {}) {
    this.paused = paused;
    this.duration = duration;
    this.currentTime = currentTime;
    this.volume = volume;
    this.muted = muted;
    this.isConnected = connected;
    this.hidden = hidden;
    this.styles = style;
    this.parentElement = parentElement;
    this.ownerDocument = null;
    this.rectWidth = rectWidth;
    this.rectHeight = rectHeight;
    this.playCount = 0;
    this.pauseCount = 0;
  }

  async play() {
    this.playCount += 1;
    this.paused = false;
  }

  pause() {
    this.pauseCount += 1;
    this.paused = true;
  }

  hasAttribute(name) {
    return name === 'hidden' && this.hidden;
  }

  matches() {
    return false;
  }

  getClientRects() {
    return this.isConnected &&
      this.rectWidth > 0 &&
      this.rectHeight > 0 &&
      this.styles.display !== 'none'
      ? [{ width: this.rectWidth, height: this.rectHeight }]
      : [];
  }
}

class FixtureControl {
  constructor({
    hidden = false,
    disabled = false,
    ariaDisabled = null,
    isConnected = true,
    style = {},
    parentElement = null,
    rectWidth = 10,
    rectHeight = 10,
    matchSelectors = [],
    controls = {},
  } = {}) {
    this.hidden = hidden;
    this.disabled = disabled;
    this.ariaDisabled = ariaDisabled;
    this.isConnected = isConnected;
    this.styles = style;
    this.parentElement = parentElement;
    this.ownerDocument = null;
    this.rectWidth = rectWidth;
    this.rectHeight = rectHeight;
    this.matchSelectors = matchSelectors;
    this.controls = controls;
    this.clickCount = 0;
  }

  hasAttribute(name) {
    if (name === 'hidden') return this.hidden;
    if (name === 'disabled') return this.disabled;
    return false;
  }

  getAttribute(name) {
    if (name === 'aria-disabled') return this.ariaDisabled;
    return null;
  }

  matches(selector) {
    return this.matchSelectors.includes(selector);
  }

  querySelector(selector) {
    return this.controls[selector] ?? null;
  }

  getClientRects() {
    return this.isConnected &&
      this.rectWidth > 0 &&
      this.rectHeight > 0 &&
      this.styles.display !== 'none'
      ? [{ width: this.rectWidth, height: this.rectHeight }]
      : [];
  }

  click() {
    this.clickCount += 1;
  }
}

function makeDocument({
  title = 'Example episode',
  controls = {},
  videos: suppliedVideos,
  videoMatches = {},
} = {}) {
  const fallbackVideo = suppliedVideos?.[0] ?? new StubVideo();
  const videos = suppliedVideos ?? [fallbackVideo];
  const defaultPlayerRoot = new FixtureControl({
    matchSelectors: ['#movie_player', '.bpx-player-container', '#bilibiliPlayer'],
    controls,
  });
  const defaultMatches = {
    [youtubeShortsSelector]: [],
    [youtubeMainSelector]: videos,
    [bilibiliVideoSelector]: videos,
  };
  for (const video of new Set([...videos, ...Object.values(videoMatches).flat()])) {
    if (!video.parentElement) video.parentElement = defaultPlayerRoot;
  }

  const document = {
    title,
    defaultView: {
      getComputedStyle(element) {
        const styles = {
          display: 'inline',
          visibility: 'visible',
          opacity: '1',
          contentVisibility: 'visible',
          ...element.styles,
        };
        if (!Object.hasOwn(element.styles, 'visibility')) {
          let parent = element.parentElement;
          while (parent) {
            if (Object.hasOwn(parent.styles, 'visibility')) {
              styles.visibility = parent.styles.visibility;
              break;
            }
            parent = parent.parentElement;
          }
        }
        return {
          display: styles.display,
          visibility: styles.visibility,
          opacity: styles.opacity,
          getPropertyValue(name) {
            return name === 'content-visibility' ? styles.contentVisibility : '';
          },
        };
      },
    },
    querySelector(selector) {
      if (selector === 'video') return videos[0] ?? null;
      return controls[selector] ?? null;
    },
    querySelectorAll(selector) {
      if (selector === 'video') return videos;
      if (Object.hasOwn(videoMatches, selector)) return videoMatches[selector];
      return defaultMatches[selector] ?? [];
    },
  };

  const nodes = new Set([
    defaultPlayerRoot,
    ...videos,
    ...Object.values(videoMatches).flat(),
    ...Object.values(controls),
  ]);
  for (const node of [...nodes]) {
    for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
      nodes.add(ancestor);
      for (const child of Object.values(ancestor.controls ?? {})) nodes.add(child);
    }
  }
  for (const node of nodes) node.ownerDocument = document;
  return { document, video: videos[0] ?? fallbackVideo, videos };
}

function advertise(document, url = 'https://www.youtube.com/watch?v=1') {
  const target = readMediaTarget(document, url);
  assert.ok(target, 'the selected site player should be advertised');
  return target;
}

test('site allowlist accepts only the exact supported HTTPS hostnames', () => {
  const { document } = makeDocument();
  assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.kind, 'youtube');
  assert.equal(readMediaTarget(document, 'https://www.bilibili.com/video/BV1')?.kind, 'bilibili');
  assert.equal(readMediaTarget(document, 'https://bilibili.com/video/BV1')?.kind, 'bilibili');
  assert.equal(readMediaTarget(document, 'https://m.youtube.com/watch?v=1'), undefined);
  assert.equal(readMediaTarget(document, 'https://evil.youtube.com/watch?v=1'), undefined);
  assert.equal(readMediaTarget(document, 'http://www.youtube.com/watch?v=1'), undefined);
});

test('capabilities are derived from the site player and its available episode controls', () => {
  const next = new FixtureControl();
  const previous = new FixtureControl();
  const { document } = makeDocument({
    controls: { '.ytp-next-button': next, '.ytp-prev-button': previous },
  });
  const target = readMediaTarget(document, 'https://www.youtube.com/watch?v=1');

  assert.equal(target?.capabilities.playPause, true);
  assert.equal(target?.capabilities.seek, true);
  assert.equal(target?.capabilities.next, true);
  assert.equal(target?.capabilities.previous, true);
  assert.equal(target?.capabilities.playerVolumeMaximum, 1);
});

test('hidden, CSS-hidden, disabled, and detached episode controls are unavailable', async () => {
  const hiddenAncestor = new FixtureControl({ hidden: true });
  const displayNoneAncestor = new FixtureControl({ style: { display: 'none' } });
  const hiddenVisibilityAncestor = new FixtureControl({ style: { visibility: 'hidden' } });
  const transparentAncestor = new FixtureControl({ style: { opacity: '0' } });
  const cases = [
    ['hidden attribute', new FixtureControl({ hidden: true })],
    ['hidden ancestor', new FixtureControl({ parentElement: hiddenAncestor })],
    ['display none', new FixtureControl({ style: { display: 'none' } })],
    ['display none ancestor', new FixtureControl({ parentElement: displayNoneAncestor })],
    [
      'inherited visibility hidden',
      new FixtureControl({ parentElement: hiddenVisibilityAncestor }),
    ],
    ['visibility hidden', new FixtureControl({ style: { visibility: 'collapse' } })],
    ['transparent ancestor', new FixtureControl({ parentElement: transparentAncestor })],
    ['content visibility hidden', new FixtureControl({ style: { contentVisibility: 'hidden' } })],
    ['zero-area control', new FixtureControl({ rectWidth: 0 })],
    ['disabled attribute', new FixtureControl({ disabled: true })],
    ['aria disabled', new FixtureControl({ ariaDisabled: 'true' })],
    ['detached element', new FixtureControl({ isConnected: false })],
  ];

  for (const [name, control] of cases) {
    const { document } = makeDocument({ controls: { '.ytp-next-button': control } });
    assert.equal(
      readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.capabilities.next,
      false,
      name,
    );
    await assert.rejects(
      executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next'),
      /next episode control is unavailable/,
      name,
    );
    assert.equal(control.clickCount, 0, name);
  }
});

test('execution rechecks current rendering and still permits a visible child override', async () => {
  const hiddenParent = new FixtureControl({ style: { visibility: 'hidden' } });
  const child = new FixtureControl({
    parentElement: hiddenParent,
    style: { visibility: 'visible' },
  });
  const { document } = makeDocument({ controls: { '.ytp-next-button': child } });
  assert.equal(
    readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.capabilities.next,
    true,
  );
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next');
  assert.equal(child.clickCount, 1);

  child.styles.visibility = 'hidden';
  await assert.rejects(
    executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next'),
    /next episode control is unavailable/,
  );
  assert.equal(child.clickCount, 1);

  child.styles.visibility = 'visible';
  assert.equal(
    readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.capabilities.next,
    true,
  );
  child.isConnected = false;
  await assert.rejects(
    executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next'),
    /next episode control is unavailable/,
  );
  assert.equal(child.clickCount, 1);
});

test('a visible child control remains usable inside a zero-area overflow wrapper', async () => {
  const wrapper = new FixtureControl({
    rectWidth: 0,
    rectHeight: 0,
    style: { overflow: 'visible' },
  });
  const child = new FixtureControl({ parentElement: wrapper });
  const { document } = makeDocument({ controls: { '.ytp-next-button': child } });

  assert.equal(
    readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.capabilities.next,
    true,
  );
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next');
  assert.equal(child.clickCount, 1);
});

test('YouTube main player wins over an earlier offscreen preview video', async () => {
  const preview = new StubVideo({
    paused: false,
    volume: 0.9,
    style: { position: 'absolute', left: '-10000px', top: '0' },
  });
  const main = new StubVideo({ paused: true, volume: 0.25 });
  const { document } = makeDocument({
    videos: [preview, main],
    videoMatches: {
      [youtubeMainSelector]: [main],
      [bilibiliVideoSelector]: [main],
    },
  });

  assert.equal(advertise(document).playerVolume, 0.25);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 0.6);
  assert.equal(main.volume, 0.6);
  assert.equal(preview.volume, 0.9);
  assert.equal(preview.pauseCount, 0);
});

test('a unique playing candidate wins within the scoped main player', () => {
  const pausedPreview = new StubVideo({ paused: true, volume: 0.2 });
  const activeMain = new StubVideo({ paused: false, volume: 0.7 });
  const { document } = makeDocument({
    videos: [pausedPreview, activeMain],
    videoMatches: { [youtubeMainSelector]: [pausedPreview, activeMain] },
  });

  assert.equal(advertise(document).playerVolume, 0.7);
});

test('YouTube Shorts selects its active renderer and scopes its navigation controls there', async () => {
  const shortNext = new FixtureControl();
  const mainNext = new FixtureControl();
  const shortsRoot = new FixtureControl({
    matchSelectors: ['ytd-reel-video-renderer[is-active]'],
    controls: { '.ytp-next-button': shortNext },
  });
  const mainRoot = new FixtureControl({
    matchSelectors: ['#movie_player'],
    controls: { '.ytp-next-button': mainNext },
  });
  const backgroundMain = new StubVideo({
    paused: false,
    volume: 0.9,
    parentElement: mainRoot,
  });
  const activeShort = new StubVideo({
    paused: true,
    volume: 0.3,
    parentElement: shortsRoot,
  });
  const { document } = makeDocument({
    videos: [backgroundMain, activeShort],
    videoMatches: {
      [youtubeShortsSelector]: [activeShort],
      [youtubeMainSelector]: [backgroundMain],
    },
  });

  const target = advertise(document);
  assert.equal(target.playerVolume, 0.3);
  assert.equal(target.capabilities.next, true);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=short', 'next');
  assert.equal(shortNext.clickCount, 1);
  assert.equal(mainNext.clickCount, 0);
});

test('Bilibili selects and controls only the video inside its player container', async () => {
  const preview = new StubVideo({ paused: false, volume: 0.95 });
  const next = new FixtureControl();
  const biliRoot = new FixtureControl({
    matchSelectors: ['.bpx-player-container'],
    controls: { '.bpx-player-ctrl-btn.bpx-player-ctrl-next': next },
  });
  const active = new StubVideo({ paused: true, volume: 0.4, parentElement: biliRoot });
  const { document } = makeDocument({
    videos: [preview, active],
    videoMatches: { [bilibiliVideoSelector]: [active] },
  });
  const url = 'https://www.bilibili.com/video/BV1';

  const target = advertise(document, url);
  assert.equal(target.kind, 'bilibili');
  assert.equal(target.playerVolume, 0.4);
  assert.equal(target.capabilities.next, true);
  await executeMediaAction(document, url, 'next');
  assert.equal(next.clickCount, 1);
});

test('episode actions stay inside the selected player when several player containers exist', async () => {
  const previewNext = new FixtureControl();
  const activeNext = new FixtureControl();
  const previewRoot = new FixtureControl({
    matchSelectors: ['#movie_player'],
    controls: { '.ytp-next-button': previewNext },
  });
  const activeRoot = new FixtureControl({
    matchSelectors: ['#movie_player'],
    controls: { '.ytp-next-button': activeNext },
  });
  const preview = new StubVideo({ paused: true, parentElement: previewRoot });
  const active = new StubVideo({ paused: false, parentElement: activeRoot });
  const { document } = makeDocument({
    videos: [preview, active],
    controls: { '.ytp-next-button': previewNext },
    videoMatches: { [youtubeMainSelector]: [preview, active] },
  });

  assert.equal(advertise(document).capabilities.next, true);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'next');
  assert.equal(previewNext.clickCount, 0);
  assert.equal(activeNext.clickCount, 1);
});

test('ambiguous scoped player candidates fail closed instead of selecting the first video', async () => {
  for (const paused of [false, true]) {
    const first = new StubVideo({ paused, volume: 0.2 });
    const second = new StubVideo({ paused, volume: 0.8 });
    const { document } = makeDocument({
      videos: [first, second],
      videoMatches: { [youtubeMainSelector]: [first, second] },
    });

    assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1'), undefined);
    await assert.rejects(
      executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 0.1),
      /media tab is no longer available/,
    );
    assert.equal(first.volume, 0.2);
    assert.equal(second.volume, 0.8);
  }
});

test('hidden or detached site-player videos are not replaced by unrelated previews', async () => {
  for (const active of [
    new StubVideo({ hidden: true }),
    new StubVideo({ connected: false }),
    new StubVideo({ rectWidth: 0, rectHeight: 0 }),
  ]) {
    const preview = new StubVideo({ paused: false, volume: 0.9 });
    const { document } = makeDocument({
      videos: [preview, active],
      videoMatches: { [youtubeMainSelector]: [active] },
    });

    assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1'), undefined);
    await assert.rejects(
      executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'playPause'),
      /media tab is no longer available/,
    );
    assert.equal(preview.pauseCount, 0);
    assert.equal(preview.playCount, 0);
  }
});

test('execution rejects a player identity change after the advertised snapshot', async () => {
  const previouslyActive = new StubVideo({ paused: true, volume: 0.25 });
  const newlyActive = new StubVideo({ paused: true, volume: 0.75 });
  const videoMatches = { [youtubeMainSelector]: [previouslyActive] };
  const { document } = makeDocument({ videos: [previouslyActive, newlyActive], videoMatches });

  assert.equal(advertise(document).playerVolume, 0.25);
  videoMatches[youtubeMainSelector] = [newlyActive];
  await assert.rejects(
    executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'playPause'),
    /active media player changed/,
  );
  assert.equal(previouslyActive.playCount, 0);
  assert.equal(newlyActive.playCount, 0);

  assert.equal(advertise(document).playerVolume, 0.75);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'playPause');
  assert.equal(newlyActive.playCount, 1);
});

test('a player switch during asynchronous play fails without replaying on the new player', async () => {
  const first = new StubVideo({ paused: true });
  const second = new StubVideo({ paused: true });
  const videoMatches = { [youtubeMainSelector]: [first] };
  const { document } = makeDocument({ videos: [first, second], videoMatches });
  let finishPlay;
  first.play = () => {
    first.playCount += 1;
    return new Promise((resolve) => {
      finishPlay = () => {
        first.paused = false;
        resolve();
      };
    });
  };

  advertise(document);
  const action = executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'playPause');
  assert.equal(first.playCount, 1);
  videoMatches[youtubeMainSelector] = [second];
  finishPlay();
  await assert.rejects(action, /active media player changed while the command was running/);
  assert.equal(first.playCount, 1);
  assert.equal(second.playCount, 0);
});

test('muted playback reports effective zero volume and a positive adjustment unmutes it', async () => {
  const { document, video } = makeDocument();
  video.volume = 0.65;
  video.muted = true;

  assert.equal(advertise(document).playerVolume, 0);

  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 0.7);
  assert.equal(video.volume, 0.7);
  assert.equal(video.muted, false);
  assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.playerVolume, 0.7);

  video.muted = true;
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 0);
  assert.equal(video.muted, true);
  assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.playerVolume, 0);
});

test('playback, relative seek, and player volume act on the selected tab video', async () => {
  const { document, video } = makeDocument();
  advertise(document);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'playPause');
  assert.equal(video.paused, false);

  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', -20);
  assert.equal(video.currentTime, 0);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 0.7);
  assert.equal(video.volume, 0.7);
});

test('live DVR seeks clamp to the active seekable window instead of zero', async () => {
  const { document, video } = makeDocument();
  video.duration = Number.POSITIVE_INFINITY;
  video.currentTime = 112;
  video.seekable = {
    length: 1,
    start(index) {
      assert.equal(index, 0);
      return 100;
    },
    end(index) {
      assert.equal(index, 0);
      return 120;
    },
  };
  advertise(document);

  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', -30);
  assert.equal(video.currentTime, 100);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', 50);
  assert.equal(video.currentTime, 120);
});

test('live DVR seeks stay outside gaps and choose the nearest range boundary', async () => {
  const { document, video } = makeDocument();
  video.duration = Number.POSITIVE_INFINITY;
  video.currentTime = 120;
  video.seekable = {
    length: 2,
    start(index) {
      return index === 0 ? 100 : 130;
    },
    end(index) {
      return index === 0 ? 120 : 150;
    },
  };
  advertise(document);

  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', 4);
  assert.equal(video.currentTime, 120);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', 8);
  assert.equal(video.currentTime, 130);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', -8);
  assert.equal(video.currentTime, 120);
});

test('missing episode selectors fail clearly and are not replaced with keyboard shortcuts', async () => {
  const { document } = makeDocument();
  advertise(document, 'https://www.bilibili.com/video/BV1');
  await assert.rejects(
    executeMediaAction(document, 'https://www.bilibili.com/video/BV1', 'next'),
    /next episode control is unavailable/,
  );
  advertise(document);
  await assert.rejects(
    executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 2),
    /outside its supported range/,
  );
});
