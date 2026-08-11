import 'package:flutter/foundation.dart';

const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// 公司内网后端地址。原生 Release 必须在构建时固定为 HTTPS；Web Release
/// 固定走同源 `/api`，由内外网域名（split-horizon DNS）决定实际站点。

/// Validated backend base URL shared by staff and visitor clients.
final String apiBaseUrl = resolveApiBaseUrl(
  _configuredApiBaseUrl,
  releaseMode: kReleaseMode,
  web: kIsWeb,
);

String resolveApiBaseUrl(
  String configured, {
  required bool releaseMode,
  required bool web,
}) {
  var value = configured.trim();
  if (value.isEmpty) {
    if (releaseMode) {
      if (web) return '/api';
      throw StateError('Release builds must define an HTTPS API_BASE_URL.');
    }
    return 'http://localhost:8080/api';
  }

  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }

  if (value.startsWith('/')) {
    if (!web || value != '/api') {
      throw StateError(
        'Relative API_BASE_URL values are only valid for Web /api.',
      );
    }
    return value;
  }

  final uri = Uri.tryParse(value);
  final validOrigin =
      uri != null &&
      uri.hasScheme &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
  if (!validOrigin || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw StateError('API_BASE_URL must be an absolute HTTP(S) URL.');
  }
  if (releaseMode && uri.scheme != 'https') {
    throw StateError('Release API_BASE_URL must use HTTPS.');
  }
  if (releaseMode && web) {
    throw StateError('Web release API_BASE_URL must use same-origin /api.');
  }
  if (releaseMode &&
      (uri.host == 'localhost' ||
          uri.host == '127.0.0.1' ||
          uri.host == '::1')) {
    throw StateError('Release API_BASE_URL cannot target a loopback host.');
  }
  return value;
}
