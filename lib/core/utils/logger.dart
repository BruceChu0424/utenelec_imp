// 极简日志（仅 debug 打印；release 静默）。脱敏由调用方保证（不打印令牌/密码/身份证）。
import 'package:flutter/foundation.dart';

abstract final class AppLogger {
  static void d(Object? msg) {
    if (kDebugMode) debugPrint('[D] $msg');
  }

  static void w(Object? msg) {
    if (kDebugMode) debugPrint('[W] $msg');
  }

  static void e(Object? msg, [Object? error]) {
    if (kDebugMode) debugPrint('[E] $msg ${error ?? ''}');
  }
}
