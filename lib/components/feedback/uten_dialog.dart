// UtenDialog - 确认对话框（UtenButton 动作 + 主题适配 + 按钮居中）
// 文档：docs/02-组件库/UtenDialog.md
import 'package:flutter/material.dart';

import '../buttons/uten_button.dart';
import '../layout/uten_scroll_gutter.dart';
import '../../core/responsive/dialog_size.dart';
import '../../core/responsive/scale.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_scroll_behavior.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/ai/page_context/ai_page_context.dart';
import 'uten_motion.dart';

/// One clear heading hierarchy for short confirmations and important alerts.
class UtenDialogHeading extends StatelessWidget {
  const UtenDialogHeading({
    super.key,
    required this.title,
    required this.icon,
    this.danger = false,
    this.accent,
  });

  final Widget title;
  final IconData icon;
  final bool danger;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent ?? (danger ? scheme.error : scheme.primary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: UtenRadius.mdAll,
          ),
          child: Icon(icon, color: color, size: 26),
        ),
        const SizedBox(width: UtenSpacing.s16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: title,
          ),
        ),
      ],
    );
  }
}

/// The standard confirmation and short-form shell. Native AlertDialog keeps
/// keyboard focus, semantics, action overflow and route behavior; the shell
/// owns the whole-window bounds and scrolls long content by default.
class UtenAlertDialog extends AlertDialog {
  const UtenAlertDialog({
    super.key,
    super.icon,
    super.iconPadding,
    super.iconColor,
    super.title,
    super.titlePadding,
    super.titleTextStyle,
    super.content,
    super.contentPadding,
    super.contentTextStyle,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.actionsOverflowAlignment,
    super.actionsOverflowDirection,
    super.actionsOverflowButtonSpacing,
    super.buttonPadding,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.semanticLabel,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.scrollable = true,
    this.maxWidth = 560,
  });

  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, available) {
      final inset = insetPadding ?? utenDialogInsetPadding(context);
      final availableBounds = utenDialogConstraints(
        context,
        available: available,
        maxWidth: maxWidth,
        insetPadding: inset,
        requested: constraints,
      );
      // A maximum is only a cap. Material's intrinsic layout otherwise shrinks
      // a short confirmation to 280px even on a large desktop. Choose the
      // design width explicitly, while keeping the viewport/keyboard bounds.
      final bounds = availableBounds.copyWith(
        minWidth: availableBounds.maxWidth,
      );
      final compact = bounds.maxWidth < 360;
      final originalScrollBehavior = ScrollConfiguration.of(context);
      final body = content == null
          ? null
          : ScrollConfiguration(
              behavior: originalScrollBehavior,
              child: content!,
            );
      AlertDialog alert(
        BoxConstraints box, {
        bool? canScroll,
        EdgeInsets? margins,
      }) => AlertDialog(
        icon: icon,
        iconPadding: iconPadding,
        iconColor: iconColor,
        title: title,
        titlePadding:
            titlePadding ??
            EdgeInsets.fromLTRB(
              compact ? 12 : 24,
              compact ? 20 : 28,
              compact ? 12 : 24,
              0,
            ),
        titleTextStyle:
            titleTextStyle ??
            Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
        content: body,
        contentPadding:
            contentPadding ??
            EdgeInsets.fromLTRB(compact ? 12 : 24, 20, compact ? 12 : 24, 24),
        contentTextStyle:
            contentTextStyle ??
            Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
        actions: actions,
        actionsPadding:
            actionsPadding ??
            EdgeInsets.fromLTRB(compact ? 12 : 24, 0, compact ? 12 : 24, 24),
        actionsAlignment: actionsAlignment ?? MainAxisAlignment.center,
        actionsOverflowAlignment:
            actionsOverflowAlignment ?? OverflowBarAlignment.center,
        actionsOverflowDirection: actionsOverflowDirection,
        actionsOverflowButtonSpacing: actionsOverflowButtonSpacing ?? 8,
        buttonPadding: buttonPadding,
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        semanticLabel: semanticLabel,
        insetPadding: margins ?? inset,
        clipBehavior: clipBehavior ?? Clip.antiAlias,
        shape:
            shape ??
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(UtenRadius.card),
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
        alignment: alignment,
        constraints: box,
        scrollable: canScroll ?? scrollable,
      );
      // In a short landscape window the action rows alone can exceed the
      // viewport. Scroll the whole dialog in this exceptional layout so no
      // action is clipped; normal windows keep actions outside body scrolling.
      final actionCount = actions?.length ?? 0;
      final stackedActionsHeight =
          actionCount * context.scaled(48) +
          (actionCount > 0 ? actionCount - 1 : 0) * 8 +
          24;
      final needsWholeScroll =
          bounds.maxHeight < context.scaled(160) ||
          (scrollable &&
              actionCount > 2 &&
              bounds.maxHeight < stackedActionsHeight + context.scaled(96));
      if (needsWholeScroll) {
        return Padding(
          padding: MediaQuery.viewInsetsOf(context) + inset,
          child: Align(
            alignment: alignment ?? Alignment.center,
            child: ConstrainedBox(
              constraints: bounds,
              child: ScrollConfiguration(
                behavior: const _UtenDialogScrollBehavior(),
                child: SingleChildScrollView(
                  // The automatic scrollbar reserves a trailing lane outside
                  // this viewport. Balance it on the leading side so the
                  // dialog surface stays centered in the keyboard-safe canvas.
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: UtenScrollGutter.trackWidth,
                    ),
                    child: MediaQuery.removeViewInsets(
                      context: context,
                      removeLeft: true,
                      removeRight: true,
                      removeTop: true,
                      removeBottom: true,
                      child: alert(
                        bounds.copyWith(
                          minWidth: bounds.maxWidth,
                          minHeight: 0,
                          maxHeight: double.infinity,
                        ),
                        canScroll: false,
                        margins: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return ScrollConfiguration(
        behavior: const _UtenDialogScrollBehavior(),
        child: alert(bounds),
      );
    },
  );
}

/// Share page scrollbar ownership and position isolation in long confirmations.
class _UtenDialogScrollBehavior extends UtenScrollBehavior {
  const _UtenDialogScrollBehavior();
}

/// Larger business workspaces keep their own bounded body and fixed actions.
/// Their width and height always fit the current canvas, keyboard and safe area.
class UtenDialogFrame extends Dialog {
  const UtenDialogFrame({
    super.key,
    super.child,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.insetAnimationDuration,
    super.insetAnimationCurve,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.semanticsRole,
    this.maxWidth = 960,
    this.fillHeight = false,
  });

  final double maxWidth;
  final bool fillHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, available) {
      final inset = insetPadding ?? utenDialogInsetPadding(context);
      return Dialog(
        backgroundColor: backgroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        insetAnimationDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : insetAnimationDuration,
        insetAnimationCurve: insetAnimationCurve,
        insetPadding: inset,
        clipBehavior: clipBehavior ?? Clip.antiAlias,
        shape: shape,
        alignment: alignment,
        semanticsRole: semanticsRole,
        constraints: utenDialogConstraints(
          context,
          available: available,
          maxWidth: maxWidth,
          insetPadding: inset,
          requested: constraints,
          fillHeight: fillHeight,
        ),
        child: child,
      );
    },
  );
}

abstract final class UtenDialog {
  // An owner may open one confirmation at a time, including its exit frames.
  // Weak keys do not retain pages after their contexts have been unmounted.
  static final _confirmationOwners = Expando<bool>('uten-dialog-confirmation');

  /// External dialog controllers can be released only after the overlay's exit
  /// animation ends. A pop result alone does not mean its TextFields unmounted.
  static Future<T?> showAndWaitForExit<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    ValueChanged<T?>? onPopped,
  }) async {
    if (_confirmationOwners[context] == true) return null;
    _confirmationOwners[context] = true;
    ModalRoute<T>? route;
    try {
      final result = await showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        animationStyle: _animationStyle(context),
        builder: (dialogContext) {
          route = ModalRoute.of<T>(dialogContext);
          return builder(dialogContext);
        },
      );
      onPopped?.call(result);
      return result;
    } finally {
      try {
        await route?.completed;
      } finally {
        _confirmationOwners[context] = false;
      }
    }
  }

  /// 显示确认对话框。返回 true=确认，false/null=取消。
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required Widget content,
    String? confirmLabel,
    String? cancelLabel,
    VoidCallback? onConfirm,
    bool danger = false,
    bool waitForExit = false,
    ValueChanged<bool?>? onPopped,
    IconData? icon,
  }) {
    Widget builder(BuildContext ctx) => SelectionArea(
      // 弹窗文字可框选复制（准则 §3.4 局部包裹：弹窗是独立路由，自带 region，
      // 不与页面 region 嵌套；TextField 不受影响，自带原生选择）。
      child: UtenAlertDialog(
        maxWidth: 520,
        title: UtenDialogHeading(
          title: Text(title),
          icon:
              icon ??
              (danger
                  ? Icons.warning_amber_rounded
                  : Icons.help_outline_rounded),
          danger: danger,
        ),
        content: Padding(
          padding: EdgeInsets.zero,
          // ADR-150: plain-text dialog bodies are readable by the AI
          // assistant while the dialog is the top route.
          child: AiPageRegistrar(
            source: AiNoticeSource(
              kind: AiNoticeKind.dialog,
              title: title,
              text: switch (content) {
                Text(:final data, :final textSpan) =>
                  data ?? textSpan?.toPlainText() ?? title,
                RichText(:final text) => text.toPlainText(),
                _ => title,
              },
            ),
            child: content,
          ),
        ),
        // 按钮整体居中（全仓弹窗统一规范）
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel ?? '取消'),
          ),
          UtenButton(
            type: danger ? UtenButtonType.danger : UtenButtonType.primary,
            size: UtenButtonSize.large,
            onPressed: () {
              Navigator.pop(ctx, true);
              onConfirm?.call();
            },
            child: Text(confirmLabel ?? '确认'),
          ),
        ],
      ),
    );
    if (waitForExit) {
      return showAndWaitForExit<bool>(
        context,
        builder: builder,
        onPopped: onPopped,
      );
    }
    return showDialog<bool>(
      context: context,
      animationStyle: _animationStyle(context),
      builder: builder,
    ).then((result) {
      onPopped?.call(result);
      return result;
    });
  }

  static AnimationStyle _animationStyle(BuildContext context) => AnimationStyle(
    duration: utenMotionDurationOf(context, UtenAnim.fast),
    reverseDuration: utenMotionDurationOf(context, UtenAnim.fast),
    curve: UtenAnim.standard,
    reverseCurve: UtenAnim.exit,
  );
}
