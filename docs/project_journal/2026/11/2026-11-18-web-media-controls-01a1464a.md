---
id: 20261118-web-media-controls-01a1464a
title: Web Media Controls and Player Volume
status: active
created: 2026-11-18
updated: 2026-11-18
branch: wip/web-media-controls
pr:
supersedes: []
superseded_by:
---

# Web Media Controls and Player Volume

## Outcome

- Add an independently hideable player overlay using the existing Mac media
  targets and adapters. Require explicit selection and honor each capability.
  Preserve the accepted five-button order and fixed 10-second seek duration.
- Switch the volume heading between system and selected-player volume. Match
  native 10% increments, the strong 100% detent, percentage labels and advertised
  ranges above 100%. Keep the keyboard page and touchpad layout.
- Bound and validate incoming media state. Coalesce slider commands only for the
  same target; preserve ordering with motion, text and discrete actions. Never
  replay a media action after an ambiguous delivery failure. Ignore acknowledgements
  for old targets or replaced volume requests.
- Admit media control through the existing authenticated WebSocket peer and Mac
  media router. Keep session/display and native gesture commands outside the Web
  command scope. No new runtime credentials enter JavaScript.

## Validation

- The previous buffer rejects the two new media-ordering regressions; the
  updated Web suite passes 68 tests. Coverage includes target disappearance,
  capability/range changes, stale acknowledgements and disconnect/reconnect.
- Isolated headless Chrome checks the built live client at 390x844, 1024x768
  and 932x430: four overlay combinations, one five-button row, fixed seeks,
  percentage snapping/range, rejection rollback and keyboard clearance. Mock
  transport never emits desktop input or plays audio.
- All 25 gateway package tests and the real TLS/WSS transport test pass. The
  transport test covers accepted media requests, unsupported capabilities,
  unavailable targets, advertised volume limits and forbidden session/display
  commands. Type checking, lint, formatting and journal validation also pass.
- Physical Safari, real IINA/Chrome actions and touch latency remain acceptance
  work; mock transport results do not establish those effects.

## Next Steps

- Deploy only when requested, preserving the fixed Mac signing identity and
  existing helper/device authorization. This work does not update installed
  apps or the daily iOS renewal payload.
- Verify media controls and volume against real IINA and Chrome targets from
  Safari. Continue the remaining Web/native parity slices separately.
