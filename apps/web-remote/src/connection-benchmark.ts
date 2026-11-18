export type BenchmarkEnding = 'complete' | 'cancelled' | 'interrupted';
export type BenchmarkReport = Readonly<{
  ending: BenchmarkEnding;
  attempts: number;
  timeouts: number;
  minimum: number | null;
  median: number | null;
  p95: number | null;
  maximum: number | null;
  jitter: number | null;
  summary: string;
}>;

/** Match native RTTBenchmarkAccumulator: 3 warmups, then 3 groups of 30. */
export class RTTBenchmarkAccumulator {
  private warmups = 3;
  private attempts = 0;
  private timeouts = 0;
  private readonly samples: number[] = [];

  get progress(): number {
    return this.attempts;
  }
  get complete(): boolean {
    return this.attempts === 90;
  }
  get group(): number {
    return Math.min(3, Math.floor(this.attempts / 30) + 1);
  }
  get sampleInGroup(): number {
    return Math.min(30, (this.attempts % 30) + 1);
  }

  record(milliseconds: number | null): void {
    if (this.complete) return;
    if (
      milliseconds !== null &&
      (!Number.isFinite(milliseconds) || milliseconds < 0 || milliseconds > 2000)
    )
      throw new Error('Invalid benchmark sample.');
    if (this.warmups > 0) {
      this.warmups -= 1;
      return;
    }
    this.attempts += 1;
    if (milliseconds === null) this.timeouts += 1;
    else this.samples.push(milliseconds);
  }

  report(ending: BenchmarkEnding): BenchmarkReport {
    const values = [...this.samples].sort((a, b) => a - b);
    const percentile = (fraction: number): number | null =>
      values.length ? values[Math.max(0, Math.ceil(fraction * values.length) - 1)]! : null;
    const minimum = percentile(0);
    const median = percentile(0.5);
    const p95 = percentile(0.95);
    const maximum = percentile(1);
    const jitter = p95 === null || median === null ? null : p95 - median;
    const statistics =
      minimum === null || median === null || p95 === null || maximum === null || jitter === null
        ? 'No successful probes'
        : `min ${minimum.toFixed(2)} ms · p50 ${median.toFixed(2)} ms · p95 ${p95.toFixed(2)} ms · max ${maximum.toFixed(2)} ms · jitter ${jitter.toFixed(2)} ms`;
    const status = ending === 'complete' ? 'Complete' : `Partial · ${ending}`;
    const loss = this.attempts ? Math.trunc((this.timeouts / this.attempts) * 100) : 0;
    return {
      ending,
      attempts: this.attempts,
      timeouts: this.timeouts,
      minimum,
      median,
      p95,
      maximum,
      jitter,
      summary: `Local network · ${status} · ${this.attempts}/90 · ${statistics} · loss ${this.timeouts} (${loss}%)`,
    };
  }
}

/** Explicitly started only; cancelling or leaving never resumes or replays probes. */
export class ConnectionBenchmark {
  private accumulator = new RTTBenchmarkAccumulator();
  private controller: AbortController | null = null;
  private generation = 0;
  private currentReport: BenchmarkReport | null = null;
  private currentError: string | null = null;

  constructor(
    private readonly probe: (signal: AbortSignal) => Promise<number | null>,
    private readonly changed: () => void,
  ) {}

  get running(): boolean {
    return this.controller !== null;
  }
  get progress(): number {
    return this.accumulator.progress;
  }
  get groupProgress(): string {
    return `Group ${this.accumulator.group} · sample ${this.accumulator.sampleInGroup}`;
  }
  get report(): BenchmarkReport | null {
    return this.currentReport;
  }
  get error(): string | null {
    return this.currentError;
  }

  start(): void {
    if (this.running) return;
    this.accumulator = new RTTBenchmarkAccumulator();
    this.currentReport = null;
    this.currentError = null;
    const controller = new AbortController();
    this.controller = controller;
    const generation = ++this.generation;
    this.changed();
    void this.run(controller, generation);
  }

  cancel(): void {
    if (!this.controller) return;
    const controller = this.controller;
    this.controller = null;
    this.generation += 1;
    controller.abort();
    this.currentReport = this.accumulator.report('cancelled');
    this.changed();
  }

  private async run(controller: AbortController, generation: number): Promise<void> {
    try {
      while (!this.accumulator.complete && generation === this.generation) {
        const sample = await this.probe(controller.signal);
        if (generation !== this.generation) return;
        this.accumulator.record(sample);
        this.changed();
      }
      if (generation !== this.generation) return;
      this.currentReport = this.accumulator.report('complete');
    } catch (error: unknown) {
      if (generation !== this.generation) return;
      this.currentReport = this.accumulator.report('interrupted');
      this.currentError =
        error instanceof Error ? error.message : 'The benchmark could not complete.';
    }
    this.controller = null;
    this.changed();
  }
}
