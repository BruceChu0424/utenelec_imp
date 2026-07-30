// 防连点 / 自动 loading-state 工具集
//
// 设计目标：
// - 业务侧只需要把"点击→等待回执"的 Future<void> 函数传进来，
//   框架负责：进入置忙、防重入、回执到达后解锁；按钮上自动出 spinner。
// - 不依赖具体 UI 组件（按钮/Switch/Slider/列表 Item 都可复用）。
// - 同步 / 异步 / 抛错 三种情况都正确解锁（finally 模式）。
//
// 典型用法：
//
//   // 1) 用 UtenActionButton（自带 loading 视觉）
//   UtenActionButton(
//     label: '提交',
//     onAction: () => api.submit(...),
//   )
//
//   // 2) 用 ClickGuard + 自定义控件（Switch/Slider/SwitchListTile 等）
//   final guard = ClickGuard();
//   SwitchListTile(
//     value: device.power,
//     onChanged: (v) => guard.run(() => api.update(...)),
//   )
//   // 在 build 里读：onChanged: guard.isBusy ? null : ...
//
// 注意：
// - ClickGuard 是按实例追踪；每个 State 一个实例（避免跨 widget 共享）。
// - 不要在 onAction 里同步抛错；如果会抛，请包 try/catch。
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

/// 防连点小工具。状态机：idle → busy → idle。
///
/// 用 `run(action)` 包装一个异步无返回值函数；
/// 如果当前在 busy 中重复调用，`run` 会直接返回 `null` 而**不会** 触发回调，
/// 因此业务层完全不需要自己写 if 拦截。
class ClickGuard {
  bool _busy = false;

  /// 当前是否在忙。
  bool get isBusy => _busy;

  /// 包装一个无返回值的回调为防重入版本。
  /// 返回 `Future<void>?`：返回 null 表示被拦截，返回非 null 表示已执行。
  Future<void>? run(Future<void> Function() action) {
    if (_busy) return null;
    _busy = true;
    return Future<void>.sync(action).whenComplete(() {
      _busy = false;
    });
  }

  /// 显式释放。仅用于一些不会走 `run` 的旁路场景，普通用法请用 `run`。
  void release() {
    if (_busy) _busy = false;
  }
}

/// 异步按钮：自带 loading 视觉 + 防连点。
/// 区别于 UtenButton（外部控制 isLoading）——这里把整个异步行为作为 prop 传入，
/// 按钮自己管 busy，让"快手连点"自动失效，**Dev 不可能写错**。
class UtenActionButton extends StatefulWidget {
  const UtenActionButton({
    super.key,
    required this.onAction,
    required this.label,
    this.icon,
    this.type = UtenActionButtonType.primary,
    this.size = UtenActionButtonSize.medium,
    this.isExpanded = false,
    this.loadingLabel,
  });

  /// 点击后要执行的异步动作。Future resolve（无论成功还是抛错）后按钮恢复可点。
  final Future<void> Function() onAction;

  /// 按钮文字。
  final Widget label;

  /// loading 时显示在 label 旁的可选文字（默认与 label 同；提供简短词如"提交中..."）。
  final Widget? loadingLabel;

  /// 主/次/危险/幽灵。
  final UtenActionButtonType type;

  /// 三档尺寸。
  final UtenActionButtonSize size;

  /// 是否撑满父宽（用于 BottomActionBar）。
  final bool isExpanded;

  /// 可选左侧图标。
  final IconData? icon;

  @override
  State<UtenActionButton> createState() => _UtenActionButtonState();
}

class _UtenActionButtonState extends State<UtenActionButton> {
  final _guard = ClickGuard();

  Future<void> _runAction() async {
    final action = _guard.run(widget.onAction);
    if (action == null) return;
    setState(() {});
    try {
      await action;
    } finally {
      if (mounted) setState(() {});
    }
  }

  EdgeInsetsGeometry get _padding => switch (widget.size) {
    UtenActionButtonSize.small => const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 6,
    ),
    UtenActionButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 10,
    ),
    UtenActionButtonSize.large => const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 14,
    ),
  };

  double get _iconSize => widget.size == UtenActionButtonSize.small
      ? 14
      : (widget.size == UtenActionButtonSize.large ? 18 : 16);

  TextStyle get _textStyle => TextStyle(
    fontSize: widget.size == UtenActionButtonSize.small
        ? 12
        : (widget.size == UtenActionButtonSize.large ? 15 : 13),
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final (bg, fg, borderColor) = _resolveColors(theme, isDark);
    final disabledBg = isDark ? UtenColors.slate700 : UtenColors.slate200;
    final disabledFg = isDark ? UtenColors.slate500 : UtenColors.slate400;
    final enabled = !_guard.isBusy;
    final radius = BorderRadius.circular(10);

    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        color: enabled ? bg : disabledBg,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: borderColor == null
              ? BorderSide.none
              : BorderSide(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? _runAction : null,
          borderRadius: radius,
          child: Container(
            constraints: widget.isExpanded
                ? const BoxConstraints(minWidth: double.infinity)
                : null,
            padding: _padding,
            child: Row(
              mainAxisSize: widget.isExpanded
                  ? MainAxisSize.max
                  : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_guard.isBusy)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: _iconSize,
                      height: _iconSize,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(
                          enabled ? fg : disabledFg,
                        ),
                      ),
                    ),
                  )
                else if (widget.icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      widget.icon,
                      size: _iconSize,
                      color: enabled ? fg : disabledFg,
                    ),
                  ),
                DefaultTextStyle.merge(
                  style: _textStyle.copyWith(color: enabled ? fg : disabledFg),
                  child: _guard.isBusy && widget.loadingLabel != null
                      ? widget.loadingLabel!
                      : widget.label,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (Color, Color, Color?) _resolveColors(ThemeData theme, bool isDark) {
    return switch (widget.type) {
      UtenActionButtonType.primary =>
        isDark
            ? (UtenColors.teal500, UtenColors.slate900, null)
            : (theme.colorScheme.primary, Colors.white, null),
      UtenActionButtonType.secondary =>
        isDark
            ? (UtenColors.darkSurfaceLow, UtenColors.slate200, null)
            : (UtenColors.slate100, UtenColors.slate900, null),
      UtenActionButtonType.ghost => (
        Colors.transparent,
        isDark ? UtenColors.slate200 : UtenColors.slate900,
        isDark ? UtenColors.slate700 : UtenColors.slate300,
      ),
      UtenActionButtonType.danger => (
        theme.colorScheme.error,
        Colors.white,
        null,
      ),
    };
  }
}

enum UtenActionButtonType { primary, secondary, ghost, danger }

enum UtenActionButtonSize { small, medium, large }
