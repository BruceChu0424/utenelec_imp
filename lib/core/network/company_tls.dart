import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'company_tls_policy.dart';
import 'company_tls_stub.dart'
    if (dart.library.io) 'company_tls_io.dart'
    as platform;

export 'company_tls_policy.dart';

/// Load and verify the public company CA once before API providers are mounted.
/// Web retains browser TLS verification and never imports an application CA.
Future<void> initializeCompanyTls({
  Future<ByteData> Function(String key)? loadAsset,
}) => platform.initializeCompanyTls(loadAsset ?? rootBundle.load);

/// One transport entry for anonymous probes, API reads/writes and refreshes.
/// The native adapter selects trust by the actual request origin, not only the
/// Dio base URL, so the company CA never extends trust for another hostname.
Dio createCompanyDio(BaseOptions options) => platform.createCompanyDio(options);

CompanyTlsException? companyTlsFailure(Object? error) {
  var current = error;
  for (var depth = 0; depth < 4; depth++) {
    if (current is CompanyTlsException) return current;
    if (current is! DioException) return null;
    final nested = current.error;
    if (identical(nested, current)) return null;
    current = nested;
  }
  return null;
}
