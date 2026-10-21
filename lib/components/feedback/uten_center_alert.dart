// UtenCenterAlert - 屏幕正中弹窗（重要通知通道）
// 文档：docs/02-组件库/UtenNotify.md
//
// 定位：
// - 用于「重要 / 紧急」级别通知，必须被用户看见（与顶部弹条 UtenNotify.banner 互补）。
// - 三档紧急度：normal（一般）/ important（重要）/ urgent（紧急）。
// - urgent 默认禁止点击遮罩关闭，必须点按钮确认，保证"强提醒"。
// - 统一入口是 `UtenNotify.alert(...)`（lib/core/ui/uten_notify.dart），
//   业务侧不要直接 new 本类。

import '../../core/theme/uten_tokens.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_colors.dart';
import '../buttons/uten_button.dart';
import 'uten_dialog.dart';
import 'uten_motion.dart';

/// 居中弹窗紧急级别。
///
/// - [normal]：一般提醒（如"有新的制度发布"），可点遮罩关闭。
/// - [important]：重要提醒（如"审批被驳回"），可点遮罩关闭，按钮为单确认。
/// - [urgent]：紧急提醒（如"设备故障停机"），默认禁止遮罩关闭 + 红色警示样式，
///   必须用户显式确认，不可静默丢失。
enum UtenAlertLevel {
  /// 一般（不紧急）
  normal,

  /// 重要
  important,

  /// 紧急
  urgent;

  /// 级别主色（图标圆底 + 确认按钮语义）
  Color get accent => switch (this) {
    UtenAlertLevel.normal => UtenColors.info,
    UtenAlertLevel.important => UtenColors.warning,
    UtenAlertLevel.urgent => UtenColors.error,
  };

  /// 级别图标
  IconData get icon => switch (this) {
    UtenAlertLevel.normal => Icons.notifications_rounded,
    UtenAlertLevel.important => Icons.error_rounded,
    UtenAlertLevel.urgent => Icons.priority_high_rounded,
  };
}

/// 屏幕正中弹窗（重要通知通道）。
///
/// 静态调用，返回 `true`=确认、`false`=取消、`null`=遮罩/返回键关闭。
///
/// ```dart
/// final ok = await UtenCenterAlert.show(
///   context,
///   title: '设备故障',
///   message: 'A 区 3 号产线已停机，请立即处理。',
///   level: UtenAlertLevel.urgent,
/// );
/// ```
abstract final class UtenCenterAlert {
  /// 显示居中弹窗。
  ///
  /// - [level] 决定配色、图标与遮罩行为；urgent 默认 `barrierDismissible=false`。
  /// - [cancelLabel] 传 null（默认）时只显示确认按钮；传入文案则显示双按钮。
  /// - [content] 可传入自定义 Widget 替代纯文本 [message]（富文本/列表等扩展场景）。
  static Future<bool?> show(
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
    double maxWidth = 520,
    double maxHeight = 520,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    assert(message != null || content != null, 'message 与 content 至少传一个');

    // 性能档：lite 档压缩进场动画时长（读一次即可，弹窗不需要监听）
    final dismissible = barrierDismissible ?? (level != UtenAlertLevel.urgent);
    final duration = utenMotionDurationOf(context, UtenAnim.fast);

    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: dismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(
        alpha: level == UtenAlertLevel.urgent ? 0.55 : 0.4,
      ),
      transitionDuration: duration,
      pageBuilder: (ctx, _, _) => _InterruptibleAlertRoute(
        interruptSignal: interruptSignal,
        child: PopScope(
          canPop: !blockSystemBack,
          child: _CenterAlertDialog(
            title: title,
            message: message,
            content: content,
            level: level,
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel,
            icon: icon,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            onConfirm: onConfirm,
            onCancel: onCancel,
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, _, child) {
        if (duration == Duration.zero) return child;
        final curved = CurvedAnimation(parent: anim, curve: UtenAnim.standard);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  /// 便捷：一般级别（单确认按钮）。
  static Future<bool?> info(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
  }) =>
      show(context, title: title, message: message, confirmLabel: confirmLabel);

  /// 便捷：重要级别（单确认按钮）。
  static Future<bool?> important(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    VoidCallback? onConfirm,
  }) => show(
    context,
    title: title,
    message: message,
    level: UtenAlertLevel.important,
    confirmLabel: confirmLabel,
    onConfirm: onConfirm,
  );

  /// 便捷：紧急级别（红色警示 + 禁止遮罩关闭 + 单确认按钮）。
  static Future<bool?> urgent(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    VoidCallback? onConfirm,
  }) => show(
    context,
    title: title,
    message: message,
    level: UtenAlertLevel.urgent,
    confirmLabel: confirmLabel,
    onConfirm: onConfirm,
  );
}

class _InterruptibleAlertRoute extends StatefulWidget {
  const _InterruptibleAlertRoute({required this.child, this.interruptSignal});

  final Widget child;
  final Listenable? interruptSignal;

  @override
  State<_InterruptibleAlertRoute> createState() =>
      _InterruptibleAlertRouteState();
}

class _InterruptibleAlertRouteState extends State<_InterruptibleAlertRoute> {
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    widget.interruptSignal?.addListener(_interrupt);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(covariant _InterruptibleAlertRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interruptSignal == widget.interruptSignal) return;
    oldWidget.interruptSignal?.removeListener(_interrupt);
    widget.interruptSignal?.addListener(_interrupt);
  }

  void _interrupt() {
    final route = _route;
    if (!mounted || route == null || !route.isActive) return;
    // The owner can be replaced while this route is being deactivated. Use
    // this exact route's navigator, without looking up a disappearing context.
    final navigator = route.navigator;
    if (navigator?.mounted == true) navigator!.removeRoute(route);
  }

  @override
  void dispose() {
    widget.interruptSignal?.removeListener(_interrupt);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _CenterAlertDialog extends StatelessWidget {
  const _CenterAlertDialog({
    required this.title,
    required this.level,
    this.message,
    this.content,
    this.confirmLabel,
    this.cancelLabel,
    this.icon,
    this.maxWidth = 520,
    this.maxHeight = 520,
    this.onConfirm,
    this.onCancel,
  });

  final String title;
  final String? message;
  final Widget? content;
  final UtenAlertLevel level;
  final String? confirmLabel;
  final String? cancelLabel;
  final IconData? icon;
  final double maxWidth;
  final double maxHeight;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = level.accent;
    final isUrgent = level == UtenAlertLevel.urgent;
    return UtenAlertDialog(
      maxWidth: maxWidth,
      constraints: BoxConstraints(maxHeight: maxHeight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UtenRadius.card),
        side: isUrgent
            ? BorderSide(color: accent.withValues(alpha: 0.5), width: 1.5)
            : BorderSide.none,
      ),
      title: UtenDialogHeading(
        title: Text(title),
        icon: icon ?? level.icon,
        accent: accent,
        danger: isUrgent,
      ),
      content:
          content ??
          Text(
            message!,
            textAlign: TextAlign.start,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        if (cancelLabel != null)
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.large,
            onPressed: () {
              Navigator.pop(context, false);
              onCancel?.call();
            },
            child: Text(cancelLabel!),
          ),
        UtenButton(
          type: isUrgent ? UtenButtonType.danger : UtenButtonType.primary,
          size: UtenButtonSize.large,
          onPressed: () {
            Navigator.pop(context, true);
            onConfirm?.call();
          },
          child: Text(confirmLabel ?? (isUrgent ? '已知悉' : '确认')),
        ),
      ],
    );
  }
}
