// UtenListTwoPane - 列表页"左筛选 / 右表格"分栏布局
// 文档：docs/数据迁移/30-UI屏幕利用率优化方案.md（§三 P1、§六断点回退）
//
// 设计原则：
// - expanded 断点（>=840）：UtenSplitView -> 左 [UtenFilterPane] 侧栏（宽 siderWidth，
//   分割线可拖调宽）+ 右表格区，筛选常驻可见、表格顶满剩余宽（2026-09-03 起统一
//   接入可拖拽分栏，对齐货品资料/分类页的 UtenSplitView 交互；此前固定宽不可拖）。
// - compact/medium：Column -> filterPane 在上、tablePane 在下，垂直堆叠（即现状）。
// - 断点驱动单套代码：调用方无需判断断点，仅按"筛选内容 / 表格内容"切分。
//
// 用法：
//   UtenListTwoPane(
//     splitPersistenceKey: 'finance.docList',  // 页面级唯一，记忆拖定宽度
//     filterPane: Column(children: [搜索框, 状态 Chip Wrap]),
//     tablePane: MasterDataTableView(...),
//   )
//
// 注意：本组件依赖父容器给出"有界高度"——通常由调用方包一层 [Expanded] 提供
// （列表页外壳：Column([页面头, Expanded(UtenListTwoPane(...)))])。

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import 'uten_filter_pane.dart';
import 'uten_split_view.dart';

/// 列表页桌面分栏布局（左筛选 + 右表格），断点驱动回退垂直堆叠。
class UtenListTwoPane extends StatelessWidget {
  const UtenListTwoPane({
    super.key,
    required this.filterPane,
    required this.tablePane,
    this.siderWidth = 260,
    this.filterPaneTitle = '筛选',
    this.filterPaneFooter,
    this.splitPersistenceKey,
  });

  /// 筛选区内容（搜索、状态 Chip、其它过滤）。
  /// expanded 时被 [UtenFilterPane] 包裹进侧栏；compact/medium 时直接堆叠在表格上方。
  final Widget filterPane;

  /// 表格区内容（通常为 `MasterDataTableView`）。
  final Widget tablePane;

  /// expanded 时左侧筛选侧栏宽度（= 分割线初始宽与双击复位宽，默认 260）。
  final double siderWidth;

  /// expanded 时 [UtenFilterPane] 顶部小标题。传 null 不显示。
  final String? filterPaneTitle;

  /// expanded 时 [UtenFilterPane] 底部 sticky 操作（如「新建」按钮）。
  /// compact/medium 不渲染（页面需在标题行/页面头放置该操作按钮）。
  final Widget? filterPaneFooter;

  /// 分栏宽度本地记忆 key（页面级唯一，如 'finance.docList'）。
  /// 传 null 时拖拽只在本次会话生效、不持久化。拖动/复位行为见 [UtenSplitView]。
  final String? splitPersistenceKey;

  @override
  Widget build(BuildContext context) {
    final isExpanded = context.breakpoint.isExpanded;
    if (!isExpanded) {
      // compact/medium: 维持现有垂直堆叠（filterPane 在上、表格在下）
      return Column(
        children: [
          filterPane,
          Expanded(child: tablePane),
        ],
      );
    }
    // expanded: 侧栏（UtenFilterPane 包裹 filterPane，可拖调宽）+ 表格顶满剩余宽
    return UtenSplitView(
      persistenceKey: splitPersistenceKey,
      initialLeadingWidth: siderWidth,
      leading: UtenFilterPane(
        title: filterPaneTitle,
        footer: filterPaneFooter,
        child: filterPane,
      ),
      trailing: tablePane,
    );
  }
}
