import 'dart:convert';

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
  );

  final String id, platform, architecture, version, releaseNotes, installMode;
  final String sha256, state;
  final int buildNumber, sizeBytes;
  final bool mandatory;
  final String? storeUrl;
  final String packageKind;
  final String? fileName;
  String get packagePath => '/client-updates/$id/download';

  bool get isWindowsInstaller =>
      platform == 'windows' &&
      packageKind == 'installer' &&
      installMode == 'windows_setup' &&
      state == 'PUBLISHED';

  bool matches(ClientInstallContext context) =>
      packageKind == 'update' &&
      platform == context.platform &&
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
      );
  final String platform, architecture, currentVersion, stagingDirectory;
  final int currentBuild;
  final bool supportsInPlaceUpdate, requiresSystemConfirmation;
  final bool lastUpdateFailed;

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
