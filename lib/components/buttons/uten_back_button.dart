// UtenBackButton - 全局统一返回键
//
// 设计原则：
// - 所有子页面左上角的返回键统一用本组件，样式/交互只在此维护一份
// - 默认行为：能 pop 则 pop（go_router 下 push 进来的页面）；
//   不能 pop（深链 / context.go 直达）则回工作台兜底，保证永远可返回
// - 视觉与 IconButtonTheme 对齐：圆角 8、前景 textSecondary

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/route_names.dart';

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

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: color),
      tooltip: tooltip ?? '返回',
      onPressed: onPressed ?? () => _defaultBack(context),
    );
  }

  /// 默认返回：优先 pop；栈空（深链/context.go 直达）时先读 returnTo 来源页
  /// （hub 卡片经 goFrom 写入，如 /sales、/purchase），没有才回工作台兜底。
  static void _defaultBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
      return;
    }
    final returnTo = GoRouterState.of(context).uri.queryParameters['returnTo'];
    context.go(returnTo ?? RouteName.dashboard);
  }
}
