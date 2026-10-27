import 'package:flutter/foundation.dart';

import '../network/api_base_url.dart';
import '../network/api_endpoint_configuration.dart';

/// Credential-free ownership, kept with encrypted token records and revocations.
class AuthTokenIssuer {
  AuthTokenIssuer._(
    this.baseUrl,
    Iterable<String> relays,
    this.businessDatasetId,
  ) : trustedRelays = List<String>.unmodifiable(relays.toList()..sort());

  final String baseUrl;
  final List<String> trustedRelays;
  final String? businessDatasetId;

  AuthTokenIssuer withDataset(String? dataset) =>
      AuthTokenIssuer._(baseUrl, trustedRelays, dataset ?? businessDatasetId);

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'trustedRelays': trustedRelays,
    if (businessDatasetId != null) 'businessDatasetId': businessDatasetId,
  };

  static AuthTokenIssuer? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final rawUrl = value['baseUrl'];
    final relays = value['trustedRelays'];
    final dataset = value['businessDatasetId'];
    if (rawUrl is! String ||
        relays is! List ||
        relays.length > 8 ||
        relays.any((e) => e is! String) ||
        (dataset != null &&
            (dataset is! String || dataset.isEmpty || dataset.length > 128)))
      return null;
    final url = AuthBackendRealmPolicy.normalize(rawUrl);
    final normalized = relays
        .map((e) => AuthBackendRealmPolicy.normalize(e as String))
        .toList();
    if (url == null ||
        normalized.any((e) => e == null) ||
        (normalized.isNotEmpty && !normalized.contains(url)))
      return null;
    return AuthTokenIssuer._(
      url,
      normalized.whereType<String>().toSet(),
      dataset as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AuthTokenIssuer &&
      baseUrl == other.baseUrl &&
      businessDatasetId == other.businessDatasetId &&
      listEquals(trustedRelays, other.trustedRelays);
  @override
  int get hashCode =>
      Object.hash(baseUrl, businessDatasetId, Object.hashAll(trustedRelays));
  @override
  String toString() => 'AuthTokenIssuer[$baseUrl]';
}

/// Only build-reviewed company relays share credentials. A matching dataset
/// UUID cannot turn a separate debug/custom authority into a trusted receiver.
class AuthBackendRealmPolicy {
  AuthBackendRealmPolicy({
    Iterable<String> trustedCompanyEndpoints = const <String>[],
  }) : trustedCompanyEndpoints = Set<String>.unmodifiable(
         trustedCompanyEndpoints
             .map(normalize)
             .whereType<String>()
             .where((url) => !_loopback(url)),
       );

  factory AuthBackendRealmPolicy.fromBuildConfiguration() {
    final endpoints = <String>[apiBaseUrl];
    if (!kIsWeb && configuredCloudApiBaseUrl.trim().isNotEmpty) {
      try {
        endpoints.add(
          resolveApiBaseUrl(
            configuredCloudApiBaseUrl,
            releaseMode: kReleaseMode,
            web: false,
          ),
        );
      } on StateError {
        // Invalid optional cloud configuration never expands credential trust.
      }
    }
    return AuthBackendRealmPolicy(trustedCompanyEndpoints: endpoints);
  }

  final Set<String> trustedCompanyEndpoints;

  AuthTokenIssuer issuerFor(String endpoint, {String? businessDatasetId}) {
    final url = normalize(endpoint);
    if (url == null) throw StateError('Invalid authentication backend');
    return AuthTokenIssuer._(
      url,
      trustedCompanyEndpoints.contains(url)
          ? trustedCompanyEndpoints
          : const <String>[],
      businessDatasetId,
    );
  }

  bool canUse(
    AuthTokenIssuer? issuer,
    String endpoint, {
    bool allowLegacy = true,
  }) {
    final target = normalize(endpoint);
    if (target == null) return false;
    if (issuer == null)
      return allowLegacy && trustedCompanyEndpoints.contains(target);
    if (issuer.trustedRelays.isEmpty) return target == issuer.baseUrl;
    return trustedCompanyEndpoints.contains(target) &&
        issuer.trustedRelays.any(trustedCompanyEndpoints.contains);
  }

  AuthTokenIssuer? legacyIssuerFor(String endpoint) {
    final url = normalize(endpoint);
    return url != null && trustedCompanyEndpoints.contains(url)
        ? issuerFor(url)
        : null;
  }

  static String? normalize(String value) {
    var uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    if (!uri.hasScheme) uri = Uri.base.resolveUri(uri);
    if (!<String>{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment)
      return null;
    var path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final scheme = uri.scheme.toLowerCase();
    final port =
        uri.hasPort &&
            !((scheme == 'https' && uri.port == 443) ||
                (scheme == 'http' && uri.port == 80))
        ? uri.port
        : null;
    return Uri(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: port,
      path: path,
    ).toString();
  }

  static bool _loopback(String value) {
    final host = Uri.parse(value).host;
    return host == 'localhost' || host == '::1' || host.startsWith('127.');
  }
}
