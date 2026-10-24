---
id: 20261024-media-01a1464a
title: Native Media Adapters for IINA and Chrome
status: active
created: 2026-10-24
updated: 2026-10-24
branch: wip/media-adapters
pr:
supersedes: []
superseded_by:
---

# Native Media Adapters for IINA and Chrome

## Summary

- Add explicitly selected Chrome-tab and IINA-window playback targets to the
  native remote. Media selection remains separate from desktop focus.

## Current State

- The Mac companion exposes an optional media-only HTTP bridge on loopback.
  A random token lives in its mode-0600 configuration. The Chrome Native
  Messaging host reads that file directly, keeping the credential out of the
  extension and page. The IINA plugin uses its local preference for the same
  bridge and does not open a listener.
- Chrome targets the current YouTube or Bilibili tab. IINA reports an exact
  target for each player window. Playback, seek, playlist navigation, and
  player volume are routed to the selected target, independently of frontmost
  application focus. Unsupported controls fail visibly.
- Player volume stays a gain ratio on the wire (`1.0` is 100%). The IINA
  adapter converts mpv percentage values at its boundary, and iOS converts the
  ratio to percentage only for its display and 10-point slider policy.
- IINA sends the plugin API's form-encoded command body and reports effective
  volume zero while muted; only positive player-volume commands clear mute.
  The loopback router uses a two-second deadline while its clients allow three
  seconds, keeps socket and route deadlines independent, and releases capacity
  after timeout. The Chrome service worker refreshes registered tabs from the
  current document every two seconds while its native messaging port is
  connected, so hidden-page timer throttling does not age out an unchanged
  player source. Muted HTML media also reports effective volume zero.
- Second-review hardening keeps IINA target IDs and UTF-8 byte limits compatible
  with JavaScriptCore, and checks playlist availability at command execution.
  Both bridge routes decode the same Codable HTTP command envelope. Timed-out
  request ownership is retained for 30 seconds with a 256-entry cap; only a
  matching late result receives 204. Chrome uses a 1.5-second action deadline,
  discards late content-script callbacks, and clamps live/DVR seeks to valid
  seekable ranges, choosing the nearest endpoint across gaps.
- Final integrated local Swift checks passed 146 AppleCore package tests, the macOS app
  build, generic iOS Simulator build, and generated plist validation. The
  `SofaRemoteNativeHost` release product also builds. Pinned Node 26.12.0/pnpm
  12.14.0 formatting, lint, strict typecheck, tests, and builds passed: Chrome
  15/15 and IINA mocks 10/10. `actionlint`, shell syntax checks, ShellCheck
  0.11.0, and project-journal validation passed. The backend lane reported six
  focused bridge route/lifecycle tests and one localhost HTTP smoke passed.
- Chrome tests use DOM fixtures and IINA tests use mocks. No Chrome extension,
  native messaging registration, IINA plugin, live media site, or device was
  installed or tested; no physical radio test or audio playback was performed.
  User setup and playback acceptance remain pending.

## Next Steps

- Follow the stack acceptance procedure after review and CI. Install only the
  signed builds selected by the user, configure Chrome and IINA locally, and
  verify each explicit target plus visible failures for unavailable controls.

## Evidence

- `apps/chrome-extension/README.md` and `apps/iina-plugin/README.md` contain
  the manual setup commands and installation paths.
- `apps/macos/README.md` documents the loopback bridge, credential boundary,
  and explicit media target behavior.
