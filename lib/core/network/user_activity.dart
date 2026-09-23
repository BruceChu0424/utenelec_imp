// 最近一次人为输入 (点击/按键/滚动/悬停/触摸) 的时刻 (ADR-110)。
//
// 服务端会话按「最后一次人为请求」计空闲。哪些请求是人为的，只有客户端知道：
// 距上次输入超过 [UserActivity.idleAfter] 才发出的请求 (角标轮询、页面定时刷新、任务心跳、
// 任何新加的轮询) 一律由 AutomaticRequestInterceptor 带上「自动」声明头，服务端不据此续期。
// 按「人在不在场」判定而不是按端点名单判定：新增轮询不需要登记，也就不会漏。
//
// 输入由应用根部的 UserActivityTracker 全局采集 (含根导航器上的弹窗里的输入)。
import 'package:flutter/foundation.dart';

class UserActivity {
  UserActivity._();

  /// 距上次输入超过这个时长发出的请求，算「用户没在操作时页面自己发的」。
  static const idleAfter = Duration(seconds: 30);

  static DateTime? _lastInputAt;

  /// 输入与空闲判定共用的时钟 (生产即系统时钟；测试可替换)。
  static DateTime Function() clock = DateTime.now;

  /// 记一次人为输入。
  static void record() => _lastInputAt = clock();

  /// 最近一次人为输入的时刻；应用启动后还没有任何输入时为 null。
  static DateTime? get lastInputAt => _lastInputAt;

  /// 此刻发出的请求是否算「用户没在操作」。
  static bool get userIsIdle {
    final last = _lastInputAt;
    return last == null || clock().difference(last) >= idleAfter;
  }

  @visibleForTesting
  static void reset() {
    _lastInputAt = null;
    clock = DateTime.now;
  }
}
