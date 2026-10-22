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
17 Pro and iPad mini on the newest compatible installed runtime, runs them
serially, and deletes only those temporary devices afterward. To reuse existing
simulators, pass their UDIDs as arguments; those devices are retained.

The runner mutes system audio and leaves it muted. Result bundles, including
failure screenshots, are saved under `.codex-tmp/apple-tools/UI-Tests/Results/`.
CI runs the same suite as part of **Swift and Apple apps** and retains its
result bundles for seven days.

The suite exercises the real SwiftUI/UIKit interface against an in-process
Mac fixture, activated with `--ui-testing` only in Debug Simulator builds. It
does not access pairing credentials, discover Macs, connect to the network,
inject desktop input, or adjust real audio. Assertions inspect the validated
commands emitted by the interface. This covers UI and command integration;
real pairing, TLS transport, Mac event injection, and physical-device gesture
feel require separate acceptance.
