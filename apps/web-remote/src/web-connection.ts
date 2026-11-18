import { RemoteInputBuffer, type InputCommand } from './remote-input.js';
import { readMediaTargets, type MediaTarget } from './media-model.js';
import { isSessionAction, type SessionState } from './session-controls.js';
import { requiresKeyboardControls } from './keyboard-controls.js';

export type WebRemoteState = SessionState &
  Readonly<{
    accessibilityGranted: boolean;
    supportsGestures: boolean;
    deviceName: string;
    systemVolume: number | null;
    mediaTargets: readonly MediaTarget[] | null;
  }>;
export type WebRemoteStatus =
  'disconnected' | 'connecting' | 'connected' | 'pairing' | 'reconnecting';
type Socket = Pick<
  WebSocket,
  'readyState' | 'bufferedAmount' | 'send' | 'close' | 'addEventListener'
>;
type Options = Readonly<{
  origin: string;
  input: RemoteInputBuffer;
  onStatus: (status: WebRemoteStatus) => void;
  onError: (message: string) => void;
  onState: (state: WebRemoteState) => void;
  onResult?: (command: InputCommand, error: string | null) => void;
  createSocket?: (url: string) => Socket;
  request?: typeof fetch;
  active?: () => boolean;
  now?: () => number;
}>;
type Pending = { sequence: number; at: number; timeout: number; command: InputCommand | null };

/** The only endpoint is the page's own HTTPS origin. No JS bearer-token storage. */
export class WebRemoteConnection {
  private readonly origin: string;
  private socket: Socket | null = null;
  private connectionID: string | null = null;
  private sequence = 0;
  private generation = 0;
  private wanted = false;
  private retries = 0;
  private lastSentAt = 0;
  private lastGestureSentAt = 0;
  private extendedKeyboardAvailable = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private readonly pending = new Map<string, Pending>();

  constructor(private readonly options: Options) {
    const origin = new URL(options.origin);
    if (origin.protocol !== 'https:' || origin.origin !== options.origin) {
      throw new Error('Web remote requires its own HTTPS origin.');
    }
    this.origin = origin.origin;
  }

  async connect(): Promise<void> {
    this.disconnect();
    this.wanted = true;
    this.retries = 0;
    await this.open();
  }

  disconnect(): void {
    this.wanted = false;
    this.options.input.cancelGesture();
    this.clear();
    this.options.onStatus('disconnected');
  }

  fail(): void {
    if (!this.wanted) return;
    this.clear();
    if (!(this.options.active?.() ?? true) || this.retries >= 30) {
      this.wanted = false;
      this.options.onStatus('disconnected');
      this.options.onError('Connection lost. Reconnect when the Mac is available.');
      return;
    }
    this.options.onStatus('reconnecting');
    const delay = Math.min(15_000, 500 * 2 ** Math.min(this.retries++, 5));
    this.timer = setTimeout(() => {
      void this.open();
    }, delay);
  }

  async beginPairing(name: string): Promise<string> {
    const value = await this.api('/api/pairing/start', { name });
    if (typeof value['requestId'] !== 'string') throw new Error('Invalid pairing response.');
    return value['requestId'];
  }

  async confirmPairing(requestId: string, code: string): Promise<void> {
    await this.api('/api/pairing/confirm', { requestId, code });
    if (this.options.active?.() ?? true) await this.connect();
  }

  async forget(): Promise<void> {
    this.disconnect();
    await this.api('/api/pairing/forget', {});
    this.options.onStatus('pairing');
  }

  private async open(): Promise<void> {
    if (!this.wanted) return;
    const generation = ++this.generation;
    this.options.onStatus(this.retries ? 'reconnecting' : 'connecting');
    try {
      const status = await this.api('/api/status');
      if (generation !== this.generation || !this.wanted) return;
      if (status['paired'] !== true) {
        this.wanted = false;
        this.options.onStatus('pairing');
        return;
      }
      const url = new URL('/remote', this.origin);
      url.protocol = 'wss:';
      const socket = (this.options.createSocket ?? ((url) => new WebSocket(url)))(url.href);
      this.socket = socket;
      socket.addEventListener('message', (event) => {
        if (this.socket === socket && generation === this.generation) this.receive(event.data);
      });
      socket.addEventListener('close', (event) => {
        if (this.socket !== socket) return;
        if (event.code === 1008) {
          this.wanted = false;
          this.clear();
          this.options.onStatus('disconnected');
          this.options.onError('The Mac ended this session. Reconnect to continue.');
        } else this.fail();
      });
      socket.addEventListener('error', () => {
        if (this.socket === socket) this.fail();
      });
      this.timer = setTimeout(() => {
        if (this.socket === socket) this.fail();
      }, 5000);
    } catch {
      if (generation === this.generation && this.wanted) this.fail();
    }
  }

  private receive(raw: unknown): void {
    try {
      if (typeof raw !== 'string' || new TextEncoder().encode(raw).length > 65_536)
        throw new Error();
      const value: unknown = JSON.parse(raw);
      if (!record(value) || value['protocolVersion'] !== 1 || 'authToken' in value)
        throw new Error();
      if (value['type'] === 'welcome') {
        if (
          this.connectionID ||
          typeof value['connectionId'] !== 'string' ||
          !value['connectionId'] ||
          value['connectionId'].length > 128
        )
          throw new Error();
        const state = readState(value['state']);
        this.extendedKeyboardAvailable =
          state.accessibilityGranted && state.capabilities.includes('keyboardControls.v1');
        this.connectionID = value['connectionId'];
        this.retries = 0;
        this.lastSentAt = this.now();
        this.options.input.connect((command) => this.send('command', command));
        this.options.onState(state);
        this.options.onStatus('connected');
        this.heartbeat();
        return;
      }
      if (!this.connectionID || value['connectionId'] !== this.connectionID) throw new Error();
      if (value['type'] === 'state') {
        const state = readState(value['state']);
        this.extendedKeyboardAvailable =
          state.accessibilityGranted && state.capabilities.includes('keyboardControls.v1');
        this.options.onState(state);
        return;
      }
      if (value['type'] !== 'result' && value['type'] !== 'pong') throw new Error();
      if (typeof value['requestId'] !== 'string') throw new Error();
      const pending = this.pending.get(value['requestId']);
      if (
        !pending ||
        pending.sequence !== value['sequence'] ||
        (pending.command === null) !== (value['type'] === 'pong')
      )
        throw new Error();
      this.pending.delete(value['requestId']);
      const failure = value['error'];
      if (
        failure !== undefined &&
        (!record(failure) ||
          typeof failure['message'] !== 'string' ||
          failure['message'].length > 1024)
      )
        throw new Error();
      const message = record(failure) ? String(failure['message']) : null;
      if (pending.command) this.options.onResult?.(pending.command, message);
      if (message) this.options.onError(message);
      // Match native PendingCommandMetadata: a rejected gesture retires input ownership,
      // including a failed terminal frame whose local gesture has already ended.
      if (message && pending.command?.name === 'gesture.frame') this.fail();
    } catch {
      this.fail();
    }
  }

  private send(type: 'command' | 'ping', command: InputCommand | null): boolean {
    if (
      command &&
      (command.name === 'keyboard.key' || command.name === 'keyboard.shortcut') &&
      requiresKeyboardControls(command) &&
      !this.extendedKeyboardAvailable
    )
      return false;
    const socket = this.socket;
    if (
      !socket ||
      socket.readyState !== 1 ||
      !this.connectionID ||
      socket.bufferedAmount > 32_768 ||
      this.pending.size >= 32 ||
      this.sequence >= Number.MAX_SAFE_INTEGER
    )
      return false;
    const requestId = crypto.randomUUID();
    const sequence = ++this.sequence;
    const envelope = {
      protocolVersion: 1,
      type,
      connectionId: this.connectionID,
      requestId,
      sequence,
      ...(command ? { command } : {}),
    };
    try {
      socket.send(JSON.stringify(envelope));
      // Match native PendingCommandMetadata without extending ordinary input deadlines.
      const timeout =
        command?.name === 'session.unlock'
          ? 12_000
          : command && isSessionAction(command.name)
            ? 10_000
            : 3000;
      this.pending.set(requestId, { sequence, at: this.now(), timeout, command });
      this.lastSentAt = this.now();
      if (command?.name === 'gesture.frame') this.lastGestureSentAt = this.lastSentAt;
      return true;
    } catch {
      return false;
    }
  }

  private heartbeat(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      const now = this.now();
      if (Array.from(this.pending.values()).some((item) => now - item.at > item.timeout)) {
        this.fail();
        return;
      }
      if (this.options.input.heldButtons.length > 0 && now - this.lastSentAt >= 1000) {
        // Duplicate down renews the native lease without posting another mouse-down.
        for (const button of this.options.input.heldButtons) {
          if (!this.send('command', { name: 'pointer.button.down', button })) {
            this.fail();
            return;
          }
        }
      }
      const gesture = this.options.input.activeGesture;
      if (
        gesture &&
        now - this.lastGestureSentAt >= 1000 &&
        !this.send('command', { name: 'gesture.frame', gesture: { ...gesture, phase: 'changed' } })
      ) {
        this.fail();
        return;
      }
      if (this.pending.size === 0 && now - this.lastSentAt >= 15_000 && !this.send('ping', null)) {
        this.fail();
        return;
      }
      this.heartbeat();
    }, 1500);
  }

  private clear(): void {
    this.generation += 1;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    this.options.input.disconnect();
    this.pending.clear();
    this.connectionID = null;
    this.extendedKeyboardAvailable = false;
    this.sequence = 0;
    const socket = this.socket;
    this.socket = null;
    socket?.close();
  }

  private now(): number {
    return this.options.now?.() ?? performance.now();
  }

  private async api(
    path: string,
    body?: Readonly<Record<string, string>>,
  ): Promise<Record<string, unknown>> {
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await (this.options.request ?? fetch)(new URL(path, this.origin), {
        method: body ? 'POST' : 'GET',
        credentials: 'same-origin',
        mode: 'same-origin',
        // A document-wide no-referrer policy otherwise produces Origin: null
        // for same-origin-mode POSTs in WebKit. Keep strict server Origin checks.
        referrerPolicy: 'same-origin',
        cache: 'no-store',
        redirect: 'error',
        signal: controller.signal,
        ...(body
          ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
          : {}),
      });
      const value: unknown = await response.json();
      if (!record(value)) throw new Error('Invalid response from the Mac.');
      if (!response.ok) throw new Error(errorMessage(value['error']));
      return value;
    } finally {
      clearTimeout(deadline);
    }
  }
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readState(value: unknown): WebRemoteState {
  if (
    !record(value) ||
    typeof value['accessibilityGranted'] !== 'boolean' ||
    typeof value['deviceName'] !== 'string' ||
    !value['deviceName'] ||
    value['deviceName'].length > 256
  )
    throw new Error();
  const volume = value['systemVolume'];
  const supportsGestures = value['supportsGestures'];
  if (
    supportsGestures !== undefined &&
    supportsGestures !== null &&
    typeof supportsGestures !== 'boolean'
  )
    throw new Error();
  if (
    volume !== undefined &&
    volume !== null &&
    (typeof volume !== 'number' || !Number.isFinite(volume) || volume < 0 || volume > 1)
  )
    throw new Error();
  return {
    capabilities: readCapabilities(value['capabilities']),
    sessionLocked: readOptionalBoolean(value['sessionLocked']),
    unlockAvailable: readOptionalBoolean(value['unlockAvailable']),
    displayAsleep: readOptionalBoolean(value['displayAsleep']),
    accessibilityGranted: value['accessibilityGranted'],
    supportsGestures: supportsGestures === true,
    deviceName: value['deviceName'],
    systemVolume: typeof volume === 'number' ? volume : null,
    mediaTargets: readMediaTargets(value['mediaTargets']),
  };
}

function readOptionalBoolean(value: unknown): boolean | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'boolean') throw new Error();
  return value;
}

function readCapabilities(value: unknown): readonly string[] {
  if (value === undefined || value === null) return [];
  if (
    !Array.isArray(value) ||
    value.length > 16 ||
    value.some(
      (entry) => typeof entry !== 'string' || !entry || new TextEncoder().encode(entry).length > 64,
    )
  )
    throw new Error();
  return value;
}

function errorMessage(code: unknown): string {
  switch (code) {
    case 'request_rejected':
      return 'The browser request was rejected. Reload this page and try again.';
    case 'incorrect_code':
      return 'Incorrect code. Check the code shown on your Mac.';
    case 'pairing_code_changed':
      return 'Three incorrect attempts. The Mac is showing a new code; wait one minute before retrying.';
    case 'pairing_rate_limited':
      return 'Too many attempts. Wait one minute and try again.';
    case 'pairing_expired':
      return 'Pairing expired. Start pairing again.';
    case 'pairing_busy':
      return 'Another browser is pairing. Finish or cancel it on the Mac.';
    case 'pairing_unavailable':
      return 'Unlock the Mac and check that another device can be paired.';
    default:
      return 'The Mac could not complete this request.';
  }
}
