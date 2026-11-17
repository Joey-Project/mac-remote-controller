import assert from 'node:assert/strict';
import test from 'node:test';
import { RemoteInputBuffer } from '../dist/remote-input.js';
import { WebRemoteConnection } from '../dist/web-connection.js';

class Socket {
  readyState = 1;
  bufferedAmount = 0;
  sent = [];
  listeners = new Map();
  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }
  emit(name, event) {
    for (const listener of this.listeners.get(name) ?? []) listener(event);
  }
  send(value) {
    this.sent.push(JSON.parse(value));
  }
  close() {
    this.readyState = 3;
    this.emit('close', { code: 1000 });
  }
  message(value) {
    this.emit('message', { data: JSON.stringify(value) });
  }
  welcome(id = 'test-connection') {
    this.message({
      protocolVersion: 1,
      type: 'welcome',
      connectionId: id,
      state: { accessibilityGranted: true, deviceName: 'Test Mac', systemVolume: 0 },
    });
  }
}

function fixture(t, { request, active } = {}) {
  const sockets = [];
  const requests = [];
  const statuses = [];
  const results = [];
  const errors = [];
  const frames = new Map();
  let identifier = 0;
  let now = 0;
  const input = new RemoteInputBuffer(
    {
      request(callback) {
        frames.set(++identifier, callback);
        return identifier;
      },
      cancel(id) {
        frames.delete(id);
      },
    },
    () => connection.fail(),
  );
  const connection = new WebRemoteConnection({
    origin: 'https://remote.example.com:47625',
    now: () => now,
    input,
    active,
    createSocket(url) {
      assert.equal(url, 'wss://remote.example.com:47625/remote');
      const socket = new Socket();
      sockets.push(socket);
      return socket;
    },
    async request(url, options) {
      requests.push({ url, options });
      return request
        ? request(url, options)
        : new Response(JSON.stringify({ paired: true }), { status: 200 });
    },
    onStatus(value) {
      statuses.push(value);
    },
    onError(message) {
      errors.push(message);
    },
    onState() {},
    onResult(command, error) {
      results.push({ command, error });
    },
  });
  t.after(() => connection.disconnect());
  return {
    connection,
    input,
    sockets,
    requests,
    statuses,
    results,
    errors,
    advance(milliseconds) {
      now += milliseconds;
    },
    frame() {
      const callbacks = Array.from(frames.values());
      frames.clear();
      callbacks.forEach((callback) => callback());
    },
  };
}

test('HTTPS own-origin requests use cookies and reject redirects without JS credentials', async (t) => {
  const f = fixture(t);
  await f.connection.connect();
  const { url, options } = f.requests[0];
  assert.equal(url.origin, 'https://remote.example.com:47625');
  assert.equal(options.credentials, 'same-origin');
  assert.equal(options.mode, 'same-origin');
  assert.equal(options.redirect, 'error');
  f.sockets[0].welcome();
  f.input.enqueue({ name: 'pointer.click', button: 'left' });
  const command = f.sockets[0].sent[0];
  assert.equal(command.sequence, 1);
  assert.equal('authToken' in command, false);
  f.sockets[0].message({
    protocolVersion: 1,
    type: 'result',
    connectionId: command.connectionId,
    requestId: command.requestId,
    sequence: command.sequence,
  });
  assert.equal(f.results.length, 1);
  assert.equal(f.results[0].error, null);
});

test('pairing POST preserves the browser Origin under the document no-referrer policy', async (t) => {
  const f = fixture(t, {
    request: () => Response.json({ requestId: 'pairing-request', paired: true }),
  });
  await f.connection.beginPairing('Test browser');
  const { url, options } = f.requests[0];
  const request = new Request(url, options);
  assert.equal(request.mode, 'same-origin');
  assert.equal(request.credentials, 'same-origin');
  assert.equal(request.redirect, 'error');
  assert.equal(request.referrerPolicy, 'same-origin');
  assert.equal(request.headers.has('Origin'), false, 'let the browser supply the Origin');
});

test('request rejection identifies a browser request problem rather than a Mac failure', async (t) => {
  const f = fixture(t, {
    request: () => Response.json({ error: 'request_rejected' }, { status: 403 }),
  });
  await assert.rejects(f.connection.beginPairing('Test browser'), /browser.*request.*rejected/i);
});

test('a pairing confirmation finishing in the background waits for foreground reconnect', async (t) => {
  let active = true;
  let finish;
  const f = fixture(t, {
    active: () => active,
    request: (url) =>
      url.pathname === '/api/pairing/confirm'
        ? new Promise((resolve) => {
            finish = resolve;
          })
        : Response.json({ paired: true }),
  });
  const confirmation = f.connection.confirmPairing('pairing-request', '0000');
  active = false;
  f.connection.disconnect();
  finish(Response.json({ paired: true }));
  await confirmation;
  assert.equal(f.sockets.length, 0);
  active = true;
  await f.connection.connect();
  f.sockets[0].welcome();
  assert.equal(f.statuses.at(-1), 'connected');
});

test('a stationary drag renews the native held-button lease without replay after disconnect', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = fixture(t);
  await f.connection.connect();
  const socket = f.sockets[0];
  socket.welcome();
  f.input.enqueue({ name: 'pointer.button.down', button: 'left' });
  const original = socket.sent[0];
  socket.message({
    protocolVersion: 1,
    type: 'result',
    connectionId: original.connectionId,
    requestId: original.requestId,
    sequence: original.sequence,
  });
  f.advance(2000);
  t.mock.timers.tick(1500);
  assert.deepEqual(
    socket.sent.map((item) => item.command?.name),
    ['pointer.button.down', 'pointer.button.down'],
  );
  f.connection.disconnect();
  f.advance(20_000);
  t.mock.timers.tick(20_000);
  assert.equal(socket.sent.at(-1).command.name, 'pointer.button.up');
});

test('reconnect drops queued movement, resets sequences, and ignores old socket callbacks', async (t) => {
  const f = fixture(t);
  await f.connection.connect();
  const old = f.sockets[0];
  old.welcome('old-session');
  f.input.enqueue({ name: 'pointer.move', x: 9, y: 10 });
  await f.connection.connect();
  old.welcome('stale-session');
  const current = f.sockets[1];
  current.welcome('new-session');
  f.frame();
  assert.deepEqual(current.sent, []);
  f.input.enqueue({ name: 'keyboard.key', key: 'escape' });
  assert.equal(current.sent[0].sequence, 1);
  assert.equal(current.sent[0].connectionId, 'new-session');
});

test('an unacknowledged-command limit closes instead of growing or replaying the queue', async (t) => {
  const f = fixture(t);
  await f.connection.connect();
  const socket = f.sockets[0];
  socket.welcome();
  for (let index = 0; index < 32; index += 1)
    assert.equal(f.input.enqueue({ name: 'keyboard.key', key: 'left' }), true);
  assert.equal(f.input.enqueue({ name: 'keyboard.key', key: 'left' }), false);
  assert.equal(socket.sent.length, 32);
  assert.equal(socket.readyState, 3);
  assert.equal(f.statuses.at(-1), 'reconnecting');
});

test('a Mac policy close does not create a competing-tab reconnect loop', async (t) => {
  const f = fixture(t);
  await f.connection.connect();
  f.sockets[0].welcome();
  f.sockets[0].emit('close', { code: 1008 });
  assert.equal(f.statuses.at(-1), 'disconnected');
  assert.equal(f.input.enqueue({ name: 'pointer.click', button: 'left' }), false);
  await f.connection.connect();
  assert.equal(f.sockets.length, 2);
});

test('wrong-session responses terminate the stream without accepting an acknowledgement', async (t) => {
  const f = fixture(t);
  await f.connection.connect();
  const socket = f.sockets[0];
  socket.welcome();
  f.input.enqueue({ name: 'keyboard.text', text: 'example' });
  const command = socket.sent[0];
  socket.message({
    protocolVersion: 1,
    type: 'result',
    connectionId: 'other-session',
    requestId: command.requestId,
    sequence: command.sequence,
  });
  assert.equal(f.results.length, 0);
  assert.equal(socket.readyState, 3);
});
