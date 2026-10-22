---
id: 20261022-touchpad-01a1464a
title: Connected Touchpad and Keyboard Modes
status: active
created: 2026-10-22
updated: 2026-10-22
branch: wip/touchpad-modes
pr:
supersedes: []
superseded_by:
---

# Connected Touchpad and Keyboard Modes

## Summary

- The selected iOS interaction slice makes the connected Mac the screen title,
  gives the touchpad the available screen area, and switches between touchpad
  and keyboard from the top menu.

## Current State

- The connected view fills its available area with the touchpad and does not put
  it inside a page-level scroll view. One-finger movement and tap continue to
  control the pointer and left click; two-finger tap performs right click, and
  two-finger movement scrolls.
- The top menu switches between touchpad and keyboard modes and includes the
  volume toggle and disconnect action. The title shows the connected Mac name.
  Keyboard mode includes the arrow keys with Return, Escape, Delete, and Space.
- Volume uses a fixed top position. It starts hidden in touchpad mode; the menu
  toggle controls a touchpad pin preference that persists across mode changes.
  Keyboard mode always shows volume at the same top and horizontal position,
  regardless of the touchpad preference. Mode changes and volume visibility
  changes send neither text nor volume commands. Existing committed-text and
  input-method composition behavior is unchanged.
- The implementation is complete. The existing 54 AppleCore package tests
  pass using fake audio in `.codex-tmp/touchpad-modes-20261022/swift-tests.log`;
  SwiftFormat and strict SwiftLint pass, and the signed arm64 iOS device build
  succeeds. The package tests do not validate this UI. CoreSimulator responded
  normally, but generic scheme-based destination selection failed. There has
  been no Simulator or physical-device acceptance of the new UI. The signed
  app was installed on the paired iPhone; launch was denied because the device
  was locked. System output was muted at volume zero before the launch attempt
  and remains muted. Build and installation receipts are ignored under
  `.codex-tmp/touchpad-modes-20261022/`.
- Earlier physical iPhone acceptance covered the Apple input foundation and QR
  pairing only. It is not acceptance evidence for these screen and gesture
  changes. iPhone and iPad layout/mode acceptance remains pending.

## Repeatable UI Coverage

- The shared iOS scheme includes `SofaRemoteiOSUITests`. Six UI regressions
  exercise touchpad drag and two-finger secondary click, volume pinning and
  placement, arrow-key commands, draft preservation and explicit submission,
  disconnect, and landscape layout with scrollable keyboard controls.
- A Debug-only Simulator fixture starts at a connected "UI Test Mac" and
  records up to 128 validated commands. It bypasses Keychain, Bonjour, transport,
  desktop input, and real audio. Release and physical-device builds do not
  include this fixture. This is UI/command integration coverage; it does not
  establish real pairing or Mac event-delivery acceptance.
- `tooling/swift/test-ios-ui.sh` runs the same suite locally and in the existing
  Apple CI job. Its default devices are a temporary iPhone 17 Pro and iPad mini
  on the newest compatible installed runtime. It leaves system audio muted,
  retains result bundles, and removes only devices it created. Existing device
  IDs may be supplied for local diagnosis. CI retains result artifacts for
  seven days.
- The 54 AppleCore tests, strict Swift formatting/SwiftLint, shell validation,
  and actionlint pass. A local UI execution pass is not asserted here.
  Local Simulator lifecycle requests stalled before the first UI execution;
  Computer Use separately reported a locked Mac and failed automatic unlock.
  These observations do not establish that the lock caused the Simulator stall.
  UI execution evidence belongs in the test result bundles and PR checks.

## Pairing Direction

- The current QR invitation remains implemented. It transfers a certificate
  pin and a single-use, two-minute token; see [Protocol v1](../../../../packages/protocol/v1-design.md).
- Phone-initiated numeric comparison, with approval on the Mac, is the proposed
  default direction for a future pairing design. The protocol choice is
  unresolved and no pairing implementation changed in this slice. A comparison
  must authenticate a commitment and bind both approvals to the same connection;
  independently displaying the same short random number or truncating a TLS
  exporter does not establish that property by itself.
- Keep QR as an optional fallback under consideration. Review the [SAS section
  of RFC 6189](https://www.rfc-editor.org/rfc/rfc6189.html#section-4.4.1.1) and
  the [Bluetooth numeric comparison overview](https://www.bluetooth.com/blog/bluetooth-pairing-part-4/)
  when choosing a concrete protocol.

## Next Steps

- Validate touchpad/keyboard switching, two-finger tap versus scroll, volume
  visibility and placement, arrow keys, and committed Chinese/emoji text on an
  iPhone. Check rotation, multitasking, and layout on an iPad separately.
- Keep three/four-finger dragging, Mission Control gestures, modifier shortcuts,
  media adapters, Control Centre widgets, a Web SPA, and App Clips as future
  work.

## Evidence

- Existing AppleCore test log: `.codex-tmp/touchpad-modes-20261022/swift-tests.log`.
- The foundation's physical iPhone acceptance and its limits are recorded in
  [the Apple foundation journal](2026-10-16-native-remote-01a1464a.md).
