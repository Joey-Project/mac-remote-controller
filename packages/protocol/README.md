# Shared protocol

This directory contains the language-neutral wire contract and cross-client
fixtures. The Apple implementation lives in `packages/apple-core`; future Kotlin
and TypeScript clients must preserve the same version, trust, and request rules.

The [v1 contract](v1-design.md) distinguishes the implemented Apple foundation
from the planned media-adapter semantics. The JSON fixture in `fixtures/` is
mirrored in the Swift test resources; CI checks that the copies agree.
