---
id: 20261024-native-stack-ci-01a1464a
title: Native Pull Request Stack Verifier Events
status: completed
created: 2026-10-24
updated: 2026-10-25
branch: wip/native-stack-ci
pr:
supersedes: []
superseded_by:
---

# Native Pull Request Stack Verifier Events

## Outcome

- Subscribe the existing verifier to GitHub's `pull_request.stacked` activity
  so joining a native stack wakes a verifier for the current PR scope.
- Keep the existing required-check name, token permissions, provider review
  requirement, and upstream Action reference unchanged.
- The upstream v2.2.11 verifier supports authenticated GitHub-native stacks
  whose trunk is the repository's default branch. A manually chained set of
  feature-base PRs still needs native stack registration.
- Preserve the canonical non-skipping v2.2.13 verifier/controller from master.
  Both `stacked` and `edited` events invoke the verifier with the same required
  check. The actionlint exception remains scoped to the verifier path through
  `.github/actionlint.yaml`; the CI command needs no redundant global ignore.
- Stack registration does not merge any PR. Each feature head retains its
  own CI and review requirements.
- The iPhone/iPad UI-test step has a 40-minute cap inside the Apple job's
  50-minute cap. UI tests use a bounded 240-second per-test allowance. One PR5
  result artifact recorded successful actions at 117 seconds, before the prior
  120-second allowance. This is one timing observation; it does not establish
  the cause or recurrence of PR9's earlier exit-65 run.
- On UI-test failure, the script preserves the original `xcodebuild` status and
  reports up to ten failure summaries as GitHub annotations. Missing or
  unreadable summaries produce warnings without hiding the test failure.
- The UI runner shuts down and deletes each temporary simulator after its
  destination completes, before starting the next destination. The exit trap
  retries cleanup only for still-owned created devices; explicit UDIDs remain
  untouched. Cleanup errors fail a successful run and do not replace an
  existing `xcodebuild` failure status. This removes avoidable simulator
  overlap but does not establish the cause of earlier Simulator startup
  failures.
- actionlint 1.7.12 does not include the documented `stacked` activity. A
  path-specific filter permits only that exact diagnostic in this verifier;
  other invalid activity names remain errors.

## Validation

- actionlint 1.7.12, Prettier, Markdownlint, project-journal validation, and
  whitespace checks pass. A temporary `stacked_typo` negative control remains
  rejected by actionlint. Current-head CI and provider review are recorded
  on the PR.
- Ordinary repository-hygiene CI runs five mocked Simulator-lifecycle cases:
  ordered per-device shutdown/deletion, shutdown and delete failures, preserved
  `xcodebuild` status plus failure annotations, and explicit-UDID preservation.
  The mocks do not launch Simulator or adjust real audio.
- Native stack metadata and the `stacked` webhook are GitHub control-plane
  behavior; local YAML validation does not establish successful registration.

## References

- [Creating stacked pull requests](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-stacked-pull-requests)
- [Stacked pull request APIs and webhooks](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks)
