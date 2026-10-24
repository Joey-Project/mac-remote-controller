---
id: 20261024-native-stack-ci-01a1464a
title: Native Pull Request Stack Verifier Events
status: completed
created: 2026-10-24
updated: 2026-10-24
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
- Stack registration does not merge any PR. Each feature head retains its
  own CI and review requirements.
- actionlint 1.7.12 does not include the documented `stacked` activity. A
  path-specific filter permits only that exact diagnostic in this verifier;
  other invalid activity names remain errors.

## Validation

- actionlint 1.7.12, Prettier, Markdownlint, project-journal validation, and
  whitespace checks pass. A temporary `stacked_typo` negative control remains
  rejected by actionlint. Current-head CI and provider review are recorded
  on the PR.
- Native stack metadata and the `stacked` webhook are GitHub control-plane
  behavior; local YAML validation does not establish successful registration.

## References

- [Creating stacked pull requests](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-stacked-pull-requests)
- [Stacked pull request APIs and webhooks](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks)
