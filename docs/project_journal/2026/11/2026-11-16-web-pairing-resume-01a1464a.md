---
id: 20261116-web-pairing-resume-01a1464a
title: Web Pairing Resume and Safari Requests
status: completed
created: 2026-11-16
updated: 2026-11-17
branch: wip/web-pairing-resume
pr: 40
supersedes: []
superseded_by:
---

# Web Pairing Resume and Safari Requests

## Outcome

- Preserve pairing presentation across visibility/page interruptions. Recheck
  authorization once on return, without displaying inactive remote controls or
  discarding an in-progress pairing form. Explicit disconnect still stops
  automatic reconnection.
- Hide the control surface until a WebSocket welcome confirms the connection.
  A pairing confirmation that finishes while hidden waits for foreground
  reconnect instead of opening a background control connection.
- Use an explicit same-origin referrer policy for API requests. This avoids
  Safari's null Origin for same-origin-mode POSTs under the document's
  no-referrer policy; the server's exact Host/Origin checks remain unchanged.
- Explain request rejection separately from an unspecified Mac operation
  failure. Keep the configured endpoint and port unchanged.
- Float both Web and native numeric pairing-code windows above ordinary
  windows, keep them visible when the app deactivates, and allow them across
  Spaces and alongside full-screen applications. Retain the existing Cancel
  button/Escape action and prompt-driven dismissal after pairing or cancellation.

## Validation

- Three new connection regressions fail against the previous implementation:
  the request policy, actionable rejection error, and background confirmation.
- Web tests cover unpaired foreground restoration, duplicate lifecycle events,
  explicit disconnect, and welcome-gated control presentation.
- All 49 Web tests, TypeScript type checking, lint, formatting, Markdown lint,
  project-journal validation and whitespace checks passed locally.
- Physical iPhone Safari pairing and real Mac input are separate acceptance
  checks; passing model/transport tests does not establish either result.

## Runtime Deployment

- Installed signed candidate `4ed5596` at the fixed Mac application path through
  the normal administrator-authorized helper update. The fixed development
  certificate, Accessibility approval, unlock enabled state and identical
  original device grants were verified after activation.
- Read-only HTTPS checks confirmed the unchanged configured LAN endpoint and
  compared each served HTML, JavaScript and CSS asset with the signed candidate.
  The installed resources and actual responses all match the build.
- The iOS app and daily renewal payload were unchanged by that deployment;
  physical acceptance is recorded separately below.
- The user subsequently reported the Safari experience working, and identified
  the obscured code window as a remaining issue. Window presentation acceptance
  for the floating-window change remains separate from the deployed `4ed5596`.

## Next Steps

- Verify the updated code window above another app, across Spaces and with a
  full-screen app; confirm Cancel and successful pairing both dismiss it.
- Continue physical Web gesture/keyboard acceptance and implement the recorded
  native feature gaps incrementally; BLE and other platform-dependent features
  need their own feasibility assessment.
