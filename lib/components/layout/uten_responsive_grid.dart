// UtenResponsiveGrid - 自适应瀑布流网格
// 文档：docs/00-项目准则/03-自适应布局组件.md
//
// 真瀑布流实现：按容器宽度算列数后，把子项轮流分配到各列，
// 每列是一个独立的 Column 垂直堆叠——各列高度互不影响。
//
// 为什么不用 Wrap：Wrap 按行对齐，每行高度 = 该行最高子项的高度，
// 矮卡片下方会被迫留出大片空白（视觉上「第二行和第一行间隔很远」）。
// 分栏瀑布流下每张卡片只与本列上下相邻，间距恒为 runSpacing，无多余空白。
//
// 列数基于父容器实际宽度（LayoutBuilder），不是屏幕宽度——
// 这样在桌面端被侧边栏挤窄的内容区也能正确算列数。
//
// 子项分配采用轮流制（第 i 项进第 i % cols 列），保证视觉上
// 仍按从左到右、从上到下的顺序阅读，与 Wrap 版一致。

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

  /// 列与列之间的横向间距
  final double spacing;

  /// 同列内卡片之间的纵向间距（默认与 spacing 相同）
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

        // 单列直接堆叠，无需 Row 分栏
        if (cols <= 1) {
          return SizedBox(
            width: double.infinity,
            child: Padding(
              padding: padding ?? EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < itemCount; i++) ...[
                    if (i > 0) SizedBox(height: rs),
                    itemBuilder(context, i, itemWidth),
                  ],
                ],
              ),
            ),
          );
        }

        // 轮流分配：第 i 项进第 i % cols 列（保持从左到右的阅读顺序）
        final columnItems = List.generate(cols, (_) => <int>[]);
        for (var i = 0; i < itemCount; i++) {
          columnItems[i % cols].add(i);
        }

        return SizedBox(
          width: double.infinity, // 强制占满父容器宽度，避免被父级居中
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start, // 各列顶部对齐
              children: [
                for (var c = 0; c < cols; c++) ...[
                  if (c > 0) SizedBox(width: spacing),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = 0; j < columnItems[c].length; j++) ...[
                          if (j > 0) SizedBox(height: rs),
                          itemBuilder(context, columnItems[c][j], itemWidth),
                        ],
                      ],
                    ),
                  ),
                ],
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
