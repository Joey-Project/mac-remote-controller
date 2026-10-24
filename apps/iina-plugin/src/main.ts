import {
  iinaFormData,
  mpvPercentFromGainRatio,
  shouldUnmuteForGainRatio,
  targetSnapshot,
  validateAction,
} from './iina-controls';

const targetId = `iina:${crypto.randomUUID()}`;
const bridgePort = iina.preferences.get('bridge_port') as number;
const bridgeToken = iina.preferences.get('bridge_token') as string;
const baseURL = `http://127.0.0.1:${bridgePort}/v1/iina`;
const tickMilliseconds = 250;

let disconnected = false;
let running = false;

function authHeaders(): Record<string, string> {
  return { Authorization: `Bearer ${bridgeToken}` };
}

async function request<T>(
  method: 'get' | 'post',
  path: string,
  data?: Record<string, unknown>,
): Promise<T> {
  const options = {
    headers: authHeaders(),
    params: {} as Record<string, string>,
    data: method === 'post' ? iinaFormData(data ?? {}) : {},
  };
  const response =
    method === 'get'
      ? await iina.http.get<unknown, T>(`${baseURL}${path}`, options)
      : await iina.http.post<unknown, T>(`${baseURL}${path}`, options);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw new Error(`Sofa Remote bridge returned HTTP ${response.statusCode}.`);
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
      if (iina.playlist.count() <= 1) throw new Error('IINA has no next playlist item.');
      iina.playlist.playNext();
      return;
    case 'previous':
      if (iina.playlist.count() <= 1) throw new Error('IINA has no previous playlist item.');
      iina.playlist.playPrevious();
      return;
    case 'setVolume':
      iina.core.audio.volume = mpvPercentFromGainRatio(value!, maximumMpvPercent)!;
      if (shouldUnmuteForGainRatio(value!)) iina.core.audio.muted = false;
      return;
    default:
      throw new Error('Unsupported media action.');
  }
}

async function pollOnce(): Promise<void> {
  const state = snapshot();
  if (iina.core.status.idle) {
    await request('post', '/unregister', { targetId });
    return;
  }
  await request('post', '/update', state.target);
  const result = await request<{
    command?: { requestId: string; targetId: string; action: string; value?: number };
  }>('get', `/next?targetId=${encodeURIComponent(targetId)}`);
  const command = result.command;
  if (!command) return;
  let error: string | undefined;
  try {
    if (command.targetId !== targetId || typeof command.requestId !== 'string') {
      throw new Error('The media command target did not match this IINA window.');
    }
    await execute(command.action, command.value);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : 'IINA could not complete the command.';
  }
  await request('post', '/result', {
    requestId: command.requestId,
    targetId,
    ok: error === undefined,
    ...(error ? { error: error.slice(0, 1024) } : {}),
  });
}

async function runLoop(): Promise<void> {
  if (
    running ||
    disconnected ||
    !Number.isInteger(bridgePort) ||
    bridgePort < 1 ||
    bridgePort > 65_535 ||
    bridgeToken.length < 32
  ) {
    return;
  }
  running = true;
  while (!disconnected) {
    const started = Date.now();
    try {
      await pollOnce();
    } catch {
      // Keep the token out of logs. Connection state is visible through the local companion.
    }
    const delay = Math.max(0, tickMilliseconds - (Date.now() - started));
    await new Promise<void>((resolve) => setTimeout(resolve, delay));
  }
  running = false;
}

function unregister(): void {
  disconnected = true;
  void request('post', '/unregister', { targetId }).catch(() => undefined);
}

iina.event.on('iina.window-loaded', () => {
  void runLoop();
});
iina.event.on('iina.window-will-close', unregister);
void runLoop();
