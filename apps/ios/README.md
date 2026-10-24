# iPhone and iPad

Open `SofaRemoteiOS.xcodeproj` in the selected Xcode, choose your own signing team,
and run `SofaRemoteiOS` on an iPhone or iPad with iOS/iPadOS 17 or newer. Both use
the same target, with a responsive layout and iPad multitasking enabled.

1. Run the Mac companion on the same local network.
2. On Mac, choose **Pair iPhone or iPad** from the Sofa Remote menu bar item.
3. On iPhone/iPad, allow Local Network access, choose **Scan pairing QR code**,
   allow Camera access, and scan the Mac's invitation within two minutes.
4. Allow Accessibility for Sofa Remote on Mac when using pointer/keyboard input.

Already paired Macs appear in the nearby list and reconnect when tapped. The app
checks the saved certificate pin before sending its credential. A replacement
Mac identity requires a new, explicit QR pairing. Remove a device from the Mac
companion to revoke it. Pairing credentials stay in each platform's Keychain.

Bluetooth LE is available after the same Wi-Fi QR pairing. From the connected
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
drag while holding the Mac's left mouse button, and four-finger swipes request
Mission Control (up), App Exposé (down), or the previous/next Space (left/right).
These use public macOS keyboard shortcuts. The matching shortcuts must be enabled
in System Settings > Keyboard > Keyboard Shortcuts > Mission Control on the Mac;
custom shortcut assignments can change the result. No private macOS APIs are used.

The remote menu lets you turn three-finger drag, four-finger shortcuts, pressure
click, and optional haptic feedback on or off. Pressure click works only where
iOS reports force-capable touch input; ordinary tap remains available on every
device. Haptics default off. Gesture controls stay disabled when paired to an
older companion that does not advertise support. If a touch sequence changes
finger count or is cancelled, it cannot turn into a click; an active drag sends
button-up on cancellation and is also released by the Mac after disconnect or an
eight-second lost-release timeout.

The top menu switches between touchpad and keyboard modes and includes the
volume toggle and disconnect action. The keyboard includes the arrow keys,
Return, Escape, Delete, and Space. Compose text locally, then tap Send to submit
committed Unicode text; intermediate input-method composition is not streamed.

Pointer and scroll updates are combined for up to one display interval before
they are sent. Adjacent deltas retain their sum; clicks and keyboard commands
remain in order. If the bounded queue overloads, movement after the latest
click or keyboard command may be cleared and replaced with the newest movement.
Movement that positions an accepted click stays ahead of that click.

The volume control uses a fixed position at the top of the screen. It starts
hidden in touchpad mode; use the top menu to change the touchpad's volume-pin
preference, which persists across mode changes. Keyboard mode always shows the
control at that same top and horizontal position. Changing modes or volume
visibility does not send text or adjust volume.
System volume is continuous and reports outputs that do not support software
volume control.

Moving the app out of the active state disconnects it. Reconnect intentionally
when returning. Pending clicks and text are never replayed after a connection
loss; their outcome may be unknown. No screen preview is transmitted.

When the Mac media bridge is enabled, supported Chrome tabs and IINA player
windows appear in a separate player-source picker. The selected source stays
independent of the frontmost desktop app. Play/pause, relative seek (5, 10, or
30 seconds), next/previous where available, and player volume do not retarget
Mac system input. Player volume follows the selected adapter's reported maximum
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
40-minute limit within the Apple job's 50-minute limit, leaving time for the
always-run artifact upload. CI retains result bundles for seven days.
On failure, the runner reports up to ten escaped XCTest failure messages as
GitHub annotations while preserving the original `xcodebuild` exit status.

The suite runs on iPhone and iPad. The landscape-only test is skipped on iPhone
because the app supports portrait orientation there. Per-device test counts are
recorded in the result bundles. The iPad test requires actual landscape window
dimensions before checking control bounds.

The suite exercises the real SwiftUI/UIKit interface against an in-process
Mac fixture, activated with `--ui-testing` only in Debug Simulator builds. It
does not access pairing credentials, discover Macs, connect to the network,
inject desktop input, or adjust real audio. Assertions inspect the validated
commands emitted by the interface. This covers UI and command integration;
real pairing, TLS transport, Mac event injection, and physical-device gesture
feel require separate acceptance.
