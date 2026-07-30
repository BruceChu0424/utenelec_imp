// 鉴权拦截器：注入 Bearer access token；401 时单飞刷新并重试；刷新失败触发会话失效。
import 'dart:async';

import 'package:dio/dio.dart';

import '../../security/secure_storage.dart';
import '../network_policy.dart';
import '../session_event_bus.dart';
import 'token_refresh_result.dart';

class AuthInterceptor extends Interceptor {
  AuthInterceptor({
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
    final token = await storage.getAccessToken();
    if (!options.headers.containsKey('Authorization') &&
        token != null &&
        token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    // 登录/刷新接口本身的 401 不触发刷新与失效（否则失败登录会误清令牌）
    final path = err.requestOptions.path;
    if (status != 401 ||
        path.endsWith('/auth/login') ||
        path.endsWith('/auth/refresh')) {
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
      // 刷新接口已经签发了新令牌，业务请求的 403/5xx/网络异常（甚至部署窗口
      // 中的错误 401）都不能作为销毁会话的依据。把真实重放错误交给页面处理。
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
      final refresh = await storage.getRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        const result = TokenRefreshResult.rejected();
        c.complete(result);
        return result;
      }
      final dio = _dioFactory();
      final resp = await dio.post<dynamic>(
        '/auth/refresh',
        data: {'refreshToken': refresh},
      );
      final data = resp.data;
      final body = data is Map<String, dynamic> ? data : null;
      final access = body?['accessToken'] as String?;
      final newRefresh = body?['refreshToken'] as String?;
      if (access != null && access.isNotEmpty) {
        await storage.saveTokens(accessToken: access, refreshToken: newRefresh);
        // 把刷新返回的最新 profile（含权限快照）转发给 sessionProvider，
        // 让权限随 access 刷新滑动更新（不再只在登录时拉一次，重登才生效）。
        final user = body?['user'];
        if (user is Map<String, dynamic>) {
          SessionEventBus.instance.publishProfile(user);
        }
        final result = TokenRefreshResult.refreshed(access);
        c.complete(result);
        return result;
      }
      final error = invalidRefreshResponse(resp);
      final result = TokenRefreshResult.unavailable(error);
      c.complete(result);
      return result;
    } on DioException catch (error) {
      final result = isDefinitiveRefreshRejection(error.response?.statusCode)
          ? TokenRefreshResult.rejected(error)
          : TokenRefreshResult.unavailable(error);
      c.complete(result);
      return result;
    } catch (error, stackTrace) {
      final result = TokenRefreshResult.unavailable(
        DioException(
          requestOptions: RequestOptions(path: '/auth/refresh'),
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
      // 清理完成后再发布事件，避免新登录与未等待的旧 clear 发生竞态。
      await storage.clear();
    } catch (_) {
      // 即使平台安全存储异常，也必须让内存会话立即失效。
    } finally {
      SessionEventBus.instance.expire();
    }
  }
}
