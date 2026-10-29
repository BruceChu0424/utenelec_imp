import 'dart:convert';

abstract final class ClientRuntimeFamily {
  static const flutter = 'flutter';
  static const wpfLegacy = 'wpf_legacy';

  static bool supportsWindowsArchitecture(String family, String architecture) =>
      switch (family) {
        flutter => const {'x86', 'x64', 'arm64'}.contains(architecture),
        wpfLegacy => const {'x86', 'x64'}.contains(architecture),
        _ => false,
      };
}

class ClientRelease {
  const ClientRelease({
    required this.id,
    required this.platform,
    required this.architecture,
    required this.version,
    required this.buildNumber,
    required this.releaseNotes,
    required this.installMode,
    this.sha256 = '',
    this.sizeBytes = 0,
    this.mandatory = false,
    this.storeUrl,
    this.state = 'PUBLISHED',
    this.packageKind = 'update',
    this.fileName,
    this.runtimeFamily = ClientRuntimeFamily.flutter,
  });

  factory ClientRelease.fromJson(Map<String, dynamic> json) => ClientRelease(
    id: json['id'] as String,
    platform: json['platform'] as String,
    architecture: json['architecture'] as String,
    version: json['version'] as String,
    buildNumber: (json['buildNumber'] as num).toInt(),
    releaseNotes: json['releaseNotes'] as String? ?? '',
    installMode: json['installMode'] as String,
    sha256: json['sha256'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    mandatory: json['mandatory'] == true,
    storeUrl: json['storeUrl'] as String?,
    state: json['state'] as String? ?? 'PUBLISHED',
    packageKind: json['packageKind'] as String? ?? 'update',
    fileName: json['fileName'] as String?,
    runtimeFamily:
        json['runtimeFamily'] as String? ?? ClientRuntimeFamily.flutter,
  );

  final String id, platform, architecture, version, releaseNotes, installMode;
  final String sha256, state;
  final int buildNumber, sizeBytes;
  final bool mandatory;
  final String? storeUrl;
  final String packageKind;
  final String? fileName;
  final String runtimeFamily;
  String get packagePath =>
      '/client-updates/$id/download${runtimeFamily == ClientRuntimeFamily.wpfLegacy ? '?runtimeFamily=wpf_legacy' : ''}';

  bool get isWindowsInstaller =>
      platform == 'windows' &&
      packageKind == 'installer' &&
      ClientRuntimeFamily.supportsWindowsArchitecture(
        runtimeFamily,
        architecture,
      ) &&
      installMode ==
          (runtimeFamily == ClientRuntimeFamily.wpfLegacy
              ? 'windows_wpf_setup'
              : 'windows_setup') &&
      state == 'PUBLISHED';

  bool get isAndroidPackage =>
      platform == 'android' &&
      runtimeFamily == ClientRuntimeFamily.flutter &&
      const {
        'arm64',
        'armeabi-v7a',
        'x64',
        'universal',
      }.contains(architecture) &&
      const {'update', 'installer'}.contains(packageKind) &&
      installMode == 'android_package' &&
      state == 'PUBLISHED';

  bool get isTrustedStoreRelease =>
      runtimeFamily == ClientRuntimeFamily.flutter &&
      installMode == 'store' &&
      state == 'PUBLISHED' &&
      trustedStoreUri != null;

  bool matches(ClientInstallContext context) =>
      packageKind == 'update' &&
      platform == context.platform &&
      runtimeFamily == context.runtimeFamily &&
      (architecture == context.architecture || architecture == 'universal') &&
      buildNumber > context.currentBuild &&
      state == 'PUBLISHED';

  Uri? get trustedStoreUri {
    final uri = Uri.tryParse(storeUrl ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort && uri.port != 443) {
      return null;
    }
    if ((platform == 'ios' || platform == 'macos') &&
        uri.host == 'apps.apple.com') {
      return uri;
    }
    if (platform == 'android' &&
        uri.host == 'play.google.com' &&
        uri.path == '/store/apps/details') {
      return uri;
    }
    return null;
  }
}

class ClientInstallContext {
  const ClientInstallContext({
    required this.platform,
    required this.architecture,
    required this.currentVersion,
    required this.currentBuild,
    this.stagingDirectory = '',
    this.supportsInPlaceUpdate = false,
    this.requiresSystemConfirmation = false,
    this.lastUpdateFailed = false,
    this.runtimeFamily = ClientRuntimeFamily.flutter,
  });
  factory ClientInstallContext.fromJson(Map<dynamic, dynamic> json) =>
      ClientInstallContext(
        platform: json['platform'] as String,
        architecture: json['architecture'] as String,
        currentVersion: json['currentVersion'] as String,
        currentBuild: (json['currentBuild'] as num).toInt(),
        stagingDirectory: json['stagingDirectory'] as String? ?? '',
        supportsInPlaceUpdate: json['supportsInPlaceUpdate'] == true,
        requiresSystemConfirmation: json['requiresSystemConfirmation'] == true,
        lastUpdateFailed: _failed(
          json['lastUpdateResultJson'],
          (json['currentBuild'] as num).toInt(),
        ),
        runtimeFamily:
            json['runtimeFamily'] as String? ?? ClientRuntimeFamily.flutter,
      );
  final String platform, architecture, currentVersion, stagingDirectory;
  final int currentBuild;
  final bool supportsInPlaceUpdate, requiresSystemConfirmation;
  final bool lastUpdateFailed;
  final String runtimeFamily;

  static bool _failed(Object? value, int currentBuild) {
    if (value is! String || value.isEmpty) return false;
    try {
      final result = jsonDecode(value) as Map;
      return result['status'] == 'failed' &&
          (result['buildNumber'] as num? ?? 0) > currentBuild;
    } catch (_) {
      return false;
    }
  }
}
