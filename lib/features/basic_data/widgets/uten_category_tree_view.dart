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
import '../models/uten_tree_node.dart';

/// 树的选择语义(与组织架构树同一枚举)。
typedef UtenCategoryTreeMode = UtenTreeSelectMode;

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
  );
}
