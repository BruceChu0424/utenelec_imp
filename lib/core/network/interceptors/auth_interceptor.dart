// 鉴权拦截器：注入 Bearer access token；401 时单飞刷新并重试；刷新失败触发会话失效。
import 'dart:async';

import 'package:dio/dio.dart';

import '../../security/secure_storage.dart';
import '../session_event_bus.dart';

class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.storage, required this.baseUrl});

  final SecureStorage storage;
  final String baseUrl;

  Completer<String?>? _refreshing;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final token = await storage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    // 登录/刷新接口本身的 401 不触发刷新与失效（否则失败登录会误清令牌）
    final path = err.requestOptions.path;
    if (status != 401 || path.endsWith('/auth/login') || path.endsWith('/auth/refresh')) {
      handler.next(err);
      return;
    }
    if (err.requestOptions.extra['retried'] == true) {
      _expire();
      handler.next(err);
      return;
    }
    final newToken = await _refresh();
    if (newToken == null) {
      _expire();
      handler.next(err);
      return;
    }
    try {
      final opts = err.requestOptions
        ..extra['retried'] = true
        ..headers['Authorization'] = 'Bearer $newToken';
      final retryDio = Dio(BaseOptions(baseUrl: baseUrl));
      final resp = await retryDio.fetch<dynamic>(opts);
      handler.resolve(resp);
    } catch (_) {
      _expire();
      handler.next(err);
    }
  }

  Future<String?> _refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final c = Completer<String?>();
    _refreshing = c;
    try {
      final refresh = await storage.getRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        c.complete(null);
        return null;
      }
      final dio = Dio(BaseOptions(baseUrl: baseUrl));
      final resp = await dio.post<dynamic>('/auth/refresh', data: {'refreshToken': refresh});
      final data = resp.data as Map<String, dynamic>;
      final access = data['accessToken'] as String?;
      final newRefresh = data['refreshToken'] as String?;
      if (access != null) {
        await storage.saveTokens(accessToken: access, refreshToken: newRefresh);
        // 把刷新返回的最新 profile（含权限快照）转发给 sessionProvider，
        // 让权限随 access 刷新滑动更新（不再只在登录时拉一次，重登才生效）。
        final user = data['user'];
        if (user is Map<String, dynamic>) {
          SessionEventBus.instance.publishProfile(user);
        }
        c.complete(access);
        return access;
      }
      c.complete(null);
      return null;
    } on DioException catch (_) {
      c.complete(null);
      return null;
    } catch (_) {
      c.complete(null);
      return null;
    } finally {
      _refreshing = null;
    }
  }

  void _expire() {
    // 清令牌 + 通知会话失效
    storage.clear();
    SessionEventBus.instance.expire();
  }
}
