// UtenDepartmentTreeView - 全站唯一组织架构树（公开组件）
//
// 从 UtenDepartmentPicker 抽屉内的树实现原样开放而来，能力/样式不变：
// 搜索（可开关，命中路径自动展开）、level 短标签、公司根显隐开关、
// 骨架层（决策层/管理中心）灰显仅展开、展开状态管理、单/多选/无选择语义。
//
// 两个使用场景：
// - 选择器抽屉：mode=single/multi + showCompanyRoot=false + 默认可选层级谓词
// - 部门管理页：mode=none + showCompanyRoot=true + 全部可点 + trailingBuilder
import 'package:flutter/material.dart';

import '../models/department_node.dart';

/// 树的选择语义。
enum UtenDepartmentTreeMode { none, single, multi }

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

/// 公司根隐藏时的顶层节点（从决策层开始列）。
List<DepartmentNode> departmentTreeRoots(
  List<DepartmentNode> tree, {
  required bool showCompanyRoot,
}) {
  if (showCompanyRoot) return tree;
  return [
    for (final n in tree)
      if (n.level == kCompanyDepartmentLevel) ...n.children else n,
  ];
}

class UtenDepartmentTreeView extends StatefulWidget {
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
    this.emptySearchText,
    this.expandOnRowTap = false,
  });

  /// 点击节点文字行时是否同时展开/收起子部门（有子节点才生效）。
  /// 查看类页面（如部门管理）设 true：点部门既选中又展开，不必只点 chevron 图标。
  final bool expandOnRowTap;

  /// 树数据（调用方给，组件不自己拉）。
  final List<DepartmentNode> nodes;

  /// 选择语义：none（纯浏览/管理）/ single / multi。
  final UtenDepartmentTreeMode mode;

  /// 当前选中节点 id（none=高亮；single=勾选项；multi=勾选集合）。
  final Set<String> selectedIds;

  /// single/multi 模式下可选节点被点击。
  final void Function(DepartmentNode node)? onToggleSelect;

  /// none 模式下的行点击（如管理页选中查看）。
  final void Function(DepartmentNode node)? onNodeTap;

  /// 节点是否可点/可选。默认：仅可选层级（一级部门/二级班组/三级科室），
  /// 其余灰显仅作展开骨架。管理页传 (_) => true。
  final bool Function(DepartmentNode node)? nodeEnabledPredicate;

  /// 公司根显隐：选择器=false；管理页=true（公司根也要能被选中管理）。
  final bool showCompanyRoot;

  /// 是否显示顶部搜索框。
  final bool showSearch;

  /// 默认展开深度（depth < 该值的节点展开）。
  final int initiallyExpandDepth;

  /// 节点尾部操作插槽（在内置选择控件之前）：管理页放 人数/岗位/删除，
  /// 选择器放数量徽标。
  final Widget? Function(DepartmentNode node)? trailingBuilder;

  /// 顶部标题区（如管理页「组织架构」）。
  final Widget? header;

  final String searchHint;

  /// 搜索无命中时的文案（默认「未找到匹配「q」的部门」）。
  final String? emptySearchText;

  @override
  State<UtenDepartmentTreeView> createState() => _UtenDepartmentTreeViewState();
}

class _UtenDepartmentTreeViewState extends State<UtenDepartmentTreeView> {
  final _searchCtl = TextEditingController();
  late Set<String> _expanded;
  String _query = '';

  bool get _searching => _query.trim().isNotEmpty;

  bool _enabled(DepartmentNode node) =>
      (widget.nodeEnabledPredicate ??
              (n) => kSelectableDepartmentLevels.contains(n.level))
          .call(node);

  @override
  void initState() {
    super.initState();
    _expanded = _defaultExpanded();
    _searchCtl.addListener(() => setState(() => _query = _searchCtl.text));
  }

  @override
  void didUpdateWidget(UtenDepartmentTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes ||
        widget.initiallyExpandDepth != oldWidget.initiallyExpandDepth ||
        widget.showCompanyRoot != oldWidget.showCompanyRoot) {
      // 保留已展开节点，补上默认可展开的新节点。
      _expanded.addAll(_defaultExpanded());
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Set<String> _defaultExpanded() {
    final out = <String>{};
    void walk(List<DepartmentNode> nodes, int depth) {
      for (final n in nodes) {
        if (n.hasChildren && depth < widget.initiallyExpandDepth) out.add(n.id);
        walk(n.children, depth + 1);
      }
    }

    walk(
      departmentTreeRoots(
        widget.nodes,
        showCompanyRoot: widget.showCompanyRoot,
      ),
      0,
    );
    return out;
  }

  /// 搜索时：命中节点 + 其全部祖先（命中路径自动展开）。
  Set<String> _visibleIds() {
    final q = _query.trim();
    final visible = <String>{};
    bool walk(List<DepartmentNode> nodes, List<String> ancestors) {
      var anyHit = false;
      for (final n in nodes) {
        final selfHit = n.name.contains(q);
        final childHit = walk(n.children, [...ancestors, n.id]);
        if (selfHit || childHit) {
          visible.addAll(ancestors);
          visible.add(n.id);
          anyHit = true;
        }
      }
      return anyHit;
    }

    walk(widget.nodes, const []);
    return visible;
  }

  void _toggleExpand(DepartmentNode node) {
    if (_searching) return;
    setState(() {
      if (_expanded.contains(node.id)) {
        _expanded.remove(node.id);
      } else {
        _expanded.add(node.id);
      }
    });
  }

  void _onRowTap(DepartmentNode node) {
    if (_enabled(node)) {
      if (widget.expandOnRowTap && node.hasChildren) _toggleExpand(node);
      switch (widget.mode) {
        case UtenDepartmentTreeMode.none:
          widget.onNodeTap?.call(node);
        case UtenDepartmentTreeMode.single:
        case UtenDepartmentTreeMode.multi:
          widget.onToggleSelect?.call(node);
      }
    } else if (node.hasChildren) {
      _toggleExpand(node);
    }
  }

  Widget _levelTag(ThemeData theme, String level, bool enabled) {
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
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildNode(
    DepartmentNode node,
    int depth,
    Set<String>? visibleFilter,
  ) {
    if (!widget.showCompanyRoot && node.level == kCompanyDepartmentLevel) {
      // 公司根不显示，直接展开其子级。
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in node.children) _buildNode(c, depth, visibleFilter),
        ],
      );
    }
    if (visibleFilter != null && !visibleFilter.contains(node.id)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final enabled = _enabled(node);
    final expanded = _searching || _expanded.contains(node.id);
    final isSelected = widget.selectedIds.contains(node.id);
    final trailing = widget.trailingBuilder?.call(node);
    final highlight = widget.mode == UtenDepartmentTreeMode.none && isSelected;

    final row = Material(
      color: highlight ? theme.colorScheme.primaryContainer : null,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onRowTap(node),
        child: Padding(
          padding: EdgeInsets.only(
            left: 8 + depth * 18.0,
            right: 8,
            top: 6,
            bottom: 6,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: node.hasChildren
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _toggleExpand(node),
                        child: Icon(
                          expanded
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : null,
              ),
              _levelTag(theme, node.level, enabled),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: enabled
                        ? (isSelected ? theme.colorScheme.primary : null)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
              if (enabled && widget.mode == UtenDepartmentTreeMode.multi)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => widget.onToggleSelect?.call(node),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                )
              else if (enabled &&
                  widget.mode == UtenDepartmentTreeMode.single &&
                  isSelected)
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (node.hasChildren && expanded)
          for (final c in node.children)
            _buildNode(c, depth + 1, visibleFilter),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roots = departmentTreeRoots(
      widget.nodes,
      showCompanyRoot: widget.showCompanyRoot,
    );
    final visibleFilter = _searching ? _visibleIds() : null;
    return Column(
      children: [
        ?widget.header,
        if (widget.showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final r in roots) _buildNode(r, 0, visibleFilter),
              if (_searching && (visibleFilter?.isEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      widget.emptySearchText ?? '未找到匹配「$_query」的部门',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
