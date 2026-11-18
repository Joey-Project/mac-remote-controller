---
id: 20261118-web-session-controls-01a1464a
title: Web Session and Display Controls
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-session-controls
pr:
supersedes: []
superseded_by:
---

# Web Session and Display Controls

## Outcome

- Add state-dependent Lock/Unlock Mac, Turn Display Off/Wake Display and
  Lock & Turn Display Off to the existing Web menu. Keep the touchpad,
  keyboard, media controls and floating-panel layout intact; allow the longer
  menu to scroll within short viewports.
- Reuse the companion's existing native session/display executor and unlock
  helper. A paired browser still needs its own explicit unlock permission on
  the Mac. Do not change helper installation, grants or native app behavior.
- Mirror native capability and session-state policy. Missing support hides a
  control and unknown state disables it. Display wake leaves the login session
  locked; display off keeps the Mac running. Full-system sleep and network wake
  are separate work.
- Release local held input before each explicit action. Permit one pending
  session operation while ordinary input remains immediate. Never retry or
  replay an action after an error, disconnect or reconnect.
- Use the native app's 12-second unlock and 10-second session/display deadlines;
  preserve ordinary input's three-second deadline and existing heartbeat cadence.

## Validation

- The parameterless-command regression fails on the previous Web buffer. The
  updated suite passes all 114 Web tests covering native policy states, denied/unknown permission,
  invalid payloads, local drag release, busy state, timeout separation and no
  replay. Type checking, lint, formatting and journal validation pass.
- The AppKit-free gateway fixture models session/display state using native
  `SessionControlPolicy`. The TLS/WSS test covers each fixed action with unlock
  permission both allowed and denied, malformed commands, continued input after
  denial and cookie revocation. Fixtures never control desktop state or audio.
- All 25 gateway package tests and both TLS/WSS permission scenarios pass.
  Strict Swift format and pinned SwiftLint checks pass for changed Swift files.
- Isolated headless Chrome checks phone, tablet and landscape viewports:
  390x844, 1024x768 and 932x430. It exercises button hit testing and menu scroll
  bounds, lock/display transitions, denied and unknown state, an unlock-only
  older companion, ordinary input during a 4.5-second unlock, keyboard draft
  retention, disconnect/no replay and stale acknowledgements. Existing media,
  volume, desktop and all eight panel combinations remain in the run. The
  browser and test HTTPS server exit after validation.

## Next Steps

- Deploy only when requested. Preserve the fixed Mac signing identity, helper
  grants and daily iOS renewal payload.
- Accept the menu in physical Safari: lock/unlock with an explicitly allowed
  browser, denied unlock, display off/wake and the combined action. Verify real
  Mac effects separately from fixture and CI results.
- Continue Web pinch and richer keyboard/settings as later independent slices.
