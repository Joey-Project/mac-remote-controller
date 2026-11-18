---
id: 20261118-keyboard-controls-01a1464a
title: Web and Native Keyboard Controls
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-keyboard-controls
pr:
supersedes: []
superseded_by:
---

# Web and Native Keyboard Controls

## Outcome

- Extend the separate Web and iPhone/iPad keyboard pages with Tab/Shift-Tab,
  forward Delete, Home/End, Page Up/Down and fixed Copy/Cut/Paste/Select all,
  Undo/Redo and Find buttons. Preserve the original eight keys, text drafts,
  floating groups and touchpad behavior.
- Add the `keyboardControls.v1` capability and strict `keyboard.shortcut`
  allowlist. Older companions retain legacy keys/text and disable only new
  buttons. Web state updates, reconnect and Accessibility loss refresh button
  availability; the transport also checks the current capability.
- Each action sends once and stays an ordering barrier. The Mac prepares both
  events before posting a private-source down/up pair, clears remote modifier
  flags on up and never posts modifier-key down events. There is no held
  modifier UI, arbitrary key code, clipboard transfer or reconnect replay.
- Keep browser editing/focus shortcuts local. The controls target the current
  Mac app, with its own bindings deciding the effect. Pointer pacing and
  gesture recognition paths are unchanged.

## Validation

- Regression tests first demonstrate rejection of new navigation and acceptance
  of extra key fields in the preceding implementation.
- Swift tests cover exact codec round trips/rejection, capability classification,
  ordering and actual native event objects without posting to the desktop.
- Web tests cover allowlists, malformed requests, old capabilities, live
  permission changes, immediate ordering and reconnect without replay.
- The desktop-free TLS/WSS fixture accepts navigation/editing requests and
  rejects arbitrary modifier/key-code requests. Its recorded events stay typed.
- Isolated muted browser checks cover phone/tablet/landscape button sizes and
  hit testing, drafts, old companions, permissions and reconnect. Existing media,
  desktop, session, pinch and Settings regression checks remain in the harness.
- Native UI fixtures cover all new requests and legacy controls on iPhone/iPad.
  Physical target-app behavior remains separate from command submission.

## Next Steps

- After authorized deployment, accept shortcuts in Finder, Chrome and IINA,
  including non-default keyboard layouts/app bindings and the absence of stuck
  remote modifier state. Physical acceptance remains deferred by the user.
- Keep installation/helper hash authorization and daily-renewal payload refresh
  separate; this feature does not change their configuration.
