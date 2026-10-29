import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'client_release.dart';
import 'software_windows_host.dart';

enum SoftwareDownloadPlatform {
  windows('Windows', Icons.window_rounded),
  android('Android', Icons.android_rounded),
  macos('macOS', Icons.desktop_mac_outlined),
  ios('iOS', Icons.phone_iphone_rounded);

  const SoftwareDownloadPlatform(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Flutter resolves the native host OS and the browser host OS on Web.
final softwareDevicePlatformProvider = Provider<SoftwareDownloadPlatform?>((
  ref,
) {
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => SoftwareDownloadPlatform.windows,
    TargetPlatform.android => SoftwareDownloadPlatform.android,
    TargetPlatform.macOS => SoftwareDownloadPlatform.macos,
    TargetPlatform.iOS => SoftwareDownloadPlatform.ios,
    _ => null,
  };
});

String softwareProductName(Locale locale) => locale.languageCode == 'zh'
    ? '优腾综合管理平台(UIMP)'
    : 'Uten Integrated Management Platform (UIMP)';

/// Browser OS hints choose the initial tab only. The user selects a target when
/// saving an installer for another PC; package selection never crosses targets.
String initialWindowsRuntimeFamily(String? userAgent) {
  final version = RegExp(
    r'Windows NT (\d+)\.(\d+)',
    caseSensitive: false,
  ).firstMatch(userAgent ?? '');
  return version?.group(1) == '6' &&
          const {'1', '3'}.contains(version?.group(2))
      ? ClientRuntimeFamily.wpfLegacy
      : ClientRuntimeFamily.flutter;
}

final softwareWindowsRuntimeFamilyProvider = Provider<String>((ref) {
  return initialWindowsRuntimeFamily(softwareWindowsUserAgent());
});

List<String> windowsDownloadArchitectures(String runtimeFamily) =>
    runtimeFamily == ClientRuntimeFamily.wpfLegacy
    ? const ['x64', 'x86']
    : const ['x64', 'arm64', 'x86'];

String windowsRuntimeLabel(String runtimeFamily) =>
    runtimeFamily == ClientRuntimeFamily.wpfLegacy
    ? 'Windows 7 SP1 / 8.1 兼容版'
    : 'Windows 10 / 11 常规版';

ClientRelease? selectWindowsInstaller(
  Iterable<ClientRelease> releases, {
  required String runtimeFamily,
  required String architecture,
}) => releases
    .where(
      (release) =>
          release.isWindowsInstaller &&
          release.runtimeFamily == runtimeFamily &&
          release.architecture == architecture,
    )
    .firstOrNull;
