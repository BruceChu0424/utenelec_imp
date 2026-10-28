// 再认证拦截器 (ADR-110)：服务端回 403 REAUTH_REQUIRED 时弹统一的「重新输入密码」框，
// 换到会话凭证后原样重发一次；连续操作复用，空闲五分钟后再验证。
//
// 服务端在进入业务之前校验/拒绝凭证 (被拒的请求什么都没做)，所以重发是安全的。
// 用户取消输入时原 403 照常抛给页面，页面按普通失败提示即可。
import 'package:dio/dio.dart';

import '../step_up_coordinator.dart';
import '../user_activity.dart';

class StepUpInterceptor extends Interceptor {
  StepUpInterceptor(
    this._dio, {
    StepUpCoordinator? coordinator,
    this.identity,
    this.isCurrent,
  }) : _coordinator = coordinator ?? StepUpCoordinator.instance;

  /// 携带再认证凭证的请求头 (与服务端 StepUpInterceptor.HEADER 一致)。
  static const header = 'X-Uten-Step-Up';
  static const renewalHeader = 'X-Uten-Step-Up-Idle-Seconds';
  static const activityPath = '/auth/step-up/activity';
  static const _attemptedKey = '_utenStepUpAttempted';
  static const _startedKey = '_utenStepUpStarted';

  final Dio _dio;
  final StepUpCoordinator _coordinator;
  final Object? Function(RequestOptions options)? identity;
  final Future<bool> Function(RequestOptions options)? isCurrent;

  Object _identityOf(RequestOptions options) =>
      identity?.call(options) ?? options.baseUrl;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _coordinator.bindIdentity(_identityOf(options));
    final path = options.uri.path;
    final exchange =
        path.endsWith('/auth/login') ||
        path.endsWith('/auth/refresh') ||
        path.endsWith('/auth/logout') ||
        path.endsWith('/auth/step-up');
    if (exchange) {
      options.headers.remove(header);
    } else if (!const {'GET', 'HEAD', 'OPTIONS'}.contains(options.method)) {
      final token = _coordinator.cachedToken;
      if (token != null) options.headers[header] = token;
      options.extra[_startedKey] = UserActivity.clock();
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final options = response.requestOptions;
    final token = options.headers[header];
    if (token is String &&
        response.headers.value(renewalHeader) ==
            '${StepUpCoordinator.idleTimeout.inSeconds}') {
      _coordinator.confirm(
        token,
        requestStartedAt: options.extra[_startedKey] as DateTime?,
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final options = err.requestOptions;
    if (response?.statusCode != 403 ||
        _code(response?.data) != 'REAUTH_REQUIRED') {
      handler.next(err);
      return;
    }
    _coordinator.invalidate(options.headers[header] as String?);
    // 活动保活是静默请求，失效后等下一次实际保存才重新询问密码。
    if (options.uri.path.endsWith(activityPath) ||
        options.extra[_attemptedKey] == true ||
        (isCurrent != null && !await isCurrent!(options))) {
      handler.next(err);
      return;
    }
    final identity = _identityOf(options);
    _coordinator.bindIdentity(identity);
    final String? token;
    try {
      token = await _coordinator.obtain();
    } catch (_) {
      handler.next(err);
      return;
    }
    if (token == null ||
        token.isEmpty ||
        identity != _identityOf(options) ||
        (isCurrent != null && !await isCurrent!(options))) {
      handler.next(err);
      return;
    }
    options.headers[header] = token;
    options.extra[_attemptedKey] = true;
    try {
      final replayed = await _dio.fetch<dynamic>(options);
      handler.resolve(replayed);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  static String? _code(Object? data) {
    if (data is Map && data['code'] is String) return data['code'] as String;
    return null;
  }
}
