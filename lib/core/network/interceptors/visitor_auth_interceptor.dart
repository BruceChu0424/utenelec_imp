// 访客鉴权拦截器：注入 visitor Bearer token；401 单飞刷新（/visitor/auth/refresh）；失败触发访客会话失效。
import 'dart:async';

import 'package:dio/dio.dart';

import '../../security/secure_storage.dart';
import '../visitor_session_event_bus.dart';

class VisitorAuthInterceptor extends Interceptor {
  VisitorAuthInterceptor({required this.storage, required this.baseUrl});

  final SecureStorage storage;
  final String baseUrl;

  Completer<String?>? _refreshing;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
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
      final refresh = await storage.getVisitorRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        c.complete(null);
        return null;
      }
      final dio = Dio(BaseOptions(baseUrl: baseUrl));
      final resp = await dio.post<dynamic>('/visitor/auth/refresh', data: {'refreshToken': refresh});
      final data = resp.data as Map<String, dynamic>;
      final access = data['accessToken'] as String?;
      final newRefresh = data['refreshToken'] as String?;
      if (access != null) {
        await storage.saveVisitorTokens(accessToken: access, refreshToken: newRefresh);
        c.complete(access);
        return access;
      }
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
    storage.clearVisitorTokens();
    VisitorSessionEventBus.instance.expire();
  }
}
