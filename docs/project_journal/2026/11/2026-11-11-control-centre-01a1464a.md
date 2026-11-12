---
id: 20261111-control-centre-01a1464a
title: iOS Control Centre and Widget Entry Points
status: active
created: 2026-11-11
updated: 2026-11-12
branch: codex/control-centre-entrypoints-20261111
pr: https://github.com/Joey-Project/mac-remote-controller/pull/31
supersedes: []
superseded_by:
---

# iOS Control Centre and Widget Entry Points

## Summary

- Provide native touchpad and keyboard launch controls, Home Screen and Lock
  Screen widgets, and renewal support for their fixed WidgetKit extension.
- Preserve the existing touchpad, keyboard, volume UI and connection admission.

## Current State

- Control Centre exposes separate Touchpad and Keyboard controls on iOS/iPadOS
  18 or newer. Two fixed foreground App Intents run in the main app. Widgets
  retain iOS 17 support: the small and accessory families open touchpad, while
  the medium Home widget has separate touchpad and keyboard links.
- The extension has no App Group, pairing storage or remote connection. Its
  timeline is static; it does not poll, display cached connection state or
  perform a command. The main app accepts only the two exact navigation URLs.
  An offline launch keeps the usual explicit pairing/connection flow and retains
  the requested mode until a connection completes. Reopening an entry dismisses
  settings/details and releases an existing local drag before changing modes.
- The app embeds `SofaRemoteWidgets.appex`. App and extension inherit the same
  version settings; both intents are source members of both targets. Existing
  Swift CI covers the shared entry and extension sources.
- Renewal allows only this fixed WidgetKit bundle and identifier. It issues
  a separate profile through the probe's fixed `widget-profile` mode, checks
  expiry advancement independently, signs inside out and verifies preserved
  entitlements and executable instructions. Profiles use distinct private
  paths; the main receipt's existing expiration fields retain their meaning.
- Unknown/nested/substituted extensions, missing profiles and cross-team or
  certificate mismatches stop signing or installation. Failed extension
  issuance cannot install a partially renewed app. Legacy apps do not invoke
  the extension mode and keep the original renewal flow.
- The updated pinned probe rebuilds with Swift 6.3.3. Device and Simulator
  app/extension builds and the UI test bundle compile with Xcode 26.6. The
  generated app and extension both contain opening-intent metadata.
- Two strict navigation URL tests and all 41 renewal-tool tests pass. New UI
  tests cover cold/repeated URL opening and disconnected/unknown routes without
  input. Their execution remains separate from compilation.
- Real native Control Centre discovery, addition and taps on iOS 26.5 Simulator
  exposed a failure in the original enum-parameter OpenIntent path. Two fixed
  foreground actions replace that declaration combination; both production
  controls now open the correct app mode through actual system UI. The native
  regression test waits for rendered controls instead of tapping placeholders.
- Simulator UI tests use local ad-hoc signing without an Apple team or account
  so WidgetKit/intent execution is exercised normally. Mocked lifecycle tests
  enforce those flags while preserving device cleanup and failure propagation.
  Native system-gallery acceptance is explicit opt-in because it changes the
  Simulator's controls. Ordinary CI retains the deterministic URL regressions.

## Remaining Acceptance

- Complete native iPad Control Centre and Lock Screen/Home widget launches.
  The iPad gallery accessibility query and native Home widget long-press-menu
  attempts timed out and are not passes; keep discovery, adding, rendering and
  link activation separate. No real-device acceptance is implied by Simulator
  results.
- First sign both iOS bundle identifiers with the existing development team and
  certificate, then validate actual extension-profile issuance, candidate
  signatures, installation and renewed expiry on the paired phone.
- Package the updated probe before accepting an extension-bearing iOS payload.
  No running probe, approved payload, installed app or daily schedule is changed
  by this implementation. Keep deployment and new observation days explicit.

## Evidence

- [iOS setup and entry points](../../../../apps/ios/README.md#control-centre-and-widgets).
- [Extension renewal contract](../../../../tooling/renewal/README.md#widgetkit-extension-renewal).
- Local bounded build/test evidence: `.codex-tmp/control-centre-20261111/`.
