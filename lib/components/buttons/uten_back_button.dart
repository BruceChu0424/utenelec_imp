// UtenBackButton - 全局统一返回键
//
// 设计原则：
// - 所有子页面左上角的返回键统一用本组件，样式/交互只在此维护一份
// - 默认行为：能 pop 则 pop（go_router 下 push 进来的页面）；
//   不能 pop（深链 / context.go 直达）则回工作台兜底，保证永远可返回
// - 视觉与 IconButtonTheme 对齐：圆角 8、前景 textSecondary
// - 按钮尺寸==图标尺寸（2026-10-24 口径）：桌面端按钮收缩到 24×24，
//   图标自身落在页面最左缘（x=0），标题不再隔着 40 槽的死区；触屏端
//   保留 UtenControlMetrics 最小命中区（48+），图标仍贴按钮盒左缘

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
  const UtenBackButton({super.key, this.onPressed, this.tooltip, this.color});

  /// 自定义返回行为；为空时走默认逻辑（pop → 兜底回工作台）
  final VoidCallback? onPressed;

  /// 无障碍/悬停提示，默认「返回」
  final String? tooltip;

  /// 图标颜色；默认取 IconButtonTheme 前景色
  final Color? color;

  /// 图标与桌面端按钮的边长（按钮==图标口径）。
  static const double _extent = 24;

  /// 返回键在 UtenAppBar 顶栏占用的 leading 槽宽：桌面 = 按钮宽（24），
  /// 触屏 = 主题最小命中区。宿主传给 AppBar.leadingWidth，保证标题紧跟。
  static double slotWidth(BuildContext context) =>
      UtenControlMetrics.usesTouchTargets(context)
      ? UtenControlMetrics.minimumHitExtent(context)
      : _extent;

  @override
  Widget build(BuildContext context) {
    final touch = UtenControlMetrics.usesTouchTargets(context);
    return IconButton(
      icon: Icon(Icons.arrow_back_ios_new_rounded, size: _extent, color: color),
      tooltip: tooltip ?? '返回',
      alignment: AlignmentDirectional.centerStart,
      padding: EdgeInsets.zero,
      // 桌面端收紧到 24×24（UtenControlTheme 会把 IconButton 最小命中区
      // 钉在 40，必须显式 tight 覆盖）；触屏端交给主题最小命中区。
      constraints: touch
          ? null
          : BoxConstraints.tight(const Size.square(_extent)),
      onPressed: onPressed ?? () => _defaultBack(context),
    );
  }

  /// 默认返回 = 全站唯一返回契约 [backTo]：优先 pop；栈空（深链/context.go 直达）
  /// 时先读 returnTo 来源页（hub 卡片经 goFrom 写入，如 /sales、/purchase），
  /// 没有才回工作台兜底。实现只在 nav_helpers 维护一份。
  static void _defaultBack(BuildContext context) =>
      backTo(context, defaultPath: RouteName.dashboard);
}
