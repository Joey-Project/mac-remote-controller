interface TargetSnapshot {
  kind: 'youtube' | 'bilibili';
  name: string;
  capabilities: {
    playPause: boolean;
    seek: boolean;
    next: boolean;
    previous: boolean;
    playerVolumeMaximum: number;
  };
  playerVolume: number;
}

interface MediaStateMessage {
  type: 'mediaState';
  snapshot: TargetSnapshot | null;
}

interface MediaCommandResultMessage {
  type: 'mediaCommandResult';
  requestId: string;
  ok: boolean;
  error?: string;
}

interface NativeMediaCommand {
  type: 'media.command';
  requestId: string;
  targetId: string;
  action: 'playPause' | 'seek' | 'next' | 'previous' | 'setVolume';
  value?: number;
}

const HOST_NAME = 'com.joeyteng.sofaremote';
const maximumPendingCommands = 8;
const nativeMessageByteLimit = 64 * 1024;
const targetRefreshIntervalMilliseconds = 2_000;

const commandForTab = new Map<string, { tabId: number; targetId: string; timeout: number }>();
const knownMediaTabs = new Set<number>();
let nativePort: chrome.runtime.Port | undefined;

function allowedKindForURL(url: string | undefined): 'youtube' | 'bilibili' | undefined {
  if (!url) return undefined;
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') return undefined;
    if (parsed.hostname === 'www.youtube.com') return 'youtube';
    if (parsed.hostname === 'bilibili.com' || parsed.hostname === 'www.bilibili.com') {
      return 'bilibili';
    }
  } catch {
    return undefined;
  }
  return undefined;
}

function ensureNativePort(): chrome.runtime.Port | undefined {
  if (nativePort) return nativePort;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    nativePort = port;
    port.onMessage.addListener((message: unknown) => receiveNativeMessage(port, message));
    port.onDisconnect.addListener(() => {
      if (nativePort === port) nativePort = undefined;
      for (const pending of commandForTab.values()) clearTimeout(pending.timeout);
      commandForTab.clear();
    });
    return port;
  } catch {
    return undefined;
  }
}

function postToNative(message: unknown): boolean {
  const port = ensureNativePort();
  if (!port) return false;
  const encoded = JSON.stringify(message);
  if (new TextEncoder().encode(encoded).byteLength > nativeMessageByteLimit) return false;
  try {
    port.postMessage(message);
    return true;
  } catch {
    if (nativePort === port) nativePort = undefined;
    return false;
  }
}

function markTargetUnavailable(tabId: number): void {
  knownMediaTabs.delete(tabId);
  postToNative({ type: 'media.targetUnavailable', targetId: `chrome:${tabId}` });
}

function refreshKnownTargets(): void {
  if (!nativePort || knownMediaTabs.size === 0) return;
  for (const tabId of knownMediaTabs) {
    try {
      void chrome.tabs.sendMessage(tabId, { type: 'mediaRefresh' }).catch(() => undefined);
    } catch {
      markTargetUnavailable(tabId);
    }
  }
}

function validateSnapshot(
  value: unknown,
  expectedKind: 'youtube' | 'bilibili',
): TargetSnapshot | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const candidate = value as Partial<TargetSnapshot>;
  const caps = candidate.capabilities;
  if (candidate.kind !== expectedKind || typeof candidate.name !== 'string' || !caps) {
    return undefined;
  }
  if (candidate.name.length === 0 || new TextEncoder().encode(candidate.name).byteLength > 256) {
    return undefined;
  }
  if (
    typeof caps.playPause !== 'boolean' ||
    typeof caps.seek !== 'boolean' ||
    typeof caps.next !== 'boolean' ||
    typeof caps.previous !== 'boolean' ||
    caps.playerVolumeMaximum !== 1 ||
    typeof candidate.playerVolume !== 'number' ||
    !Number.isFinite(candidate.playerVolume) ||
    candidate.playerVolume < 0 ||
    candidate.playerVolume > 1
  )
    return undefined;
  return candidate as TargetSnapshot;
}

function sendCommandResult(requestId: string, targetId: string, ok: boolean, error?: string): void {
  const payload: Record<string, unknown> = {
    type: 'media.commandResult',
    targetId,
    requestId,
    ok,
  };
  if (error) payload.error = error.slice(0, 1_024);
  postToNative(payload);
}

function isValidCommand(message: NativeMediaCommand): boolean {
  if (
    typeof message.requestId !== 'string' ||
    message.requestId.length > 128 ||
    !/^chrome:[1-9][0-9]{0,9}$/.test(message.targetId)
  )
    return false;
  switch (message.action) {
    case 'playPause':
    case 'next':
    case 'previous':
      return (
        message.value === undefined &&
        Object.keys(message).sort().join(',') === 'action,requestId,targetId,type'
      );
    case 'seek':
      return (
        typeof message.value === 'number' &&
        Number.isFinite(message.value) &&
        message.value !== 0 &&
        Math.abs(message.value) <= 3_600 &&
        Object.keys(message).sort().join(',') === 'action,requestId,targetId,type,value'
      );
    case 'setVolume':
      return (
        typeof message.value === 'number' &&
        Number.isFinite(message.value) &&
        message.value >= 0 &&
        message.value <= 1 &&
        Object.keys(message).sort().join(',') === 'action,requestId,targetId,type,value'
      );
  }
}

function receiveNativeMessage(port: chrome.runtime.Port, value: unknown): void {
  if (!value || typeof value !== 'object') return;
  const message = value as Partial<NativeMediaCommand>;
  if (message.type !== 'media.command' || !isValidCommand(message as NativeMediaCommand)) return;
  if (commandForTab.size >= maximumPendingCommands || commandForTab.has(message.requestId!)) {
    sendCommandResult(message.requestId!, message.targetId!, false, 'The browser is busy.');
    return;
  }
  const tabId = Number(message.targetId!.slice('chrome:'.length));
  const timeout = setTimeout(() => {
    const pending = commandForTab.get(message.requestId!);
    if (!pending) return;
    commandForTab.delete(message.requestId!);
    sendCommandResult(
      message.requestId!,
      pending.targetId,
      false,
      'The browser tab did not respond.',
    );
  }, 4_000);
  commandForTab.set(message.requestId!, { tabId, targetId: message.targetId!, timeout });
  try {
    chrome.tabs.sendMessage(
      tabId,
      {
        type: 'mediaCommand',
        requestId: message.requestId,
        action: message.action,
        value: message.value,
      },
      () => {
        if (chrome.runtime.lastError) {
          const pending = commandForTab.get(message.requestId!);
          if (!pending) return;
          clearTimeout(pending.timeout);
          commandForTab.delete(message.requestId!);
          sendCommandResult(
            message.requestId!,
            pending.targetId,
            false,
            'The selected browser tab is closed.',
          );
        }
      },
    );
  } catch {
    const pending = commandForTab.get(message.requestId!);
    if (pending) {
      clearTimeout(pending.timeout);
      commandForTab.delete(message.requestId!);
      sendCommandResult(
        message.requestId!,
        pending.targetId,
        false,
        'The selected browser tab is closed.',
      );
    }
  }
}

chrome.runtime.onMessage.addListener(
  (message: MediaStateMessage | MediaCommandResultMessage, sender) => {
    const tabId = sender.tab?.id;
    const expectedKind = allowedKindForURL(sender.url ?? sender.tab?.url);
    if (tabId === undefined || sender.frameId !== 0 || !expectedKind) return false;

    if (message?.type === 'mediaState') {
      if (message.snapshot === null) {
        markTargetUnavailable(tabId);
        return false;
      }
      const snapshot = validateSnapshot(message.snapshot, expectedKind);
      if (!snapshot) return false;
      knownMediaTabs.add(tabId);
      postToNative({ type: 'media.targetUpdate', targetId: `chrome:${tabId}`, target: snapshot });
      return false;
    }

    if (message?.type === 'mediaCommandResult') {
      const pending = commandForTab.get(message.requestId);
      if (!pending || pending.tabId !== tabId) return false;
      clearTimeout(pending.timeout);
      commandForTab.delete(message.requestId);
      sendCommandResult(message.requestId, pending.targetId, message.ok === true, message.error);
    }
    return false;
  },
);

chrome.tabs.onRemoved.addListener((tabId) => {
  markTargetUnavailable(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (knownMediaTabs.has(tabId) && changeInfo.url && !allowedKindForURL(changeInfo.url)) {
    markTargetUnavailable(tabId);
  }
});

setInterval(refreshKnownTargets, targetRefreshIntervalMilliseconds);

chrome.runtime.onStartup.addListener(() => {
  ensureNativePort();
});
chrome.runtime.onInstalled.addListener(() => {
  ensureNativePort();
});
