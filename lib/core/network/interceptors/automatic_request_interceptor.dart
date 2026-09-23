// 「自动请求」声明拦截器 (ADR-110)：用户已有一段时间没有操作时发出的请求带 X-Uten-Automatic: 1，
// 服务端据此不续期会话的最后活动时间，页面开着不动、只有角标在轮询也会按时自动退出。
//
// 这个头只能让会话更早过期，服务端信任它没有安全风险。每次发请求 (含重试、刷新令牌后的重放、
// 再认证后的重发) 都按当时的输入状态重新判定。
import 'package:dio/dio.dart';

import '../user_activity.dart';

class AutomaticRequestInterceptor extends Interceptor {
  const AutomaticRequestInterceptor();

  /// 与服务端 AutomaticRequestPolicy.HEADER 一致。
  static const header = 'X-Uten-Automatic';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (UserActivity.userIsIdle) {
      options.headers[header] = '1';
    } else {
      options.headers.remove(header);
    }
    handler.next(options);
  }
}
