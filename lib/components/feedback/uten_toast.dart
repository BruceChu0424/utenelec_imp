// UtenToast - 轻提示（兼容适配层）
// 文档：docs/02-组件库/UtenNotify.md
//
// 历史遗留入口：早期页面用 `UtenToast.success/error/...`，与 UtenNotify /
// context.appSuccess 是两套并行实现。为消除重复代码，本类改为**纯适配层**：
// 保持原有静态方法签名不变，内部全部转发到 AppNotificationService 全局队列
// （顶部微信式弹条：去重 + 上限 3 条 + 跨路由不丢），不再自绘 Overlay。
//
// 新代码请直接使用 `context.appSuccess/appError/...` 或 `context.guardAction(...)`
// （见 lib/core/ui/action_feedback.dart），不要再新增 UtenToast 调用。

import 'package:flutter/material.dart';

import '../../core/ui/app_notification.dart';
import '../../core/ui/uten_notify.dart';

/// Uten 轻提示类型
enum UtenToastType { success, error, warning, info }

/// Uten 轻提示（适配层：转发到全局顶部通知服务）。
class UtenToast {
  UtenToast._();

  static void show(
    BuildContext context,
    String message, {
    UtenToastType type = UtenToastType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    final kind = switch (type) {
      UtenToastType.success => AppNotificationKind.success,
      UtenToastType.error => AppNotificationKind.error,
      UtenToastType.warning => AppNotificationKind.warning,
      UtenToastType.info => AppNotificationKind.info,
    };
    UtenNotify.banner(
      context,
      message: message,
      kind: kind,
      duration: duration,
    );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.success);

  static void error(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.error);

  static void warning(BuildContext context, String message) =>
      show(context, message, type: UtenToastType.warning);

  static void info(BuildContext context, String message) =>
      show(context, message);
}
