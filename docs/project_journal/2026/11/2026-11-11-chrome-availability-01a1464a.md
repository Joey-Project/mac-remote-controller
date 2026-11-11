---
id: 20261111-chrome-availability-01a1464a
title: Chrome Media Recovery After Worker Restart
status: active
created: 2026-11-11
updated: 2026-11-11
branch: codex/chrome-availability-20261111
pr: https://github.com/Joey-Project/mac-remote-controller/pull/30
supersedes: []
superseded_by:
---

# Chrome Media Recovery After Worker Restart

## Summary

- Diagnose the reported Chrome extension unavailability without requiring phone
  interaction. Preserve the accepted media UI, command deadlines and permissions.
- Keep the current live installation separate from isolated automated validation.

## Current State

- Previously, worker startup refreshed only an in-memory set of known media tabs.
  A new worker has an empty set, so existing hidden players could remain undiscovered
  until another page event or timer. Regression tests reproduce this without
  a real browser or phone.
- Each fresh worker now queries currently loaded YouTube/Bilibili tabs and asks
  their existing content scripts for a fresh snapshot. Startup and installation
  events share an in-flight enumeration. Only a validated snapshot starts native
  work; no stored tab identity or playback command is restored.
- Unsupported URLs, discarded tabs, invalid tab identities, unavailable scripts
  and failed queries remain inert. No script injection, page reload, permission
  expansion, periodic tab enumeration or additional native reconnect timer is used.
- Existing reconnection backoff, bounded registration, acknowledgement matching
  and late-result rejection remain covered by the service-worker tests.
- Validation builds run in an isolated package snapshot because a browser may
  still load the repository's generated `dist` directory. Tests do not replace
  files in an active extension installation.
- All 49 Chrome package tests pass, including eight discovery regressions.
  Five new cases failed against the original worker before the fix. Strict
  TypeScript checking, Oxlint, formatting, Markdown and journal checks pass.

## Remaining Acceptance

- The reported live failure is not yet tied to one observed cause. Matching
  installation files and correct registration alone do not prove tab delivery.
- Verify real Chrome worker restart, page delivery and matched results when the
  browser surface is available; physical-phone acceptance remains separate.
- An extension update can invalidate an already-loaded content script. That page
  still needs its documented refresh; this change does not inject a replacement.

## Evidence

- Related adapter design and acceptance:
  [media workstream](../10/2026-10-24-media-adapters-01a1464a.md).
- Source: `apps/chrome-extension/src/service-worker.ts`.
- Regression coverage: `apps/chrome-extension/test/service-worker.test.mjs`.
- Local sanitized diagnostics and isolated tests:
  `.codex-tmp/chrome-availability-20261111/`.
