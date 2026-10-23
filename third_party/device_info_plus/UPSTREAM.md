# device_info_plus 11.5.0 Android toolchain migration

Runtime sources and the original BSD license come from the published 11.5.0
archive, SHA-256 `98f28b42168cc509abc92f88518882fd58061ea372d7999aecc424345c7bff6a`.
All Dart and native runtime behavior is preserved; only the whitespace hygiene
described below touches platform metadata text.
Examples and upstream development tests are omitted.

The Android Gradle file now uses the application's AGP/Kotlin toolchain and the
modern Kotlin compiler-options interface, retaining JVM 17. It no longer declares
its own obsolete KGP 1.7.22/AGP 8.3.1 or independently pins an old Kotlin stdlib.
Flutter 3.44 owns the documented transitional KGP application; newer hosts can use
AGP built-in Kotlin. No warnings or compiler checks are suppressed. Package
metadata marks this unpublished local package as 11.5.0+uten.1.

Hosted 13.2+ adds built-in Kotlin support, but its dependency/platform requirements
also change. Remove this override and directory together after a reviewed hosted
upgrade passes the device-audit tests and native build jobs. Never patch the
global Pub cache or a runner's downloaded package.

References: [Flutter's plugin migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors)
and the [upstream changelog](https://pub.dev/packages/device_info_plus/changelog).

A separate source hygiene patch normalizes only line endings, trailing spaces,
and excess final blank lines in `ios/device_info_plus.podspec`.
The original archive and file hashes remain recorded. The audit helper compares
these files to the actual upstream archive after precisely that whitespace
normalization; a substantive code change is rejected even if its local hash is
updated. No whitespace check is disabled.
