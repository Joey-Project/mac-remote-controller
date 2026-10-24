# Remote protocol v1

Status: the Apple foundation implements discovery, pairing, state, pointer,
keyboard, system volume, authenticated Bluetooth LE, and typed media controls.
iPhone/iPad is the first mobile target; Android remains future work.
Physical Bluetooth validation remains outstanding.

## First slice

1. Define interoperable command, state, and error models with shared fixtures.
2. Discover and explicitly pair a mobile client with the Mac companion.
3. Read connection, permission, and system-volume state.
4. Control the desktop pointer and committed text, then system volume.

IINA and Chrome media adapters use this foundation. Media commands retain an
explicit selected-source identity independent of desktop focus.

## Connection and trust

- Use a LAN protocol that both Apple and Android clients can implement. Use
  Bonjour/DNS-SD for discovery and TLS WebSocket for mobile-to-Mac messages.
- Discovery is a hint, not authorization. Advertisements contain no pairing
  secret. The Mac exposes a short-lived pairing invitation only when pairing is
  explicitly enabled.
- A QR invitation carries the expected server identity and a one-time random
  pairing token. Verify that server identity before sending credentials.
  Previously paired devices use revocable credentials stored by the platform's
  secure storage.
- Never silently trust a replacement server certificate or downgrade to an
  unencrypted connection. Stop with a visible trust error.
- Chrome extension transport needs a separate integration decision; do not
  assume browser WebSockets can customize certificate trust like native clients.

The Apple transport uses Network.framework and TLS 1.2 or newer. A persistent
P-256 private key and ten-year self-signed certificate identify the Mac. The
client verifies the leaf certificate's SHA-256 fingerprint before authentication.
Discovery uses an opaque UUID as the `_sofaremote._tcp` service name.
Resolve that service to its hostname and port, then use a complete
`wss://hostname:port/` endpoint. A Bonjour or raw host/port endpoint alone does
not provide Network.framework's WebSocket upgrade request with its URL context.

The QR is `sofaremote://pair/` followed by standard Base64-encoded UTF-8 JSON:
`protocolVersion`, `serviceName` (UUID), `certificateSHA256` (64 lowercase hex
digits), `token` (Base64 of 32 random bytes), and `expiresAt` (Unix seconds).
Invitations last 120 seconds. Clients reject expired invitations and lifetimes
more than five minutes into their future. Explicit Mac UI opening is required;
closing pairing or redeeming it invalidates that token.

Send `authenticate` with `authToken` and `deviceName` after TLS. The token is
either an invitation or an existing device credential. The server persists a
fresh 32-byte device credential before consuming an invitation, then returns it
as `authToken` in `welcome`. `welcome` also contains `connectionId` and `state`.
Existing devices reuse their stored credential; it is not reissued on reconnect.
The mobile client must persist a new credential before enabling controls. A lost
first welcome may leave an unused device entry; remove it on Mac and pair again.
Revocation closes current connections. Authentication failure closes the socket
without allowing input. Unauthenticated connections expire after ten seconds.

## Message identity

Use UTF-8 JSON text frames. Every message carries `protocolVersion: 1` and a
message `type`. Reject unsupported protocol versions before executing commands.

After authentication, the server issues a new opaque `connectionId`. Each
command contains that ID, a unique `requestId`, and a positive monotonic
`sequence` within the connection. Sequence values stay within JSON's exact
integer range. The server processes commands in arrival order and rejects stale,
duplicate, or out-of-order sequences without executing them again. Gaps are
allowed. After validating message/session/request identity, consume a new
sequence before command value validation; invalid values do not desynchronize
later input.

Every command receives a result that echoes its request and sequence identity.
Successful enqueueing on the phone does not imply successful execution on Mac.
If the connection closes before a result arrives, the outcome is unknown.
Reconnect with a new connection identity and fresh state; never automatically
replay clicks, key presses, relative seeking, or playback toggles.

An illustrative authenticated request:

```json
{
  "protocolVersion": 1,
  "type": "command",
  "connectionId": "connection-example",
  "requestId": "request-example",
  "sequence": 1,
  "command": {
    "name": "system.volume.set",
    "value": 0.35
  }
}
```

The example identifiers are display examples, not credentials or a proposed ID
encoding. The Swift binding and JSON fixture implement these bounds.

## Implemented messages

All messages use `protocolVersion: 1` and one of `authenticate`, `welcome`,
`command`, `result`, `state`, `ping`, `pong`, or `disconnect`. Maximum encoded
size is 64 KiB. A command has
`connectionId`, UUID `requestId`, positive `sequence`, and a `command` object.
A result echoes those three identities; absent `error` means success. An error
has `code` and `message`. Malformed or incompatible wire envelopes close the
connection. A result means the Mac submitted the input to its OS API; it does
not prove that the foreground app accepted the input or completed an action.

| Command               | Fields         | Bounds                                                                  |
| --------------------- | -------------- | ----------------------------------------------------------------------- |
| `pointer.move`        | `x`, `y`       | Relative finite deltas, each within ±500                                |
| `pointer.click`       | `button`       | `left` or `right`, at the current cursor                                |
| `pointer.scroll`      | `x`, `y`       | Pixel deltas, each within ±100                                          |
| `pointer.button.down` | `button`       | Hold `left` or `right`; requires advertised gesture support             |
| `pointer.button.up`   | `button`       | Release a held button in the same connection                            |
| `system.shortcut`     | `shortcut`     | `mission-control`, `app-expose`, `previous-space`, or `next-space`      |
| `keyboard.text`       | `text`         | 1–4096 UTF-8 bytes of committed text                                    |
| `keyboard.key`        | `key`          | `return`, `escape`, `backspace`, `space`, `left`, `right`, `up`, `down` |
| `system.volume.set`   | `value`        | Finite scalar in 0...1                                                  |
| `media.control`       | `mediaRequest` | Exact target ID, typed action, and optional finite value; see below     |

State contains `deviceName`, `accessibilityGranted`, optional `systemVolume`, and
optional `systemVolumeReason`. Absent volume means unavailable, never zero.
An independently muted output reports effective volume `0`; a nonzero volume
command also clears mute. Fractional scroll pixels accumulate per connection,
and their remainder is discarded on disconnect.
The server includes an initial snapshot in `welcome`, then sends state once per
second and immediately after a system-volume command. Pointer and keyboard
commands receive a correlated `result`; they do not imply a following `state`.
Clients acknowledge commands using `result` and consume state as independent
snapshots, without waiting for one snapshot per command.
The client bounds outstanding commands and its unsent queue to eight each.
Adjacent relative deltas are combined within the wire bounds. All other input
commands except coalesced system-volume updates are ordering barriers, including
button holds, releases, and system shortcuts. Under overload, only trailing
motion after the latest barrier may be replaced; accepted motion before a
barrier is retained, and a new discrete action is rejected if the queue is full.
If a required button release is rejected, the client closes the session so the
Mac releases held input during session cleanup.
Adjacent unsent absolute-volume updates retain the latest value. Disconnect
discards pending and unsent input. Missing command results time out after three
seconds and close the connection without replaying commands.

### Bluetooth LE transport

Pair the iPhone or iPad with the Mac over the existing Wi-Fi QR flow first.
Bluetooth LE then uses the paired 32-byte token as a pre-shared key; it never
sends the token itself. The Mac advertises its existing opaque per-Mac service
UUID. That UUID only narrows scan results and contains no pairing credential.
The iOS app is the CoreBluetooth central and the Mac companion is the
peripheral. Bluetooth permission and an available radio are required on both
devices.

Every BLE connection runs a one-shot mutual-authentication handshake with fresh
32-byte client and server nonces. HMAC-SHA-256 proofs bind the service name,
device name, and nonces. HKDF-SHA-256 derives separate client-to-server and
server-to-client keys; ChaCha20-Poly1305 protects every wire message with a
strictly increasing per-direction sequence number as authenticated data.
Frames use a four-byte big-endian length prefix. Handshake records are limited
to 512 bytes; encrypted messages are limited to the wire-message bound plus
framing overhead. Queues are capped at 1 MiB. Authentication expires after 12
seconds, and incomplete frames expire after three seconds. Invalid, oversized,
unauthenticated, replayed, or out-of-order frames close the BLE connection.

Changing transport explicitly disconnects the current peer. Select the paired
Mac again from the setup screen to connect over the selected transport. A failed
Bluetooth connection is shown as a failure; the app does not silently fall back
to Wi-Fi or replay a pending control.
Previously paired Macs that do not advertise the `roundTripProbe.v1`
capability remain usable for normal controls, but the benchmark stays disabled.

### Connection benchmark

The benchmark sends three warm-up probes followed by 90 sequential no-op
`ping`/`pong` exchanges in three groups of 30. Probes do not execute pointer,
keyboard, volume, or playback commands. Each measured exchange has a two-second
timeout; cancelling keeps a partial report. Successful measured round trips
produce minimum, p50, p95, maximum, and `p95 - p50` jitter. Timed-out measured
probes are excluded from latency percentiles and included in the reported loss
count and rate; warm-ups are excluded from both.

The mobile app measures round-trip duration with its monotonic clock. The Mac
separately reports how many probes it handled and the elapsed Mac-local time to
prepare the latest pong. Those Mac-side values are not subtracted from mobile
RTT because the clocks are independent. Comparison reports are retained per
Mac so Wi-Fi and Bluetooth results can be viewed after an explicit switch.

## Media sources and command

`state.mediaTargets` is optional for compatibility with older companions. If
present, it is an array of at most 64 unique targets. Each target has a bounded
opaque `id`, display `name`, `kind` (`iina`, `youtube`, or `bilibili`), typed
capabilities, and optional current `playerVolume`. Capabilities include
`playPause`, `seek`, `next`, `previous`, and optional `playerVolumeMaximum`.
Current player volume must be within the reported maximum. Absence of
`mediaTargets` means the companion does not provide media controls; an empty
array means no adapter source is currently available.

`media.control` contains exactly one `mediaRequest` object: `targetId`, `action`,
and an optional `value`. Actions are `playPause`, `seek`, `next`, `previous`, and
`setVolume`. Seek is a nonzero finite relative number no greater than 3600
seconds in magnitude. Set-volume is finite and nonnegative, then checked against
the selected source's advertised maximum at execution. Other actions reject a
value. The Mac rejects unsupported capabilities and unavailable targets with a
result; it never substitutes a foreground player or another tab.

The companion's optional media bridge binds only to IPv4 loopback
`127.0.0.1:47623`. Chrome uses a pinned native messaging host; IINA uses the
official plugin HTTP client and polls the companion. A separate random bearer
token is stored in a per-user mode-0600 companion file. The bridge is media-only,
rejects cross-origin requests, bounds HTTP bodies, clients, request rate, and
pending commands, and authenticates each request. No token is exposed to Chrome
page scripts or content scripts. Adapter polling is not an authenticated
network pairing mechanism.

## State and media boundaries

The optional `supportsGestures` state flag enables the held-button and fixed
shortcut commands above. Absence means unsupported; clients must keep these
controls disabled for legacy companions. Ordinary taps remain atomic clicks.
The Mac sets native single/double-click state using its configured double-click
interval, proximity, button, and remote-session identity.

Held pointer ownership is limited to one remote session. Conflicting pointer
commands from another session fail explicitly. A client must release held input
when a gesture is cancelled or its surface is removed; the server also releases
on disconnect, revocation, or eight seconds without valid client activity.
Four-finger actions invoke fixed public macOS shortcuts, so local shortcut
configuration controls their availability and meaning.

- Desktop input targets the current desktop. It does not change the selected
  media source. Keyboard text contains committed Unicode input, not intermediate
  IME composition.
- Media operations name a source ID. A missing or unavailable source fails
  explicitly; do not fall back to the foreground player or a different tab.
- Sources are scoped to the running Mac companion and their adapter instance.
  Refresh source identities after a companion restart or adapter replacement;
  never retain a stale selection by matching its display title alone.
- Capabilities and accessibility permission state are observable. The Mac checks
  permission and capability again when executing an operation.
- The wire contract exposes an allowlist of typed operations. It does not accept
  arbitrary shell commands, scripts, file paths, or executable key bindings.

## Volume units

Represent volume as a finite gain ratio: `1.0` means 100%. System volume is in
`0.0...1.0`. A player's actual reported maximum is independent and may exceed
`1.0`; do not impose a generic 100% or 1000% player limit.
Adapters normalize their native volume units at the protocol boundary; for
example, IINA's mpv percentage is divided by 100 when reported and multiplied
by 100 only when a gain-ratio command is applied. The mobile UI converts the
gain ratio to percentage values for display and its 10-point slider policy.

Keep system and selected-player volume separately in state. Switching the UI
mode sends no volume command. Unavailable values are explicit rather than zero.
Reject values outside the current target's range instead of silently changing
the target or clamping an invalid request.

The mobile player-volume slider applies 10-percentage-point steps without
ordinary ticks and a stronger, passable 100% detent. System volume stays
continuous. Haptic feedback belongs to the client interaction, not the wire.

## Errors and validation

Results distinguish success (no `error`) and failure. Error results carry the
request identity and a user-displayable message. The foundation uses
`invalid_command` and `control_unavailable`; incompatible versions, malformed
messages, and failed authentication close the connection. Media-specific error
codes follow with their adapters.

Clients do not retry a command just because an error or timeout occurred.
Refresh state where useful and let the user repeat an intentional action.

The foundation tests cover valid round trips, malformed/unknown messages, version
rejection, duplicate and stale sequences, Unicode text, bounds, and invitation
expiry. Media-adapter fixtures cover player gain above 100%, explicit source
routing, and source lease expiry. Live-player behavior and physical-device
acceptance remain separate from these package and fixture tests.
