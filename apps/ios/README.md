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

Drag one finger to move the desktop pointer; tap to left-click; use two fingers
to scroll. Right-click and a small allowlist of keyboard keys have separate
buttons. Compose text locally, then tap Send to submit committed Unicode text;
intermediate input-method composition is not streamed. System volume is
continuous and reports outputs that do not support software volume control.

Moving the app out of the active state disconnects it. Reconnect intentionally
when returning. Pending clicks and text are never replayed after a connection
loss; their outcome may be unknown. No screen preview is transmitted.

Media-source selection, player volume, playback controls, and Finder shortcuts
follow with the media adapters. The system/player mode button is visibly
unavailable in this first slice.

The host's stale CoreSimulator installation can prevent `xcodebuild` from finding
a generic iOS destination. This does not establish an app compile result; use
the required CI Apple build until the local Xcode installation is repaired.
