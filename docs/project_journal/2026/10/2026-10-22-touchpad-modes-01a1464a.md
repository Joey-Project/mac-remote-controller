---
id: 20261022-touchpad-01a1464a
title: Connected Touchpad and Keyboard Modes
status: active
created: 2026-10-22
updated: 2026-10-22
branch: wip/touchpad-modes
pr: 3
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
  succeeds. The package tests do not validate this UI. A local iPhone 17 Pro
  run on iOS 26.5 completed with five tests passed, one intentional
  landscape-only skip, and zero failures. Per-device execution results and
  remaining failures are retained in xcresult bundles and the PR. Build and
  installation receipts are ignored under
  `.codex-tmp/touchpad-modes-20261022/`.
- Earlier physical iPhone acceptance covered the Apple input foundation and QR
  pairing only. It is not acceptance evidence for these screen and gesture
  changes. The signed app was installed on the paired iPhone, but launch was
  denied while the device was locked; system output was muted at volume zero
  before that attempt. Physical interaction acceptance for this slice remains
  pending.

## Repeatable UI Coverage

- The shared iOS scheme includes `SofaRemoteiOSUITests`. Six UI regressions
  exercise touchpad drag and two-finger secondary click, volume pinning and
  placement, arrow-key commands, draft preservation and explicit submission,
  disconnect, and iPad landscape layout with scrollable keyboard controls.
  iPhone runs five methods and skips the landscape-only method; iPad runs all
  six and must demonstrate an actually rotated window before layout assertions.
- A Debug-only Simulator fixture starts at a connected "UI Test Mac" and
  records up to 128 validated commands. It bypasses Keychain, Bonjour, transport,
  desktop input, and real audio. Release and physical-device builds do not
  include this fixture. This is UI/command integration coverage; it does not
  establish real pairing or Mac event-delivery acceptance.
- `tooling/swift/test-ios-ui.sh` runs the same suite locally and in the existing
  Apple CI job. Its default devices are a temporary iPhone 17 Pro and iPad mini
  on the newest compatible installed runtime. It waits for Simulator boot
  readiness, then runs each destination serially with separate DerivedData and
  result bundles. Each test has a 120-second timeout. Extra system diagnostic
  collection is disabled; assertions, screenshot attachments, and xcresult
  data remain available. The runner leaves system audio muted and removes only
  devices it created. Existing device IDs may be supplied for local diagnosis.
  CI retains result artifacts for seven days.
- The completed local iPhone result covers Simulator UI and validated command
  integration only. The fixture bypasses pairing, transport, desktop input,
  and real audio. iPad Simulator acceptance requires all six tests to complete;
  neither Simulator result establishes physical-device behavior.

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

- Validate touchpad feel, two-finger tap versus scroll, and Chinese/emoji input
  methods on a physical iPhone; confirm real pairing, transport, and Mac event
  delivery separately from the Simulator fixture. Check rotation,
  multitasking, and layout on a physical iPad separately.
- Keep three/four-finger dragging, Mission Control gestures, modifier shortcuts,
  media adapters, Control Centre widgets, a Web SPA, and App Clips as future
  work.

## Evidence

- Existing AppleCore test log: `.codex-tmp/touchpad-modes-20261022/swift-tests.log`.
- The foundation's physical iPhone acceptance and its limits are recorded in
  [the Apple foundation journal](2026-10-16-native-remote-01a1464a.md).
