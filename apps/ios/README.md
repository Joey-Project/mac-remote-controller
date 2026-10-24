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

The connected screen defaults to a touchpad that fills the available area,
without an enclosing page scroll view. Drag one finger to move the desktop
pointer, tap to left-click, tap with two fingers to right-click, and scroll with
two fingers. The top menu switches between touchpad and keyboard modes and
includes the volume toggle and disconnect action. The keyboard includes the
arrow keys, Return, Escape, Delete, and Space. Compose text locally, then tap
Send to submit committed Unicode text; intermediate input-method composition
is not streamed.

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

Only system volume is available in this slice. Media-source selection, player
volume, playback controls, and Finder shortcuts follow with the media adapters.

## Simulator UI Tests

Run the shared `SofaRemoteiOS` scheme's tests in Xcode, or run
`tooling/swift/test-ios-ui.sh` from the repository. The script creates an iPhone
17 Pro and iPad mini on the newest compatible installed runtime, then runs a
separate serial `xcodebuild` invocation for each simulator. Each invocation uses
that simulator's UDID for its own DerivedData directory and result bundle, so
build products cannot be shared across destinations. Before each invocation,
the runner waits for the simulator to finish booting. The script deletes only
the temporary devices it created. To reuse existing simulators, pass their
UDIDs as arguments; those devices are retained.
Debug builds use the selected destination's active architecture for both the
app and its package dependencies.

The runner mutes system audio and leaves it muted. Result bundles, including
failure screenshots, are saved under
`.codex-tmp/apple-tools/UI-Tests/Results/<run-id>-<simulator-UDID>.xcresult/`.
`IOS_UI_TEST_DERIVED_DATA` and `IOS_UI_TEST_RESULT_BUNDLE` can each override the
corresponding root directory; each run still creates per-simulator subpaths or
bundles beneath those roots. CI disables Xcode's extra system diagnostic
collection because it stalled for ten minutes; test assertions, attachments,
and result bundles remain available. Each test has a 120-second execution
allowance, including app launch. Cold Simulator startup, package compilation,
and test execution are repeated for both destinations. The UI test step has a
30-minute limit within the Apple job's 40-minute limit, leaving time for the
always-run artifact upload. CI retains result bundles for seven days.

The six test methods run on iPad. On iPhone, five run and the landscape-only
test is skipped because the app supports portrait orientation there. The iPad
test requires actual landscape window dimensions before checking control bounds.

The suite exercises the real SwiftUI/UIKit interface against an in-process
Mac fixture, activated with `--ui-testing` only in Debug Simulator builds. It
does not access pairing credentials, discover Macs, connect to the network,
inject desktop input, or adjust real audio. Assertions inspect the validated
commands emitted by the interface. This covers UI and command integration;
real pairing, TLS transport, Mac event injection, and physical-device gesture
feel require separate acceptance.
