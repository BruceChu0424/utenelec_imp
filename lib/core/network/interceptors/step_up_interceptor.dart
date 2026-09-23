// 再认证拦截器 (ADR-110)：服务端回 403 REAUTH_REQUIRED 时弹统一的「重新输入密码」框，
// 换到一次性凭证后把原请求带上 X-Uten-Step-Up 原样重发一次。
//
// 服务端在进入业务之前就核销/拒绝凭证 (被拒的请求什么都没做)，所以重发是安全的。
// 用户取消输入时原 403 照常抛给页面，页面按普通失败提示即可。
import 'package:dio/dio.dart';

import '../step_up_coordinator.dart';

class StepUpInterceptor extends Interceptor {
  StepUpInterceptor(this._dio, {StepUpCoordinator? coordinator})
    : _coordinator = coordinator ?? StepUpCoordinator.instance;

  /// 携带再认证凭证的请求头 (与服务端 StepUpInterceptor.HEADER 一致)。
  static const header = 'X-Uten-Step-Up';
  static const _attemptedKey = '_utenStepUpAttempted';

  final Dio _dio;
  final StepUpCoordinator _coordinator;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    final options = err.requestOptions;
    if (response?.statusCode != 403 ||
        _code(response?.data) != 'REAUTH_REQUIRED' ||
        options.extra[_attemptedKey] == true) {
      handler.next(err);
      return;
    }
    final String? token;
    try {
      token = await _coordinator.obtain();
    } catch (_) {
      handler.next(err);
      return;
    }
    if (token == null || token.isEmpty) {
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
