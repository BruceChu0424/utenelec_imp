// UtenBackButton - 全局统一返回键
//
// 设计原则：
// - 所有子页面左上角的返回键统一用本组件，样式/交互只在此维护一份
// - 默认行为：能 pop 则 pop（go_router 下 push 进来的页面）；
//   不能 pop（深链 / context.go 直达）则回工作台兜底，保证永远可返回
// - 视觉与 IconButtonTheme 对齐：圆角 8、前景 textSecondary
// - 图标保持 24，贴按钮左缘；桌面命中区至少 40×40，触屏至少 48×48。
//   原来标题前的空隙收进按钮内部，视觉左对齐与可点击范围分别维护。

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

  /// 图标颜色；默认取 IconButtonTheme 前景色
  final Color? color;

  /// 提交等不可离开状态禁用按钮，避免空回调触发默认返回。
  final bool enabled;

  /// 图标大小独立于命中区。
  static const double _extent = 24;

  /// 宿主的 leading 槽宽与整个可点击按钮一致，标题无需额外间距。
  static double slotWidth(BuildContext context) =>
      UtenControlMetrics.minimumHitExtent(context);

  @override
  Widget build(BuildContext context) {
    final extent = slotWidth(context);
    return IconButton(
      icon: Icon(Icons.arrow_back_ios_new_rounded, size: _extent, color: color),
      tooltip: tooltip ?? '返回',
      alignment: AlignmentDirectional.centerStart,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tight(Size.square(extent)),
      visualDensity: VisualDensity.standard,
      onPressed: enabled ? onPressed ?? () => _defaultBack(context) : null,
    );
  }

  /// 默认返回 = 全站唯一返回契约 [backTo]：优先 pop；栈空（深链/context.go 直达）
  /// 时先读 returnTo 来源页（hub 卡片经 goFrom 写入，如 /sales、/purchase），
  /// 没有才回工作台兜底。实现只在 nav_helpers 维护一份。
  static void _defaultBack(BuildContext context) =>
      backTo(context, defaultPath: RouteName.dashboard);
}
