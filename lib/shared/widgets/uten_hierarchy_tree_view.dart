// UtenHierarchyTreeView - 全站层级树的唯一实现(泛型 T extends UtenTreeNode<T>，ADR-111)。
//
// 分类树(UtenCategoryTreeView：货品/模具/客户/供应商/收付款类别)与组织架构树
// (UtenDepartmentTreeView：部门管理页与部门选择器)原先各写一份、七成逐行相同：
// 搜索(命中路径自动展开)、展开折叠、外部统一搜索的加载/失败/无结果反馈、
// 单/多选/无选择语义、选中高亮、trailing 插槽。现在只有这一份，两者只是它的薄封装，
// 差异经参数给出：节点左侧徽标([leadingBuilder]，部门层级短标签)、行文字([labelOf]，
// 分类显示「名称(编码)」)、透传节点([passThrough]，部门选择器隐藏公司根、直接列其子级)、
// 同级是否按编码排序、默认展开/收起规则与可选谓词。
//
// 放在 shared：部门与基础资料两个 feature 都用它，谁都不反向依赖谁(节点契约同理在 shared)。
import 'package:flutter/material.dart';

import '../../components/inputs/uten_search_bar.dart';
import '../models/uten_tree_node.dart';

/// 树的选择语义。
enum UtenTreeSelectMode { none, single, multi }

class UtenHierarchyTreeView<T extends UtenTreeNode<T>> extends StatefulWidget {
  const UtenHierarchyTreeView({
    super.key,
    required this.nodes,
    required this.searchHint,
    required this.emptyNoun,
    this.mode = UtenTreeSelectMode.none,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onNodeTap,
    this.nodeEnabledPredicate,
    this.showSearch = true,
    this.initiallyExpandDepth = 1,
    this.initiallyExpandedIds = const {},
    this.initiallyCollapsedNames = const {},
    this.trailingBuilder,
    this.leadingBuilder,
    this.labelOf,
    this.passThrough,
    this.header,
    this.searchFieldKey,
    this.emptySearchText,
    this.expandOnRowTap = false,
    this.visibleFilterIds,
    this.externalSearchQuery,
    this.externalSearchLoading = false,
    this.externalSearchError,
    this.sortByCode = false,
  });

  /// 树数据(调用方给，组件不自己拉)。
  final List<T> nodes;
  final String searchHint;

  /// 无结果文案里的对象名(「分类或内容」「部门或员工」)。
  final String emptyNoun;

  /// 选择语义：none(纯浏览/管理)/ single / multi。
  final UtenTreeSelectMode mode;

  /// 当前选中节点 id(none=高亮；single=勾选项；multi=勾选集合)。
  final Set<String> selectedIds;

  /// single/multi 模式下可选节点被点击。
  final void Function(T node)? onToggleSelect;

  /// none 模式下的行点击(如管理页选中查看)。
  final void Function(T node)? onNodeTap;

  /// 节点是否可点/可选；不可点的只作展开骨架。默认全部可点。
  final bool Function(T node)? nodeEnabledPredicate;

  final bool showSearch;

  /// 默认展开深度(depth < 该值的节点展开)。
  final int initiallyExpandDepth;

  /// 额外强制默认展开的节点 id(与深度规则叠加)。
  final Set<String> initiallyExpandedIds;

  /// 名称包含任一关键词的节点默认不展开(「未分类(历史孤儿)」这类大杂烩节点)。
  final Set<String> initiallyCollapsedNames;

  /// 节点尾部操作插槽(在内置选择控件之前)。
  final Widget? Function(T node)? trailingBuilder;

  /// 节点文字左侧徽标(部门层级短标签)。
  final Widget? Function(T node, bool enabled)? leadingBuilder;

  /// 行文字；默认显示名称。
  final String Function(T node)? labelOf;

  /// 透传节点：不单独成行，其子级按它的深度直接列出(部门选择器隐藏公司根)。
  final bool Function(T node)? passThrough;

  /// 顶部标题区。
  final Widget? header;
  final Key? searchFieldKey;

  /// 搜索无命中时的文案(覆盖默认「未找到匹配「q」的…」)。
  final String? emptySearchText;

  /// 点击节点文字行时是否同时展开/收起(有子节点才生效)。
  final bool expandOnRowTap;

  /// 外部受控可见节点集合：非 null 时仅渲染集合内节点(命中节点 + 祖先链)，
  /// 集合内节点自动展开(搜索定位用)。
  final Set<String>? visibleFilterIds;

  /// 页面层统一搜索的当前关键词：即使不显示内置搜索框，也展示加载/失败/无结果反馈。
  final String? externalSearchQuery;
  final bool externalSearchLoading;
  final String? externalSearchError;

  /// 是否在组件内按编码重排同级节点。
  final bool sortByCode;

  @override
  State<UtenHierarchyTreeView<T>> createState() =>
      _UtenHierarchyTreeViewState<T>();
}

class _UtenHierarchyTreeViewState<T extends UtenTreeNode<T>>
    extends State<UtenHierarchyTreeView<T>> {
  final _searchCtl = TextEditingController();
  late Set<String> _expanded;
  String _query = '';

  bool get _searching => _query.trim().isNotEmpty;

  bool _enabled(T node) => widget.nodeEnabledPredicate?.call(node) ?? true;

  bool _passes(T node) => widget.passThrough?.call(node) ?? false;

  @override
  void initState() {
    super.initState();
    _expanded = _defaultExpanded();
    _searchCtl.addListener(() => setState(() => _query = _searchCtl.text));
  }

  @override
  void didUpdateWidget(UtenHierarchyTreeView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes != oldWidget.nodes ||
        widget.initiallyExpandDepth != oldWidget.initiallyExpandDepth ||
        widget.initiallyExpandedIds != oldWidget.initiallyExpandedIds) {
      // 保留已展开节点，补上默认可展开的新节点。
      _expanded.addAll(_defaultExpanded());
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// 实际成行的顶层节点：透传节点换成它的子级。
  List<T> _displayRoots(List<T> nodes) => [
    for (final n in nodes)
      if (_passes(n)) ..._displayRoots(n.children) else n,
  ];

  Set<String> _defaultExpanded() {
    final out = <String>{...widget.initiallyExpandedIds};
    bool collapsed(T n) =>
        widget.initiallyCollapsedNames.any((k) => n.name.contains(k));
    void walk(List<T> nodes, int depth) {
      for (final n in nodes) {
        if (n.hasChildren &&
            depth < widget.initiallyExpandDepth &&
            !collapsed(n)) {
          out.add(n.id);
        }
        walk(n.children, depth + 1);
      }
    }

    walk(_displayRoots(widget.nodes), 0);
    return out;
  }

  /// 搜索时：命中节点 + 其全部祖先(命中路径自动展开)。
  Set<String> _visibleIds() {
    final q = _query.trim().toLowerCase();
    final visible = <String>{};
    bool walk(List<T> nodes, List<String> ancestors) {
      var anyHit = false;
      for (final n in nodes) {
        final selfHit =
            n.name.toLowerCase().contains(q) ||
            n.code.toLowerCase().contains(q);
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

  /// 按 code 字母序排序同级(A-Z；空编码排前，中文按 Unicode 序排后)。
  List<T> _ordered(List<T> ns) {
    if (!widget.sortByCode) return ns;
    return [...ns]..sort((a, b) => a.code.compareTo(b.code));
  }

  void _toggleExpand(T node) {
    if (_searching) return;
    setState(() {
      if (_expanded.contains(node.id)) {
        _expanded.remove(node.id);
      } else {
        _expanded.add(node.id);
      }
    });
  }

  void _onRowTap(T node) {
    if (_enabled(node)) {
      // 查看页：点有子节点的行先展开/收起，再走选中/勾选语义。
      if (widget.expandOnRowTap && node.hasChildren) _toggleExpand(node);
      switch (widget.mode) {
        case UtenTreeSelectMode.none:
          widget.onNodeTap?.call(node);
        case UtenTreeSelectMode.single:
        case UtenTreeSelectMode.multi:
          widget.onToggleSelect?.call(node);
      }
    } else if (node.hasChildren) {
      _toggleExpand(node);
    }
  }

  Widget _buildNode(T node, int depth, Set<String>? visibleFilter) {
    if (_passes(node)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in _ordered(node.children))
            _buildNode(c, depth, visibleFilter),
        ],
      );
    }
    if (visibleFilter != null && !visibleFilter.contains(node.id)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final enabled = _enabled(node);
    // 外部可见集合(搜索定位用)：命中节点的祖先链也展开，否则深层命中不可见。
    // 用原始 widget.visibleFilterIds 判展开(非交集)，内部搜索不误展开外部节点。
    final externalFilter = widget.visibleFilterIds;
    final expanded =
        _searching ||
        _expanded.contains(node.id) ||
        (externalFilter != null && externalFilter.contains(node.id));
    final isSelected = widget.selectedIds.contains(node.id);
    final trailing = widget.trailingBuilder?.call(node);
    final leading = widget.leadingBuilder?.call(node, enabled);
    final highlight = widget.mode == UtenTreeSelectMode.none && isSelected;

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
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              if (leading == null) const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.labelOf?.call(node) ?? node.name,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: enabled
                        ? (isSelected ? theme.colorScheme.primary : null)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
              if (enabled && widget.mode == UtenTreeSelectMode.multi)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => widget.onToggleSelect?.call(node),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                )
              else if (enabled &&
                  widget.mode == UtenTreeSelectMode.single &&
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
          for (final c in _ordered(node.children))
            _buildNode(c, depth + 1, visibleFilter),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roots = _ordered(widget.nodes);
    final internal = _searching ? _visibleIds() : null;
    final external = widget.visibleFilterIds;
    final externalQuery = widget.externalSearchQuery?.trim() ?? '';
    final externalSearching = externalQuery.isNotEmpty;
    // 内部搜索集合与外部集合同时存在时取交集；否则取非空那个；都空则不限(null)。
    final Set<String>? visibleFilter = internal != null && external != null
        ? internal.intersection(external)
        : (internal ?? external);
    final showExternalEmpty =
        externalSearching &&
        !widget.externalSearchLoading &&
        widget.externalSearchError == null &&
        (visibleFilter?.isEmpty ?? false);
    return Column(
      children: [
        ?widget.header,
        if (widget.showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            // 本地过滤：_searchCtl 的监听器随每次输入(含内置清除按钮)刷新 _query。
            child: UtenSearchBar(
              key: widget.searchFieldKey,
              controller: _searchCtl,
              hint: widget.searchHint,
            ),
          ),
        if (widget.externalSearchLoading)
          const LinearProgressIndicator(minHeight: 2),
        if (widget.externalSearchError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                widget.externalSearchError!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (final r in roots) _buildNode(r, 0, visibleFilter),
              if ((_searching && (visibleFilter?.isEmpty ?? false)) ||
                  showExternalEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        widget.emptySearchText ??
                            '未找到匹配「${externalSearching ? externalQuery : _query}」的${widget.emptyNoun}', // TODO(l10n): 补 arb
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
