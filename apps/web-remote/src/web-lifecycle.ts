import type { WebRemoteStatus } from './web-connection.js';

/** Keep pairing presentation independent from a suspended transport. */
export class WebRemoteLifecycle {
  private status: WebRemoteStatus = 'connecting';
  private needsPairing = false;
  private resumeConnection = false;

  update(status: WebRemoteStatus): void {
    this.status = status;
    if (status === 'pairing') this.needsPairing = true;
    if (status === 'connected') this.needsPairing = false;
  }

  get showPairing(): boolean {
    return this.needsPairing;
  }

  get showControls(): boolean {
    return this.status === 'connected';
  }

  suspend(): void {
    // visibilitychange and pagehide may both arrive for one interruption.
    this.resumeConnection ||=
      this.status === 'pairing' ||
      this.status === 'connecting' ||
      this.status === 'connected' ||
      this.status === 'reconnecting';
  }

  resume(): boolean {
    const resume = this.resumeConnection;
    this.resumeConnection = false;
    return resume;
  }

  stop(): void {
    this.resumeConnection = false;
  }
}
