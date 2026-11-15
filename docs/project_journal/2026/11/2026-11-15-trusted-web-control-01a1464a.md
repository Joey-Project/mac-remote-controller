---
id: 20261115-trusted-web-control-01a1464a
title: Trusted LAN Web Remote
status: active
created: 2026-11-15
updated: 2026-11-15
branch: codex/web-remote-20261115
pr:
supersedes: []
superseded_by:
---

# Trusted LAN Web Remote

## Scope

- Add a real no-install browser client for trusted pairing, pointer, keyboard,
  system volume, and reconnect. Preserve native input latency and accepted UI.
- Keep the existing offline preview offline. The new input primitives are not
  connected to a browser transport or a Mac command executor yet.
- The user selected a private-LAN HTTPS endpoint under a user-owned domain,
  with automatic DNS updates when the Mac's private IPv4 address changes.

## Trust and Addressing

- Browser TLS uses normal public certificate validation for the configured
  hostname. The browser does not emulate native certificate-pin verification.
- DNS-only records point directly to the private LAN address; control traffic
  does not traverse the DNS provider. ACME DNS-01 can prove domain ownership
  without an inbound public HTTP listener or router port forwarding.
- Domain, zone/record identifiers, certificates, private keys, and API tokens
  belong in local private configuration, never in tracked project files.
- A public CNAME targeting a Bonjour `.local` name is not a portable substitute
  for address updates across ordinary DNS and multicast DNS resolvers.
- DNS caching can delay reconnection after an address change. Updating DNS is
  separate from restarting a listener bound to the new private interface.

## Current Implementation

- `RemoteInputBuffer` coalesces adjacent movement and volume updates for one
  frame. Clicks, button transitions, text, and keys flush earlier motion and
  send immediately. Packet splitting preserves displacement within native
  movement/scroll bounds. Queue overflow or transport failure ends the input
  stream; disconnect discards unsent commands, and reconnect never replays them.
- Gesture cancellation discards stale movement and releases held buttons once.
- `WebEndpoint` validates an explicit private IPv4 binding, canonical DNS
  hostname, nonprivileged port, and absolute certificate/key paths.
- `LANDNSPublisher` serializes updates to one configured DNS record. It verifies
  the record ID, hostname, A type, and DNS-only status before any change. An
  unchanged address produces no write. A changed address is patched and read
  back; the publisher never automatically repeats an ambiguous write.
- The separate Swift package keeps future HTTP/WebSocket/TLS dependencies out
  of AppleCore, iOS, the Native Messaging host, and the unlock helper.

## Next Steps

- Complete the HTTPS/WebSocket listener, same-origin request policy, browser
  pairing, secure cookie credentials, explicit revocation, and bounded sessions.
- Integrate the Web peer with native command ordering and held-input cleanup;
  keep privileged session controls outside the initial browser allowlist.
- Add the live touchpad/keyboard UI, connection lifecycle, and pushed state.
- Connect address observation, DNS publication, listener rebinding, and
  certificate renewal without adding work to the pointer hot path.
- Add the package and live-browser coverage to CI, then validate actual TLS,
  pairing, reconnection, and Mac effects before claiming live Web acceptance.

## References

- [Cloudflare dynamic DNS](https://developers.cloudflare.com/dns/manage-dns-records/how-to/managing-dynamic-ip-addresses/)
- [Let's Encrypt DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- [Multicast DNS special-use names](https://www.rfc-editor.org/rfc/rfc6762.html#section-3)
- Prior feasibility: `2026/10/2026-10-24-web-remote-feasibility-01a1464a.md`.
