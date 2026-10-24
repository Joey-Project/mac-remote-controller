import assert from 'node:assert/strict';
import test from 'node:test';
import { executeMediaAction, readMediaTarget } from '../dist/site-controls.js';

class StubVideo {
  paused = true;
  duration = 30;
  currentTime = 10;
  volume = 0.5;
  muted = false;
  seekable = { length: 0 };

  async play() {
    this.paused = false;
  }

  pause() {
    this.paused = true;
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

  getClientRects() {
    return this.isConnected && this.styles.display !== 'none'
      ? [{ width: this.rectWidth, height: this.rectHeight }]
      : [];
  }

  click() {
    this.clickCount += 1;
  }
}

function makeDocument({ title = 'Example episode', controls = {} } = {}) {
  const video = new StubVideo();
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
      if (selector === 'video') return video;
      return controls[selector];
    },
  };
  for (const control of Object.values(controls)) {
    for (let ancestor = control; ancestor; ancestor = ancestor.parentElement) {
      ancestor.ownerDocument = document;
    }
  }
  return { document, video };
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

test('capabilities are derived from the current video and available episode controls', () => {
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

test('muted playback reports effective zero volume and a positive adjustment unmutes it', async () => {
  const { document, video } = makeDocument();
  video.volume = 0.65;
  video.muted = true;

  assert.equal(readMediaTarget(document, 'https://www.youtube.com/watch?v=1')?.playerVolume, 0);

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

  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', 4);
  assert.equal(video.currentTime, 120);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', 8);
  assert.equal(video.currentTime, 130);
  await executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'seek', -8);
  assert.equal(video.currentTime, 120);
});

test('missing episode selectors fail clearly and are not replaced with keyboard shortcuts', async () => {
  const { document } = makeDocument();
  await assert.rejects(
    executeMediaAction(document, 'https://www.bilibili.com/video/BV1', 'next'),
    /next episode control is unavailable/,
  );
  await assert.rejects(
    executeMediaAction(document, 'https://www.youtube.com/watch?v=1', 'setVolume', 2),
    /outside its supported range/,
  );
});
