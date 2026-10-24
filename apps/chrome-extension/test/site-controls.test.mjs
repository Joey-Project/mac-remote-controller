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

function makeDocument({ title = 'Example episode', controls = {} } = {}) {
  const video = new StubVideo();
  const document = {
    title,
    querySelector(selector) {
      if (selector === 'video') return video;
      return controls[selector];
    },
  };
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
  const next = {
    click() {},
    hasAttribute() {
      return false;
    },
    getAttribute() {
      return null;
    },
  };
  const previous = {
    click() {},
    hasAttribute() {
      return false;
    },
    getAttribute() {
      return null;
    },
  };
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
