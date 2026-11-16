---
id: 20261116-web-pairing-resume-01a1464a
title: Web Pairing Resume and Safari Requests
status: completed
created: 2026-11-16
updated: 2026-11-16
branch: wip/web-pairing-resume
pr:
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

## Validation

- Three new connection regressions fail against the previous implementation:
  the request policy, actionable rejection error, and background confirmation.
- Web tests cover unpaired foreground restoration, duplicate lifecycle events,
  explicit disconnect, and welcome-gated control presentation.
- All 49 Web tests, TypeScript type checking, lint, formatting, Markdown lint,
  project-journal validation and whitespace checks passed locally.
- Physical iPhone Safari pairing and real Mac input are separate acceptance
  checks; passing model/transport tests does not establish either result.

## Next Steps

- Verify the iPhone Safari foreground/pairing sequence against the deployed
  signed Mac companion, then complete real input acceptance from another device.
