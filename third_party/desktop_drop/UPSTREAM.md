# desktop_drop 0.8.4 Android toolchain migration

Runtime sources and the original MIT license come from the published 0.8.4
archive, SHA-256 `47ded09c85909edfed644fd4cbb5051b040d0aed5c79e7e062ea4b3b7156dbe4`.
All Dart and native runtime behavior is preserved; only the whitespace hygiene
described below touches native source text.
Examples and upstream development tests are omitted.

The functional Android build change is `android/build.gradle`: use the application's single
AGP/Kotlin toolchain instead of declaring another KGP/AGP version, and align Java
and Kotlin output at 17. Flutter 3.44 automatically applies its documented Kotlin
compatibility plugin to Android libraries which have migrated away from an
explicit KGP application. No warnings, compiler checks, or runtime behavior are
disabled. Package metadata changes only mark this as an unpublished local
0.8.4+uten.1 package and remove upstream workspace-only resolution.

Upstream 0.9.2 addresses the KGP warning but requires Flutter 3.47.7/Dart 3.13.5
and a different drop callback/provider-lifetime API. Keep the current application's
reviewed API until that migration is performed. Remove this override and directory
together after its drop-target tests and Android/Windows build jobs pass against
a compatible hosted release. Never patch the global Pub cache.

References: [Flutter's plugin migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors)
and the [upstream changelog](https://pub.dev/packages/desktop_drop/changelog).

A separate source hygiene patch normalizes only line endings, trailing spaces,
and excess final blank lines in `CHANGELOG.md`, `android/src/main/kotlin/one/mixin/desktop/drop/DesktopDropPlugin.kt`, `macos/desktop_drop/Sources/desktop_drop/DesktopDropPlugin.swift`.
The original archive and file hashes remain recorded. The audit helper compares
these files to the actual upstream archive after precisely that whitespace
normalization; a substantive code change is rejected even if its local hash is
updated. No whitespace check is disabled.
