// 鉴权拦截器：注入 Bearer access token；401 时协调刷新并重试；刷新明确失效才结束会话。
import 'package:dio/dio.dart';

import '../../security/auth_refresh_lock.dart';
import '../../security/secure_storage.dart';
import '../network_policy.dart';
import '../session_event_bus.dart';
import 'token_refresh_result.dart';

class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.storage,
    required this.baseUrl,
    Dio Function()? dioFactory,
    AuthRefreshLock? refreshLock,
  }) : _dioFactory = dioFactory ?? (() => Dio(buildApiBaseOptions(baseUrl))),
       _refreshLock = refreshLock ?? AuthRefreshLock('staff:$baseUrl');

  final SecureStorage storage;
  final String baseUrl;
  final Dio Function() _dioFactory;
  final AuthRefreshLock _refreshLock;

  static const _requestLineageKey = '_utenAuthRequestLineage';
  static const _requestIntentKey = '_utenAuthRequestIntent';
  static const _autoAuthorizationKey = '_utenAuthHeaderInjected';
  static const _profileGenerationKey = '_utenAuthTokenGeneration';
  static const _profileIntentKey = '_utenAuthIntentGeneration';
  static const _profileLineageKey = '_utenAuthSessionLineage';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_isPublicAuthExchange(options.path)) {
      // Login, refresh, and logout must remain reachable even when the local
      // secure token record is unavailable. Never leak a stale bearer header
      // into these credential exchanges.
      _removeAuthorizationHeader(options);
      options.extra[_autoAuthorizationKey] = false;
      handler.next(options);
      return;
    }

    final current = await storage.getAuthTokenSnapshot();
    final alreadyCaptured = options.extra.containsKey(_requestLineageKey);
    if (!alreadyCaptured) {
      // This marker is immutable for the logical request, including safe
      // connectivity retries. A later login must never adopt an older request.
      options.extra[_requestLineageKey] = current.sessionLineage;
      options.extra[_requestIntentKey] = current.intentGeneration;
      options.extra[_autoAuthorizationKey] = false;
    }

    final requestLineage = options.extra[_requestLineageKey] as String?;
    if (alreadyCaptured &&
        requestLineage != current.sessionLineage &&
        options.extra[_autoAuthorizationKey] == true) {
      _removeAuthorizationHeader(options);
      options.extra[_autoAuthorizationKey] = false;
    }

    if (_authorizationHeader(options) == null &&
        requestLineage != null &&
        requestLineage == current.sessionLineage &&
        current.hasAccessToken) {
      options.headers['Authorization'] = 'Bearer ${current.accessToken!}';
      options.extra[_autoAuthorizationKey] = true;
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;
    if (!_isTrackedAuthenticatedRequest(options)) {
      handler.next(response);
      return;
    }

    try {
      if (await _requestSessionMatches(options)) {
        handler.next(response);
      } else {
        handler.reject(_sessionChangedError(options));
      }
    } catch (_) {
      // Returning data to a different account is worse than discarding one
      // response. The write, if any, is never replayed; the user is told to
      // refresh and inspect the authoritative result before trying again.
      handler.reject(_sessionCheckUnavailableError(options));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    if (status != 401 ||
        _isPublicAuthExchange(path) ||
        err.requestOptions.extra['retried'] == true) {
      handler.next(err);
      return;
    }

    final requestLineage =
        err.requestOptions.extra[_requestLineageKey] as String?;
    final requestIntent = err.requestOptions.extra[_requestIntentKey] as int?;
    final failedAccess = _bearerToken(err.requestOptions);
    if (requestLineage == null ||
        requestIntent == null ||
        failedAccess == null) {
      handler.next(err);
      return;
    }

    final current = await storage.getAuthTokenSnapshot();
    // A new login/logout/password-change intent is a hard boundary. The old
    // request is never replayed under the new account, for reads or writes.
    if (current.sessionLineage != requestLineage ||
        current.intentGeneration != requestIntent) {
      handler.next(_sessionChangedError(err.requestOptions));
      return;
    }

    // A sibling request refreshed this same lineage first.
    if (current.hasAccessToken && current.accessToken != failedAccess) {
      await _replayIfCurrentLineage(
        err,
        handler,
        requestLineage,
        requestIntent,
      );
      return;
    }

    final refreshResult = await _refresh(current, requestLineage);
    if (refreshResult.disposition == TokenRefreshDisposition.refreshed) {
      await _replayIfCurrentLineage(
        err,
        handler,
        requestLineage,
        requestIntent,
      );
      return;
    }
    handler.next(refreshResult.error ?? err);
  }

  Future<void> _replayIfCurrentLineage(
    DioException err,
    ErrorInterceptorHandler handler,
    String requestLineage,
    int requestIntent,
  ) async {
    final latest = await storage.getAuthTokenSnapshot();
    if (latest.sessionLineage != requestLineage ||
        latest.intentGeneration != requestIntent ||
        !latest.hasAccessToken) {
      handler.next(_sessionChangedError(err.requestOptions));
      return;
    }

    try {
      final opts = err.requestOptions
        ..extra['retried'] = true
        ..headers['Authorization'] = 'Bearer ${latest.accessToken!}';
      final retryDio = _dioFactory();
      final response = await retryDio.fetch<dynamic>(opts);
      if (!await _requestSessionMatches(opts)) {
        handler.next(_sessionChangedError(opts));
        return;
      }
      handler.resolve(response);
    } on DioException catch (retryError) {
      // A successful refresh followed by a business/replay failure is not
      // evidence that the newly issued session is invalid.
      handler.next(retryError);
    } catch (error, stackTrace) {
      handler.next(
        DioException(
          requestOptions: err.requestOptions,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<TokenRefreshResult> _refresh(
    AuthTokenSnapshot observed,
    String requestLineage,
  ) async {
    try {
      return await _refreshLock.synchronized(
        () => _refreshWhileLocked(observed, requestLineage),
      );
    } catch (error, stackTrace) {
      return TokenRefreshResult.unavailable(
        DioException(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<TokenRefreshResult> _refreshWhileLocked(
    AuthTokenSnapshot observed,
    String requestLineage,
  ) async {
    var current = await storage.getAuthTokenSnapshot();
    if (current.sessionLineage != requestLineage) {
      return const TokenRefreshResult.rejected();
    }

    if (!current.isSameSession(observed) &&
        current.hasAccessToken &&
        current.accessToken != observed.accessToken) {
      return _resultForLatestSession(current, requestLineage);
    }
    if (!current.hasRefreshToken) {
      return _rejectAndExpireIfCurrent(current, requestLineage);
    }

    // A password-change intent may have advanced metadata without changing the
    // active token. Refresh that exact latest record and preserve its lineage.
    final submitted = current;
    try {
      final dio = _dioFactory();
      final response = await dio.post<dynamic>(
        '/auth/refresh',
        data: <String, String?>{'refreshToken': submitted.refreshToken},
      );
      final data = response.data;
      final body = data is Map<String, dynamic> ? data : null;
      final access = body?['accessToken'] as String?;
      final newRefresh = body?['refreshToken'] as String?;
      if (access != null && access.isNotEmpty) {
        final saved = await storage.saveTokensIfUnchanged(
          expected: submitted,
          accessToken: access,
          refreshToken: newRefresh,
        );
        if (!saved) {
          return _resultForLatestSession(
            await storage.getAuthTokenSnapshot(),
            requestLineage,
          );
        }

        current = await storage.getAuthTokenSnapshot();
        if (current.sessionLineage != requestLineage ||
            current.accessToken != access) {
          return _resultForLatestSession(current, requestLineage);
        }

        final user = body?['user'];
        if (user is Map<String, dynamic>) {
          SessionEventBus.instance.publishProfile(<String, dynamic>{
            ...user,
            _profileGenerationKey: current.generation,
            _profileIntentKey: current.intentGeneration,
            _profileLineageKey: current.sessionLineage,
          });
        }
        return TokenRefreshResult.refreshed(access);
      }
      return TokenRefreshResult.unavailable(invalidRefreshResponse(response));
    } on DioException catch (error) {
      if (isDefinitiveRefreshRejection(error.response)) {
        return _rejectAndExpireIfCurrent(submitted, requestLineage, error);
      }
      return TokenRefreshResult.unavailable(error);
    } catch (error, stackTrace) {
      return TokenRefreshResult.unavailable(
        DioException(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<TokenRefreshResult> _rejectAndExpireIfCurrent(
    AuthTokenSnapshot submitted,
    String requestLineage, [
    DioException? error,
  ]) async {
    final cleared = await storage.clearTokensIfUnchanged(submitted);
    if (!cleared) {
      return _resultForLatestSession(
        await storage.getAuthTokenSnapshot(),
        requestLineage,
        error,
      );
    }
    SessionEventBus.instance.expire();
    return TokenRefreshResult.rejected(error);
  }

  TokenRefreshResult _resultForLatestSession(
    AuthTokenSnapshot latest,
    String requestLineage, [
    DioException? fallbackError,
  ]) {
    if (latest.sessionLineage == requestLineage && latest.hasAccessToken) {
      return TokenRefreshResult.refreshed(latest.accessToken!);
    }
    return TokenRefreshResult.rejected(fallbackError);
  }

  bool _isTrackedAuthenticatedRequest(RequestOptions options) =>
      !_isPublicAuthExchange(options.path) &&
      options.extra[_autoAuthorizationKey] == true;

  Future<bool> _requestSessionMatches(RequestOptions options) async {
    final requestLineage = options.extra[_requestLineageKey] as String?;
    final requestIntent = options.extra[_requestIntentKey] as int?;
    if (requestLineage == null || requestIntent == null) return false;

    final current = await storage.getAuthTokenSnapshot();
    return current.sessionLineage == requestLineage &&
        current.intentGeneration == requestIntent;
  }

  static DioException _sessionChangedError(RequestOptions options) =>
      _localSessionBoundaryError(
        options,
        code: 'SESSION_CHANGED',
        message: '账号已在其他窗口切换，本次旧页面结果已忽略',
      );

  static DioException _sessionCheckUnavailableError(RequestOptions options) =>
      _localSessionBoundaryError(
        options,
        code: 'SESSION_STATE_UNAVAILABLE',
        message: '账号状态暂时无法确认，请刷新页面查看结果；请勿重复提交',
      );

  static DioException _localSessionBoundaryError(
    RequestOptions options, {
    required String code,
    required String message,
  }) {
    final response = Response<dynamic>(
      requestOptions: options,
      statusCode: 409,
      data: <String, dynamic>{'code': code, 'message': message},
    );
    return DioException.badResponse(
      statusCode: 409,
      requestOptions: options,
      response: response,
    );
  }

  static bool _isPublicAuthExchange(String path) =>
      path.endsWith('/auth/login') ||
      path.endsWith('/auth/refresh') ||
      path.endsWith('/auth/logout');

  static Object? _authorizationHeader(RequestOptions options) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') return entry.value;
    }
    return null;
  }

  static void _removeAuthorizationHeader(RequestOptions options) {
    options.headers.removeWhere(
      (key, _) => key.toLowerCase() == 'authorization',
    );
  }

  static String? _bearerToken(RequestOptions options) {
    final value = _authorizationHeader(options);
    if (value == null) return null;
    final header = value is Iterable
        ? value.map((item) => item.toString()).join(',')
        : value.toString();
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    final token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }
}
