# Shared protocol

This directory contains the language-neutral wire contract and cross-client
fixtures. The Apple implementation lives in `packages/apple-core`; future Kotlin
and TypeScript clients must preserve the same version, trust, and request rules.

The [v1 contract](v1-design.md) documents Apple pairing, desktop input, system
volume, and typed media-source commands. JSON fixtures in `fixtures/` are
mirrored in the Swift test resources; CI checks that the copies agree.
