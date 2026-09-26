// UtenMasterPicker - 「左分类树 + 右分页列表」主档选择面板的泛型实现(ADR-111 前端去重)。
//
// 客户选择器与供应商选择器原先各写一份 600+ 行、84% 相同的面板(统一搜索定位分类、
// 分类浏览、全局搜索分页、二次确认)，差异只在仓储、文案与供应商的「添加供应商」。
// 现在面板只有这一份，[showUtenClientPicker] / [showUtenSupplierPicker] 只提供
// [UtenMasterPickerSpec]；表单字段 [UtenMasterPickerField] 同理。
//
// 形态：compact 底部抽屉 / medium+ 右侧滑入面板，宽 = max(720, 屏宽 50%)（2026-09-24
// 与货品选择滑窗同步改版：左树无缩进层级色 + 单根提升 + UtenSplitView 可拖分割线，
// 默认左栏宽 = 最长一行实测宽）。列表始终请求服务端
// selectableOnly(只含「使用」状态)，total/totalPages 与 items 是同一数据库谓词下的
// 权威结果，前端不再二次过滤。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_table_column_kit.dart'
    show utenTableSelectedRowColor;
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../models/product_category_node.dart';
import 'category_tree_search.dart';
import 'uten_category_tree_view.dart';

/// 一种主档选择面板的全部差异点。
class UtenMasterPickerSpec<TItem> {
  const UtenMasterPickerSpec({
    required this.title,
    required this.noun,
    required this.loadTree,
    required this.loadCategoryPage,
    required this.search,
    required this.idOf,
    required this.categoryIdOf,
    required this.labelOf,
    required this.subtitleOf,
    this.searchKey,
    this.quickCreateLabel,
    this.quickCreate,
  });

  final String title;

  /// 面向人的实体名(客户/供应商)，拼进提示文案。
  final String noun;
  final Future<List<ProductCategoryNode>> Function() loadTree;

  /// 分类(子树)下可选记录的一页；[keyword] 为统一搜索带入的分类内过滤词。
  final Future<PagedResult<TItem>> Function(
    String categoryId,
    int page,
    String? keyword,
  )
  loadCategoryPage;

  /// 全局搜索的一页(每页 100 条，面板按页拉全再按分类定位)。
  final Future<PagedResult<TItem>> Function(String query, int page) search;
  final String Function(TItem item) idOf;
  final String? Function(TItem item) categoryIdOf;
  final String Function(TItem item) labelOf;
  final List<String?> Function(TItem item) subtitleOf;
  final Key? searchKey;

  /// 面板头部「添加…」按钮(有权限才给)：返回新建好的记录，面板直接选中它。
  final String? quickCreateLabel;
  final Future<TItem?> Function(BuildContext context)? quickCreate;
}

/// 弹出主档选择面板，返回所选记录；取消返回 null。
Future<TItem?> showUtenMasterPicker<TItem>(
  BuildContext context,
  UtenMasterPickerSpec<TItem> spec,
) async {
  List<ProductCategoryNode> tree;
  try {
    tree = await spec.loadTree();
  } catch (_) {
    if (context.mounted) {
      context.appError('${spec.noun}分类加载失败，请稍后重试');
    }
    return null;
  }
  if (!context.mounted) return null;
  // 单根提升：与货品选择滑窗同口径（2026-09-24），单包装根不占一层。
  tree = hoistSingleRootTree(tree);
  // 滑窗宽度跟屏幕自适应：约占屏宽 50%，下限保持旧款 720。
  final screenWidth = MediaQuery.sizeOf(context).width;
  return showUtenAdaptivePanel<TItem>(
    context: context,
    drawerWidth: math.max(720.0, screenWidth * 0.5),
    builder: (_) => _MasterPickerSheet<TItem>(spec: spec, tree: tree),
  );
}

class _MasterPickerSheet<TItem> extends ConsumerStatefulWidget {
  const _MasterPickerSheet({required this.spec, required this.tree});

  final UtenMasterPickerSpec<TItem> spec;
  final List<ProductCategoryNode> tree;

  @override
  ConsumerState<_MasterPickerSheet<TItem>> createState() =>
      _MasterPickerSheetState<TItem>();
}

class _MasterPickerSheetState<TItem>
    extends ConsumerState<_MasterPickerSheet<TItem>> {
  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  String _globalQuery = '';
  Set<String>? _visibleFilterIds;
  Set<String> _contentMatchCategoryIds = {};
  bool _searchLocationLoading = false;
  String? _searchLocationError;
  bool _showingGlobalResults = false;
  String? _categoryContentKeyword;
  int _requestVersion = 0;
  int _page = 1;
  List<TItem>? _items;
  int _totalPages = 1;
  String? _globalItemsQuery;
  List<TItem> _globalItems = const [];
  bool _loading = false;
  String? _error;

  /// 已点选(高亮)的记录；点底部「确定」才 pop 返回，取消/关闭则放弃(二次操作契约)。
  TItem? _picked;

  /// 左树自然宽度缓存（与货品选择滑窗同款量宽）。
  double? _naturalTreeWidth;

  UtenMasterPickerSpec<TItem> get _spec => widget.spec;

  @override
  void initState() {
    super.initState();
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
      _reloadCategory();
    }
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    _requestVersion++;
    final keepKeyword =
        _globalQuery.isNotEmpty &&
        hierarchyBranchContainsAny(
          widget.tree,
          node.id,
          _contentMatchCategoryIds,
        );
    setState(() {
      _selectedCategoryId = node.id;
      _categoryContentKeyword = keepKeyword ? _globalQuery : null;
      _showingGlobalResults = false;
      _page = 1;
    });
    _reloadCategory();
  }

  /// 用户继续输入时立即让正在飞行的旧请求失效(UtenSearchBar 的 300ms 防抖期间
  /// 旧结果不回写)；防抖到期后由 [_onKeywordChanged] 发起替换请求。
  void _onKeywordInputChanged(String v) {
    _requestVersion++;
    _globalItemsQuery = null;
    _globalItems = const [];
  }

  void _onKeywordChanged(String v) {
    if (!mounted) return;
    _applyGlobalSearch(v.trim());
  }

  Future<void> _applyGlobalSearch(String query) async {
    if (!mounted) return;
    if (query.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null;
        _contentMatchCategoryIds = {};
        _globalItemsQuery = null;
        _globalItems = const [];
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = false;
        _categoryContentKeyword = null;
        _selectedCategoryId ??= widget.tree.isEmpty
            ? null
            : widget.tree.first.id;
        _page = 1;
      });
      await _reloadCategory();
      return;
    }
    setState(() {
      _globalQuery = query;
      _visibleFilterIds = categoryHits(widget.tree, query);
      _contentMatchCategoryIds = {};
      _globalItemsQuery = null;
      _globalItems = const [];
      _searchLocationLoading = true;
      _searchLocationError = null;
      _showingGlobalResults = true;
      _categoryContentKeyword = null;
      _page = 1;
    });
    await _reloadGlobalSearch(allowCategoryFallback: true);
  }

  Future<void> _reloadCategory() async {
    final categoryId = _selectedCategoryId;
    final requestVersion = ++_requestVersion;
    if (categoryId == null) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _totalPages = 1;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _spec.loadCategoryPage(
        categoryId,
        _page,
        _categoryContentKeyword,
      );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _items = r.items;
        _totalPages = r.totalPages < 1 ? 1 : r.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '加载${_spec.noun}失败，请稍后重试';
        _loading = false;
      });
    }
  }

  bool _stale(int requestVersion, String query, int requestedPage) =>
      !mounted ||
      requestVersion != _requestVersion ||
      query != _globalQuery ||
      requestedPage != _page;

  Future<void> _reloadGlobalSearch({
    required bool allowCategoryFallback,
  }) async {
    final query = _globalQuery;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<TItem> allItems;
      if (_globalItemsQuery == query) {
        allItems = _globalItems;
      } else {
        final byId = <String, TItem>{};
        var backendPage = 1;
        var backendTotalPages = 1;
        while (backendPage <= backendTotalPages) {
          final result = await _spec.search(query, backendPage);
          if (_stale(requestVersion, query, requestedPage)) return;
          for (final item in result.items) {
            byId.putIfAbsent(_spec.idOf(item), () => item);
          }
          if (result.totalPages > backendTotalPages) {
            backendTotalPages = result.totalPages;
          }
          backendPage++;
        }
        allItems = byId.values.toList(growable: false);
      }
      final resolution = resolveHierarchySearch(
        roots: widget.tree,
        query: query,
        contentCategoryIds: allItems.map(_spec.categoryIdOf),
      );

      if (allItems.isEmpty && allowCategoryFallback && requestedPage == 1) {
        final categoryId = resolution.selectedId;
        if (categoryId != null) {
          final categoryPage = await _spec.loadCategoryPage(
            categoryId,
            1,
            null,
          );
          if (_stale(requestVersion, query, requestedPage)) return;
          setState(() {
            _selectedCategoryId = categoryId;
            _visibleFilterIds = resolution.visibleIds;
            _contentMatchCategoryIds = {};
            _globalItemsQuery = query;
            _globalItems = const [];
            _searchLocationLoading = false;
            _searchLocationError = null;
            _showingGlobalResults = false;
            _categoryContentKeyword = null;
            _items = categoryPage.items;
            _totalPages = categoryPage.totalPages < 1
                ? 1
                : categoryPage.totalPages;
            _loading = false;
          });
          return;
        }
      }

      const displaySize = 100;
      final totalPages = allItems.isEmpty
          ? 1
          : (allItems.length + displaySize - 1) ~/ displaySize;
      final safePage = requestedPage.clamp(1, totalPages);
      final start = (safePage - 1) * displaySize;
      final end = (start + displaySize).clamp(0, allItems.length);
      setState(() {
        _selectedCategoryId = resolution.selectedId;
        _visibleFilterIds = resolution.visibleIds;
        _contentMatchCategoryIds = resolution.contentCategoryIds;
        _globalItemsQuery = query;
        _globalItems = allItems;
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = true;
        _page = safePage;
        _items = allItems.sublist(start, end);
        _totalPages = totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        if (_items == null || _loading) {
          _error = '搜索${_spec.noun}失败，请稍后重试';
        } else {
          _searchLocationError = '完整分类定位失败，请稍后重试';
        }
        _loading = false;
        _searchLocationLoading = false;
      });
    }
  }

  void _reloadCurrentPage() {
    if (_globalQuery.isNotEmpty && _showingGlobalResults) {
      _reloadGlobalSearch(allowCategoryFallback: false);
    } else {
      _reloadCategory();
    }
  }

  Future<void> _quickCreate() async {
    final create = _spec.quickCreate;
    if (create == null) return;
    final created = await create(context);
    if (created == null || !mounted) return;
    setState(() => _picked = created);
  }

  double _treeNaturalWidth(ThemeData theme) {
    return _naturalTreeWidth ??= measureCategoryTreeNaturalWidth(
      widget.tree,
      theme.textTheme.bodyMedium,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = _picked;
    final treePane = UtenCategoryTreeView<ProductCategoryNode>(
      nodes: widget.tree,
      mode: UtenCategoryTreeMode.single,
      selectedIds: _selectedCategoryId == null
          ? const <String>{}
          : {_selectedCategoryId!},
      expandOnRowTap: true,
      // 左树默认全部收起（2026-09-24 用户口径，与货品选择滑窗同款）。
      initiallyExpandDepth: 0,
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _globalQuery,
      externalSearchLoading: _searchLocationLoading,
      externalSearchError: _searchLocationError,
      header: _buildUnifiedSearch(),
      flatLevelColors: true,
      onToggleSelect: _onCategoryTap,
    );
    Widget body;
    if (context.breakpoint.isCompact) {
      body = Row(
        children: [
          SizedBox(width: 176, child: treePane),
          const VerticalDivider(width: 1),
          Expanded(child: _buildRightPane(theme)),
        ],
      );
    } else {
      // medium+：可拖分割线（与货品选择滑窗/货品资料页同款），
      // 默认左栏宽 = 最长一行实测宽。
      body = UtenSplitView(
        persistenceKey: 'masterPicker.categoryTree',
        initialLeadingWidth: _treeNaturalWidth(theme),
        minLeadingWidth: 200,
        maxLeadingWidth: 560,
        leading: treePane,
        trailing: _buildRightPane(theme),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _spec.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_spec.quickCreate != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    onPressed: _quickCreate,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(_spec.quickCreateLabel ?? '添加${_spec.noun}'),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: body),
        UtenPickerConfirmBar(
          selectedCount: picked == null ? 0 : 1,
          selectedLabel: picked == null ? null : _spec.labelOf(picked),
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Expanded(child: _buildList(theme)),
        if ((_items?.isNotEmpty ?? false) && _totalPages > 1)
          _buildPager(theme),
      ],
    );
  }

  Widget _buildUnifiedSearch() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.breakpoint.isCompact ? 8 : 16,
        8,
        context.breakpoint.isCompact ? 8 : 16,
        8,
      ),
      child: UtenSearchBar(
        key: _spec.searchKey,
        controller: _keywordCtl,
        hint: '搜索分类/${_spec.noun}',
        onInputChanged: _onKeywordInputChanged,
        onChanged: _onKeywordChanged,
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    final items = _items;
    if (items == null || items.isEmpty) {
      return Center(
        child: Text(
          '未找到匹配${_spec.noun}',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final item = items[i];
        final sub = _spec
            .subtitleOf(item)
            .where((s) => s != null && s.isNotEmpty)
            .join(' · ');
        final current = _picked;
        final picked =
            current != null && _spec.idOf(current) == _spec.idOf(item);
        return ListTile(
          selected: picked,
          // 选中行淡绿背景（全站表格统一口径，与货品选择滑窗同款）。
          selectedTileColor: utenTableSelectedRowColor(theme),
          title: Text(_spec.labelOf(item)),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: Theme.of(ctx).textTheme.bodySmall),
          trailing: picked
              ? Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              : null,
          onTap: () => setState(() => _picked = item),
        );
      },
    );
  }

  Widget _buildPager(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _page > 1
                ? () {
                    setState(() => _page -= 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
          Text('$_page / $_totalPages'),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _page < _totalPages
                ? () {
                    setState(() => _page += 1);
                    _reloadCurrentPage();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

/// 只读展示 + 点击打开选择面板的表单字段(单据表头「客户」「供应商/委外商」用)。
///
/// 只提交 id；展示名由本组件持有(宿主表单每次 onChanged 后都用同一份静态初值重建)，
/// 上游引入/到货预填等场景用新 id/name 重建时同步一次，避免仍显示旧值。
class UtenMasterPickerField<TItem> extends StatefulWidget {
  const UtenMasterPickerField({
    super.key,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    required this.idOf,
    required this.nameOf,
    required this.label,
    required this.icon,
    this.hint,
    this.required = false,
    this.enabled = true,
    this.errorMessage,
  });

  final String? initialId;
  final String? initialName;

  /// 回写提交值(id 或 null=清除)。
  final void Function(String? id) onChanged;

  /// 打开选择面板，取消返回 null。
  final Future<TItem?> Function() onPick;
  final String Function(TItem item) idOf;
  final String Function(TItem item) nameOf;
  final String label;
  final IconData icon;
  final String? hint;
  final bool required;
  final bool enabled;
  final String? errorMessage;

  @override
  State<UtenMasterPickerField<TItem>> createState() =>
      _UtenMasterPickerFieldState<TItem>();
}

class _UtenMasterPickerFieldState<TItem>
    extends State<UtenMasterPickerField<TItem>> {
  late final TextEditingController _ctl;
  String? _id;

  static String? _normalizedId(String? id) =>
      (id == null || id.isEmpty) ? null : id;

  @override
  void initState() {
    super.initState();
    _id = _normalizedId(widget.initialId);
    _ctl = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void didUpdateWidget(UtenMasterPickerField<TItem> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialId != oldWidget.initialId ||
        widget.initialName != oldWidget.initialName) {
      _id = _normalizedId(widget.initialId);
      _ctl.text = widget.initialName ?? '';
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(TItem? item) {
    setState(() {
      _id = item == null ? null : widget.idOf(item);
      _ctl.text = item == null ? '' : widget.nameOf(item);
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredEmpty =
        widget.required && _id == null && widget.errorMessage == null;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.6,
      child: TextField(
        controller: _ctl,
        readOnly: true,
        decoration: applyRequiredEmpty(
          UtenInputDecoration(
            InputDecoration(
              label: requiredLabel(
                widget.label,
                theme,
                required: widget.required,
                base: theme.inputDecorationTheme.labelStyle,
              ),
              hintText: widget.hint ?? '点击选择${widget.label}',
              error: widget.errorMessage == null
                  ? null
                  : UtenFieldMessage.error(widget.errorMessage!),
              prefixIcon: Icon(widget.icon),
              suffixIcon: _id != null
                  ? IconButton(
                      tooltip: '清除选择',
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: widget.enabled ? () => _set(null) : null,
                    )
                  : Icon(
                      Icons.unfold_more_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
            ),
          ),
          theme,
          requiredEmpty: requiredEmpty,
        ),
        onTap: widget.enabled
            ? () async {
                final item = await widget.onPick();
                if (item != null) _set(item);
              }
            : null,
      ),
    );
  }
}
