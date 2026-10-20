// UtenHierarchyTreeView - 全站层级树的唯一实现(泛型 T extends UtenTreeNode<T>，ADR-111)。
//
// 分类树(UtenCategoryTreeView：货品/模具/客户/供应商/收付款类别)与组织架构树
// (UtenDepartmentTreeView：部门管理页与部门选择器)原先各写一份、七成逐行相同：
// 搜索(命中路径自动展开)、展开折叠、外部统一搜索的加载/失败/无结果反馈、
// 单/多选/无选择语义、选中高亮、trailing 插槽。现在只有这一份，两者只是它的薄封装，
// 差异经参数给出：节点左侧徽标([leadingBuilder]，部门层级短标签)、行文字([labelOf]，
// 分类正文只显示业务名称)、透传节点([passThrough]，部门选择器隐藏公司根、直接列其子级)、
// 同级是否按编码排序、默认展开/收起规则、可选谓词与行右键/长按菜单
// ([rowMenuBuilder]，与表格行同一机制、右键即选中)。
//
// 放在 shared：部门与基础资料两个 feature 都用它，谁都不反向依赖谁(节点契约同理在 shared)。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../components/data_display/uten_selection_lifecycle.dart';

import '../../components/feedback/uten_context_menu.dart';
import '../../components/feedback/uten_motion.dart';
import '../../components/inputs/uten_search_bar.dart';
import '../../components/layout/uten_adaptive_hierarchy_pane.dart';
import '../../components/layout/uten_hierarchy_content_width.dart';
import '../../components/layout/uten_panel_opening_scope.dart';
import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import '../models/uten_tree_node.dart';
import '../hierarchy/category_tree_search.dart';
import '../search/keyword_search.dart';
import 'uten_hierarchy_search_header.dart';

/// 树的选择语义。
enum UtenTreeSelectMode { none, single, multi }

/// 行级前景皮肤（2026-10-19 用户口径「深色行的增/改/删图标应反白，颜色逻辑
/// 写在组件里，全站含收付款一致」）：树组件按行底明暗（flat 深绿一级行 vs
/// 浅色档行）算好行内 trailing/leading 内容应使用的前景色，经 InheritedWidget
/// 下发——宿主的行尾图标/文字（分类树增/改/删、锁提示、徽标等）在自己 build
/// 里 `UtenHierarchyRowSkin.maybeOf(context)?.foreground` 取色即可，不必逐页
/// 判层级；无皮肤上游（非树场景）回落宿主自带色。
class UtenHierarchyRowSkin extends InheritedWidget {
  const UtenHierarchyRowSkin({
    super.key,
    required this.foreground,
    required super.child,
  });

  /// 该行 trailing/leading 图标与辅助文字的推荐前景色（深绿行 = 白）。
  final Color foreground;

  static UtenHierarchyRowSkin? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenHierarchyRowSkin>();

  @override
  bool updateShouldNotify(UtenHierarchyRowSkin oldWidget) =>
      foreground != oldWidget.foreground;
}

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
    this.searchController,
    this.searchTrailing,
    this.emptySearchText,
    this.expandOnRowTap = false,
    this.visibleFilterIds,
    this.externalSearchQuery,
    this.externalSearchLoading = false,
    this.externalSearchError,
    this.sortByCode = false,
    this.flatLevelColors = false,
    this.rowMenuBuilder,
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

  /// 节点尾部操作插槽(在内置选择控件之前)。图标/文字颜色请读
  /// [UtenHierarchyRowSkin.maybeOf] 的 foreground——深绿一级行会拿到白色，
  /// 浅色行拿到 onSurfaceVariant，全站一致（2026-10-19 用户口径）。
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
  final TextEditingController? searchController;
  final Widget? searchTrailing;

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

  /// 行右键(桌面)/长按(触屏)菜单的**宿主动作**条目（2026-10-19 用户口径：全站
  /// 所有树、所有节点都可右键，与表格行 [MasterDataTableView.rowMenuBuilder]
  /// 同一机制）。菜单本身由树内置：宿主动作在前，树自带的「展开/收起」在后
  /// （有子级且非搜索态时）；弹出前先把该行置为选中（表格同款「右键即默认
  /// 选中」），但不展开/收起子级。宿主条目与通用项全空则不弹菜单。
  final List<UtenContextMenuEntry> Function(T node)? rowMenuBuilder;

  /// 无缩进层级色模式（选择器滑窗窄左栏用，2026-09-24 用户口径：层级多或名字长
  /// 时缩进吃掉宽度，名字几乎看不到）。行不按深度缩进，改为整行按深度铺色：
  /// 五档梯度（UtenColors.treeLevelRow）——一级深绿实底白字、往下逐档降饱和降
  /// 明度、四档起转中性灰，4 及更深固定第五档（至少 5 个层级色差、最深一层固定
  /// 一色、色差拉开且协调，2026-09-24 第二轮口径）；行距收紧、行间 1px 分隔线。
  /// 选中 = 行首整高色块盖过展开/收起箭头与名字（宽 = 箭头位 + 名字
  /// 自然宽 + 呼吸位，上限为扣除行尾控件后的实际标题簇宽；右侧上下两角平台统一控件
  /// 圆角）。切换选中 = 块体刚性平移：旧行**向左滑出**左缘、新行**向右滑入**
  /// （2026-10-19 用户口径）。名字/箭头随色块同拍取反色——一级深绿行本身即深绿，反其道用白块 +
  /// 深绿前景；浏览态右缘对勾退役（2026-10-19 用户口径，色块盖名后冗余；同日
  /// 早前形态依次为左缘 3px 强调条 → 盖箭头短块）。
  /// 完整祖先路径由名称提示与外部选中路径表达；行内只保留单行节点标题。
  /// 2026-10-18：整列视作一块卡片——首行上两角、末行下两角用系统圆角
  /// （UtenRadius.md），中间行保持方角相接。
  final bool flatLevelColors;

  @override
  State<UtenHierarchyTreeView<T>> createState() =>
      _UtenHierarchyTreeViewState<T>();
}

class _HierarchyBranchMotion {
  _HierarchyBranchMotion(this.controller);
  final AnimationController controller;
  bool closing = false;
}

class _UtenHierarchyTreeViewState<T extends UtenTreeNode<T>>
    extends State<UtenHierarchyTreeView<T>>
    with TickerProviderStateMixin {
  late TextEditingController _searchCtl;
  final _headerKey = GlobalKey();
  final _scrollController = ScrollController();
  bool _ownsSearchController = false;
  late Set<String> _expanded;
  String _query = '';
  UtenHierarchyContentWidthController? _widthController;
  Object? _forestWidthKey;
  double _forestTitleWidth = 0;
  int _fontRevision = 0;
  Object? _rankKey;
  final _branchRanks = <String, int?>{};
  final _branchMotions = <String, _HierarchyBranchMotion>{};

  void _stopBranchMotions() {
    for (final motion in _branchMotions.values) {
      motion.controller.dispose();
    }
    _branchMotions.clear();
  }

  bool get _searching => _query.trim().isNotEmpty;

  /// flat 选中色块要盖过名字（2026-10-19 用户口径）：按选中态文字样式量测每个
  /// 标签的自然宽（TextPainter），同一 (字体版本, 缩放, 标签) 只量一次；系统
  /// 字体热载时 [_onSystemFontsChanged] 会换代身键并清缓存。
  final _labelWidthCache = <String, double>{};

  double _labelWidth(String label, TextStyle style, TextScaler scaler) {
    final key = '$_fontRevision:$scaler:$style:$label';
    return _labelWidthCache[key] ??= () {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final width = painter.maxIntrinsicWidth;
      painter.dispose();
      return width;
    }();
  }

  bool _enabled(T node) => widget.nodeEnabledPredicate?.call(node) ?? true;

  bool _passes(T node) => widget.passThrough?.call(node) ?? false;

  /// flat 模式按深度铺色：五档梯度（UtenColors.treeLevelRow）——一级深绿实底白字，
  /// 往下逐档降饱和降明度、四档起转中性灰，4 及更深固定第五档；相邻档色差一眼可分。
  Color? _flatRowBackground(ThemeData theme, int depth) =>
      UtenColors.treeLevelRow(depth, dark: theme.brightness == Brightness.dark);

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_onSystemFontsChanged);
    _expanded = _defaultExpanded();
    _attachSearchController();
    // 拼音组合中（composing 非空）不过滤：半截拼音把树闪成「未找到」、也打断
    // 组合节奏；组合结束会再通知一次，届时按完整词过滤（2026-10-09 根因修复）。
  }

  void _attachSearchController() {
    _ownsSearchController = widget.searchController == null;
    _searchCtl = widget.searchController ?? TextEditingController();
    _query = _searchCtl.text;
    _searchCtl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    if (_searchCtl.value.composing != TextRange.empty) return;
    _stopBranchMotions();
    setState(() => _query = _searchCtl.text);
  }

  @override
  void didUpdateWidget(UtenHierarchyTreeView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.externalSearchQuery != widget.externalSearchQuery ||
        oldWidget.visibleFilterIds != widget.visibleFilterIds) {
      _stopBranchMotions();
    }
    if (widget.searchController != oldWidget.searchController) {
      _searchCtl.removeListener(_onSearchChanged);
      if (_ownsSearchController) _searchCtl.dispose();
      _attachSearchController();
    }
    if (widget.nodes != oldWidget.nodes ||
        widget.initiallyExpandDepth != oldWidget.initiallyExpandDepth ||
        widget.initiallyExpandedIds != oldWidget.initiallyExpandedIds) {
      // 保留已展开节点，补上默认可展开的新节点。
      _expanded.addAll(_defaultExpanded());
    }
  }

  @override
  void dispose() {
    _stopBranchMotions();
    PaintingBinding.instance.systemFonts.removeListener(_onSystemFontsChanged);
    _widthController?.reportLabelWidth(this, null);
    _widthController = null;
    _searchCtl.removeListener(_onSearchChanged);
    if (_ownsSearchController) _searchCtl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSystemFontsChanged() {
    _fontRevision++;
    _forestWidthKey = null;
    _labelWidthCache.clear();
    if (mounted) setState(() {});
  }

  /// Measure model titles, including collapsed and virtualized rows. The cache
  /// belongs to this tree's immutable node snapshot; controls are still measured
  /// from real rows, never from hidden widgets or a second selection subtree.
  void _reportForestWidth(BuildContext context, ThemeData theme) {
    final controller = UtenHierarchyContentWidthScope.maybeOf(context);
    if (controller != _widthController) {
      _widthController?.reportLabelWidth(this, null);
      _widthController = controller;
    }
    if (controller == null) return;
    final style = DefaultTextStyle.of(context).style
        .merge(theme.textTheme.bodyMedium)
        .copyWith(fontWeight: FontWeight.w600);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final key = (
      widget.nodes,
      widget.labelOf,
      widget.passThrough,
      style,
      scaler,
      direction,
      locale,
      _fontRevision,
    );
    if (key != _forestWidthKey) {
      _forestWidthKey = key;
      final labelOf = widget.labelOf;
      final passThrough = widget.passThrough;
      Iterable<String> labels(List<T> nodes) sync* {
        for (final node in nodes) {
          if (!(passThrough?.call(node) ?? false)) {
            yield labelOf?.call(node) ?? node.name;
          }
          yield* labels(node.children);
        }
      }

      final titles = labels(widget.nodes).iterator;
      var width = 0.0;
      // Offscreen titles still determine the natural split width, but text
      // shaping must yield between bounded batches instead of blocking the
      // first search/selection frame for the entire forest.
      void measureBatch(Duration _) {
        if (!mounted ||
            key != _forestWidthKey ||
            controller != _widthController) {
          return;
        }
        final painter = TextPainter(
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
          maxLines: 1,
        );
        var complete = false;
        try {
          for (var i = 0; i < 40; i++) {
            if (!titles.moveNext()) {
              complete = true;
              break;
            }
            painter.text = TextSpan(text: titles.current, style: style);
            painter.layout();
            if (painter.maxIntrinsicWidth > width) {
              width = painter.maxIntrinsicWidth;
            }
          }
        } finally {
          painter.dispose();
        }
        if (complete) {
          setState(() => _forestTitleWidth = width);
        } else {
          WidgetsBinding.instance.addPostFrameCallback(measureBatch);
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }

      WidgetsBinding.instance.addPostFrameCallback(measureBatch);
    }
    controller.reportLabelWidth(
      this,
      _forestTitleWidth > 0 ? _forestTitleWidth : null,
      metricsKey: (
        key,
        theme,
        widget.mode,
        widget.flatLevelColors,
        widget.leadingBuilder,
        widget.trailingBuilder,
        widget.nodeEnabledPredicate,
        UtenControlMetrics.usesTouchTargets(context),
        UtenControlMetrics.minimumHitExtent(context, desktop: 32),
      ),
    );
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
  Set<String> _visibleIds() => categoryHits(widget.nodes, _query);

  /// 行是否按渲染态展开（与 [_buildNode] 的判定同源）。
  bool _rowExpanded(T node) =>
      _searching ||
      _expanded.contains(node.id) ||
      (widget.visibleFilterIds?.contains(node.id) ?? false);

  // Flatten models only. Each visible row is built by the viewport, including
  // children of a large expanded category; recursive Columns eagerly mounted
  // the whole branch on search, selection and expansion.
  List<({T node, int depth, List<String> ancestors, List<String> branches})>
  _rowPlan(Set<String>? visible) {
    final rows =
        <
          ({T node, int depth, List<String> ancestors, List<String> branches})
        >[];
    void walk(
      List<T> nodes,
      int depth,
      List<String> ancestors,
      List<String> branches,
    ) {
      for (final node in _ordered(nodes)) {
        if (_passes(node)) {
          walk(node.children, depth, ancestors, branches);
          continue;
        }
        if (visible != null && !visible.contains(node.id)) continue;
        rows.add((
          node: node,
          depth: depth,
          ancestors: ancestors,
          branches: branches,
        ));
        if (node.hasChildren &&
            (_rowExpanded(node) || _branchMotions[node.id]?.closing == true)) {
          walk(
            node.children,
            depth + 1,
            [...ancestors, node.name],
            [...branches, node.id],
          );
        }
      }
    }

    walk(widget.nodes, 0, const [], const []);
    return rows;
  }

  void _ensureBranchRanks() {
    final query = widget.externalSearchQuery ?? _query;
    final key = (widget.nodes, query);
    if (_rankKey == key) return;
    _rankKey = key;
    _branchRanks.clear();
    if (query.trim().isEmpty) return;
    int? rank(T node) {
      var best = keywordSearchRank([node.name, node.code], query);
      for (final child in node.children) {
        final nested = rank(child);
        if (nested != null && (best == null || nested < best)) best = nested;
      }
      return _branchRanks[node.id] = best;
    }

    for (final root in widget.nodes) {
      rank(root);
    }
  }

  /// 本次 build 的 flat 首末行 id（build 开头重算，_buildNode 只读）。
  ({String? firstId, String? lastId})? _flatEdgeRowIds;

  /// Preserve the established sibling order within each relevance tier.
  List<T> _ordered(List<T> nodes) {
    final ordered = widget.sortByCode
        ? ([...nodes]..sort((a, b) => a.code.compareTo(b.code)))
        : [...nodes];
    final query = widget.externalSearchQuery ?? _query;
    if (query.trim().isEmpty) return ordered;
    final positions = {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index,
    };
    ordered.sort((a, b) {
      final aRank = _branchRanks[a.id] ?? (1 << 20);
      final bRank = _branchRanks[b.id] ?? (1 << 20);
      final rank = aRank.compareTo(bRank);
      return rank != 0 ? rank : positions[a.id]!.compareTo(positions[b.id]!);
    });
    return ordered;
  }

  void _toggleExpand(T node) {
    if (_searching) return;
    final duration = utenMotionDurationOf(context, UtenAnim.fast);
    final expanding = !_expanded.contains(node.id);
    setState(() {
      if (expanding) {
        _expanded.add(node.id);
      } else {
        _expanded.remove(node.id);
      }
      if (duration == Duration.zero ||
          widget.visibleFilterIds != null ||
          (widget.externalSearchQuery?.trim().isNotEmpty ?? false)) {
        _branchMotions.remove(node.id)?.controller.dispose();
        return;
      }
      final motion = _branchMotions.putIfAbsent(node.id, () {
        final created = _HierarchyBranchMotion(
          AnimationController(
            vsync: this,
            duration: duration,
            value: expanding ? 0 : 1,
          ),
        );
        created.controller.addStatusListener((status) {
          if ((created.closing && status == AnimationStatus.dismissed) ||
              (!created.closing && status == AnimationStatus.completed)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !identical(_branchMotions[node.id], created)) {
                return;
              }
              // A fast second click may have reversed this transition.
              if ((created.closing && !created.controller.isDismissed) ||
                  (!created.closing && !created.controller.isCompleted)) {
                return;
              }
              setState(() => _branchMotions.remove(node.id));
              created.controller.dispose();
            });
            WidgetsBinding.instance.ensureVisualUpdate();
          }
        });
        return created;
      });
      motion.closing = !expanding;
      if (expanding) {
        motion.controller.forward();
      } else {
        motion.controller.reverse();
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
      if (widget.onNodeTap != null || widget.onToggleSelect != null) {
        UtenHierarchyPanelScope.maybeOf(context)?.onSelection?.call();
      }
    } else if (node.hasChildren) {
      _toggleExpand(node);
    }
  }

  /// 行右键/长按菜单弹开前的选中（表格同款「右键即默认选中」）：走点行的选中
  /// 语义但不展开/收起子级；single/multi 下已是选中态不再切换——那里的回调是
  /// toggle 语义，右键不该把已选中行反选掉。
  void _onRowMenuOpening(T node) {
    if (!_enabled(node)) return;
    switch (widget.mode) {
      case UtenTreeSelectMode.none:
        widget.onNodeTap?.call(node);
      case UtenTreeSelectMode.single:
      case UtenTreeSelectMode.multi:
        if (!widget.selectedIds.contains(node.id)) {
          widget.onToggleSelect?.call(node);
        }
    }
    if (widget.onNodeTap != null || widget.onToggleSelect != null) {
      UtenHierarchyPanelScope.maybeOf(context)?.onSelection?.call();
    }
  }

  /// 行菜单条目（2026-10-19 用户口径「所有树所有节点」）：宿主动作
  /// （[UtenHierarchyTreeView.rowMenuBuilder]，如分类树的增/改/删）在前，树自带
  /// 通用项「展开/收起」在后（有子级且非搜索态）；两组之间竖线分组，全空则
  /// 不弹（UtenContextMenuRegion 对空条目不弹菜单）。
  List<UtenContextMenuEntry> _rowMenuEntries(T node) {
    final entries = [...?widget.rowMenuBuilder?.call(node)];
    final expanded = _rowExpanded(node);
    if (node.hasChildren && !_searching) {
      if (entries.isNotEmpty) entries.add(const UtenMenuDivider());
      entries.add(
        UtenMenuItem(
          icon: expanded
              ? Icons.unfold_less_rounded
              : Icons.unfold_more_rounded,
          label: expanded ? '收起' : '展开', // TODO(l10n): 补 arb
          onTap: () => _toggleExpand(node),
        ),
      );
    }
    return entries;
  }

  Widget _buildNode(
    T node,
    int depth,
    List<String> ancestors,
    Duration animDuration,
  ) {
    final theme = Theme.of(context);
    final enabled = _enabled(node);
    final expanded = _rowExpanded(node);
    final isSelected = widget.selectedIds.contains(node.id);
    final trailing = widget.trailingBuilder?.call(node);
    final leading = widget.leadingBuilder?.call(node, enabled);
    final highlight = widget.mode == UtenTreeSelectMode.none && isSelected;
    final flat = widget.flatLevelColors;
    final rowBg = flat
        ? _flatRowBackground(theme, depth)
        : (highlight ? theme.colorScheme.primaryContainer : null);
    final onDarkRow = flat && depth == 0;
    final rowAccent = onDarkRow ? Colors.white : theme.colorScheme.primary;
    final rowRadius = !flat
        ? BorderRadius.circular(UtenRadius.md)
        : BorderRadius.vertical(
            top: Radius.circular(
              node.id == _flatEdgeRowIds?.firstId ? UtenRadius.md : 0,
            ),
            bottom: Radius.circular(
              node.id == _flatEdgeRowIds?.lastId ? UtenRadius.md : 0,
            ),
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final indent = flat
            ? 0.0
            : (depth * 16.0).clamp(0.0, constraints.maxWidth * 0.12);
        final hitExtent = UtenControlMetrics.minimumHitExtent(
          context,
          desktop: 32,
        );
        final label = widget.labelOf?.call(node) ?? node.name;
        final flatSelected = flat && isSelected;
        final blockColor = onDarkRow
            ? Colors.white
            : _flatRowBackground(theme, 0);
        final selectedForeColor = onDarkRow
            ? _flatRowBackground(theme, 0)
            : Colors.white;
        final toggleColor = flatSelected
            ? selectedForeColor
            : (onDarkRow ? Colors.white : theme.colorScheme.onSurfaceVariant);
        final minHeight = flat
            ? UtenFilterRow.heightOf(context)
            : UtenControlMetrics.controlHeight(context);
        final verticalPadding = flat
            ? (UtenControlMetrics.usesTouchTargets(context) ? 0.0 : 2.0)
            : 6.0;
        final Widget? selection;
        if (enabled && widget.mode == UtenTreeSelectMode.multi) {
          selection = Checkbox(
            value: isSelected,
            onChanged: (_) => widget.onToggleSelect?.call(node),
            materialTapTargetSize: UtenControlMetrics.usesTouchTargets(context)
                ? MaterialTapTargetSize.padded
                : MaterialTapTargetSize.shrinkWrap,
          );
        } else if (enabled && widget.mode == UtenTreeSelectMode.single) {
          selection = isSelected
              ? Icon(Icons.check_circle_rounded, size: 18, color: rowAccent)
              : const SizedBox(width: 18, height: 18);
        } else {
          selection = null;
        }
        final expandSlot = SizedBox(
          width: hitExtent,
          height: hitExtent,
          child: node.hasChildren
              ? IconButton(
                  tooltip: expanded ? '收起$label' : '展开$label',
                  constraints: BoxConstraints.tightFor(
                    width: hitExtent,
                    height: hitExtent,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => _toggleExpand(node),
                  icon: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: toggleColor),
                    duration: animDuration,
                    curve: UtenAnim.standard,
                    builder: (context, color, _) => AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: animDuration,
                      curve: UtenAnim.standard,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: color ?? toggleColor,
                      ),
                    ),
                  ),
                )
              : null,
        );
        final title = Expanded(
          child: UtenHierarchyLabelWidth(
            child: Tooltip(
              message: [...ancestors, label].join(' / '),
              child: AnimatedDefaultTextStyle(
                duration: animDuration,
                curve: UtenAnim.standard,
                style: (theme.textTheme.bodyMedium ?? const TextStyle())
                    .copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : (onDarkRow ? FontWeight.w600 : FontWeight.w400),
                      color: enabled
                          ? (flat
                                ? (flatSelected
                                      ? toggleColor
                                      : (onDarkRow ? Colors.white : null))
                                : (onDarkRow
                                      ? Colors.white
                                      : isSelected
                                      ? theme.colorScheme.primary
                                      : null))
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        );
        final titleCluster = <Widget>[
          expandSlot,
          const SizedBox(width: 4),
          if (leading != null) ...[leading, const SizedBox(width: 8)],
          title,
        ];
        final Widget body;
        if (flat) {
          final hasControls = trailing != null || selection != null;
          // The expanded title cluster receives the width left AFTER the real
          // trailing controls are laid out. Its selection block can never cover
          // those controls, and the title ellipsis stays entirely inside it.
          body = Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, titleConstraints) {
                    final nameWidth = _labelWidth(
                      label,
                      theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ) ??
                          const TextStyle(),
                      MediaQuery.textScalerOf(context),
                    );
                    final blockWidth = leading == null
                        ? math.min(
                            titleConstraints.maxWidth,
                            8 + hitExtent + 4 + nameWidth + 8,
                          )
                        : titleConstraints.maxWidth;
                    return ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minHeight),
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          AnimatedPositioned(
                            duration: animDuration,
                            curve: UtenAnim.standard,
                            top: 0,
                            bottom: 0,
                            left: flatSelected ? 0 : -blockWidth,
                            width: blockWidth,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: blockColor,
                                borderRadius: const BorderRadius.horizontal(
                                  right: Radius.circular(UtenRadius.control),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: verticalPadding,
                            ),
                            child: Row(children: titleCluster),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              ?trailing,
              if (selection != null) ...[
                if (trailing != null) const SizedBox(width: 8),
                selection,
              ],
              if (hasControls) const SizedBox(width: 8),
            ],
          );
        } else {
          body = Padding(
            padding: EdgeInsets.fromLTRB(
              8 + indent,
              verticalPadding,
              8,
              verticalPadding,
            ),
            child: Row(
              children: [
                ...titleCluster,
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
                if (selection != null) ...[const SizedBox(width: 8), selection],
              ],
            ),
          );
        }
        final content = Semantics(
          selected: isSelected,
          expanded: node.hasChildren ? expanded : null,
          child: Material(
            color: rowBg,
            borderRadius: rowRadius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled || node.hasChildren ? () => _onRowTap(node) : null,
              child: DecoratedBox(
                decoration: flat
                    ? BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: onDarkRow
                                ? theme.colorScheme.surface
                                : theme.colorScheme.outlineVariant,
                          ),
                        ),
                      )
                    : const BoxDecoration(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: UtenHierarchyRowSkin(
                    foreground: onDarkRow
                        ? Colors.white
                        : theme.colorScheme.onSurfaceVariant,
                    child: body,
                  ),
                ),
              ),
            ),
          ),
        );
        return UtenHierarchyRowWidth(
          child: UtenContextMenuRegion(
            entriesBuilder: () => _rowMenuEntries(node),
            onMenuOpening: () => _onRowMenuOpening(node),
            child: content,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => UtenPanelOpeningScope.isReadyOf(context)
      ? UtenSelectionLifecycleScope(
          child: UtenMotion(duration: UtenAnim.normal, builder: _buildTree),
        )
      : const UtenPanelOpeningPlaceholder();

  Widget _buildTree(BuildContext context, Duration animDuration) {
    if (animDuration == Duration.zero) _stopBranchMotions();
    final theme = Theme.of(context);
    _reportForestWidth(context, theme);
    _ensureBranchRanks();
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
    // flat 模式：先按当前渲染顺序定出首/末行（圆角挂点），再构建行。
    final plan = _rowPlan(visibleFilter);
    _flatEdgeRowIds = widget.flatLevelColors && plan.isNotEmpty
        ? (firstId: plan.first.node.id, lastId: plan.last.node.id)
        : null;
    final header = KeyedSubtree(
      key: _headerKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?widget.header,
          if (widget.showSearch)
            Padding(
              // 左缘贴 0（2026-10-18 全站分栏口径）：与壳层分类页的左栏搜索、
              // 返回键图标共用 x=0 左缘，不再各自缩进。
              padding: const EdgeInsets.only(bottom: 8),
              // 本地过滤：_searchCtl 的监听器随每次输入(含内置清除按钮)刷新 _query。
              child: UtenHierarchySearchHeader(
                search: KeyedSubtree(
                  key: ObjectKey(_searchCtl),
                  child: UtenSearchBar(
                    key: widget.searchFieldKey,
                    controller: _searchCtl,
                    hint: widget.searchHint,
                  ),
                ),
                trailing: widget.searchTrailing,
              ),
            ),
          if (widget.externalSearchLoading)
            const LinearProgressIndicator(minHeight: 2),
          if (widget.externalSearchError != null)
            Padding(
              // 与内置搜索框共缘（左缘贴 0 口径）。
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
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
        ],
      ),
    );
    final showEmpty =
        (_searching && (visibleFilter?.isEmpty ?? false)) || showExternalEmpty;
    final rowIndexes = {
      for (var i = 0; i < plan.length; i++)
        ValueKey('hierarchy-row:${plan[i].node.id}'): i,
    };
    Widget rowBuilder(BuildContext context, int index) {
      if (index < plan.length) {
        final entry = plan[index];
        final motion = entry.branches
            .map((id) => _branchMotions[id])
            .whereType<_HierarchyBranchMotion>()
            .firstOrNull;
        final opacity =
            motion?.controller.drive(CurveTween(curve: UtenAnim.standard)) ??
            const AlwaysStoppedAnimation<double>(1);
        return KeyedSubtree(
          key: ValueKey('hierarchy-row:${entry.node.id}'),
          child: ExcludeFocus(
            excluding: motion?.closing ?? false,
            child: ExcludeSemantics(
              excluding: motion?.closing ?? false,
              child: IgnorePointer(
                ignoring: motion?.closing ?? false,
                child: FadeTransition(
                  opacity: opacity,
                  child: SlideTransition(
                    position: opacity.drive(
                      Tween<Offset>(
                        begin: const Offset(0, 0.08),
                        end: Offset.zero,
                      ),
                    ),
                    child: UtenSelectionLifecycleScope(
                      child: RepaintBoundary(
                        child: _buildNode(
                          entry.node,
                          entry.depth,
                          entry.ancestors,
                          animDuration,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Padding(
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
      );
    }

    final rowCount = plan.length + (showEmpty ? 1 : 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Match the shared collapsing layout's short-viewport contract: let
        // all controls, status/error text and nodes scroll together. A fixed
        // header must never consume a short directory's entire viewport.
        if (constraints.maxHeight < UtenBreakpoints.mediumStart) {
          return CustomScrollView(
            controller: _scrollController,
            primary: false,
            slivers: [
              SliverToBoxAdapter(child: header),
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 8),
                sliver: SliverList.builder(
                  itemCount: rowCount,
                  itemBuilder: rowBuilder,
                  findChildIndexCallback: (key) => rowIndexes[key],
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            header,
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                primary: false,
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: rowCount,
                itemBuilder: rowBuilder,
                findChildIndexCallback: (key) => rowIndexes[key],
              ),
            ),
          ],
        );
      },
    );
  }
}
