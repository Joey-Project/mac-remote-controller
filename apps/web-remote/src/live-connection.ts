import { ConnectionBenchmark } from './connection-benchmark.js';
import type { WebRemoteState, WebRemoteStatus } from './web-connection.js';

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error('The connection interface could not be loaded.');
  return value as T;
}

/** Connection-only rendering never runs on the pointer transmission path. */
export class LiveConnectionDetails {
  private readonly name = element<HTMLElement>('connection-name');
  private readonly status = element<HTMLElement>('connection-status');
  private readonly address = element<HTMLElement>('connection-address');
  private readonly start = element<HTMLButtonElement>('benchmark-start');
  private readonly progress = element<HTMLProgressElement>('benchmark-progress');
  private readonly progressText = element<HTMLElement>('benchmark-progress-text');
  private readonly result = element<HTMLElement>('benchmark-result');
  private readonly error = element<HTMLElement>('benchmark-error');
  private readonly availability = element<HTMLElement>('benchmark-availability');
  private readonly benchmark: ConnectionBenchmark;
  private connected = false;
  private capable = false;

  constructor(probe: (signal: AbortSignal) => Promise<number | null>) {
    this.benchmark = new ConnectionBenchmark(probe, () => this.render());
    this.address.textContent = location.host;
    this.start.addEventListener('click', () => {
      if (this.benchmark.running) this.benchmark.cancel();
      else if (this.connected && this.capable) this.benchmark.start();
    });
    this.render();
  }

  updateStatus(status: WebRemoteStatus): void {
    this.connected = status === 'connected';
    this.status.textContent = {
      connected: 'Connected',
      disconnected: 'Disconnected',
      connecting: 'Connecting…',
      reconnecting: 'Reconnecting…',
      pairing: 'Not paired',
    }[status];
    if (!this.connected) {
      this.capable = false;
      this.benchmark.cancel();
    }
    this.render();
  }

  update(state: WebRemoteState): void {
    this.name.textContent = state.deviceName;
    this.capable = state.capabilities.includes('roundTripProbe.v1');
    if (!this.capable) this.benchmark.cancel();
    this.render();
  }

  leave(): void {
    this.benchmark.cancel();
  }

  private render(): void {
    const benchmark = this.benchmark;
    this.start.disabled = !benchmark.running && (!this.connected || !this.capable);
    this.start.textContent = benchmark.running ? 'Cancel benchmark' : 'Run benchmark';
    this.progress.hidden = this.progressText.hidden = !benchmark.running;
    this.progress.value = benchmark.progress;
    this.progressText.textContent = `${benchmark.progress} / 90 probes · ${benchmark.groupProgress}`;
    this.result.textContent = benchmark.report?.summary ?? '';
    this.result.hidden = !benchmark.report;
    this.error.textContent = benchmark.error ?? '';
    this.error.hidden = !benchmark.error;
    this.availability.textContent = !this.connected
      ? 'Connect to your Mac to run the benchmark.'
      : !this.capable
        ? 'Update the Mac companion to run this benchmark.'
        : '';
    this.availability.hidden = !this.availability.textContent;
  }
}
