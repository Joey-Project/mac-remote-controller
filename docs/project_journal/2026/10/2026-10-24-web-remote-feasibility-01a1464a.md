---
id: 20261024-web-remote-01a1464a
title: No-Install Web Remote Feasibility
status: completed
created: 2026-10-24
updated: 2026-10-24
branch: wip/mobile-web-probe
pr:
supersedes: []
superseded_by:
---

# No-Install Web Remote Feasibility

## Summary

- Added an offline TypeScript UI preview for evaluating touchpad, two-finger
  scroll, keyboard, and volume layouts in a browser. It does not connect to or
  control a Mac.
- A Safari SPA cannot preserve the existing QR invitation's direct server
  certificate pin check. Real web control needs an explicitly redesigned trust
  and endpoint path.

## Current State

- The existing invitation contains a Bonjour service UUID, a SHA-256
  certificate pin, and a short-lived one-time token. The iOS client resolves
  `_sofaremote._tcp` and makes a WSS connection whose TLS verifier compares the
  peer certificate against that QR pin.
- Browser JavaScript cannot perform the native Bonjour lookup. The standardized
  WebSocket interface exposes the URL and messaging state, but no peer
  certificate or certificate-pinning hook. Sending the invitation token to a
  manually entered endpoint would discard the existing QR-to-server binding.
- The current native endpoint is not directly usable as a secure Safari client.
  The preview therefore has no endpoint or pairing fields, does not parse
  invitations, opens no Mac control socket, and does not persist preview values.
- The preview handles one-finger movement and tap, two-finger scroll, pointer
  capture cancellation, window blur, and page deactivation. Its test boundary
  rejects network/storage APIs and checks gesture lifecycle hooks.
- The root pnpm workspace and CI include the offline preview's lint,
  type-check, tests, and build. The app keeps its package-local generated
  output ignored.
- A desktop in-app-browser smoke of the source-identical built mirror passed:
  the offline/no-Mac banner appeared, a left-click action ran locally, keyboard
  mode switched, text input reached nine characters, the right-arrow counter
  advanced, local volume reached 0%, and reload reset cursor, keys, text, and
  volume. The static server used `127.0.0.1:61201` and was stopped afterward.
  This did not test Safari, iPhone multitouch, Mac transport, pairing, or BLE.

## Transport Options

### App Clip

- An App Clip can use native networking APIs, preserving the option to verify a
  WSS certificate against the invitation pin. App Clips cannot use Bonjour, so
  pairing still needs an explicit endpoint or a small native discovery
  replacement.
- A local App Clip experience is useful for development: the Clip must be
  cached on the test device from an Xcode, Development, Ad Hoc, or TestFlight
  build, and the local invocation is registered on that device. Public default
  and demo links require the app and Clip to pass App Store review and become
  available in the App Store.

### Trusted HTTPS/WSS gateway

- A same-origin HTTPS page and WSS gateway could keep discovery and certificate
  verification server-side: the gateway resolves Bonjour, validates the Mac
  certificate against the QR pin, and only then forwards the one-time token to
  that Mac. Safari would trust the gateway through normal browser TLS validation;
  this is a different boundary from a browser comparing the Mac certificate
  itself.
- This requires a browser-trusted HTTPS origin reachable on the local network,
  a server-side pairing flow that binds the invitation to the pinned Mac, and a
  clear rule for where the one-time token is held. A self-signed Mac
  certificate alone does not supply a browser-trusted page origin.

The lowest-friction secure path has not been chosen. Do not add web
authentication or transport until one of these options has a concrete endpoint,
trust anchor, and token-binding design.

## Primary References

- [Apple: choosing functionality for an App Clip](https://developer.apple.com/documentation/appclip/choosing-the-right-functionality-for-your-app-clip) documents runtime restrictions, including that Bonjour is unavailable.
- [Apple: testing the App Clip launch experience](https://developer.apple.com/documentation/appclip/testing-the-launch-experience-of-your-app-clip) describes local experiences and cached development, Ad Hoc, or TestFlight builds.
- [Apple: configuring App Clip experiences](https://developer.apple.com/documentation/appclip/configuring-the-launch-experience-of-your-app-clip) describes default and demo invocation links and App Store Connect setup.
- [WHATWG WebSocket Standard](https://websockets.spec.whatwg.org/#the-websocket-interface) defines the browser interface and notes that it does not provide raw network access; the interface has no peer-certificate property.
- [WebKit issue 238049](https://bugs.webkit.org/show_bug.cgi?id=238049) records WebKit's response that Web Bluetooth was not being considered. The existing remote uses Wi-Fi/WSS, so Bluetooth is not a dependency for this preview.

## Next Steps

- If real no-install control remains a goal, choose either App Clip plus a
  Bonjour-free endpoint invitation, or a trusted same-origin gateway with
  server-side pin validation. Specify the endpoint, trust anchor, token lifetime,
  and token handoff before implementing transport.
- Use the offline preview only to evaluate browser control ergonomics. It is not
  evidence of pairing, TLS identity checks, Mac command delivery, or physical
  device behavior.

## Evidence

- Preview source and test hooks: `apps/web-remote/`.
- Workspace and CI commands: root `package.json`, `pnpm-workspace.yaml`, and
  `.github/workflows/ci.yml`.
- Protocol and trust implementation: `packages/apple-core/Sources/AppleCore/Pairing.swift`, `packages/apple-core/Sources/AppleCore/BonjourResolver.swift`, `packages/apple-core/Sources/AppleCore/WebSocketPeer.swift`, and `apps/ios/SofaRemoteiOS/App/RemoteModel.swift`.
