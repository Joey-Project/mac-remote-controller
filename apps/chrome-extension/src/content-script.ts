import { executeMediaAction, readMediaTarget, type MediaAction } from './site-controls';

interface MediaCommandMessage {
  type: 'mediaCommand';
  requestId: string;
  action: MediaAction;
  value?: number;
}

let lastSnapshot = '';
let scheduledRefresh: number | undefined;
const observedVideos = new WeakSet<HTMLVideoElement>();

function notifyWorker(message: unknown): void {
  try {
    void chrome.runtime.sendMessage(message).catch(() => undefined);
  } catch {
    // The extension context can be invalidated while a tab is closing.
  }
}

function refreshTarget(force = false): void {
  const snapshot = readMediaTarget(document, location.href);
  const encoded = snapshot ? JSON.stringify(snapshot) : '';
  if (!force && encoded === lastSnapshot) return;
  lastSnapshot = encoded;
  notifyWorker({ type: 'mediaState', snapshot: snapshot ?? null });
}

function scheduleRefresh(): void {
  if (scheduledRefresh !== undefined) window.clearTimeout(scheduledRefresh);
  scheduledRefresh = window.setTimeout(() => {
    scheduledRefresh = undefined;
    refreshTarget();
  }, 120);
}

function observeVideo(): void {
  const video = document.querySelector('video');
  if (!video || observedVideos.has(video)) return;
  observedVideos.add(video);
  for (const eventName of ['loadedmetadata', 'emptied', 'play', 'pause', 'volumechange', 'ended']) {
    video.addEventListener(eventName, scheduleRefresh);
  }
}

chrome.runtime.onMessage.addListener((message: MediaCommandMessage) => {
  if (!message || message.type !== 'mediaCommand') return;
  void executeMediaAction(document, location.href, message.action, message.value)
    .then(() => {
      notifyWorker({
        type: 'mediaCommandResult',
        requestId: message.requestId,
        ok: true,
      });
    })
    .catch((error: unknown) => {
      notifyWorker({
        type: 'mediaCommandResult',
        requestId: message.requestId,
        ok: false,
        error: error instanceof Error ? error.message : 'The media action failed.',
      });
    });
  return false;
});

function installObservers(): void {
  if (!document.documentElement) {
    document.addEventListener('DOMContentLoaded', installObservers, { once: true });
    return;
  }
  const observer = new MutationObserver(() => {
    observeVideo();
    scheduleRefresh();
  });
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['src', 'class', 'aria-label', 'disabled'],
  });

  for (const eventName of ['popstate', 'hashchange', 'pageshow', 'yt-navigate-finish']) {
    window.addEventListener(eventName, () => {
      observeVideo();
      refreshTarget(true);
    });
  }

  observeVideo();
  refreshTarget(true);
  window.setInterval(() => {
    observeVideo();
    refreshTarget(true);
  }, 2_000);
}

installObservers();
