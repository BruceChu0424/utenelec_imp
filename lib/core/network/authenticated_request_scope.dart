import 'dart:async';

import 'package:dio/dio.dart';

import '../security/secure_storage.dart';
import 'api_exception.dart';

/// Credential-free identity. Refresh generations and token bytes are not identity.
class AuthenticatedRequestIdentity {
  const AuthenticatedRequestIdentity({
    required this.baseUrl,
    required this.lineage,
    required this.intent,
    required this.impersonationLineage,
  });

  factory AuthenticatedRequestIdentity.fromRecords(
    String baseUrl,
    AuthTokenSnapshot auth,
    ImpersonationRecord? impersonation,
  ) => AuthenticatedRequestIdentity(
    baseUrl: baseUrl,
    lineage: auth.sessionLineage,
    intent: auth.intentGeneration,
    impersonationLineage: impersonation?.lineage,
  );

  final String baseUrl;
  final String? lineage;
  final int intent;
  final String? impersonationLineage;

  @override
  bool operator ==(Object other) =>
      other is AuthenticatedRequestIdentity &&
      baseUrl == other.baseUrl &&
      lineage == other.lineage &&
      intent == other.intent &&
      impersonationLineage == other.impersonationLineage;

  @override
  int get hashCode =>
      Object.hash(baseUrl, lineage, intent, impersonationLineage);
}

/// One user operation may issue several HTTP commands. Capture before any draft,
/// dialog, audit or network await; callers provide a sticky page/intent guard.
/// The immutable binding is also retained on RequestOptions for retry chains.
class AuthenticatedRequestScope {
  AuthenticatedRequestScope._(this.identity, this._storage, this._isCurrent);

  final AuthenticatedRequestIdentity identity;
  final SecureStorage? _storage;
  final bool Function() _isCurrent;
  bool _invalidated = false;
  static final Object _zoneKey = Object();
  static const _requestKey = '_utenAuthenticatedRequestScope';

  static Future<AuthenticatedRequestScope> capture({
    required String baseUrl,
    required SecureStorage? storage,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw changed();
    try {
      // Start both reads before yielding; never fetch a fresh identity per item.
      final records = storage == null
          ? (auth: const AuthTokenSnapshot.empty(), impersonation: null)
          : await readAuthRequestRecords(storage);
      final auth = records.auth;
      final impersonation = records.impersonation;
      if (!isCurrent() || impersonation?.isExpired == true) throw changed();
      final scope = AuthenticatedRequestScope._(
        AuthenticatedRequestIdentity.fromRecords(baseUrl, auth, impersonation),
        storage,
        isCurrent,
      );
      await scope.verify();
      return scope;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw unavailable();
    }
  }

  static AuthenticatedRequestScope? attach(RequestOptions options) {
    final retained = options.extra[_requestKey] as AuthenticatedRequestScope?;
    if (retained != null) return retained;
    final scope = Zone.current[_zoneKey] as AuthenticatedRequestScope?;
    if (scope != null) options.extra[_requestKey] = scope;
    return scope;
  }

  void checkCurrent() {
    if (_invalidated || !_isCurrent()) {
      _invalidated = true;
      throw changed();
    }
  }

  bool get isCurrent {
    try {
      checkCurrent();
      return true;
    } on ApiException {
      return false;
    }
  }

  void checkIdentity(AuthenticatedRequestIdentity current) {
    checkCurrent();
    if (identity != current) {
      _invalidated = true;
      throw changed();
    }
  }

  void checkEndpoint(RequestOptions options) {
    checkCurrent();
    final expected = Uri.parse(identity.baseUrl);
    final actual = options.uri;
    if (options.baseUrl != identity.baseUrl ||
        expected.scheme != actual.scheme ||
        expected.authority != actual.authority) {
      _invalidated = true;
      throw changed();
    }
  }

  Future<void> verify() async {
    checkCurrent();
    final storage = _storage;
    // Unauthenticated clients cannot adopt an authenticated binding.
    if (storage == null) return;
    try {
      final records = await readAuthRequestRecords(storage);
      final auth = records.auth;
      final impersonation = records.impersonation;
      checkIdentity(
        AuthenticatedRequestIdentity.fromRecords(
          identity.baseUrl,
          auth,
          impersonation,
        ),
      );
      if (impersonation?.isExpired == true) {
        _invalidated = true;
        throw changed();
      }
    } on ApiException {
      rethrow;
    } catch (_) {
      throw unavailable();
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    await verify();
    return runZoned(action, zoneValues: {_zoneKey: this});
  }

  static ApiException changed() => ApiException(
    'SESSION_CHANGED',
    '页面、服务器或登录身份已变化，请重新进入并核对原报告',
    httpStatus: 409,
    hasResponseCode: true,
  );

  static ApiException unavailable() => ApiException(
    'SESSION_STATE_UNAVAILABLE',
    '账号状态暂时无法确认，请核对原报告；请勿重新制单',
    httpStatus: 409,
    hasResponseCode: true,
  );
}

bool isSessionBoundaryError(Object error) =>
    error is ApiException &&
    const {'SESSION_CHANGED', 'SESSION_STATE_UNAVAILABLE'}.contains(error.code);

/// Observe both read failures before yielding; one failed store must not leave
/// the other future's error unhandled while a command is waiting.
Future<({AuthTokenSnapshot auth, ImpersonationRecord? impersonation})>
readAuthRequestRecords(SecureStorage storage) async {
  final values = await Future.wait<Object?>([
    storage.getAuthTokenSnapshot(),
    storage.getImpersonationRecord(),
  ], eagerError: true);
  return (
    auth: values[0] as AuthTokenSnapshot,
    impersonation: values[1] as ImpersonationRecord?,
  );
}
