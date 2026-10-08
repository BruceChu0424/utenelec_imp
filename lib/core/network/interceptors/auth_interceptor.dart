// 鉴权拦截器：注入 Bearer access token；临近过期提前单飞刷新；401 时协调刷新并重试；
// 刷新明确失效才结束会话。
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../security/auth_refresh_lock.dart';
import '../../security/secure_storage.dart';
import '../api_exception.dart';
import '../authenticated_request_scope.dart';
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
  static const _requestIdentityKey = '_utenAuthRequestIdentity';
  static const _requestIntentKey = '_utenAuthRequestIntent';
  static const _autoAuthorizationKey = '_utenAuthHeaderInjected';
  static const _usedImpersonationKey = '_utenAuthUsedImpersonation';
  static const _profileGenerationKey = '_utenAuthTokenGeneration';
  static const _profileIntentKey = '_utenAuthIntentGeneration';
  static const _profileLineageKey = '_utenAuthSessionLineage';

  /// 访问令牌剩余寿命不足这么久时, 发请求前先单飞刷新(ADR-108)。
  ///
  /// 此前只在收到 401 后才刷新: 每 15 分钟一轮, 那一刻并发的请求全部先吃一次 401
  /// 再重放。提前刷新后这一轮 401 基本消失; 仍然 401 的(如服务端吊销)照走下面的兜底。
  static const refreshAhead = Duration(seconds: 60);

  /// 本端第一次见到某个访问令牌的时刻。剩余寿命按「令牌寿命(exp - iat) - 本端已用时长」
  /// 算, 不拿本机时钟直接比 exp——办公电脑与服务器时钟不一致时不会每个请求都去刷新。
  static final Map<String, DateTime> _firstSeen = <String, DateTime>{};

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Capture the operation binding before the first await. Retries retain the
    // original object even when their interceptor callbacks run in another Zone.
    final scope = AuthenticatedRequestScope.attach(options);
    if (_isPublicAuthExchange(options.path)) {
      // Login, refresh, and logout must remain reachable even when the local
      // secure token record is unavailable. Never leak a stale bearer header
      // into these credential exchanges.
      _removeAuthorizationHeader(options);
      options.extra[_autoAuthorizationKey] = false;
      options.extra[_usedImpersonationKey] = false;
      handler.next(options);
      return;
    }

    try {
      scope?.checkCurrent();
      final initial = await _readContext();
      final identity = AuthenticatedRequestIdentity.fromRecords(
        options.baseUrl,
        initial.auth,
        initial.impersonation,
      );
      options.extra.putIfAbsent(
        _requestIdentityKey,
        () => _credentialIdentity(options, identity),
      );
      _requireIdentity(options, identity);
      final isManagement = _isImpersonationManagementPath(options.path);
      final usesImpersonation =
          !isManagement && initial.impersonation?.isExpired == false;
      options.extra.putIfAbsent(
        _requestLineageKey,
        () => usesImpersonation
            ? 'imp:${initial.impersonation!.lineage}'
            : initial.auth.sessionLineage,
      );
      options.extra.putIfAbsent(
        _requestIntentKey,
        () => initial.auth.intentGeneration,
      );
      options.extra.putIfAbsent(_autoAuthorizationKey, () => false);
      if (!usesImpersonation &&
          _authorizationHeader(options) == null &&
          initial.auth.hasAccessToken &&
          initial.auth.hasRefreshToken &&
          isNearExpiry(initial.auth.accessToken!)) {
        await _refresh(initial.auth, initial.auth.sessionLineage!);
      }
      // Re-read after every credential/refresh await. Never adopt a new identity
      // or preserve an old admin header after entering impersonation.
      final current = await _readContext();
      _requireIdentity(
        options,
        AuthenticatedRequestIdentity.fromRecords(
          options.baseUrl,
          current.auth,
          current.impersonation,
        ),
      );
      if (current.impersonation?.isExpired == true) {
        _publishImpersonationExpiry(options);
        // Expiry cannot promote this logical request from target to staff.
        // Only a new request after UI restoration may use the staff identity.
        if (!isManagement || scope != null) {
          throw AuthenticatedRequestScope.changed();
        }
      }
      final impersonation =
          isManagement || current.impersonation?.isExpired != false
          ? null
          : current.impersonation;
      if (scope != null && !current.auth.hasAccessToken) {
        throw AuthenticatedRequestScope.changed();
      }
      options.extra[_usedImpersonationKey] = impersonation != null;
      if (_authorizationHeader(options) == null ||
          options.extra[_autoAuthorizationKey] == true) {
        _removeAuthorizationHeader(options);
        final access = impersonation?.accessToken ?? current.auth.accessToken;
        if (access != null && access.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $access';
          options.extra[_autoAuthorizationKey] = true;
        }
      }
      scope?.checkCurrent();
      handler.next(options);
    } on ApiException catch (error) {
      handler.reject(
        _localSessionBoundaryError(
          options,
          code: error.code,
          message: error.message,
        ),
      );
    } catch (_) {
      handler.reject(_sessionCheckUnavailableError(options));
    }
  }

  Future<({AuthTokenSnapshot auth, ImpersonationRecord? impersonation})>
  _readContext() async {
    return readAuthRequestRecords(storage);
  }

  void _requireIdentity(
    RequestOptions options,
    AuthenticatedRequestIdentity current,
  ) {
    if (options.extra[_requestIdentityKey] !=
        _credentialIdentity(options, current)) {
      throw AuthenticatedRequestScope.changed();
    }
    final scope = AuthenticatedRequestScope.attach(options);
    scope?.checkEndpoint(options);
    scope?.checkIdentity(current);
  }

  AuthenticatedRequestIdentity _credentialIdentity(
    RequestOptions options,
    AuthenticatedRequestIdentity context,
  ) {
    // Impersonation management and step-up intentionally use the staff session.
    // A scoped business operation still checks the full context separately.
    if (!_isImpersonationManagementPath(options.path)) return context;
    return AuthenticatedRequestIdentity(
      baseUrl: context.baseUrl,
      lineage: context.lineage,
      intent: context.intent,
      impersonationLineage: null,
    );
  }

  /// 访问令牌是否已进入「提前刷新」窗口(剩余寿命 ≤ [refreshAhead])。
  ///
  /// 解析不了(非 JWT / 缺 exp、iat)按「不临近」处理, 交给 401 兜底。
  static bool isNearExpiry(String accessToken, {DateTime? now}) {
    final lifetime = _tokenLifetime(accessToken);
    if (lifetime == null) return false;
    final at = now ?? DateTime.now();
    if (_firstSeen.length > 16) _firstSeen.clear();
    final seen = _firstSeen.putIfAbsent(accessToken, () => at);
    return lifetime - at.difference(seen) <= refreshAhead;
  }

  static Duration? _tokenLifetime(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map) return null;
      final exp = payload['exp'];
      final iat = payload['iat'];
      if (exp is! num || iat is! num || exp <= iat) return null;
      return Duration(seconds: (exp - iat).toInt());
    } catch (_) {
      return null;
    }
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
    } on ApiException catch (error) {
      handler.reject(
        _localSessionBoundaryError(
          options,
          code: error.code,
          message: error.message,
        ),
      );
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
    final usedImpersonation =
        err.requestOptions.extra[_usedImpersonationKey] == true;

    if (status == 401 && !_isPublicAuthExchange(path)) {
      try {
        if (!await _requestSessionMatches(err.requestOptions)) {
          handler.next(_sessionChangedError(err.requestOptions));
          return;
        }
      } on ApiException catch (error) {
        handler.next(
          _localSessionBoundaryError(
            err.requestOptions,
            code: error.code,
            message: error.message,
          ),
        );
        return;
      } catch (_) {
        handler.next(_sessionCheckUnavailableError(err.requestOptions));
        return;
      }
    }

    // 模拟 token 401（到期 / 失效）：退出模拟、恢复 admin。不刷新（模拟 token 无
    // refresh）、不登出 admin 主会话——admin 真实令牌始终有效。
    if (status == 401 && usedImpersonation) {
      _publishImpersonationExpiry(err.requestOptions);
      handler.next(err);
      return;
    }

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

    final AuthTokenSnapshot current;
    try {
      current = await storage.getAuthTokenSnapshot();
    } catch (_) {
      handler.next(_sessionCheckUnavailableError(err.requestOptions));
      return;
    }
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
    final AuthTokenSnapshot latest;
    try {
      latest = await storage.getAuthTokenSnapshot();
    } catch (_) {
      handler.next(_sessionCheckUnavailableError(err.requestOptions));
      return;
    }
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
      // The factory may include asynchronous device-audit work. Re-run the
      // immutable request fence after it, immediately before replay dispatch.
      if (!retryDio.interceptors.contains(this)) {
        retryDio.interceptors.add(this);
      }
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
    } on ApiException catch (error) {
      handler.next(
        _localSessionBoundaryError(
          err.requestOptions,
          code: error.code,
          message: error.message,
        ),
      );
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
      options.extra.containsKey(_requestIdentityKey) &&
      _authorizationHeader(options) != null;

  Future<bool> _requestSessionMatches(RequestOptions options) async {
    if (!options.extra.containsKey(_requestIdentityKey)) return false;
    final current = await _readContext();
    final identity = AuthenticatedRequestIdentity.fromRecords(
      options.baseUrl,
      current.auth,
      current.impersonation,
    );
    final scope = AuthenticatedRequestScope.attach(options);
    scope?.checkIdentity(identity);
    if (scope != null && current.impersonation?.isExpired == true) {
      throw AuthenticatedRequestScope.changed();
    }
    return _credentialIdentity(options, identity) ==
        options.extra[_requestIdentityKey];
  }

  static DioException _sessionChangedError(RequestOptions options) =>
      _localSessionBoundaryError(
        options,
        code: 'SESSION_CHANGED',
        message: '登录状态已切换，本次旧请求结果已忽略',
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

  void _publishImpersonationExpiry(RequestOptions options) {
    final identity =
        options.extra[_requestIdentityKey] as AuthenticatedRequestIdentity?;
    if (identity?.lineage == null || identity?.impersonationLineage == null) {
      return;
    }
    SessionEventBus.instance.impersonationExpired(
      ImpersonationExpiryNotice(
        lineage: identity!.impersonationLineage!,
        staffLineage: identity.lineage!,
        staffIntent: identity.intent,
        baseUrl: identity.baseUrl,
      ),
    );
  }

  /// 模拟管理端点（enter/start/targets）始终用 admin 凭证——即便正在模拟目标 A，
  /// 切换/搜索仍以 admin 身份发请求（后端按 superAdmin 放行）。
  /// 再认证 (/auth/step-up) 同样用 admin 自己的会话：重新进入切换人时要确认的是 admin 本人的
  /// 密码，凭证也只对 admin 的会话有效 (ADR-110)。
  /// end 不在其中：它在模拟中调用，需带模拟 token（主体=目标）。
  /// 用显式白名单（而非子串匹配），避免将来新增路径被误判为管理端点。
  static bool _isImpersonationManagementPath(String path) {
    return path.endsWith('/admin/impersonation/enter') ||
        path.endsWith('/admin/impersonation/start') ||
        path.endsWith('/admin/impersonation/targets') ||
        path.endsWith('/auth/step-up');
  }

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
