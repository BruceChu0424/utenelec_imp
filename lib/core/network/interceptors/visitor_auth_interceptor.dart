// 访客鉴权拦截器：注入 visitor Bearer token；401 单飞刷新（/visitor/auth/refresh）；失败触发访客会话失效。
import 'dart:async';

import 'package:dio/dio.dart';

import '../../security/secure_storage.dart';
import '../network_policy.dart';
import '../visitor_session_event_bus.dart';
import 'token_refresh_result.dart';

class VisitorAuthInterceptor extends Interceptor {
  VisitorAuthInterceptor({
    required this.storage,
    required this.baseUrl,
    Dio Function()? dioFactory,
  }) : _dioFactory = dioFactory ?? (() => Dio(buildApiBaseOptions(baseUrl)));

  final SecureStorage storage;
  final String baseUrl;
  final Dio Function() _dioFactory;

  Completer<TokenRefreshResult>? _refreshing;
  Future<void>? _expiring;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await storage.getVisitorAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    // 访客登录/刷新接口本身的 401 不触发刷新（避免失败登录误清令牌）
    if (status != 401 || path.contains('/visitor/auth/')) {
      handler.next(err);
      return;
    }
    if (err.requestOptions.extra['retried'] == true) {
      handler.next(err);
      return;
    }
    final refreshResult = await _refresh();
    if (refreshResult.disposition == TokenRefreshDisposition.rejected) {
      await _expire();
      handler.next(refreshResult.error ?? err);
      return;
    }
    if (refreshResult.disposition == TokenRefreshDisposition.unavailable) {
      handler.next(refreshResult.error ?? err);
      return;
    }
    final newToken = refreshResult.token!;
    try {
      final opts = err.requestOptions
        ..extra['retried'] = true
        ..headers['Authorization'] = 'Bearer $newToken';
      final retryDio = _dioFactory();
      final resp = await retryDio.fetch<dynamic>(opts);
      handler.resolve(resp);
    } on DioException catch (retryError) {
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

  Future<TokenRefreshResult> _refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final c = Completer<TokenRefreshResult>();
    _refreshing = c;
    try {
      final refresh = await storage.getVisitorRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        const result = TokenRefreshResult.rejected();
        c.complete(result);
        return result;
      }
      final dio = _dioFactory();
      final resp = await dio.post<dynamic>(
        '/visitor/auth/refresh',
        data: {'refreshToken': refresh},
      );
      final data = resp.data;
      final body = data is Map<String, dynamic> ? data : null;
      final access = body?['accessToken'] as String?;
      final newRefresh = body?['refreshToken'] as String?;
      if (access != null && access.isNotEmpty) {
        await storage.saveVisitorTokens(
          accessToken: access,
          refreshToken: newRefresh,
        );
        final result = TokenRefreshResult.refreshed(access);
        c.complete(result);
        return result;
      }
      final error = invalidRefreshResponse(resp);
      final result = TokenRefreshResult.unavailable(error);
      c.complete(result);
      return result;
    } on DioException catch (error) {
      final result = isDefinitiveRefreshRejection(error.response)
          ? TokenRefreshResult.rejected(error)
          : TokenRefreshResult.unavailable(error);
      c.complete(result);
      return result;
    } catch (error, stackTrace) {
      final result = TokenRefreshResult.unavailable(
        DioException(
          requestOptions: RequestOptions(path: '/visitor/auth/refresh'),
          error: error,
          stackTrace: stackTrace,
        ),
      );
      c.complete(result);
      return result;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _expire() {
    final active = _expiring;
    if (active != null) return active;

    final expiration = _clearAndPublishExpiration();
    _expiring = expiration;
    return expiration.whenComplete(() {
      if (identical(_expiring, expiration)) {
        _expiring = null;
      }
    });
  }

  Future<void> _clearAndPublishExpiration() async {
    try {
      await storage.clearVisitorTokens();
    } catch (_) {
      // 即使平台安全存储异常，也必须让内存访客会话立即失效。
    } finally {
      VisitorSessionEventBus.instance.expire();
    }
  }
}
