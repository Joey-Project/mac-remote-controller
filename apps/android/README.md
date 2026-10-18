# Android app

This directory contains the native Android scaffold. It uses Kotlin and Jetpack Compose and currently displays only a centered scaffold label.

## Toolchain

- JDK 27 for Gradle and Kotlin compilation, with Java bytecode targeting 17
- Android Gradle Plugin 9.4.1
- Kotlin 2.4.21, with the AGP 9 built-in Kotlin version overridden by the matching Kotlin Gradle plugin
- Gradle 9.8.1 through the checked-in wrapper
- Android SDK Command-line Tools 23.0, whose Android CLI is 1.0.16625370
- Android SDK platform 37.0 and Build Tools 37.0.0
- Jetpack Compose BOM 2026.09.00
- Activity Compose 1.13.0
- ktlint Gradle plugin 14.2.0 with ktlint 1.8.0

Gradle is configured with a 2 GiB heap and up to two workers so D8 has enough heap during dex merging.

The project uses ktlint for Kotlin formatting and Android Lint for Android-specific static checks.
The wrapper pins the Gradle distribution checksum, and its bootstrap JAR is verified against Gradle's published checksum.

## Local commands

Run these commands from this directory:

```sh
./gradlew ktlintFormat
./gradlew --no-daemon --console=plain ktlintCheck lintDebug assembleDebug
```
