export type MediaAction = 'playPause' | 'seek' | 'previous' | 'next' | 'setVolume';
export type MediaRequest =
  | Readonly<{ targetId: string; action: 'playPause' | 'previous' | 'next' }>
  | Readonly<{ targetId: string; action: 'seek' | 'setVolume'; value: number }>;
export type MediaCommand = Readonly<{ name: 'media.control'; mediaRequest: MediaRequest }>;
export type MediaTarget = Readonly<{
  id: string;
  name: string;
  kind: 'iina' | 'youtube' | 'bilibili';
  capabilities: Readonly<{
    playPause: boolean;
    seek: boolean;
    previous: boolean;
    next: boolean;
    playerVolumeMaximum: number | null;
  }>;
  playerVolume: number | null;
}>;

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
function boundedString(value: unknown, bytes: number): value is string {
  return (
    typeof value === 'string' && value.length > 0 && new TextEncoder().encode(value).length <= bytes
  );
}

/** Match the native wire bounds; copy only presentation fields, never arbitrary markup. */
export function readMediaTargets(value: unknown): readonly MediaTarget[] | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value) || value.length > 64) throw new Error('Invalid media sources.');
  const ids = new Set<string>();
  return value.map((item: unknown): MediaTarget => {
    if (
      !record(item) ||
      !boundedString(item['id'], 128) ||
      !boundedString(item['name'], 256) ||
      !['iina', 'youtube', 'bilibili'].includes(String(item['kind'])) ||
      !record(item['capabilities'])
    )
      throw new Error('Invalid media source.');
    if (ids.has(item['id'])) throw new Error('Duplicate media source.');
    ids.add(item['id']);
    const caps = item['capabilities'];
    if (
      typeof caps['playPause'] !== 'boolean' ||
      typeof caps['seek'] !== 'boolean' ||
      typeof caps['previous'] !== 'boolean' ||
      typeof caps['next'] !== 'boolean'
    )
      throw new Error('Invalid media capabilities.');
    const maximum = caps['playerVolumeMaximum'] ?? null;
    if (
      maximum !== null &&
      (typeof maximum !== 'number' || !Number.isFinite(maximum) || maximum <= 0)
    )
      throw new Error('Invalid player volume range.');
    const volume = item['playerVolume'] ?? null;
    if (
      volume !== null &&
      (typeof volume !== 'number' ||
        !Number.isFinite(volume) ||
        volume < 0 ||
        maximum === null ||
        volume > maximum)
    )
      throw new Error('Invalid player volume.');
    return {
      id: item['id'],
      name: item['name'],
      kind: item['kind'] as MediaTarget['kind'],
      capabilities: {
        playPause: caps['playPause'],
        seek: caps['seek'],
        previous: caps['previous'],
        next: caps['next'],
        playerVolumeMaximum: maximum,
      },
      playerVolume: volume,
    };
  });
}

export function validMediaRequest(value: unknown): value is MediaRequest {
  if (!record(value) || !boundedString(value['targetId'], 128)) return false;
  const keys = Object.keys(value).sort().join(',');
  switch (value['action']) {
    case 'previous':
    case 'next':
    case 'playPause':
      return keys === 'action,targetId';
    case 'seek':
      return (
        keys === 'action,targetId,value' &&
        typeof value['value'] === 'number' &&
        Number.isFinite(value['value']) &&
        value['value'] !== 0 &&
        Math.abs(value['value']) <= 3600
      );
    case 'setVolume':
      return (
        keys === 'action,targetId,value' &&
        typeof value['value'] === 'number' &&
        Number.isFinite(value['value']) &&
        value['value'] >= 0
      );
    default:
      return false;
  }
}

/** Native PlayerVolumePolicy: 10 percentage points, strongest detent at 100%. */
export function snapPlayerVolume(proposed: number, maximum: number): number | null {
  if (!Number.isFinite(proposed) || !Number.isFinite(maximum) || maximum <= 0) return null;
  const bounded = Math.min(maximum, Math.max(0, proposed));
  if (bounded === 0 || bounded === maximum) return bounded;
  if (maximum >= 100 && Math.abs(bounded - 100) <= 7.5) return 100;
  const step = Math.min(10, maximum);
  return Math.min(maximum, Math.round(bounded / step) * step);
}

/** Explicit source selection; a disappearing player never silently retargets a click. */
export class MediaControlsModel {
  targets: readonly MediaTarget[] | null = null;
  selectedID: string | null = null;
  private wanted: MediaCommand | null = null;
  private confirmedVolume: number | null = null;

  get target(): MediaTarget | null {
    return this.targets?.find((target) => target.id === this.selectedID) ?? null;
  }
  get volumeMaximumPercent(): number | null {
    const maximum = this.target?.capabilities.playerVolumeMaximum;
    return maximum && Number.isFinite(maximum * 100) ? maximum * 100 : null;
  }
  get volumePercent(): number | null {
    const volume = this.volumeGain;
    return volume !== null && this.volumeMaximumPercent !== null ? volume * 100 : null;
  }
  private get volumeGain(): number | null {
    const request = this.wanted?.mediaRequest;
    return request?.action === 'setVolume'
      ? request.value
      : (this.confirmedVolume ?? this.target?.playerVolume ?? null);
  }
  supports(action: MediaAction): boolean {
    const target = this.target;
    if (!target) return false;
    return action === 'setVolume'
      ? this.volumeMaximumPercent !== null && target.playerVolume !== null
      : target.capabilities[action];
  }
  update(targets: readonly MediaTarget[] | null): boolean {
    const old = this.target;
    this.targets = targets;
    if (this.selectedID && !this.target) this.selectedID = null;
    const target = this.target;
    const changed =
      old?.id !== target?.id ||
      old?.capabilities.playerVolumeMaximum !== target?.capabilities.playerVolumeMaximum ||
      (old?.playerVolume !== null && target?.playerVolume === null);
    if (changed) this.clearVolume();
    else if (
      !this.wanted &&
      (target?.playerVolume === this.confirmedVolume || old?.playerVolume !== target?.playerVolume)
    )
      this.confirmedVolume = null;
    return changed;
  }
  select(id: string): void {
    this.selectedID = this.targets?.some((target) => target.id === id) ? id : null;
    this.clearVolume();
  }
  disconnect(): void {
    // Preserve the chosen ID for the next fresh snapshot, never reuse its old capabilities.
    this.targets = null;
    this.clearVolume();
  }
  control(action: Exclude<MediaAction, 'setVolume'>, seconds?: number): MediaCommand | null {
    if (!this.target || !this.supports(action)) return null;
    const request: MediaRequest =
      action === 'seek'
        ? { targetId: this.target.id, action, value: seconds ?? 0 }
        : { targetId: this.target.id, action };
    return validMediaRequest(request) ? { name: 'media.control', mediaRequest: request } : null;
  }
  volume(proposedPercent: number): MediaCommand | null {
    const target = this.target;
    const maximum = this.volumeMaximumPercent;
    if (!target || maximum === null || !this.supports('setVolume')) return null;
    const percent = snapPlayerVolume(proposedPercent, maximum);
    if (percent === null) return null;
    const value = percent === maximum ? target.capabilities.playerVolumeMaximum! : percent / 100;
    if (value === this.volumeGain) return null;
    return {
      name: 'media.control',
      mediaRequest: { targetId: target.id, action: 'setVolume', value },
    };
  }
  requested(command: MediaCommand): void {
    if (
      command.mediaRequest.action === 'setVolume' &&
      command.mediaRequest.targetId === this.selectedID
    )
      this.wanted = command;
  }
  complete(command: MediaCommand, error: string | null): void {
    // Input coalescing preserves this nested request identity; old target/volume acks cannot win.
    if (
      command.mediaRequest !== this.wanted?.mediaRequest ||
      command.mediaRequest.action !== 'setVolume'
    )
      return;
    this.confirmedVolume = error ? null : command.mediaRequest.value;
    this.wanted = null;
  }
  private clearVolume(): void {
    this.wanted = null;
    this.confirmedVolume = null;
  }
}
