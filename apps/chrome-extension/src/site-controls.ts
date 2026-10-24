type SiteKind = 'youtube' | 'bilibili';
export type MediaAction = 'playPause' | 'seek' | 'next' | 'previous' | 'setVolume';

interface SiteAdapter {
  hostnames: ReadonlySet<string>;
  kind: SiteKind;
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
    next: ['.ytp-next-button'],
    previous: ['.ytp-prev-button'],
  },
  {
    hostnames: new Set(['www.bilibili.com', 'bilibili.com']),
    kind: 'bilibili',
    next: ['.bpx-player-ctrl-btn.bpx-player-ctrl-next', 'button[aria-label*="下一集"]'],
    previous: ['.bpx-player-ctrl-btn.bpx-player-ctrl-prev', 'button[aria-label*="上一集"]'],
  },
];

function adapterForURL(url: string): SiteAdapter | undefined {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') return undefined;
    return siteAdapters.find((adapter) => adapter.hostnames.has(parsed.hostname));
  } catch {
    return undefined;
  }
}

function videoForDocument(document: Document): HTMLVideoElement | undefined {
  const video = document.querySelector('video');
  if (!video || typeof video.play !== 'function' || typeof video.pause !== 'function')
    return undefined;
  return video;
}

function findFirst(document: Document, selectors: readonly string[]): HTMLElement | undefined {
  for (const selector of selectors) {
    const element = document.querySelector<HTMLElement>(selector);
    if (
      element &&
      typeof element.click === 'function' &&
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
  const video = videoForDocument(document);
  if (!adapter || !video) return undefined;
  const title = truncateUTF8((document.title || adapter.kind).trim(), 230);
  return {
    kind: adapter.kind,
    name: `${adapter.kind === 'youtube' ? 'YouTube' : 'Bilibili'} · ${title}`,
    capabilities: {
      playPause: true,
      seek: Number.isFinite(video.duration) || video.seekable.length > 0,
      next: Boolean(findFirst(document, adapter.next)),
      previous: Boolean(findFirst(document, adapter.previous)),
      playerVolumeMaximum: 1,
    },
    playerVolume: Math.min(1, Math.max(0, Number.isFinite(video.volume) ? video.volume : 0)),
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
  const video = videoForDocument(document);
  if (!adapter || !video) throw new Error('This media tab is no longer available.');
  switch (action) {
    case 'playPause':
      if (video.paused) await video.play();
      else video.pause();
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
      if (!Number.isFinite(video.duration) && video.seekable.length === 0) {
        throw new Error('This video cannot seek yet.');
      }
      const maximum = Number.isFinite(video.duration)
        ? Math.max(0, video.duration - 0.25)
        : video.seekable.end(video.seekable.length - 1);
      video.currentTime = Math.min(maximum, Math.max(0, video.currentTime + value));
      return;
    }
    case 'setVolume':
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
        throw new Error('This player volume is outside its supported range.');
      }
      video.volume = value;
      return;
    case 'next':
    case 'previous': {
      const control = findFirst(document, action === 'next' ? adapter.next : adapter.previous);
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
