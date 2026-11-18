import { validMediaRequest, type MediaCommand } from './media-model.js';
import { isSystemShortcut, type SystemShortcut } from './desktop-controls.js';

export type RemoteKey =
  'return' | 'escape' | 'backspace' | 'space' | 'left' | 'right' | 'up' | 'down';
export type PointerButton = 'left' | 'right';
export type InputCommand =
  | Readonly<{ name: 'pointer.move' | 'pointer.scroll'; x: number; y: number }>
  | Readonly<{
      name: 'pointer.click' | 'pointer.button.down' | 'pointer.button.up';
      button: PointerButton;
    }>
  | Readonly<{ name: 'keyboard.key'; key: RemoteKey }>
  | Readonly<{ name: 'keyboard.text'; text: string }>
  | Readonly<{ name: 'system.volume.set'; value: number }>
  | Readonly<{ name: 'system.shortcut'; shortcut: SystemShortcut }>
  | MediaCommand;

export type FrameScheduler = Readonly<{
  request: (callback: () => void) => number;
  cancel: (identifier: number) => void;
}>;

const KEYS = new Set<RemoteKey>([
  'return',
  'escape',
  'backspace',
  'space',
  'left',
  'right',
  'up',
  'down',
]);
const MAXIMUM_PACKETS_PER_FLUSH = 32;

/** One frame of coalescing; discrete actions are ordering barriers, never retried. */
export class RemoteInputBuffer {
  private sender: ((command: InputCommand) => boolean) | null = null;
  private pending: InputCommand | null = null;
  private frame: number | null = null;
  private readonly held = new Set<PointerButton>();

  constructor(
    private readonly scheduler: FrameScheduler,
    private readonly onFailure: () => void,
  ) {}

  get heldButtons(): readonly PointerButton[] {
    return Array.from(this.held);
  }

  connect(sender: (command: InputCommand) => boolean): void {
    this.disconnect();
    this.sender = sender;
  }

  disconnect(): void {
    this.discardPending();
    this.held.clear();
    this.sender = null;
  }

  enqueue(command: InputCommand): boolean {
    if (!this.sender || !validCommand(command)) return false;
    if (command.name === 'pointer.move' || command.name === 'pointer.scroll') {
      const previous = this.pending;
      if (previous?.name === command.name) {
        const x = previous.x + command.x;
        const y = previous.y + command.y;
        const limit = command.name === 'pointer.move' ? 500 : 100;
        if (Math.max(Math.abs(x), Math.abs(y)) > limit * MAXIMUM_PACKETS_PER_FLUSH) {
          this.fail();
          return false;
        }
        this.pending = { name: command.name, x, y };
      } else {
        if (!this.flush()) return false;
        this.pending = { ...command };
      }
      this.schedule();
      return true;
    }
    if (command.name === 'system.volume.set') {
      if (this.pending?.name !== command.name && !this.flush()) return false;
      this.pending = { ...command };
      this.schedule();
      return true;
    }
    if (command.name === 'media.control' && command.mediaRequest.action === 'setVolume') {
      const previous = this.pending;
      const sameTarget =
        previous?.name === 'media.control' &&
        previous.mediaRequest.action === 'setVolume' &&
        previous.mediaRequest.targetId === command.mediaRequest.targetId;
      if (!sameTarget && !this.flush()) return false;
      this.pending = { ...command };
      this.schedule();
      return true;
    }
    if (!this.flush()) return false;
    if (command.name === 'pointer.button.down' && this.held.has(command.button)) return true;
    if (command.name === 'pointer.button.up' && !this.held.has(command.button)) return true;
    if (!this.deliver(command)) return false;
    if (command.name === 'pointer.button.down') this.held.add(command.button);
    if (command.name === 'pointer.button.up') this.held.delete(command.button);
    return true;
  }

  /** Cancel a gesture without delivering stale movement, then release held input. */
  cancelGesture(): void {
    if (this.pending?.name === 'pointer.move' || this.pending?.name === 'pointer.scroll')
      this.discardPending();
    for (const button of Array.from(this.held)) {
      if (!this.deliver({ name: 'pointer.button.up', button })) break;
      this.held.delete(button);
    }
  }

  cancelMediaVolume(): void {
    if (this.pending?.name === 'media.control' && this.pending.mediaRequest.action === 'setVolume')
      this.discardPending();
  }

  flush(): boolean {
    const command = this.pending;
    this.discardPending();
    if (!this.sender) return false;
    if (!command) return true;
    if (command.name !== 'pointer.move' && command.name !== 'pointer.scroll') {
      return this.deliver(command);
    }
    const limit = command.name === 'pointer.move' ? 500 : 100;
    const packets = Math.ceil(Math.max(Math.abs(command.x), Math.abs(command.y)) / limit);
    if (packets > MAXIMUM_PACKETS_PER_FLUSH) {
      this.fail();
      return false;
    }
    let remainingX = command.x;
    let remainingY = command.y;
    for (let left = packets; left > 0; left -= 1) {
      const x = remainingX / left;
      const y = remainingY / left;
      if (!this.deliver({ name: command.name, x, y })) return false;
      remainingX -= x;
      remainingY -= y;
    }
    return true;
  }

  private schedule(): void {
    if (this.frame !== null) return;
    this.frame = this.scheduler.request(() => {
      this.frame = null;
      this.flush();
    });
  }

  private discardPending(): void {
    if (this.frame !== null) this.scheduler.cancel(this.frame);
    this.frame = null;
    this.pending = null;
  }

  private deliver(command: InputCommand): boolean {
    if (!this.sender) return false;
    try {
      if (this.sender(command)) return true;
    } catch {
      // Delivery is ambiguous after a failure; never replay a command.
    }
    this.fail();
    return false;
  }

  private fail(): void {
    this.disconnect();
    this.onFailure();
  }
}

function validCommand(command: InputCommand): boolean {
  switch (command.name) {
    case 'pointer.move':
    case 'pointer.scroll': {
      const limit = (command.name === 'pointer.move' ? 500 : 100) * MAXIMUM_PACKETS_PER_FLUSH;
      return (
        Number.isFinite(command.x) &&
        Number.isFinite(command.y) &&
        Math.abs(command.x) <= limit &&
        Math.abs(command.y) <= limit
      );
    }
    case 'pointer.click':
    case 'pointer.button.down':
    case 'pointer.button.up':
      return command.button === 'left' || command.button === 'right';
    case 'keyboard.key':
      return KEYS.has(command.key);
    case 'keyboard.text': {
      const bytes = new TextEncoder().encode(command.text).length;
      return bytes > 0 && bytes <= 4096;
    }
    case 'system.volume.set':
      return Number.isFinite(command.value) && command.value >= 0 && command.value <= 1;
    case 'media.control':
      return validMediaRequest(command.mediaRequest);
    case 'system.shortcut':
      return (
        isSystemShortcut(command.shortcut) &&
        Object.keys(command).sort().join(',') === 'name,shortcut'
      );
    default:
      return false;
  }
}
