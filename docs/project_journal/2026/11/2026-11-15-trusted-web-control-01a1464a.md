---
id: 20261115-trusted-web-control-01a1464a
title: Trusted LAN Web Remote
status: active
created: 2026-11-15
updated: 2026-11-15
branch: codex/web-remote-20261115
pr: https://github.com/Joey-Project/mac-remote-controller/pull/37
supersedes: []
superseded_by:
---

# Trusted LAN Web Remote

## Scope

- Provide a real no-install LAN client for Mac-displayed four-digit pairing,
  pointer, keyboard, system volume, revocation and reconnect.
- Preserve native input transport and accepted native UI. Keep the original
  offline preview separate from the new live entry point.
- Use a user-owned DNS-only hostname and public HTTPS certificate; bind only to
  an explicit private IPv4 address. Control traffic stays on the LAN.

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

## Implementation

- The Mac-only `web-gateway` package serves TLS 1.3 HTTPS/WSS on a dedicated NIO
  thread. It bounds admission, HTTP bodies, frames, rates and idle sessions, and
  checks exact Host/Origin before privileged requests or WebSocket upgrade.
- An unlocked Mac displays a two-minute PIN. The initiating browser owns its
  request through a separate secure cookie; three wrong entries rotate the PIN,
  and global limits prevent immediate retries across new requests. Pairing
  persists through the existing Keychain device store and revocation path.
- Secure, HttpOnly, SameSite=Strict host cookies authenticate input-only peers.
  Native tokens never reach JavaScript or URLs. Session/unlock/display/media and
  system-shortcut commands are outside the browser allowlist.
- Live touchpad and keyboard pages include a collapsible system-volume layer.
  Motion is frame-coalesced while keys, text and button transitions preserve
  ordering. Disconnect drops old input; acknowledged text clears only on success.
  Visibility changes cancel gestures, and stationary drags refresh the native
  held-input lease without repeating desktop button-down events.
- The Mac menu enables the endpoint, opens/copies its URL and reloads private
  configuration. Interface changes debounce listener rebinding. Optional
  Cloudflare publication verifies one existing DNS-only A record before patching
  and reading it back; unchanged addresses cause no write. Retries first re-read
  after ambiguous outcomes. DNS caches can still delay recovery.
- Certificate/key loading runs off the main actor. Replacement material is
  preloaded before listener restart. The separate daily Certbot check uses a
  private local runtime and leaves the phone-renewal automation untouched.
  Oversized historical Certbot logs are trimmed before the next attempt so a
  verbose failure cannot permanently exhaust renewal's log budget; unrelated
  files and symlink targets remain untouched.
- Domain/account identifiers, keys, tokens and certificates stay in private
  local configuration, outside Git. Setup and maintenance are documented under
  `tooling/web_remote/`.

## Validation

- TypeScript tests cover gesture cancellation, input ordering, stale connection
  generations, acknowledgement loss, reconnect and drag leases.
- Swift tests cover endpoint/Origin/cookie admission, pairing ownership,
  deadlines/rate limits, DNS verification, and private-file access policy.
- Apple CI drives real TLS/HTTP/WSS against the desktop-free Swift fixture,
  using an ephemeral explicitly trusted test certificate. It checks rejected
  cross-origin/anonymous requests, PIN ownership/reuse, input acknowledgements,
  disconnect cleanup, command scope, revocation and clean process shutdown.
- Local Chrome acceptance used a normal browser-trusted production certificate:
  page loading, PIN pairing, pointer/click/scroll commands, acknowledged text,
  control keys, mock volume, overlay, disconnect/reconnect, reload and forget.
  The fixture recorded zero real desktop events. This does not establish real
  Mac effects, physical Safari behavior or touch latency.
- The Mac candidate builds with the existing fixed development certificate.
  No simulator was started for this Web workstream.
- Initial certificate issuance and an actual scheduled maintenance check were
  separately verified locally. The check did not replace a certificate that
  was not due; expiration advancement and a full renewal cycle remain unproven.

## Next Steps

- Install the accepted Mac candidate and verify physical iPhone/iPad Safari,
  multitouch, keyboard/viewport behavior, and real Mac application effects.
- Observe actual certificate replacement and restart, changing LAN addresses,
  DNS caching, permission guidance and router rebinding protections.
- Keep App Clip evaluation and native-only controls outside this first Web slice.

## References

- [Cloudflare dynamic DNS](https://developers.cloudflare.com/dns/manage-dns-records/how-to/managing-dynamic-ip-addresses/)
- [Let's Encrypt DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- [Multicast DNS special-use names](https://www.rfc-editor.org/rfc/rfc6762.html#section-3)
- Prior feasibility: `2026/10/2026-10-24-web-remote-feasibility-01a1464a.md`.
- [Web setup](../../../../tooling/web_remote/README.md)
