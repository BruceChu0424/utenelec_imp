// UtenNotify - 全项目统一通知门面
// 文档：docs/02-组件库/UtenNotify.md
//
// 两条通道，业务侧只认这一个入口：
//
// 1. `UtenNotify.banner(...)` —— 顶部消息弹条（微信式）
//    日常 / 不阻塞：新消息叠在旧消息上，可展开最近 3 条，点击可跳详情。
//    底层走 AppNotificationService 全局队列（去重 + 展示上限 3 条 + 跨路由不丢）。
//
// 2. `UtenNotify.alert(...)` —— 屏幕正中弹窗
//    重要 / 阻塞：必须被用户看见。三档紧急度 normal / important / urgent，
//    urgent 红色警示且默认禁止点遮罩关闭。
//
// 选型规则（详见文档）：
// - 操作反馈（保存成功/失败）→ banner（或 context.appSuccess/Error 快捷方式）
// - 来新消息、审批状态变更、日常提醒 → banner（可带 onTap 跳详情）
// - 重要公告、需要用户确认的提醒 → alert(normal / important)
// - 紧急故障、强提醒、不容许错过 → alert(urgent)
//
// 扩展方式：新增通知形态（如底部弹条、角标推送）在本文件加静态方法，
// 不要在业务代码里直接 showDialog / showSnackBar / 操作 Overlay。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/feedback/uten_center_alert.dart';
import '../network/api_error.dart';
import '../network/api_exception.dart';
import 'app_notification.dart';

/// 统一通知门面：两条通道（顶部弹条 + 居中弹窗）的唯一调用入口。
abstract final class UtenNotify {
  // ============================================================
  // 通道一：顶部消息弹条（微信式，日常 / 不阻塞）
  // ============================================================

  /// 显示一条顶部消息弹条。
  ///
  /// - [kind] 语义级别，决定配色与默认图标。
  /// - [icon] 自定义左侧图标（如来消息的业务图标），null 用 kind 语义图标。
  /// - [onTap] 点击弹条后的动作（如跳转详情页），执行后弹条自动关闭。
  /// - [onDismissed] 仅在该条实际显示后完成关闭时调用；排队未显示或 clear 不调用。
  /// - [duration] 自动消失时长，默认 3.2s（error 建议 5s，用 [error] 快捷方法）。
  static void banner(
    BuildContext context, {
    required String message,
    String? title,
    AppNotificationKind kind = AppNotificationKind.info,
    IconData? icon,
    VoidCallback? onTap,
    VoidCallback? onDismissed,
    Duration? duration,
    bool force = false,
  }) {
    _notifierOf(context).showMessage(
      message,
      title: title,
      kind: kind,
      duration: duration,
      icon: icon,
      onTap: onTap,
      onDismissed: onDismissed,
      force: force,
    );
  }

  /// 顶部弹条：成功（绿）。
  static void success(BuildContext context, String message, {String? title}) =>
      _notifierOf(context).showSuccess(message, title: title);

  /// 顶部弹条：错误（红，5s）。
  static void error(
    BuildContext context,
    String message, {
    String? title,
    List<ApiFieldError>? fieldErrors,
  }) => _notifierOf(
    context,
  ).showError(message, title: title, fieldErrors: fieldErrors);

  /// 顶部弹条：警告（橙）。
  static void warning(BuildContext context, String message, {String? title}) =>
      _notifierOf(context).showWarning(message, title: title);

  /// 顶部弹条：信息（中性）。
  static void info(BuildContext context, String message, {String? title}) =>
      _notifierOf(context).showInfo(message, title: title);

  /// 从 ApiException 自动提取 message + fieldErrors 显示为错误弹条。
  static void apiError(
    BuildContext context,
    Object error, {
    String? fallback = '操作失败，请稍后重试',
  }) {
    final notifier = _notifierOf(context);
    if (error is ApiException) {
      notifier.showError(
        error.message.isNotEmpty ? error.message : (fallback ?? ''),
        fieldErrors: error.fieldErrors,
      );
    } else {
      notifier.showError(fallback ?? '操作失败，请稍后重试');
    }
  }

  // ============================================================
  // 通道二：屏幕正中弹窗（重要 / 阻塞）
  // ============================================================

  /// 显示屏幕正中弹窗。返回 `true`=确认、`false`=取消、`null`=遮罩关闭。
  ///
  /// [level] 三档紧急度：
  /// - `UtenAlertLevel.normal`：一般提醒，可点遮罩关闭；
  /// - `UtenAlertLevel.important`：重要提醒，橙色警示；
  /// - `UtenAlertLevel.urgent`：紧急提醒，红色警示 + 默认禁止遮罩关闭。
  static Future<bool?> alert(
    BuildContext context, {
    required String title,
    String? message,
    Widget? content,
    UtenAlertLevel level = UtenAlertLevel.normal,
    String? confirmLabel,
    String? cancelLabel,
    bool? barrierDismissible,
    bool blockSystemBack = false,
    Listenable? interruptSignal,
    IconData? icon,
    double maxWidth = 400,
    double maxHeight = 520,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) => UtenCenterAlert.show(
    context,
    title: title,
    message: message,
    content: content,
    level: level,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    barrierDismissible: barrierDismissible,
    blockSystemBack: blockSystemBack,
    interruptSignal: interruptSignal,
    icon: icon,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    onConfirm: onConfirm,
    onCancel: onCancel,
  );

  /// 居中弹窗：紧急级别快捷方式（红色警示 + 必须显式确认）。
  static Future<bool?> urgentAlert(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    VoidCallback? onConfirm,
  }) => UtenCenterAlert.urgent(
    context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    onConfirm: onConfirm,
  );

  // ============================================================

  static AppNotificationService _notifierOf(BuildContext context) =>
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appNotificationProvider.notifier);
}

/// BuildContext 便捷扩展：业务侧 `context.notify...` 一行调用。
extension UtenNotifyContextX on BuildContext {
  /// 顶部消息弹条（微信式）：`context.notifyBanner('张经理 审批了你的请假单')`。
  void notifyBanner(
    String message, {
    String? title,
    AppNotificationKind kind = AppNotificationKind.info,
    IconData? icon,
    VoidCallback? onTap,
    VoidCallback? onDismissed,
    Duration? duration,
    bool force = false,
  }) => UtenNotify.banner(
    this,
    message: message,
    title: title,
    kind: kind,
    icon: icon,
    onTap: onTap,
    onDismissed: onDismissed,
    duration: duration,
    force: force,
  );

  /// 居中弹窗：`await context.notifyAlert(title: '...', message: '...', level: ...)`。
  Future<bool?> notifyAlert({
    required String title,
    String? message,
    Widget? content,
    UtenAlertLevel level = UtenAlertLevel.normal,
    String? confirmLabel,
    String? cancelLabel,
    bool? barrierDismissible,
    bool blockSystemBack = false,
    Listenable? interruptSignal,
    IconData? icon,
    double maxWidth = 400,
    double maxHeight = 520,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) => UtenNotify.alert(
    this,
    title: title,
    message: message,
    content: content,
    level: level,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    barrierDismissible: barrierDismissible,
    blockSystemBack: blockSystemBack,
    interruptSignal: interruptSignal,
    icon: icon,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    onConfirm: onConfirm,
    onCancel: onCancel,
  );
}
