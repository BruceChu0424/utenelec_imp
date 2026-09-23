// UtenDepartmentTreeView - 全站唯一组织架构树（公开组件）
//
// 能力/样式：搜索(可开关，命中路径自动展开)、level 短标签、公司根显隐开关、
// 骨架层（决策层/管理中心）灰显仅展开、展开状态管理、单/多选/无选择语义。
// 实现在 shared 的 UtenHierarchyTreeView(与分类树共用一份，ADR-111)；本组件只给
// 部门的口径：层级短标签徽标、默认只有可选层级可点、公司根按开关透传。
//
// 两个使用场景：
// - 选择器抽屉：mode=single/multi + showCompanyRoot=false + 默认可选层级谓词
// - 部门管理页：mode=none + showCompanyRoot=true + 全部可点 + trailingBuilder
import 'package:flutter/material.dart';

import '../../../shared/widgets/uten_hierarchy_tree_view.dart';
import '../models/department_node.dart';

/// 树的选择语义(与分类树同一枚举)。
typedef UtenDepartmentTreeMode = UtenTreeSelectMode;

/// 层级短标签（树节点左侧小徽标）。
String departmentLevelTag(String level) => switch (level) {
  kCompanyDepartmentLevel => '司',
  '决策层' => '决',
  '管理中心' => '中',
  '一级部门' => '部',
  '二级班组' => '组',
  '三级科室' => '科',
  _ => '部',
};

class UtenDepartmentTreeView extends StatelessWidget {
  const UtenDepartmentTreeView({
    super.key,
    required this.nodes,
    this.mode = UtenDepartmentTreeMode.none,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onNodeTap,
    this.nodeEnabledPredicate,
    this.showCompanyRoot = false,
    this.showSearch = true,
    this.initiallyExpandDepth = 1,
    this.trailingBuilder,
    this.header,
    this.searchHint = '搜索部门名称',
    this.searchFieldKey,
    this.emptySearchText,
    this.expandOnRowTap = false,
    this.visibleFilterIds,
    this.externalSearchQuery,
    this.externalSearchLoading = false,
    this.externalSearchError,
    this.initiallyExpandedIds = const {},
  });

  /// 额外强制默认展开的节点 id 集合（与 [initiallyExpandDepth] 叠加，不互斥）。
  /// 用于"只展开某个特定子节点，同级其它节点保持折叠"的场景（如模具车间选择器只展开生产部）。
  final Set<String> initiallyExpandedIds;

  /// 点击节点文字行时是否同时展开/收起子部门(查看类页面如部门管理设 true)。
  final bool expandOnRowTap;

  /// 外部受控可见节点集合：部门管理页「搜员工/搜部门定位」的命中节点 + 祖先链。
  final Set<String>? visibleFilterIds;

  /// 页面层统一搜索的当前关键词：即使 [showSearch] 为 false，也展示加载、失败和
  /// 「部门或员工」无结果反馈；数据查询仍由页面负责。
  final String? externalSearchQuery;
  final bool externalSearchLoading;
  final String? externalSearchError;

  final List<DepartmentNode> nodes;
  final UtenDepartmentTreeMode mode;
  final Set<String> selectedIds;
  final void Function(DepartmentNode node)? onToggleSelect;
  final void Function(DepartmentNode node)? onNodeTap;

  /// 节点是否可点/可选。默认：仅可选层级（一级部门/二级班组/三级科室），
  /// 其余灰显仅作展开骨架。管理页传 (_) => true。
  final bool Function(DepartmentNode node)? nodeEnabledPredicate;

  /// 公司根显隐：选择器=false；管理页=true（公司根也要能被选中管理）。
  final bool showCompanyRoot;
  final bool showSearch;
  final int initiallyExpandDepth;

  /// 节点尾部操作插槽：管理页放 人数/岗位/删除，选择器放数量徽标。
  final Widget? Function(DepartmentNode node)? trailingBuilder;
  final Widget? header;
  final String searchHint;
  final Key? searchFieldKey;

  /// 搜索无命中时的文案(默认「未找到匹配「q」的部门或员工」)。
  final String? emptySearchText;

  @override
  Widget build(BuildContext context) => UtenHierarchyTreeView<DepartmentNode>(
    nodes: nodes,
    mode: mode,
    selectedIds: selectedIds,
    onToggleSelect: onToggleSelect,
    onNodeTap: onNodeTap,
    nodeEnabledPredicate:
        nodeEnabledPredicate ??
        (n) => kSelectableDepartmentLevels.contains(n.level),
    showSearch: showSearch,
    initiallyExpandDepth: initiallyExpandDepth,
    initiallyExpandedIds: initiallyExpandedIds,
    trailingBuilder: trailingBuilder,
    leadingBuilder: (node, enabled) => _LevelTag(node.level, enabled: enabled),
    passThrough: showCompanyRoot
        ? null
        : (node) => node.level == kCompanyDepartmentLevel,
    header: header,
    searchHint: searchHint,
    searchFieldKey: searchFieldKey,
    emptySearchText: emptySearchText,
    emptyNoun: '部门或员工',
    expandOnRowTap: expandOnRowTap,
    visibleFilterIds: visibleFilterIds,
    externalSearchQuery: externalSearchQuery,
    externalSearchLoading: externalSearchLoading,
    externalSearchError: externalSearchError,
  );
}

/// 层级短标签徽标：可选层级主色，骨架层灰显。
class _LevelTag extends StatelessWidget {
  const _LevelTag(this.level, {required this.enabled});

  final String level;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        departmentLevelTag(level),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
