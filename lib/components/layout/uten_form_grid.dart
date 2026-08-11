// UtenFormGrid - 编辑/详情页表单字段多列网格
// 文档：docs/数据迁移/30-UI屏幕利用率优化方案.md（§三 P2、§四 UtenFormGrid、§六断点回退）
//
// 设计原则：
// - 用 LayoutBuilder 按容器实际宽度算列数（默认 compact 1 / medium 2 / expanded 3），
//   不依赖屏幕宽度——桌面端被侧栏挤窄的内容区也能正确算列数。
// - 用 Wrap 让每个字段子项宽度 = 单格宽，自动换行；子项高度自定义。
// - compact 自动回退 1 列（手机垂直），单套代码。
// - 长字段（备注/地址 TextArea）建议放在网格外（全宽），或用 [lastRowFill] 让最后一个子项跨整行。
//
// 用法：
//   Column(children: [
//     UtenFormGrid(children: [
//       TextField(...),            // 单据号
//       _dropdown(...),            // 供应商
//       _employeePicker(...),      // 经办人
//       ...
//     ]),
//     TextField(maxLines: 3, ...), // 备注：放在网格外，跨整行
//   ])
//
// 注意：本组件要求父容器给出"有界宽度"（Card 内边距、Padding 等场景均满足）。
// 子项自行控制高度（TextField / 下拉 / 日期选择器 / ListTile 等），Label 仍在字段上方（既有风格）。

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';

/// 编辑/详情页主表字段多列网格（断点驱动，compact 自动 1 列）。
///
/// 与 [UtenResponsiveGrid] 的区别：后者用于卡片瀑布流（按容器宽 1-6 列）；
/// 本组件专为表单字段设计（默认至多 3 列、行高随子项、间距更紧凑）。
class UtenFormGrid extends StatelessWidget {
  const UtenFormGrid({
    super.key,
    required this.children,
    this.columns,
    this.spacing = UtenSpacing.s12,
    this.runSpacing = UtenSpacing.s12,
    this.lastRowFill = false,
  });

  /// 字段子项列表。每个子项会被强制设为单格宽（[lastRowFill] 时最后一个跨整行）。
  final List<Widget> children;

  /// 强制列数（覆盖默认按宽度算的列数）。null 时按容器宽度自动算。
  final int? columns;

  /// 主轴（横向）间距，默认 12（对齐 [UtenSpacing.s12]）。
  final double spacing;

  /// 交叉轴（纵向）行间距，默认 12。
  final double runSpacing;

  /// 是否让最后一个子项跨整行（用于把 TextArea/备注放进网格时占满整行）。
  /// 默认 false（最后一个子项也按单格宽）。
  ///
  /// 注意：若子项总数恰好被列数整除，开此开关会让倒数第二行出现空槽——
  /// 此时建议改为把该长字段放在网格外。
  final bool lastRowFill;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用宽度（父容器实际宽度）；无界场景回退到屏幕宽度。
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final cols = (columns ?? defaultColumnsForWidth(width)).clamp(1, 6);
        final itemWidth = (width - spacing * (cols - 1)) / cols;

        final wrapped = <Widget>[];
        for (var i = 0; i < children.length; i++) {
          final isLastFull = lastRowFill && i == children.length - 1;
          wrapped.add(
            SizedBox(width: isLastFull ? width : itemWidth, child: children[i]),
          );
        }

        return SizedBox(
          width: double.infinity, // 强制占满父容器宽度，保证 Wrap 换行计算正确
          child: Wrap(
            spacing: spacing,
            runSpacing: runSpacing,
            children: wrapped,
          ),
        );
      },
    );
  }

  /// 默认列数（按容器宽度，对齐断点阈值）：
  /// - < 600 (compact): 1 列（手机垂直）
  /// - 600-840 (medium): 2 列
  /// - >= 840 (expanded): 3 列
  static int defaultColumnsForWidth(double width) {
    if (width < UtenBreakpoints.mediumStart) return 1;
    if (width < UtenBreakpoints.expandedStart) return 2;
    return 3;
  }
}
