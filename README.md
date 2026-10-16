# Mac Remote Controller

A native iOS and Android remote for controlling media playback on a Mac from the
sofa. The planned clients use SwiftUI and Jetpack Compose, with a Swift Mac
companion, an IINA plugin, and a Chrome extension for YouTube and Bilibili.

## Repository checks

This repository starts with a CI baseline for its existing configuration and
documentation. Native application builds will be added alongside their source.

Use Node.js 24 or newer and the pnpm version declared in `package.json`:

```sh
pnpm install --frozen-lockfile
pnpm run format:check
pnpm run lint
actionlint
```

`pnpm run format` applies formatting. GitHub Actions runs the same formatting and
Markdown checks, plus actionlint 1.7.11, on pull requests and pushes to `main` or `master`.
Dependencies are locked in `pnpm-lock.yaml`.

## Review gate

The existing Codex verifier and controller workflows are retained. The verifier
reports `codex/github-review-gate`; the controller processes official Codex review
events. Workflow ownership is defined in `.github/CODEOWNERS`.

`rulesets/codex-review-gate.json` remains a **Disabled import template**; its
presence does not establish active branch protection. See the
[upstream installation guide](https://github.com/Joey-Tools/codex-review-gate/blob/master/docs/install/human.md)
for repository protection setup.

## Project journal

Durable workstream state lives in `docs/project_journal/`:

- [CI baseline](docs/project_journal/2026/10/2026-10-16-ci-bootstrap-01a1464a.md)
- [Native remote design and implementation handoff](docs/project_journal/2026/10/2026-10-16-native-remote-01a1464a.md)
