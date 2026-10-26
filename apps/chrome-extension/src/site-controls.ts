type SiteKind = 'youtube' | 'bilibili';
export type MediaAction = 'playPause' | 'seek' | 'next' | 'previous' | 'setVolume';

interface SiteAdapter {
  hostnames: ReadonlySet<string>;
  kind: SiteKind;
  videoSelectors: readonly string[];
  controlRootSelectors: readonly string[];
  next: readonly string[];
  previous: readonly string[];
}

export interface TargetSnapshot {
  kind: SiteKind;
  name: string;
  capabilities: {
    playPause: boolean;
    seek: boolean;
    next: boolean;
    previous: boolean;
    playerVolumeMaximum: 1;
  };
  playerVolume: number;
}

const siteAdapters: readonly SiteAdapter[] = [
  {
    hostnames: new Set(['www.youtube.com']),
    kind: 'youtube',
    videoSelectors: [
      'ytd-reel-video-renderer[is-active] video',
      '#movie_player video.html5-main-video',
    ],
    controlRootSelectors: ['ytd-reel-video-renderer[is-active]', '#movie_player'],
    next: ['.ytp-next-button'],
    previous: ['.ytp-prev-button'],
  },
  {
    hostnames: new Set(['www.bilibili.com', 'bilibili.com']),
    kind: 'bilibili',
    videoSelectors: ['.bpx-player-video-wrap video'],
    controlRootSelectors: ['.bpx-player-container', '#bilibiliPlayer'],
    next: ['.bpx-player-ctrl-btn.bpx-player-ctrl-next', 'button[aria-label*="下一集"]'],
    previous: ['.bpx-player-ctrl-btn.bpx-player-ctrl-prev', 'button[aria-label*="上一集"]'],
  },
];

const advertisedVideoByDocument = new WeakMap<Document, HTMLVideoElement | null>();

function adapterForURL(url: string): SiteAdapter | undefined {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') return undefined;
    return siteAdapters.find((adapter) => adapter.hostnames.has(parsed.hostname));
  } catch {
    return undefined;
  }
}

function videoForDocument(document: Document, adapter: SiteAdapter): HTMLVideoElement | undefined {
  for (const selector of adapter.videoSelectors) {
    const matches = Array.from(document.querySelectorAll<HTMLVideoElement>(selector));
    if (matches.length === 0) continue;

    const rendered = matches.filter(
      (video) =>
        typeof video.play === 'function' && typeof video.pause === 'function' && isRendered(video),
    );
    if (rendered.length === 0) continue;

    const playing = rendered.filter((video) => !video.paused);
    if (playing.length === 1) return playing[0];
    if (playing.length > 1) return undefined;
    return rendered.length === 1 ? rendered[0] : undefined;
  }
  return undefined;
}

interface SeekableRange {
  start: number;
  end: number;
}

function readSeekableRanges(video: HTMLVideoElement): SeekableRange[] {
  const ranges: SeekableRange[] = [];
  for (let index = 0; index < video.seekable.length; index += 1) {
    try {
      const start = video.seekable.start(index);
      const end = video.seekable.end(index);
      if (Number.isFinite(start) && Number.isFinite(end) && end >= start) {
        ranges.push({ start, end });
      }
    } catch {
      // The live window can change while the browser exposes the TimeRanges.
    }
  }
  return ranges.sort((left, right) => left.start - right.start);
}

function clampToSeekableRanges(target: number, direction: number, ranges: SeekableRange[]): number {
  let previous: SeekableRange | undefined;
  for (const range of ranges) {
    if (target < range.start) {
      if (!previous) return range.start;
      const previousDistance = target - previous.end;
      const nextDistance = range.start - target;
      if (previousDistance === nextDistance) {
        return direction > 0 ? range.start : previous.end;
      }
      return previousDistance < nextDistance ? previous.end : range.start;
    }
    if (target <= range.end) return target;
    previous = range;
  }
  return previous?.end ?? target;
}

function isRendered(element: HTMLElement): boolean {
  if (!element.isConnected) return false;
  const view = element.ownerDocument.defaultView;
  if (!view) return false;

  for (let ancestor: Element | null = element; ancestor; ancestor = ancestor.parentElement) {
    if (ancestor.hasAttribute('hidden')) return false;
    const style = view.getComputedStyle(ancestor);
    if (style.display === 'none' || style.getPropertyValue('content-visibility') === 'hidden') {
      return false;
    }
    const opacity = Number.parseFloat(style.opacity);
    if (Number.isFinite(opacity) && opacity <= 0) return false;
  }

  const visibility = view.getComputedStyle(element).visibility;
  if (visibility === 'hidden' || visibility === 'collapse') return false;
  return Array.from(element.getClientRects()).some((rect) => rect.width > 0 && rect.height > 0);
}

function closestMatchingElement(
  element: Element,
  selectors: readonly string[],
): Element | undefined {
  for (let ancestor: Element | null = element; ancestor; ancestor = ancestor.parentElement) {
    if (selectors.some((selector) => ancestor.matches(selector))) return ancestor;
  }
  return undefined;
}

function findFirst(
  root: Element | undefined,
  selectors: readonly string[],
): HTMLElement | undefined {
  if (!root) return undefined;
  for (const selector of selectors) {
    const element = root.querySelector<HTMLElement>(selector);
    if (
      element &&
      typeof element.click === 'function' &&
      isRendered(element) &&
      !element.hasAttribute('disabled') &&
      element.getAttribute('aria-disabled') !== 'true'
    ) {
      return element;
    }
  }
  return undefined;
}

export function readMediaTarget(document: Document, url: string): TargetSnapshot | undefined {
  const adapter = adapterForURL(url);
  const video = adapter ? videoForDocument(document, adapter) : undefined;
  advertisedVideoByDocument.set(document, video ?? null);
  if (!adapter || !video) return undefined;
  const controlRoot = closestMatchingElement(video, adapter.controlRootSelectors);
  const title = truncateUTF8((document.title || adapter.kind).trim(), 230);
  return {
    kind: adapter.kind,
    name: `${adapter.kind === 'youtube' ? 'YouTube' : 'Bilibili'} · ${title}`,
    capabilities: {
      playPause: true,
      seek: Number.isFinite(video.duration) || video.seekable.length > 0,
      next: Boolean(findFirst(controlRoot, adapter.next)),
      previous: Boolean(findFirst(controlRoot, adapter.previous)),
      playerVolumeMaximum: 1,
    },
    playerVolume: video.muted
      ? 0
      : Math.min(1, Math.max(0, Number.isFinite(video.volume) ? video.volume : 0)),
  };
}

function truncateUTF8(value: string, maximum: number): string {
  let result = '';
  const encoder = new TextEncoder();
  for (const character of value) {
    if (encoder.encode(result + character).byteLength > maximum) break;
    result += character;
  }
  return result;
}

export async function executeMediaAction(
  document: Document,
  url: string,
  action: MediaAction,
  value?: number,
): Promise<void> {
  const adapter = adapterForURL(url);
  const video = adapter ? videoForDocument(document, adapter) : undefined;
  if (!adapter || !video) {
    advertisedVideoByDocument.set(document, null);
    throw new Error('This media tab is no longer available.');
  }
  if (
    !advertisedVideoByDocument.has(document) ||
    advertisedVideoByDocument.get(document) !== video
  ) {
    throw new Error(
      'The active media player changed; refresh the target before sending another command.',
    );
  }
  switch (action) {
    case 'playPause':
      if (video.paused) {
        await video.play();
        if (videoForDocument(document, adapter) !== video) {
          throw new Error('The active media player changed while the command was running.');
        }
      } else video.pause();
      return;
    case 'seek': {
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        value === 0 ||
        Math.abs(value) > 3_600
      ) {
        throw new Error('Invalid seek amount.');
      }
      const currentTime = video.currentTime;
      const targetTime = currentTime + value;
      if (!Number.isFinite(currentTime) || !Number.isFinite(targetTime)) {
        throw new Error('This video cannot seek yet.');
      }
      if (Number.isFinite(video.duration)) {
        const maximum = Math.max(0, video.duration - 0.25);
        video.currentTime = Math.min(maximum, Math.max(0, targetTime));
        return;
      }
      const ranges = readSeekableRanges(video);
      if (ranges.length === 0) throw new Error('This video cannot seek yet.');
      video.currentTime = clampToSeekableRanges(targetTime, value, ranges);
      return;
    }
    case 'setVolume':
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
        throw new Error('This player volume is outside its supported range.');
      }
      video.volume = value;
      if (value > 0) video.muted = false;
      return;
    case 'next':
    case 'previous': {
      const controlRoot = closestMatchingElement(video, adapter.controlRootSelectors);
      const control = findFirst(controlRoot, action === 'next' ? adapter.next : adapter.previous);
      if (!control) {
        throw new Error(
          `The ${action === 'next' ? 'next' : 'previous'} episode control is unavailable.`,
        );
      }
      control.click();
      return;
    }
  }
}
