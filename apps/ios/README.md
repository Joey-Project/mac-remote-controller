# iPhone and iPad

Open `SofaRemoteiOS.xcodeproj` in the selected Xcode, choose your own signing team,
and run `SofaRemoteiOS` on an iPhone or iPad with iOS/iPadOS 17 or newer. Both use
the same target, with a responsive layout and iPad multitasking enabled.

## Control Centre and widgets

On iOS/iPadOS 18 or newer, edit Control Centre, choose **Add a Control**, and
search for **Sofa Remote**. Add **Sofa Remote Touchpad** or **Sofa Remote Keyboard**.
Each opens its corresponding page in the app. The same controls are available
where the system offers Lock Screen or Action button controls.

The **Sofa Remote** widget is available from the Home Screen widget gallery on
iOS/iPadOS 17 or newer. The small widget opens the touchpad; the medium widget
has separate Touchpad and Keyboard links. Lock Screen circular, rectangular and
inline widgets open the touchpad on supported devices.

If disconnected, an entry first shows the usual connection screen. Choose your
paired Mac normally; the requested mode is retained until connection completes.
Entry points do not pair, connect, send input or unlock a Mac automatically.
They do not show cached connection or lock state. Pairing credentials remain in
the main app's Keychain; the extension needs no App Group or shared credential.

Control Centre entries use two fixed foreground App Intents shared by the app
and extension targets. Widget links accept only `sofaremote://remote/touchpad` and
`sofaremote://remote/keyboard`; unknown routes and links carrying additional data
are ignored. These URLs select a page and never encode remote commands.

The app contains a separately signed WidgetKit extension. First device signing
must provision both bundle identifiers with the same development team and
certificate. Use the updated [renewal probe](../../tooling/renewal/README.md#widgetkit-extension-renewal)
before adopting this app into a daily renewal job. The extension receives its
own renewed profile; older accepted apps without extensions keep their existing
renewal flow. First-device signing and real profile issuance remain distinct
from a successful Simulator build.

## Pair and connect

1. Run the Mac companion on the same local network.
2. Unlock the Mac. On iPhone/iPad, allow Local Network access and tap the
   unpaired Mac under **Nearby Macs**.
3. The Mac opens a pairing window. Enter its four-digit code on the phone.
4. Allow Accessibility for Sofa Remote on Mac when using pointer/keyboard input.

The code expires after two minutes or three incorrect attempts. Cancellation,
disconnection and Mac locking also invalidate it. Request and failed-attempt
limits apply across replacement codes; after too many failures, wait a minute
before requesting another code. Pairing does not automatically allow remote unlock.
The PIN is never sent over the network: SRP-6a authenticates the exchange and
binds it to the Mac's actual TLS identity before either side saves credentials.

For an older companion or a camera-based alternative, expand **Other pairing
methods**. On Mac choose **Use QR pairing instead…**, then scan its invitation
or paste it on the phone within two minutes. Camera permission is needed only
when scanning.

Already paired Macs appear in the nearby list and reconnect when tapped. The app
checks the saved certificate pin before sending its credential. A replacement
Mac identity requires a new, explicit pairing. Remove a device from the Mac
companion to revoke it. Pairing credentials stay in each platform's Keychain.

To recover after revocation or replacing the Mac identity, long-press that Mac
in the Wi-Fi **Nearby Macs** list and choose **Pair again…**. Enter the new code
shown on the Mac. The saved pairing is replaced only after successful
verification; cancelling leaves the old record in place.

Bluetooth LE is available after Wi-Fi numeric or QR pairing. From the connected
screen's menu, choose **Switch to Bluetooth LE** to reconnect using the paired
credential. Enable Bluetooth and allow Bluetooth access in iOS Settings. The
advertised service UUID is only a discovery hint; the app authenticates the Mac
before sending control messages. Switching transports disconnects the current
peer; select the paired Mac again from the setup screen to reconnect. Failures
stay visible, pending controls are never replayed, and Wi-Fi is not used as a
silent fallback.

The connected screen defaults to a touchpad that fills the available area,
without an enclosing page scroll view. Drag one finger to move the desktop
pointer, tap to left-click, double-tap to send a native Mac double-click, tap
with two fingers to right-click, and scroll with two fingers. On a companion
that advertises gesture support, three fingers
drag while holding the Mac's left mouse button. Open **Control panels** in the
toolbar and enable **Desktop controls** for Previous desktop, Mission Control,
App windows (App Exposé), and Next desktop buttons. Four-finger touchpad actions
are disabled while their continuous interaction remains deferred.
Mission Control and App Exposé use native Dock notifications; Spaces use a
complete touchpad swipe event sequence. These actions emit no keyboard or modifier
events and do not depend on the Mac's Control-arrow shortcut mappings. The native
Dock/HID interfaces are undocumented and checked at runtime; an unavailable
interface reports an error rather than falling back to a keyboard shortcut.
This does not create a virtual trackpad device or require a driver. On macOS 27,
the Space swipe carries an HID payload; earlier systems use Dock gesture fields.

The Settings page lets you turn three-finger drag, pressure
click, and optional haptic feedback on or off. Preferences apply immediately and
are saved on this device using the existing preference keys. Open Settings from
the remote's more menu or from the setup screen without connecting a Mac.
Unsupported controls explain the missing hardware or companion support.
Pressure click works only where
iOS reports force-capable touch input; ordinary tap remains available on every
device. Haptics default off. Gesture controls stay disabled when paired to an
older companion that does not advertise support. If a touch sequence changes
finger count or is cancelled, it cannot turn into a click; an active drag sends
button-up on cancellation and is also released by the Mac after disconnect or an
eight-second lost-release timeout.

The leading toolbar button switches directly between the separate touchpad and
keyboard pages. Its icon and accessibility label describe the destination mode.
Tap the connected Mac's name to open connection details, including its name,
status, current transport, transport switching, benchmark and disconnect.
Switching transport retains the existing disconnect-and-reconnect behavior;
choose the paired Mac again to reconnect. The keyboard includes the arrow keys,
Return, Escape, Delete, and Space. Compose text locally, then tap Send to submit
committed Unicode text; intermediate input-method composition is not streamed.

The more menu offers Settings and **Lock Mac** or **Unlock Mac** according to the observed
session state, and **Turn Display Off** or **Wake Display** according to the
observed display state. **Lock & Turn Display Off** is a separate action that
confirms the lock before switching off the displays. Unknown states disable the
corresponding action; older companions hide unsupported controls. Unlock still
requires the installed helper and per-device permission. Lock and display power
do not require that helper or Accessibility permission.

Turning displays off keeps the Mac from automatically sleeping while at least
one authenticated remote connection remains. Waking a display, detecting a local
display wake, disconnecting the last remote, or quitting the companion releases
that keep-awake request. Explicit sleep, lid closure and system power emergencies
remain governed by macOS. Display-only commands preserve the system's existing
password-after-display-sleep policy; use the combined action to request a lock
explicitly. Wake Display does not unlock the Mac.

Pointer and scroll updates are combined for up to one display interval before
they are sent. Adjacent deltas retain their sum; clicks and keyboard commands
remain in order. If the bounded queue overloads, movement after the latest
click or keyboard command may be cleared and replaced with the newest movement.
Movement that positions an accepted click stays ahead of that click.

The toolbar's **Control panels** menu independently toggles **Volume and playback**
and **Desktop controls**. Both groups start hidden. Show either group, stack both,
or choose **Hide all controls**; the two choices are saved on this device across
mode changes, reconnects and app launches. In touchpad mode the groups overlay
the top of the unchanged touch surface, and hidden groups intercept no touches.
Keyboard mode keeps visible groups above the separate keyboard content.
Changing panel visibility does not send text, adjust volume, or execute a Mac action.
Desktop buttons require a capable companion and Accessibility permission; their
actions use the existing authenticated, ordered command route. An active local
pointer drag is released before a desktop command is queued.
Opening and returning from Settings or connection details preserves the selected
mode, keyboard draft, player selection and overlay visibility. Presenting these
screens ends an active pointer drag and dismisses text focus without sending text.
System volume is continuous and reports outputs that do not support software
volume control.

Moving the app out of the active state disconnects it. Reconnect intentionally
when returning. Pending clicks and text are never replayed after a connection
loss; their outcome may be unknown. No screen preview is transmitted.

When the Mac media bridge is enabled, supported Chrome tabs and IINA player
windows appear in a separate player-source picker. The selected source stays
independent of the frontmost desktop app. A single row contains previous item,
backward 10 seconds, play/pause, forward 10 seconds, and next item. Seek duration
is fixed for now; it has no inline editor. These controls and player volume do not retarget
Mac system input. Player volume is displayed as a percentage of unity gain, such
as 60%, 120%, or 400%, and follows the selected adapter's reported maximum
and offers fixed 10-percentage-point steps with a stronger 100% detent, even
when the maximum is higher. The system/player volume scope
switch defaults to system volume and changes no volume by itself. Older Macs
that omit media targets keep the player controls hidden.

Chrome and IINA require separate local setup on the Mac; see their package
readmes. No adapter is installed automatically, and media transport failure is
shown to the user without replaying the command after reconnect.

## Connection benchmark

After connecting to a Mac that advertises `roundTripProbe.v1`, choose
**Connection benchmark** from the remote menu. It runs three warm-up probes and
then 90 sequential no-op probes in three groups of 30. Each measured exchange
times out after two seconds; cancellation preserves a partial report. Results
show minimum, p50, p95, maximum, jitter (`p95 - p50`), and timeout loss. The
benchmark does not issue desktop or playback controls. Older Mac companions
without the capability keep normal controls available and show the benchmark as
unsupported.

Round-trip time is measured on the iPhone or iPad's monotonic clock. The Mac
shows its own pong-preparation count and latest local processing duration; it
does not subtract the Mac clock from the mobile clock. The simulator UI fixture
does not exercise Bluetooth radio, pairing credentials, or real audio.

## Simulator UI Tests

Run the shared `SofaRemoteiOS` scheme's tests in Xcode, or run
`tooling/swift/test-ios-ui.sh` from the repository. The script creates an iPhone
17 Pro and iPad mini on the newest compatible installed runtime, then runs a
separate serial `xcodebuild` invocation for each simulator. Each invocation uses
that simulator's UDID for its own DerivedData directory and result bundle, so
build products cannot be shared across destinations. Before each invocation,
the runner waits for the simulator to finish booting. After each destination's
test and failure reporting complete, the runner shuts down and deletes that
temporary simulator before booting the next one; the exit trap retries cleanup
for any created simulator still registered as owned. A cleanup failure fails
the run, and an existing `xcodebuild` failure status remains the reported exit
status. To reuse existing simulators, pass their UDIDs as arguments; those
devices are never shut down or deleted by the script.
Debug builds use the selected destination's active architecture for both the
app and its package dependencies.

UI tests use local ad-hoc signing, with no Apple account or team. The native
Control Centre test is opt-in: run the script with
`TEST_RUNNER_SOFA_REMOTE_NATIVE_CONTROLS_UI_TEST=1` to forward the flag to XCTest.
It adds both controls through the system gallery and checks their destination
pages without sending remote input. It customizes Control Centre, so prefer the
default temporary devices. iPhone system controls passed local acceptance;
iPad system-gallery queries timed out and remain unverified. Ordinary CI runs
the URL-route regressions, which remain separate from native control activation
and Home/Lock Screen widget acceptance.

The runner mutes system audio and leaves it muted. Result bundles, including
failure screenshots, are saved under
`.codex-tmp/apple-tools/UI-Tests/Results/<run-id>-<simulator-UDID>.xcresult/`.
`IOS_UI_TEST_DERIVED_DATA` and `IOS_UI_TEST_RESULT_BUNDLE` can each override the
corresponding root directory; each run still creates per-simulator subpaths or
bundles beneath those roots. CI disables Xcode's extra system diagnostic
collection because it stalled for ten minutes; test assertions, attachments,
and result bundles remain available. Each test has a 240-second execution
allowance, including app launch. Cold Simulator startup, package compilation,
and test execution are repeated for both destinations. The UI test step has a
50-minute limit within the Apple job's 75-minute limit, leaving time for the
always-run artifact upload. CI retains result bundles for seven days.
On failure, the runner reports up to ten escaped XCTest failure messages as
GitHub annotations while preserving the original `xcodebuild` exit status.

The suite runs on iPhone and iPad. The landscape-only test is skipped on iPhone
because the app supports portrait orientation there. Per-device test counts are
recorded in the result bundles. The iPad test requires actual landscape window
dimensions before checking control bounds.

The suite exercises the real SwiftUI/UIKit interface against an in-process
Mac fixture, activated with `--ui-testing` only in Debug Simulator builds. It
disables UIKit and SwiftUI animations in that fixture so mode and menu assertions
wait for control state rather than Simulator animation-completion notifications.
Normal Simulator launches and physical-device builds retain their animations. It
does not access pairing credentials, discover Macs, connect to the network,
inject desktop input, or adjust real audio. Assertions inspect the validated
commands emitted by the interface. This covers UI and command integration;
real pairing, TLS transport, Mac event injection, and physical-device gesture
feel require separate acceptance.
