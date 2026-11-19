# Web and App Feature Parity

The reference is the iPhone/iPad App, including the shared keyboard controls.
The Android App is still a scaffold. This table describes source functionality;
merge, deployment, renewal-payload refresh and physical acceptance are separate.

## Remote controls

| User action                 | Web and iPhone/iPad App                                                                                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Choose touchpad or keyboard | Separate switchable pages; opening details or Settings preserves the selected mode and unsent draft.                                                                                                         |
| Move and click              | Relative pointer movement, left click and two-finger right tap. Source tap timestamps preserve click spacing independently of packet arrival.                                                                |
| Scroll and zoom             | Two-finger scroll versus phased pinch magnification; unsupported companions keep scroll/right tap.                                                                                                           |
| Drag                        | Optional three-finger drag; release/cancel on interruption and no replay after reconnect.                                                                                                                    |
| Pressure click              | Optional on inputs that report pressure. Web ignores the standard unsupported 0.5/0 pressure values, emits one click and suppresses the trailing tap.                                                        |
| Touch feedback              | Opt-in local feedback for tap, drag start and pressure click. Native uses UIKit; Web uses short best-effort vibration only where exposed and permitted. Unavailable/refused feedback never blocks control.   |
| Desktop actions             | Previous desktop, Mission Control, App windows and Next desktop in a hideable panel. Four-finger swipe remains deferred in both clients.                                                                     |
| Basic keyboard              | Arrow keys, Escape, Return, Space, Backspace and committed text submission.                                                                                                                                  |
| Navigation/editing          | Tab/Shift-Tab, forward Delete, Home/End, Page Up/Down, Copy/Cut/Paste/Select all, Undo/Redo and Find. Fixed one-shot native event pairs, no held modifier or clipboard transfer.                             |
| System volume               | Global Mac volume with percentage display.                                                                                                                                                                   |
| Player volume               | Switch volume scope, 10-percentage-point steps and 100% snap; show supported values above 100% as percentages.                                                                                               |
| Media playback              | Player selection and five actions: previous, back, play/pause, forward, next. Individual player capabilities govern availability.                                                                            |
| Skip interval               | Local Settings choice of 5, 10, 15 or 30 seconds in either direction.                                                                                                                                        |
| Lock state                  | Lock/Unlock Mac selected from current state, using the companion's existing per-device permission and native helper.                                                                                         |
| Display state               | Turn Display Off/Wake Display selected from current state; separate Lock & Turn Display Off. No whole-system sleep command.                                                                                  |
| Floating controls           | Persist independent visibility, allow all-hidden combinations and Hide all in either remote mode. Web retains separate volume/media switches; App groups volume and playback together.                       |
| Connection details          | Current Mac, state, transport and Disconnect. Web also shows its own-origin address.                                                                                                                         |
| RTT benchmark               | Three warmups excluded, then three groups of 30 sequential authenticated no-op probes. Same nearest-rank statistics, jitter, timeout loss and cancellable partial results; reconnect does not restart a run. |
| Preferences                 | Local skip, drag, pressure and feedback preferences. Web migrates earlier preferences and retains in-memory operation when storage fails. Pairing secrets are not preferences.                               |
| Reconnect and permissions   | Fresh authenticated state controls availability; unsupported capabilities are explained and input is never replayed.                                                                                         |

## Entry and platform differences

| Area                            | iPhone/iPad App                                                            | Web                                                                                                                                                           |
| ------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Enrollment                      | Bonjour, four-digit pairing and legacy QR invitation fallback.             | Open the configured trusted HTTPS origin, then four-digit pairing. No native certificate-pin/invitation import or nearby-Mac list.                            |
| Saved authorization             | Native Keychain pairing; Mac can separately permit unlock for each device. | Secure HttpOnly cookie pairing; each browser/Home Screen context may need its own pairing and unlock permission.                                              |
| Network transport               | Wi-Fi and Bluetooth LE, with per-transport benchmark results.              | HTTPS/WSS local-network transport. BLE is not implemented; Safari does not natively expose Web Bluetooth. Use the App for BLE comparisons.                    |
| Quick entry                     | Native touchpad/keyboard App Intents, Control Centre controls and widgets. | `/#touchpad` and `/#keyboard` links, Home Screen guidance and links usable by a system Open URL shortcut. These do not create a native widget/control.        |
| Installation and background use | Signed App and extension; independent renewal workflow.                    | Existing web-app metadata and browser/Home Screen entry. No service worker, offline input queue or background remote commands. The Mac must remain reachable. |
| Hardware feedback               | Hardware/OS capability determines pressure and haptics.                    | Observed touch/pen pressure and exposed/permitted vibration determine availability. These APIs do not promise UIKit's haptic feel.                            |

The browser's configured origin, clock precision and event scheduling differ
from the App. A successful no-op RTT is not proof of input-to-display latency,
nor proof that two measurements used the same device or network route.
An event clock outside the native timestamp range retains the existing
server-timed click fallback instead of disabling basic clicks.

## Acceptance and evidence

Unit and isolated muted-browser checks cover the remote actions, old companions,
permission changes, navigation, state persistence, entry links and no replay.
Desktop-free TLS/WSS checks cover actual authenticated framing and validation.
Physical Safari multitouch, force/vibration hardware, Home Screen installation,
VoiceOver/Dynamic Type and real Finder/Chrome/IINA effects remain acceptance
items. Automated command submission does not mark those effects accepted.

- [Connection details and benchmark](project_journal/2026/11/2026-11-18-web-connection-details-01a1464a.md)
- [Pairing and browser acceptance](project_journal/2026/11/2026-11-16-web-pairing-resume-01a1464a.md)
- [Browser feature parity](project_journal/2026/11/2026-11-18-web-feature-parity-01a1464a.md)
- [Keyboard controls](project_journal/2026/11/2026-11-18-keyboard-controls-01a1464a.md)
- [Media controls](project_journal/2026/11/2026-11-18-web-media-controls-01a1464a.md)
- [Desktop controls](project_journal/2026/11/2026-11-18-web-desktop-controls-01a1464a.md)
- [Session/display controls](project_journal/2026/11/2026-11-18-web-session-controls-01a1464a.md)
- [Pinch](project_journal/2026/11/2026-11-18-web-pinch-01a1464a.md)
- [Settings](project_journal/2026/11/2026-11-18-web-settings-01a1464a.md)

Platform references checked on 2026-11-18:

- [Pointer Events pressure defaults](https://w3c.github.io/pointerevents/#dom-pointerevent-pressure).
- [Web Bluetooth implementation status](https://github.com/whatwg/bluetooth/blob/main/implementation-status.md#safari).
- [WebKit Home Screen web-app behavior](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/#every-site-can-be-a-web-app-on-ios-and-ipados).
