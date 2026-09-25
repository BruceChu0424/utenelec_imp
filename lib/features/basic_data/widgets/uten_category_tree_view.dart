// UtenCategoryTreeView - 通用分类树组件（泛型 T extends UtenTreeNode<T>）。
//
// 任何实现 UtenTreeNode 的节点都可复用，统一树外观(搜索 / 展开折叠 / 搜索命中路径
// 自动展开 / 选中高亮 / code 排序 / 点行展开 / trailing 插槽)。
// 现有复用方：货品/模具/客户/供应商（ProductCategoryNode）、收付款类别（PaymentStyleNode）。
//
// 实现在 shared 的 UtenHierarchyTreeView(与组织架构树共用一份，ADR-111)；本组件只把
// 分类的口径传进去：行文字「名称(编码)」、同级默认按编码排序、全部节点可点、
// 「未分类(历史孤儿)」这类大杂烩节点可默认收起。
import 'package:flutter/material.dart';

import '../../../shared/widgets/uten_hierarchy_tree_view.dart';
import '../models/product_category_node.dart';
import '../models/uten_tree_node.dart';

/// 树的选择语义(与组织架构树同一枚举)。
typedef UtenCategoryTreeMode = UtenTreeSelectMode;

/// 单根提升：整片森林只剩一个根（如整库唯一的「货品资料」包装根）时不再
/// 占一层，直接列其子类（2026-09-24 用户口径：货品选择滑窗左边只显示
/// 原材料/半成品/成品等实际分类）。逐层向下直到出现多个根或根为叶子；
/// 叶子根（如 scope 过滤后仅剩「原材料」且无子类）保持原样仍可选。
List<T> hoistSingleRootTree<T extends UtenTreeNode<T>>(List<T> nodes) {
  var current = nodes;
  while (current.length == 1 && current.first.hasChildren) {
    current = current.first.children;
  }
  return current;
}

/// 量测分类树最长一行「名称(编码)」的自然文字宽（TextPainter 实测，2026-09-24），
/// 加行内装具余量（8 左缘 + 3 选中强调条 + 24 展开位 + 4 间隙 + 8 右缘 + 12 滚动
/// 余量 + 一级加粗增量）后夹在 [min]–[max]。选择器滑窗把它作为 UtenSplitView 的
/// initialLeadingWidth，实现「默认划分 = 左边内容最宽那行的宽度」。
double measureCategoryTreeNaturalWidth(
  List<ProductCategoryNode> nodes,
  TextStyle? style, {
  double min = 200,
  double max = 560,
}) {
  final painter = TextPainter(textDirection: TextDirection.ltr);
  var widest = 0.0;
  void walk(List<ProductCategoryNode> nodes) {
    for (final n in nodes) {
      final label = n.code.isEmpty ? n.name : '${n.name}(${n.code})';
      painter.text = TextSpan(text: label, style: style);
      painter.layout();
      if (painter.width > widest) widest = painter.width;
      walk(n.children);
    }
  }

  walk(nodes);
  painter.dispose();
  return (widest + 65).clamp(min, max);
}

class UtenCategoryTreeView<T extends UtenTreeNode<T>> extends StatelessWidget {
  const UtenCategoryTreeView({
    super.key,
    required this.nodes,
    this.mode = UtenCategoryTreeMode.none,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onNodeTap,
    this.nodeEnabledPredicate,
    this.showSearch = true,
    this.initiallyExpandDepth = 1,
    this.trailingBuilder,
    this.header,
    this.searchHint = '搜索分类名称', // TODO(l10n): 补 arb
    this.searchFieldKey,
    this.emptySearchText,
    this.expandOnRowTap = false,
    this.initiallyCollapsedNames = const {},
    this.visibleFilterIds,
    this.externalSearchQuery,
    this.externalSearchLoading = false,
    this.externalSearchError,
    this.sortByCode = true,
    this.flatLevelColors = false,
  });

  /// 名称包含任一关键词的节点，默认不展开（即使深度在 [initiallyExpandDepth] 内）。
  /// 用于「未分类（历史孤儿）」这类大杂烩节点：默认收起，避免一进来就铺开几百行。
  final Set<String> initiallyCollapsedNames;

  /// 外部受控可见节点集合(可选)：非 null 时仅渲染集合内节点(命中节点 + 祖先链)，
  /// 用于货品资料页「搜货品/搜分类定位」。null = 不限。
  final Set<String>? visibleFilterIds;

  /// 页面层统一搜索的当前关键词：即使 [showSearch] 为 false，也展示加载/失败/无结果反馈。
  final String? externalSearchQuery;
  final bool externalSearchLoading;
  final String? externalSearchError;

  /// 是否在组件内按编码重排同级节点；服务端已按业务 sortOrder 返回的页面设 false。
  final bool sortByCode;

  /// 无缩进层级色模式（透传 UtenHierarchyTreeView；选择器滑窗窄左栏用）。
  final bool flatLevelColors;

  /// 点击节点文字行时是否同时展开/收起子类(查看类页面 true，管理页 false)。
  final bool expandOnRowTap;

  final List<T> nodes;
  final UtenCategoryTreeMode mode;
  final Set<String> selectedIds;
  final void Function(T node)? onToggleSelect;
  final void Function(T node)? onNodeTap;

  /// 节点是否可点/可选。默认全部可点（分类无骨架层级概念）。
  final bool Function(T node)? nodeEnabledPredicate;
  final bool showSearch;
  final int initiallyExpandDepth;
  final Widget? Function(T node)? trailingBuilder;
  final Widget? header;
  final String searchHint;
  final Key? searchFieldKey;
  final String? emptySearchText;

  @override
  Widget build(BuildContext context) => UtenHierarchyTreeView<T>(
    nodes: nodes,
    mode: mode,
    selectedIds: selectedIds,
    onToggleSelect: onToggleSelect,
    onNodeTap: onNodeTap,
    nodeEnabledPredicate: nodeEnabledPredicate,
    showSearch: showSearch,
    initiallyExpandDepth: initiallyExpandDepth,
    initiallyCollapsedNames: initiallyCollapsedNames,
    trailingBuilder: trailingBuilder,
    labelOf: (node) =>
        node.code.isEmpty ? node.name : '${node.name}(${node.code})',
    header: header,
    searchHint: searchHint,
    searchFieldKey: searchFieldKey,
    emptySearchText: emptySearchText,
    emptyNoun: '分类或内容', // TODO(l10n): 补 arb
    expandOnRowTap: expandOnRowTap,
    visibleFilterIds: visibleFilterIds,
    externalSearchQuery: externalSearchQuery,
    externalSearchLoading: externalSearchLoading,
    externalSearchError: externalSearchError,
    sortByCode: sortByCode,
    flatLevelColors: flatLevelColors,
  );
}
