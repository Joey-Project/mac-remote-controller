# Android app

This directory contains the native Android scaffold. It uses Kotlin and Jetpack Compose and currently displays only a centered scaffold label.

## Toolchain

- JDK 17
- Android Gradle Plugin 9.3.2
- Kotlin 2.2.10, provided as the AGP 9 built-in Kotlin version
- Gradle 9.7.0 through the checked-in wrapper
- Android SDK platform 36 and Build Tools 36.0.0
- Jetpack Compose BOM 2026.06.00 (the Compose 1.11 line supports compileSdk 36)
- ktlint Gradle plugin 14.2.0 with ktlint 1.8.0

Detekt is not enabled yet. The current compatible plugin line is built against a newer Kotlin compiler than AGP 9's built-in Kotlin 2.2.10. The project uses ktlint for Kotlin formatting and Android Lint for Android-specific static checks.

## Local commands

Run these commands from this directory:

```sh
./gradlew ktlintFormat
./gradlew --no-daemon --console=plain ktlintCheck lintDebug assembleDebug
```
