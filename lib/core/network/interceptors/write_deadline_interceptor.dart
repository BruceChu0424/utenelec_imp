// 写请求截止时间矫正(Web)。
//
// 背景(2026-09-21 生产日报审核事故)：connectTimeout 在 Web 上不是「建连超时」。
// XMLHttpRequest 没有独立的建连超时，dio_web_adapter 在 xhr.send() 之前就起一个
// Timer(connectTimeout)，到点若 readyState 还没到 HEADERS_RECEIVED 就 xhr.abort()。
// 这个 Timer 只被「上传进度」或「下载进度」事件取消，而上传进度监听只在请求带 body 时才注册
// (dio 仅在 data != null 时建上传流)。于是所有不带 body 的写请求(/approve、/reverse、
// /confirm 这一类)把 connectTimeout 变成了「服务端必须在这么久内开口」的硬上限，
// 与 receiveTimeout 完全无关。
//
// 后果是最坏的一种：服务端事务已经提交，浏览器却把连接掐了，用户看到「网络连接超时」，
// 页面停在旧状态，再点一次就撞上「仅草稿单据可审核」。实测 15.094 秒的一次审核就是这样丢的。
//
// 所以 Web 上写请求的 connectTimeout 必须放宽到与 receiveTimeout 同级——
// 让「总共愿意等多久」只有 receiveTimeout 一个口径。非 Web 平台上 connectTimeout 是真正的
// socket 建连超时，保持短值才能对不可达的服务端快速失败，因此默认只在 Web 生效。
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../network_policy.dart';

/// 幂等读方法：这些请求由 SafeRequestRetryInterceptor 自动重试，
/// 被连接计时器误伤也能自愈，保留快速失败更有价值。
const _safeMethods = {'GET', 'HEAD', 'OPTIONS'};

class WriteDeadlineInterceptor extends Interceptor {
  /// [enabled] 默认跟随平台；测试显式传 true 以便在 VM 里验证规则本身。
  const WriteDeadlineInterceptor({this.enabled = kIsWeb});

  final bool enabled;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (enabled && !_safeMethods.contains(options.method.toUpperCase())) {
      // postLongRunning 一类已经自带更宽的 receiveTimeout，这里跟着它走，
      // 顺带修好它在 Web 上「只改了 receiveTimeout、仍被 15 秒掐断」的老问题。
      final deadline = options.receiveTimeout ?? apiReceiveTimeout;
      if ((options.connectTimeout ?? Duration.zero) < deadline) {
        options.connectTimeout = deadline;
      }
    }
    handler.next(options);
  }
}
