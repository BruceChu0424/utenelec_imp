// UtenFilterPane - 列表页桌面分栏左侧"筛选区"容器
// 文档：docs/数据迁移/30-UI屏幕利用率优化方案.md（§四 P1）
//
// 设计原则：
// - 仅在 expanded 断点以"侧栏"形式出现（由 [UtenListTwoPane] 内部使用）
// - 顶部"筛选"小标题 + 可滚动内容（搜索/状态 Chip/其它过滤） + 可选 sticky 底部操作
// - 右侧发丝级分隔线划分与表格的视觉边界
// - compact/medium 不使用此组件（直接堆叠 filterPane 原内容）
//
// 注意：本组件依赖父容器给出"有界高度"——侧栏场景由 [UtenListTwoPane] 的
// `Row(crossAxisAlignment: stretch)` 提供。勿直接放进无界高度的 Column 中。

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 列表页桌面分栏的筛选侧栏容器
///
/// 顶部小标题（默认"筛选"）+ 中部可滚动内容 + 可选 sticky 底部操作区，
/// 右侧带发丝级分隔线。仅设计用于 [UtenListTwoPane] 的 expanded 分支。
class UtenFilterPane extends StatelessWidget {
  const UtenFilterPane({
    super.key,
    required this.child,
    this.title = '筛选',
    this.footer,
    this.showRightDivider = true,
  });

  /// 筛选内容（搜索框 / 状态 Chip Wrap / 其它过滤项）。在中部可滚动区渲染。
  final Widget child;

  /// 顶部小标题。传 null 不显示标题占位。
  final String? title;

  /// 可选 sticky 底部操作区（如「新建」按钮）。
  /// 不为 null 时显示在底部、带发丝顶分隔线，不随中部内容滚动。
  final Widget? footer;

  /// 是否显示右侧发丝级分隔线（在 [UtenListTwoPane] 中作为侧栏时默认 true）。
  final bool showRightDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final dividerColor =
        theme.dividerTheme.color ??
        (isDark ? UtenColors.darkBorder : UtenColors.border);

    final body = <Widget>[
      if (title != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s16,
            UtenSpacing.s16,
            UtenSpacing.s4,
          ),
          child: Text(
            title!,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
      Expanded(
        // primary:false：本滚动件是页面局部侧栏，永不参与外层
        // UtenCollapsingHeaderScrollView 注入的 PrimaryScrollController 联动——
        // 否则与表体 primary 列表共同挂到同一 inner controller，触发
        // Scrollbar「single ScrollPosition」断言（多 ScrollPosition 冲突）。
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s4,
            UtenSpacing.s16,
            UtenSpacing.s16,
          ),
          child: child,
        ),
      ),
      if (footer != null)
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: footer,
          ),
        ),
    ];

    if (!showRightDivider) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      ),
    );
  }
}
