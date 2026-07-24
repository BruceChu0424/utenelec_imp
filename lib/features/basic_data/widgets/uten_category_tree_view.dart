// UtenCategoryTreeView - 货品分类树组件。
//
// 拷贝自 UtenDepartmentTreeView，去掉部门特有的 level 徽标逻辑
// （kSelectableDepartmentLevels / departmentLevelTag / kCompanyDepartmentLevel /
//   showCompanyRoot 参数及相关分支），保留递归渲染 / 展开折叠 / 搜索命中路径自动展开 /
// 单·多·无选择语义 / trailing 插槽。
//
// TODO(architecture): 未来可泛化为 UtenTreeView<T>，由 Department/Category 共享，
// 目前两棵树差异（level 徽标 vs 无徽标）尚小，先各保留一份避免抽象过早。
import 'package:flutter/material.dart';

import '../models/product_category_node.dart';

/// 树的选择语义。
enum UtenCategoryTreeMode { none, single, multi }

class UtenCategoryTreeView extends StatefulWidget {
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
    this.emptySearchText,
  });

  /// 树数据（调用方给，组件不自己拉）。
  final List<ProductCategoryNode> nodes;

  /// 选择语义：none（纯浏览/管理）/ single / multi。
  final UtenCategoryTreeMode mode;

  /// 当前选中节点 id（none=高亮；single=勾选项；multi=勾选集合）。
  final Set<String> selectedIds;

  /// single/multi 模式下可选节点被点击。
  final void Function(ProductCategoryNode node)? onToggleSelect;

  /// none 模式下的行点击（如管理页选中查看）。
  final void Function(ProductCategoryNode node)? onNodeTap;

  /// 节点是否可点/可选。默认全部可点（分类无骨架层级概念）。
  final bool Function(ProductCategoryNode node)? nodeEnabledPredicate;

  /// 是否显示顶部搜索框。
  final bool showSearch;

  /// 默认展开深度（depth < 该值的节点展开）。
  final int initiallyExpandDepth;

  /// 节点尾部操作插槽（在内置选择控件之前）。
  final Widget? Function(ProductCategoryNode node)? trailingBuilder;

  /// 顶部标题区。
  final Widget? header;

  final String searchHint;

  /// 搜索无命中时的文案。
  final String? emptySearchText;

  @override
  State<UtenCategoryTreeView> createState() => _UtenCategoryTreeViewState();
}

class _UtenCategoryTreeViewState extends State<UtenCategoryTreeView> {
  final _searchCtl = TextEditingController();
  late Set<String> _expanded;
  String _query = '';

  bool get _searching => _query.trim().isNotEmpty;

  bool _enabled(ProductCategoryNode node) =>
      (widget.nodeEnabledPredicate ?? (_) => true).call(node);

  @override
  void initState() {
    super.initState();
    _expanded = _defaultExpanded();
    _searchCtl.addListener(() => setState(() => _query = _searchCtl.text));
  }

  @override
  void didUpdateWidget(UtenCategoryTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes ||
        widget.initiallyExpandDepth != oldWidget.initiallyExpandDepth) {
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
    void walk(List<ProductCategoryNode> nodes, int depth) {
      for (final n in nodes) {
        if (n.hasChildren && depth < widget.initiallyExpandDepth) out.add(n.id);
        walk(n.children, depth + 1);
      }
    }

    walk(widget.nodes, 0);
    return out;
  }

  /// 搜索时：命中节点 + 其全部祖先（命中路径自动展开）。
  Set<String> _visibleIds() {
    final q = _query.trim();
    final visible = <String>{};
    bool walk(List<ProductCategoryNode> nodes, List<String> ancestors) {
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

  /// 按 code 字母序排序子节点（A-Z；空编码排前，中文按 Unicode 序排后）。
  List<ProductCategoryNode> _sortedChildren(List<ProductCategoryNode> ns) =>
      [...ns]..sort((a, b) => a.code.compareTo(b.code));

  void _toggleExpand(ProductCategoryNode node) {
    if (_searching) return;
    setState(() {
      if (_expanded.contains(node.id)) {
        _expanded.remove(node.id);
      } else {
        _expanded.add(node.id);
      }
    });
  }

  void _onRowTap(ProductCategoryNode node) {
    if (_enabled(node)) {
      switch (widget.mode) {
        case UtenCategoryTreeMode.none:
          widget.onNodeTap?.call(node);
        case UtenCategoryTreeMode.single:
        case UtenCategoryTreeMode.multi:
          widget.onToggleSelect?.call(node);
      }
    } else if (node.hasChildren) {
      _toggleExpand(node);
    }
  }

  Widget _buildNode(
    ProductCategoryNode node,
    int depth,
    Set<String>? visibleFilter,
  ) {
    if (visibleFilter != null && !visibleFilter.contains(node.id)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final enabled = _enabled(node);
    final expanded = _searching || _expanded.contains(node.id);
    final isSelected = widget.selectedIds.contains(node.id);
    final trailing = widget.trailingBuilder?.call(node);
    final highlight = widget.mode == UtenCategoryTreeMode.none && isSelected;

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
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  node.code.isEmpty
                      ? node.name
                      : '${node.name}（${node.code}）',
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
              if (enabled && widget.mode == UtenCategoryTreeMode.multi)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => widget.onToggleSelect?.call(node),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                )
              else if (enabled &&
                  widget.mode == UtenCategoryTreeMode.single &&
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
          for (final c in _sortedChildren(node.children))
            _buildNode(c, depth + 1, visibleFilter),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roots = _sortedChildren(widget.nodes);
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
                      widget.emptySearchText ?? '未找到匹配「$_query」的分类', // TODO(l10n): 补 arb
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
