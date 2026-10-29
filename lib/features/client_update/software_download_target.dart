import 'package:flutter/material.dart';

import 'client_package_integrity.dart';
import 'client_release.dart';

enum SoftwareDownloadPlatform {
  windows('Windows', Icons.window_rounded),
  android('Android', Icons.android_rounded),
  macos('macOS', Icons.desktop_mac_outlined),
  ios('iOS', Icons.phone_iphone_rounded),
  linux('Linux', Icons.computer_outlined);

  const SoftwareDownloadPlatform(this.label, this.icon);
  final String label;
  final IconData icon;

  static SoftwareDownloadPlatform? fromName(String? value) => switch (value) {
    'windows' => windows,
    'android' => android,
    'macos' || 'macOS' => macos,
    'ios' || 'iOS' => ios,
    'linux' => linux,
    _ => null,
  };
}

enum SoftwareWindowsVersion {
  windows7Sp1('Windows 7 SP1', ClientRuntimeFamily.wpfLegacy),
  windows81('Windows 8.1', ClientRuntimeFamily.wpfLegacy),
  windows10('Windows 10', ClientRuntimeFamily.flutter),
  windows11('Windows 11', ClientRuntimeFamily.flutter);

  const SoftwareWindowsVersion(this.label, this.runtimeFamily);
  final String label, runtimeFamily;
}

/// A user-selected download destination, independently of the detecting device.
/// An OS version here describes the target requirement, never proof about a UA.
class SoftwareDownloadTarget {
  const SoftwareDownloadTarget({
    required this.platform,
    this.runtimeFamily = ClientRuntimeFamily.flutter,
    required this.architecture,
    this.windowsVersion,
  });

  final SoftwareDownloadPlatform platform;
  final String runtimeFamily, architecture;
  final SoftwareWindowsVersion? windowsVersion;

  bool get isSupported =>
      softwareDownloadArchitectures(
        platform,
        runtimeFamily: runtimeFamily,
      ).contains(architecture) &&
      (windowsVersion == null ||
          platform == SoftwareDownloadPlatform.windows &&
              windowsVersion!.runtimeFamily == runtimeFamily &&
              !(windowsVersion == SoftwareWindowsVersion.windows11 &&
                  architecture == 'x86'));

  String get key =>
      '${platform.name}:$runtimeFamily:$architecture:${windowsVersion?.name ?? 'family'}';

  String get displayLabel {
    final os = platform == SoftwareDownloadPlatform.windows
        ? windowsVersion?.label ??
              (runtimeFamily == ClientRuntimeFamily.wpfLegacy
                  ? 'Windows 7 SP1 / 8.1'
                  : architecture == 'x86'
                  ? 'Windows 10'
                  : 'Windows 10 / 11')
        : platform.label;
    final flavor = platform == SoftwareDownloadPlatform.windows
        ? runtimeFamily == ClientRuntimeFamily.wpfLegacy
              ? ' 兼容版'
              : ' 常规版'
        : '';
    return '$os · ${softwareArchitectureLabel(architecture)}$flavor';
  }

  @override
  bool operator ==(Object other) =>
      other is SoftwareDownloadTarget && key == other.key;
  @override
  int get hashCode => key.hashCode;
}

String softwareArchitectureLabel(String architecture) => switch (architecture) {
  'x86' => 'X86',
  'x64' => 'X64',
  'arm64' => 'ARM64',
  'armeabi-v7a' => 'ARMv7',
  'universal' => '通用',
  _ => '架构待确认',
};

List<String> softwareDownloadArchitectures(
  SoftwareDownloadPlatform platform, {
  String runtimeFamily = ClientRuntimeFamily.flutter,
}) {
  if (platform == SoftwareDownloadPlatform.windows) {
    return switch (runtimeFamily) {
      ClientRuntimeFamily.wpfLegacy => const ['x64', 'x86'],
      ClientRuntimeFamily.flutter => const ['x64', 'arm64', 'x86'],
      _ => const [],
    };
  }
  if (runtimeFamily != ClientRuntimeFamily.flutter) return const [];
  return switch (platform) {
    SoftwareDownloadPlatform.android => const [
      'arm64',
      'armeabi-v7a',
      'x64',
      'universal',
    ],
    SoftwareDownloadPlatform.ios => const ['arm64', 'universal'],
    SoftwareDownloadPlatform.macos ||
    SoftwareDownloadPlatform.linux => const ['arm64', 'x64', 'universal'],
    SoftwareDownloadPlatform.windows => const [],
  };
}

List<SoftwareDownloadTarget> softwareDownloadTargets(
  SoftwareDownloadPlatform platform,
) {
  if (platform == SoftwareDownloadPlatform.windows) {
    return [
      for (final version in SoftwareWindowsVersion.values)
        for (final architecture in softwareDownloadArchitectures(
          platform,
          runtimeFamily: version.runtimeFamily,
        ))
          if (!(version == SoftwareWindowsVersion.windows11 &&
              architecture == 'x86'))
            SoftwareDownloadTarget(
              platform: platform,
              runtimeFamily: version.runtimeFamily,
              architecture: architecture,
              windowsVersion: version,
            ),
    ];
  }
  return [
    for (final architecture in softwareDownloadArchitectures(platform))
      SoftwareDownloadTarget(platform: platform, architecture: architecture),
  ];
}

/// The current catalog supports Windows Setup, Android APK and trusted stores.
/// A recognized OS is not a promise that a binary has been published for it.
bool isSoftwareInstallerForTarget(
  ClientRelease release,
  SoftwareDownloadTarget target,
) {
  if (!target.isSupported ||
      release.state != 'PUBLISHED' ||
      release.buildNumber <= 0 ||
      release.platform != target.platform.name ||
      release.runtimeFamily != target.runtimeFamily ||
      !(release.architecture == target.architecture ||
          target.platform != SoftwareDownloadPlatform.windows &&
              release.architecture == 'universal')) {
    return false;
  }
  if (release.installMode == 'store') return release.isTrustedStoreRelease;
  if (!hasValidClientPackageMetadata(release)) {
    return false;
  }
  return switch (target.platform) {
    SoftwareDownloadPlatform.windows =>
      release.isWindowsInstaller &&
          (release.fileName == null ||
              release.fileName!.toLowerCase().endsWith('.exe')),
    SoftwareDownloadPlatform.android =>
      release.isAndroidPackage &&
          (release.fileName?.toLowerCase().endsWith('.apk') ?? false),
    _ => false,
  };
}

ClientRelease? selectSoftwareInstaller(
  Iterable<ClientRelease> releases, {
  required SoftwareDownloadTarget target,
}) {
  ClientRelease? result;
  for (final release in releases) {
    final exact = release.architecture == target.architecture;
    final priorExact = result?.architecture == target.architecture;
    if (isSoftwareInstallerForTarget(release, target) &&
        (result == null ||
            exact && !priorExact ||
            exact == priorExact && release.buildNumber > result.buildNumber)) {
      result = release;
    }
  }
  return result;
}

bool isSoftwareDownloadRelease(ClientRelease release) {
  final platform = SoftwareDownloadPlatform.fromName(release.platform);
  return platform != null &&
      isSoftwareInstallerForTarget(
        release,
        SoftwareDownloadTarget(
          platform: platform,
          runtimeFamily: release.runtimeFamily,
          architecture: release.architecture,
        ),
      );
}

String softwareDownloadFilename(
  ClientRelease release, {
  SoftwareDownloadTarget? target,
}) {
  if (!isSoftwareDownloadRelease(release) || release.installMode == 'store') {
    throw ArgumentError('A verified binary download release is required.');
  }
  final selected =
      target ??
      SoftwareDownloadTarget(
        platform: SoftwareDownloadPlatform.fromName(release.platform)!,
        runtimeFamily: release.runtimeFamily,
        architecture: release.architecture,
      );
  if (!isSoftwareInstallerForTarget(release, selected)) {
    throw ArgumentError(
      'The selected destination does not match this release.',
    );
  }
  final os = selected.platform == SoftwareDownloadPlatform.windows
      ? switch (selected.windowsVersion) {
          SoftwareWindowsVersion.windows7Sp1 => 'windows7sp1',
          SoftwareWindowsVersion.windows81 => 'windows8.1',
          SoftwareWindowsVersion.windows10 => 'windows10',
          SoftwareWindowsVersion.windows11 => 'windows11',
          null =>
            selected.runtimeFamily == ClientRuntimeFamily.wpfLegacy
                ? 'windows7sp1-8.1'
                : selected.architecture == 'x86'
                ? 'windows10'
                : 'windows10-11',
        }
      : selected.platform.name;
  var version = release.version.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  if (version.length > 80) version = version.substring(0, 80);
  final extension = selected.platform == SoftwareDownloadPlatform.windows
      ? 'exe'
      : 'apk';
  return 'uten-imp-$version-build${release.buildNumber}-$os-${release.architecture}-setup.$extension';
}
