---
id: 20261118-web-desktop-controls-01a1464a
title: Web Desktop Control Panel
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-desktop-controls
pr:
supersedes: []
superseded_by:
---

# Web Desktop Control Panel

## Outcome

- Add Previous desktop, Mission Control, App windows and Next desktop to an
  independently hideable Web panel. Volume, media and desktop groups support
  all eight visibility combinations; their overlay leaves the touchpad frame
  unchanged. Preserve the separate keyboard page and existing volume behavior.
- Use only the four existing protocol actions and native Mac executor. The Web
  peer admits `system.shortcut`; arbitrary shortcut values, extra keyboard
  fields, gesture frames and session/display commands remain outside its scope.
- Enable controls only while connected to a gesture-capable companion with
  Accessibility. Clear stale capability state on disconnect and require a fresh
  snapshot on reconnect. Provide permission/update guidance when unavailable.
- Release the local held drag before a desktop action and discard its queued
  motion. Send the action once through the existing ordered input route without
  waiting for media acknowledgements or adding keyboard/modifier synthesis.

## Validation

- A new input-ordering regression fails against the previous Web buffer. All
  80 Web tests pass with the change, including capability parsing, unsupported
  actions, drag-release ordering, disconnect/no replay and failed-release safety.
- All 25 gateway package tests and the real TLS/WSS transport test pass. The
  desktop-free fixture checks the exact four action payloads and rejects
  arbitrary shortcuts, extra key fields and session/display commands.
- Isolated headless Chrome exercises the built client at 390x844, 1024x768 and
  932x430. It checks all eight panel combinations and an unchanged touchpad
  frame, actual button hit testing, capability/permission changes, disconnect
  and reconnect, and immediate desktop dispatch while player volume awaits an
  acknowledgement. Existing media/volume/keyboard checks stay in the run.
- These fixtures never emit desktop input or play audio; native animation and
  real cross-Space navigation remain physical acceptance work.
- The existing local-automation idle-client test observes actual peer closure
  within its deadline, allows only a rejection frame before EOF and verifies
  that only the normal request reaches its handler. This avoids confusing a
  client read timeout with server expiry or assuming EOF is the only valid
  rejection. Two deterministic observer checks cover an open socket and a
  rejection frame followed by closure; all 12 socket tests pass. Production
  automation deadlines and behavior are unchanged.

## Next Steps

- Deploy only when requested, preserving fixed Mac signing/helper grants and
  the daily iOS renewal payload. Verify all four actions on the actual Mac from
  Safari, including an active three-finger drag followed by a desktop action.
- Continue phased Web pinch as a separate slice; preserve pointer/drag latency
  and keep session/display authorization separate.
