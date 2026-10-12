import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/platform_branding/platform_branding.dart';
import '../models/platform_server_status.dart';

abstract interface class PlatformSettingsRepository {
  Future<PlatformServerStatus> status();
  Future<PlatformBranding> fetch();
  Future<PlatformBranding> save(
    PlatformBranding branding, {
    Uint8List? logo,
    bool removeLogo = false,
  });
}

class DioPlatformSettingsRepository implements PlatformSettingsRepository {
  DioPlatformSettingsRepository(this.api);
  final ApiClient api;
  static const _path = '/admin/platform-settings';

  @override
  Future<PlatformServerStatus> status() async =>
      PlatformServerStatus.fromJson(await api.get('$_path/status'));

  @override
  Future<PlatformBranding> fetch() async => _parse(await api.get(_path));

  @override
  Future<PlatformBranding> save(
    PlatformBranding branding, {
    Uint8List? logo,
    bool removeLogo = false,
  }) async {
    if (logo != null && (logo.isEmpty || logo.length > 524288)) {
      throw const FormatException('Logo 文件须在 512 KB 以内');
    }
    if (logo != null && removeLogo) {
      throw const FormatException('不能同时更换和移除 Logo');
    }
    final saved = _parse(
      await api.put(
        _path,
        body: {
          ...branding.toUpdateJson(),
          'expectedVersion': branding.version,
          'logoBase64': logo == null ? null : base64Encode(logo),
          'removeLogo': removeLogo,
        },
      ),
    );
    if (saved.version <= branding.version) {
      throw const FormatException('服务器未确认新的平台设置版本，请重新读取核查');
    }
    return saved;
  }

  static PlatformBranding _parse(Map<String, dynamic> json) {
    if (json['version'] is! num ||
        json['companyName'] is! String ||
        json['platformName'] is! String ||
        json['primaryColor'] is! String ||
        json['secondaryColor'] is! String ||
        json['hasLogo'] is! bool) {
      throw const FormatException('服务器未返回完整的平台设置');
    }
    return PlatformBranding.fromJson(json);
  }
}

final platformSettingsRepositoryProvider = Provider<PlatformSettingsRepository>(
  (ref) => DioPlatformSettingsRepository(ref.watch(apiClientProvider)),
);
