# Mac companion

Open `SofaRemoteMac.xcodeproj` in Xcode and run `SofaRemoteMac` on macOS 14 or
newer. Sofa Remote appears in the menu bar. Allow Local Network access so the
companion can advertise its Bonjour service and accept connections.
Allow Bluetooth access when macOS requests it. The companion advertises a
per-Mac Bluetooth LE service UUID only as a scan hint; it accepts a control
session only after the paired-device handshake authenticates the iPhone or iPad.

Choose **Pair iPhone or iPad**, then scan the invitation in the mobile app. The
invitation expires after two minutes and can be redeemed only once. Closing
pairing invalidates it immediately. The companion supports up to eight paired
devices, with one active connection per device. **Remove** revokes a device's
credential and closes its current connection.

Pointer and keyboard control require permission in **System Settings → Privacy
& Security → Accessibility**. Use the companion's **Allow Accessibility…** button
to request it. Permission is checked again for each input operation. Keep the
app's signing identity stable between builds to avoid repeated permission prompts.

System volume targets the current default audio output. Fixed-volume outputs
such as some HDMI or digital devices report that volume control is unavailable.
The app does not silently substitute another volume target. Stereo channel
controls are used together when the output has no main volume property.
An independently muted output reports 0%; setting a nonzero volume clears its
mute state when supported. Unreadable mute state or a mute state that cannot be
cleared makes volume control unavailable.

The companion generates a permanent P-256 key and a self-signed certificate with
Apple's Swift Certificates library. The certificate and pairing records are
stored in Keychain. A missing or corrupt saved identity stops startup; it never
silently replaces a trusted identity. The certificate currently lasts ten years;
identity reset and certificate renewal UI are follow-up work.

Networking uses Bonjour `_sofaremote._tcp` and standard TLS WebSocket messages.
Discovery names contain only an opaque service UUID, never a pairing secret.
Only authenticated sessions can execute the typed input/volume allowlist. No
arbitrary shell commands or scripts are exposed. See the
[wire contract](../../packages/protocol/v1-design.md).
The companion samples desktop state once per second and shares that snapshot
with connected clients; a volume change triggers an immediate refreshed state.

IINA and browser playback adapters follow this foundation. Their selected source
will remain independent of desktop focus.

For the authenticated Bluetooth protocol and connection benchmark limits, see
the [wire contract](../../packages/protocol/v1-design.md#bluetooth-le-transport).
