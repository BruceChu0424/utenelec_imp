import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'client_release.dart';
import 'software_windows_host.dart';
import 'software_download_target.dart';
import 'software_host_info.dart';
import '../../shared/providers/authenticated_scope_provider.dart';
import '../../core/network/server_config.dart';

export 'software_download_target.dart';
export 'software_host_info.dart';

typedef SoftwareHostReader = Future<SoftwareHostInfo> Function();

final softwareHostReaderProvider = Provider<SoftwareHostReader>(
  (ref) => readSoftwareHostInfo,
);

class SoftwareHostProbeCancelled implements Exception {
  const SoftwareHostProbeCancelled();
}

/// A late result cannot seed the selection of another login/server or a closed page.
final softwareHostInfoProvider = FutureProvider.autoDispose<SoftwareHostInfo>((
  ref,
) async {
  ref.watch(authenticatedScopeProvider);
  ref.watch(apiBaseUrlProvider);
  var current = true;
  ref.onDispose(() => current = false);
  SoftwareHostInfo info;
  try {
    info = await ref
        .watch(softwareHostReaderProvider)()
        .timeout(const Duration(seconds: 2));
  } catch (_) {
    if (!current) throw const SoftwareHostProbeCancelled();
    info = SoftwareHostInfo(
      platform: ref.read(softwareDevicePlatformProvider),
      osLabel: ref.read(softwareDevicePlatformProvider)?.label ?? '系统待确认',
      source: 'unavailable',
      certaintyExplanation: '未能完整识别当前系统，请手动选择下载目标。',
    );
  }
  if (!current) throw const SoftwareHostProbeCancelled();
  return info;
});

/// Flutter resolves the native host OS and the browser host OS on Web.
final softwareDevicePlatformProvider = Provider<SoftwareDownloadPlatform?>((
  ref,
) {
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => SoftwareDownloadPlatform.windows,
    TargetPlatform.android => SoftwareDownloadPlatform.android,
    TargetPlatform.macOS => SoftwareDownloadPlatform.macos,
    TargetPlatform.iOS => SoftwareDownloadPlatform.ios,
    TargetPlatform.linux => SoftwareDownloadPlatform.linux,
    _ => null,
  };
});

String softwareProductName(Locale locale) => locale.languageCode == 'zh'
    ? '优腾综合管理平台(UIMP)'
    : 'Uten Integrated Management Platform (UIMP)';

/// Browser OS hints choose the initial tab only. The user selects a target when
/// saving an installer for another PC; package selection never crosses targets.
String initialWindowsRuntimeFamily(String? userAgent) {
  return softwareHostFromBrowser(userAgent: userAgent).windowsRuntimeFamily ??
      ClientRuntimeFamily.flutter;
}

final softwareWindowsRuntimeFamilyProvider = Provider<String>((ref) {
  return initialWindowsRuntimeFamily(softwareWindowsUserAgent());
});

List<String> windowsDownloadArchitectures(String runtimeFamily) =>
    softwareDownloadArchitectures(
      SoftwareDownloadPlatform.windows,
      runtimeFamily: runtimeFamily,
    );

String windowsRuntimeLabel(String runtimeFamily) =>
    runtimeFamily == ClientRuntimeFamily.wpfLegacy
    ? 'Windows 7 SP1 / 8.1 兼容版'
    : 'Windows 10 / 11 常规版';

ClientRelease? selectWindowsInstaller(
  Iterable<ClientRelease> releases, {
  required String runtimeFamily,
  required String architecture,
}) => selectSoftwareInstaller(
  releases,
  target: SoftwareDownloadTarget(
    platform: SoftwareDownloadPlatform.windows,
    runtimeFamily: runtimeFamily,
    architecture: architecture,
  ),
);
