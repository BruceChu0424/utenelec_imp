import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'company_tls_policy.dart';

CompanyTlsTrust? _companyTrust;
CompanyTlsException? _initializationFailure;
Future<void>? _initialization;

Future<void> initializeCompanyTls(
  Future<ByteData> Function(String key) loadAsset,
) => _initialization ??= _loadCompanyTrust(loadAsset);

Future<void> _loadCompanyTrust(
  Future<ByteData> Function(String key) loadAsset,
) async {
  try {
    final data = await loadAsset(companyCaAsset);
    _companyTrust = CompanyTlsTrust._verified(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      expectedSha256: companyCaPemSha256,
    );
  } catch (_) {
    // Keep the application usable enough to show its login error. Company TLS
    // requests remain fail-closed; this never accepts an unverified substitute.
    _initializationFailure = CompanyTlsException();
  }
}

Dio createCompanyDio(BaseOptions options) {
  final dio = Dio(options);
  dio.httpClientAdapter = _CompanyTlsAdapter(
    dio.httpClientAdapter,
    () => _companyTrust,
  );
  return dio;
}

final class CompanyTlsTrust {
  CompanyTlsTrust._(this.context, this._createHttpClient);

  factory CompanyTlsTrust._verified(
    List<int> certificate, {
    required String expectedSha256,
    HttpClient Function(SecurityContext context)? createHttpClient,
  }) {
    if (sha256.convert(certificate).toString() != expectedSha256) {
      throw CompanyTlsException();
    }
    final context = SecurityContext(withTrustedRoots: true);
    if (Platform.isIOS) {
      final pem = ascii.decode(certificate);
      final match = RegExp(
        r'-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----',
      ).firstMatch(pem);
      if (match == null) throw CompanyTlsException();
      context.setTrustedCertificatesBytes(
        base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
      );
    } else {
      context.setTrustedCertificatesBytes(certificate);
    }
    return CompanyTlsTrust._(context, createHttpClient);
  }

  /// Test-owned CAs and loopback connection factories never alter production
  /// origins, the bundled certificate pin or the isolate's default context.
  @visibleForTesting
  factory CompanyTlsTrust.forTesting(
    List<int> certificate, {
    required String expectedSha256,
    HttpClient Function(SecurityContext context)? createHttpClient,
  }) => CompanyTlsTrust._verified(
    certificate,
    expectedSha256: expectedSha256,
    createHttpClient: createHttpClient,
  );

  final SecurityContext context;
  final HttpClient Function(SecurityContext context)? _createHttpClient;

  IOHttpClientAdapter _adapter() => IOHttpClientAdapter(
    createHttpClient: () =>
        (_createHttpClient?.call(context) ?? HttpClient(context: context))
          ..idleTimeout = const Duration(seconds: 3),
  );

  @visibleForTesting
  HttpClientAdapter wrapForTesting(HttpClientAdapter original) =>
      _CompanyTlsAdapter(original, () => this);
}

final class _CompanyTlsAdapter implements HttpClientAdapter {
  _CompanyTlsAdapter(this._publicAdapter, this._trust);

  final HttpClientAdapter _publicAdapter;
  final CompanyTlsTrust? Function() _trust;
  IOHttpClientAdapter? _companyAdapter;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!isApprovedCompanyTlsOrigin(options.uri)) {
      return _publicAdapter.fetch(options, requestStream, cancelFuture);
    }
    final trust = _trust();
    if (trust == null) {
      throw DioException.badCertificate(
        requestOptions: options,
        error: _initializationFailure ?? CompanyTlsException(),
      );
    }
    // HttpClient follows redirects inside its adapter. Refuse them before a
    // password or bearer header can leave the approved company origin.
    options.followRedirects = false;
    final adapter = _companyAdapter ??= trust._adapter();
    try {
      return await adapter.fetch(options, requestStream, cancelFuture);
    } on HandshakeException {
      throw DioException.badCertificate(
        requestOptions: options,
        error: CompanyTlsException(),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.badCertificate ||
          error.error is HandshakeException) {
        throw DioException.badCertificate(
          requestOptions: options,
          error: CompanyTlsException(),
        );
      }
      rethrow;
    }
  }

  @override
  void close({bool force = false}) {
    _companyAdapter?.close(force: force);
    _publicAdapter.close(force: force);
  }
}
