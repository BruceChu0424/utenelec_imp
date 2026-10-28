// UtenBackButton - 全局统一返回键
//
// 设计原则：
// - 所有子页面左上角的返回键统一用本组件，样式/交互只在此维护一份
// - 默认行为：能 pop 则 pop（go_router 下 push 进来的页面）；
//   不能 pop（深链 / context.go 直达）则回工作台兜底，保证永远可返回
// - 2026-10-28 用户选定 B：主题实心圆 + 对比色返回箭头。
// - 可点击按钮与32dp可见圆形重合；标题前16dp空隙由宿主独立提供。
//   不把标题留白加进按钮，不再使用此前40/48dp水平加宽方案。

import 'package:flutter/material.dart';

import '../../core/router/nav_helpers.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/uten_tokens.dart';

/// Uten 全局返回键
///
/// 用法：
/// ```dart
/// UtenAppBar(title: '报销详情', showBackButton: true) // 内部即用本组件
/// // 或单独使用：
/// UtenBackButton()
/// UtenBackButton(onPressed: () => context.go(RouteName.notice)) // 自定义去向
/// ```
class UtenBackButton extends StatelessWidget {
  const UtenBackButton({
    super.key,
    this.onPressed,
    this.tooltip,
    this.color,
    this.enabled = true,
  });

  /// 自定义返回行为；为空时走默认逻辑（pop → 兜底回工作台）
  final VoidCallback? onPressed;

  /// 无障碍/悬停提示，默认「返回」
  final String? tooltip;

  /// 图标颜色；默认取主题 onPrimary。
  final Color? color;

  /// 提交等不可离开状态禁用按钮，避免空回调触发默认返回。
  final bool enabled;

  /// 箭头与圆形分别定义，圆形外不扩展可点击区域。
  static const double iconExtent = UtenSpacing.s20;
  static const double buttonExtent = UtenSpacing.s32;
  static const double titleGap = UtenSpacing.s16;

  /// leading只占圆形宽度；宿主另外保留 [titleGap]，该间隙不响应返回。
  static double slotWidth(BuildContext context) => buttonExtent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox.square(
        dimension: buttonExtent,
        child: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: iconExtent),
          tooltip: tooltip ?? '返回',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: buttonExtent,
            height: buttonExtent,
          ),
          visualDensity: VisualDensity.standard,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(
              Size.square(buttonExtent),
            ),
            maximumSize: const WidgetStatePropertyAll(
              Size.square(buttonExtent),
            ),
            fixedSize: const WidgetStatePropertyAll(Size.square(buttonExtent)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const WidgetStatePropertyAll(CircleBorder()),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? scheme.onSurface.withValues(alpha: 0.12)
                  : scheme.primary,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? scheme.onSurface.withValues(alpha: 0.38)
                  : color ?? scheme.onPrimary,
            ),
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => (color ?? scheme.onPrimary).withValues(
                alpha: states.contains(WidgetState.focused) ? 0.20 : 0.12,
              ),
            ),
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: scheme.onSurface, width: 2)
                  : BorderSide.none,
            ),
          ),
          onPressed: enabled ? onPressed ?? () => _defaultBack(context) : null,
        ),
      ),
    );
  }

  /// 默认返回 = 全站唯一返回契约 [backTo]：优先 pop；栈空（深链/context.go 直达）
  /// 时先读 returnTo 来源页（hub 卡片经 goFrom 写入，如 /sales、/purchase），
  /// 没有才回工作台兜底。实现只在 nav_helpers 维护一份。
  static void _defaultBack(BuildContext context) =>
      backTo(context, defaultPath: RouteName.dashboard);
}
