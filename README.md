# Mac Remote Controller

A native iPhone, iPad, and Android remote for controlling media playback on a Mac
from the sofa. The clients use SwiftUI and Jetpack Compose, with a Swift Mac
companion, an IINA plugin, and a TypeScript Chrome extension for YouTube and
Bilibili. The current apps are buildable scaffolds; pairing and remote-control
features are not implemented yet.

## Layout

```text
apps/
  macos/              Swift macOS companion
  ios/                Universal SwiftUI iPhone and iPad app
  android/            Kotlin and Jetpack Compose app
  chrome-extension/   TypeScript Manifest V3 extension
packages/
  apple-core/         Shared Swift package
  protocol/           Future language-neutral protocol and fixtures
tooling/
  swift/              Shared Apple checks and SwiftLint bootstrap
```

Each app and the Swift package keep their build/cache rules in a local
`.gitignore`. The root ignore file covers shared machine, environment, Node, and
task-temporary files. Shared Xcode projects/schemes, the Gradle wrapper, and
dependency locks belong in Git.

The Swift modules keep `.swift-format`, `.swiftlint.yml`, and Swift editor
settings in their own directories. The shared scripts in `tooling/swift/` use
those local configurations. Build products, archives, test results, personal
IDE settings, caches, and signing material are ignored; none are tracked.

## Repository checks

| Area             | Formatting             | Static checks            | Compiler and tests                              |
| ---------------- | ---------------------- | ------------------------ | ----------------------------------------------- |
| Repository       | Prettier               | Markdownlint, actionlint | Shell validation for repository scripts         |
| Swift            | Xcode's `swift format` | SwiftLint                | Shared package, macOS, and iOS Simulator builds |
| Chrome extension | Prettier               | Typed ESLint             | Strict `tsc`; unit tests; extension bundle      |
| Android          | ktlint                 | Android Lint             | Kotlin compilation; debug APK                   |

Swift and Kotlin compilation provide their type checks. The iOS target includes
both iPhone and iPad; macOS has its own app target and lifecycle.

Prefer the latest compatible stable toolchain and dependencies, with exact
dependency versions and committed lockfiles. Do not opt into preview releases.
Compiler/SDK versions can advance without raising the apps' minimum OS versions.
The platform READMEs and build files record any compatibility constraints.

Use Node.js 26 or newer and the pnpm version declared in `package.json`.
CI pins Node.js 26.12.0:

```sh
pnpm install --frozen-lockfile
pnpm run format:check
pnpm run lint
pnpm run typecheck
pnpm run test
pnpm run build
actionlint
```

`pnpm run format` applies repository and TypeScript formatting. Dependencies are
locked in the root `pnpm-lock.yaml`; install from the repository root.

On macOS, use Xcode 27.1 (Swift 6.4) and run:

```sh
tooling/swift/check.sh
```

To apply Swift formatting with the same configuration:

```sh
swift format format --in-place --recursive \
  apps/ios/SofaRemoteiOS apps/macos/SofaRemoteMac \
  packages/apple-core/Package.swift packages/apple-core/Sources
```

For Android, use JDK 27 and the Android SDK required by the checked-in Gradle
configuration, then run:

```sh
cd apps/android
./gradlew --no-daemon --console=plain ktlintCheck lintDebug assembleDebug
```

The Gradle wrapper pins its distribution and checksum. Use `ktlintFormat` to apply
Kotlin formatting. Native unit tests will be added with actual behavior; the
placeholder apps do not report empty or constant-only test tasks as coverage.
GitHub Actions runs the checks on pull requests and pushes to
`main` or `master`, using a macOS runner for Apple builds and Linux for Node and
Android. No signing credentials or device deployment are required for CI builds.

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
