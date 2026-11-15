import {
  bridgeConfiguration,
  iinaFormData,
  canNavigatePlaylist,
  createTargetID,
  maximumCommandsPerPoll,
  mpvPercentFromGainRatio,
  shouldUnmuteForGainRatio,
  targetSnapshot,
  validateAction,
} from './iina-controls';

const targetId = createTargetID();
const tickMilliseconds = 250;

let disconnected = false;
let running = false;
let wakePoll: (() => void) | undefined;
let connectionState = '';
const connectionItem = iina.menu.item('Sofa Remote: Connecting…', undefined, { enabled: false });
iina.menu.addItem(connectionItem);

function reportConnection(state: string): void {
  if (state === connectionState) return;
  connectionState = state;
  connectionItem.title = `Sofa Remote: ${state}`;
  iina.menu.forceUpdate();
  // Only static diagnostic categories are logged, never native error bodies,
  // tokens, media titles, paths, or command payloads.
  iina.console.log(`Sofa Remote connection: ${state}`);
}

class BridgeRequestError extends Error {
  constructor(readonly statusCode?: number) {
    super('The local media bridge request failed.');
  }
}

function failureState(error: unknown): string {
  if (!(error instanceof BridgeRequestError)) return 'Player unavailable; retrying';
  if (error.statusCode === 401 || error.statusCode === 403) {
    return 'Setup rejected; choose Set Up IINA in Sofa Remote';
  }
  if (error.statusCode !== undefined) return 'Bridge error; retrying';
  return 'Bridge unavailable; open Sofa Remote and enable media adapters';
}

function currentBridgeConfiguration() {
  return bridgeConfiguration(
    iina.preferences.get('bridge_port'),
    iina.preferences.get('bridge_token'),
  );
}

function refreshBridgeConfiguration(): void {
  const path = '@data/bridge.json';
  try {
    if (!iina.file.exists(path)) return;
    const file = iina.file.handle(path, 'read');
    if (!file) return;
    let bytes: Uint8Array | undefined;
    try {
      bytes = file.read(4097);
    } finally {
      file.close();
    }
    if (!bytes || bytes.length > 4096) return;
    const value: unknown = JSON.parse(String.fromCharCode(...bytes));
    if (typeof value !== 'object' || value === null) return;
    const fields = value as Record<string, unknown>;
    const configuration = bridgeConfiguration(fields.port, fields.token);
    if (!configuration) return;
    // IINA caches preferences in memory. Refresh only our two keys from the
    // companion's private file; no broad file-system permission is needed.
    iina.preferences.set('bridge_port', configuration.port);
    iina.preferences.set('bridge_token', configuration.token);
  } catch {
    // Keep manual setup usable if a managed file is absent or unreadable.
  }
}

async function request<T>(
  baseURL: string,
  token: string,
  method: 'get' | 'post',
  path: string,
  data?: Record<string, unknown>,
): Promise<T> {
  const options = {
    headers: { Authorization: `Bearer ${token}` },
    params: {} as Record<string, string>,
    data: method === 'post' ? iinaFormData(data ?? {}) : {},
  };
  let response: IINA.HTTPResponse<T>;
  try {
    response =
      method === 'get'
        ? await iina.http.get<unknown, T>(`${baseURL}${path}`, options)
        : await iina.http.post<unknown, T>(`${baseURL}${path}`, options);
  } catch (error) {
    const value =
      typeof error === 'object' && error !== null && 'statusCode' in error
        ? error.statusCode
        : undefined;
    const statusCode =
      typeof value === 'number' && Number.isInteger(value) && value >= 100 && value <= 599
        ? value
        : undefined;
    throw new BridgeRequestError(statusCode);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new BridgeRequestError(response.statusCode);
  }
  return response.data as T;
}

function snapshot() {
  const maximumMpvPercent = iina.mpv.getNumber('volume-max');
  return targetSnapshot({
    targetId,
    title: iina.core.status.title,
    idle: iina.core.status.idle,
    position: iina.core.status.position,
    duration: iina.core.status.duration,
    mpvVolumePercent: iina.core.audio.volume,
    maximumMpvPercent,
    muted: iina.core.audio.muted,
    playlistCount: iina.playlist.count(),
    playlistPosition: iina.mpv.getNumber('playlist-pos'),
  });
}

async function execute(action: string, value: number | undefined): Promise<void> {
  if (iina.core.status.idle) {
    throw new Error('IINA is idle; the media command was not applied.');
  }
  const maximumMpvPercent = iina.mpv.getNumber('volume-max');
  validateAction(action, value, maximumMpvPercent);
  switch (action) {
    case 'playPause':
      if (iina.core.status.paused) iina.core.resume();
      else iina.core.pause();
      return;
    case 'seek':
      iina.core.seek(value!, true);
      return;
    case 'next':
      if (!canNavigatePlaylist('next', iina.playlist.count(), iina.mpv.getNumber('playlist-pos'))) {
        throw new Error('IINA has no next playlist item.');
      }
      iina.playlist.playNext();
      return;
    case 'previous':
      if (
        !canNavigatePlaylist('previous', iina.playlist.count(), iina.mpv.getNumber('playlist-pos'))
      ) {
        throw new Error('IINA has no previous playlist item.');
      }
      iina.playlist.playPrevious();
      return;
    case 'setVolume':
      // IINA's core.audio proxy setter returns undefined, which throws after
      // applying an assignment in strict mode. The mpv API has no proxy trap.
      iina.mpv.set('volume', mpvPercentFromGainRatio(value!, maximumMpvPercent)!);
      if (shouldUnmuteForGainRatio(value!)) iina.mpv.set('mute', false);
      return;
    default:
      throw new Error('Unsupported media action.');
  }
}

async function pollOnce(configuration: { port: number; token: string }): Promise<number> {
  const baseURL = `http://127.0.0.1:${configuration.port}/v1/iina`;
  const state = snapshot();
  if (iina.core.status.idle) {
    await request(baseURL, configuration.token, 'post', '/unregister', { targetId });
    return 0;
  }
  await request(baseURL, configuration.token, 'post', '/update', state.target);
  if (disconnected) return 0;
  let completed = 0;
  while (!disconnected && completed < maximumCommandsPerPoll) {
    const result = await request<{
      command?: { requestId: string; targetId: string; action: string; value?: number };
    }>(baseURL, configuration.token, 'get', `/next?targetId=${encodeURIComponent(targetId)}`);
    if (disconnected) break;
    const command = result.command;
    if (!command) break;
    let error: string | undefined;
    try {
      if (command.targetId !== targetId || typeof command.requestId !== 'string') {
        throw new Error('The media command target did not match this IINA window.');
      }
      await execute(command.action, command.value);
    } catch (caught) {
      error = caught instanceof Error ? caught.message : 'IINA could not complete the command.';
    }
    await request(baseURL, configuration.token, 'post', '/result', {
      requestId: command.requestId,
      targetId,
      ok: error === undefined,
      ...(error ? { error: error.slice(0, 1024) } : {}),
    });
    completed += 1;
  }
  return completed;
}

async function runLoop(): Promise<void> {
  if (running || disconnected) return;
  running = true;
  refreshBridgeConfiguration();
  let failures = 0;
  while (!disconnected) {
    const started = Date.now();
    let completed = 0;
    try {
      let configuration = currentBridgeConfiguration();
      if (!configuration) {
        refreshBridgeConfiguration();
        configuration = currentBridgeConfiguration();
      }
      if (configuration) {
        completed = await pollOnce(configuration);
        if (!disconnected) {
          reportConnection(iina.core.status.idle ? 'Connected; open a video' : 'Connected');
        }
      } else {
        reportConnection('Setup required; choose Set Up IINA in Sofa Remote');
      }
      failures = 0;
    } catch (error) {
      if (disconnected) break;
      failures = Math.min(failures + 1, 4);
      reportConnection(failureState(error));
      if (!disconnected) refreshBridgeConfiguration();
    }
    if (disconnected) break;
    // A full batch yields to IINA's event loop before continuing. Otherwise
    // keep the existing 250 ms polling cadence without delaying each command.
    const delay =
      failures > 0
        ? Math.max(0, tickMilliseconds * 2 ** (failures - 1) - (Date.now() - started))
        : completed === maximumCommandsPerPoll
          ? 0
          : Math.max(0, tickMilliseconds - (Date.now() - started));
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        wakePoll = undefined;
        resolve();
      }, delay);
      wakePoll = () => {
        clearTimeout(timer);
        wakePoll = undefined;
        resolve();
      };
    });
  }
  running = false;
  await unregisterTarget();
}

function unregister(): void {
  if (disconnected) return;
  disconnected = true;
  wakePoll?.();
  // Finish the one in-flight request before unregistering. A late /next
  // response must never operate on a closing player or start another poll.
  if (!running) void unregisterTarget();
}

async function unregisterTarget(): Promise<void> {
  const configuration = currentBridgeConfiguration();
  if (!configuration) return;
  const baseURL = `http://127.0.0.1:${configuration.port}/v1/iina`;
  await request(baseURL, configuration.token, 'post', '/unregister', { targetId }).catch(
    () => undefined,
  );
}

iina.event.on('iina.window-loaded', () => {
  void runLoop();
});
iina.event.on('iina.window-will-close', unregister);
void runLoop();
