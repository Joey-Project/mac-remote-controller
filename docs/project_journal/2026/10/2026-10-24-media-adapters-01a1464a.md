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
- Final integrated local Swift checks passed 124 AppleCore/MacSupport tests, the Mac app
  build, generic iOS Simulator build, and generated plist validation. The
  `SofaRemoteNativeHost` product also builds. Pinned Node 26.12.0/pnpm 12.14.0
  formatting, lint, strict typecheck, tests, and builds passed. Chrome tests passed
  8/8 and IINA mock tests passed 4/4. `actionlint`, shell syntax checks, ShellCheck
  0.11.0, and project-journal validation passed.
- Chrome tests use DOM fixtures and IINA tests use mocks. No Chrome extension,
  native messaging registration, IINA plugin, live media site, or device was
  installed or tested; no audio was played. User setup and playback acceptance
  remain pending.

## Next Steps

- Follow the stack acceptance procedure after review and CI. Install only the
  signed builds selected by the user, configure Chrome and IINA locally, and
  verify each explicit target plus visible failures for unavailable controls.

## Evidence

- `apps/chrome-extension/README.md` and `apps/iina-plugin/README.md` contain
  the manual setup commands and installation paths.
- `apps/macos/README.md` documents the loopback bridge, credential boundary,
  and explicit media target behavior.
