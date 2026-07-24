// UtenResponsiveGrid - 自适应瀑布流网格
// 文档：docs/00-项目准则/03-自适应布局组件.md
//
// 用 Wrap 实现：每项宽度按列数均分，高度由子项自己决定（真正的瀑布流）。
// 列数基于父容器实际宽度（LayoutBuilder），不是屏幕宽度——
// 这样在桌面端被侧边栏挤窄的内容区也能正确算列数。

import 'package:flutter/material.dart';

/// Uten 自适应瀑布流网格
///
/// 用法：
/// ```dart
/// UtenResponsiveGrid(
///   itemCount: 8,
///   itemBuilder: (context, index, itemWidth) => MyCard(index: index),
/// )
/// ```
///
/// 列数规则（基于父容器实际宽度）：
/// - < 500: 1 列（手机）
/// - 500-800: 2 列（手机横屏 / 小平板）
/// - 800-1100: 3 列（平板）
/// - 1100-1500: 4 列（桌面）
/// - 1500-1900: 5 列（宽屏）
/// - >= 1900: 6 列（超宽屏）
class UtenResponsiveGrid extends StatelessWidget {
  const UtenResponsiveGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = 16,
    this.runSpacing,
    this.padding,
    this.columns,
    this.maxColumns = 6,
    this.minColumns = 1,
  });

  /// 子项总数
  final int itemCount;

  /// 子项构造器
  /// 返回的 Widget 宽度会被强制设为单格宽，高度自定义
  final Widget Function(BuildContext context, int index, double itemWidth)
      itemBuilder;

  /// 主轴方向间距（横向）
  final double spacing;

  /// 交叉轴方向间距（纵向，默认与 spacing 相同）
  final double? runSpacing;

  /// 外边距
  final EdgeInsetsGeometry? padding;

  /// 强制列数配置（优先级最高，设了就用这个）
  final UtenResponsiveColumns? columns;

  /// 最大列数（避免超宽屏列数过多）
  final int maxColumns;

  /// 最小列数
  final int minColumns;

  @override
  Widget build(BuildContext context) {
    final rs = runSpacing ?? spacing;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = _resolveColumns(width).clamp(minColumns, maxColumns);
        final itemWidth = (width - spacing * (cols - 1)) / cols;

        return SizedBox(
          width: double.infinity, // 强制占满父容器宽度，避免被父级居中
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Wrap(
              spacing: spacing,
              runSpacing: rs,
              children: [
                for (var i = 0; i < itemCount; i++)
                  SizedBox(
                    width: itemWidth,
                    child: itemBuilder(context, i, itemWidth),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 基于父容器实际宽度算列数（不依赖屏幕宽度/断点）
  int _resolveColumns(double width) {
    // 用户强制配置优先
    if (columns != null) {
      // 按宽度映射到 compact/medium/expanded
      if (width < 600) return columns!.compact;
      if (width < 840) return columns!.medium;
      return columns!.expanded;
    }

    // 默认规则：纯粹按容器宽度
    if (width < 500) return 1;
    if (width < 800) return 2;
    if (width < 1100) return 3;
    if (width < 1500) return 4;
    if (width < 1900) return 5;
    return 6;
  }
}

/// 列数配置（可自定义各断点列数）
class UtenResponsiveColumns {
  const UtenResponsiveColumns({
    this.compact = 1,
    this.medium = 2,
    this.expanded = 4,
  });

  /// 手机（<600dp）列数，默认 1
  final int compact;

  /// 平板（600-840dp）列数，默认 2
  final int medium;

  /// 桌面（>840dp）列数，默认 4
  final int expanded;
}
