import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
// UtenMasterPicker - 「左分类树 + 右分页列表」主档选择面板的泛型实现(ADR-111 前端去重)。
//
// 客户选择器与供应商选择器原先各写一份 600+ 行、84% 相同的面板(统一搜索定位分类、
// 分类浏览、全局搜索分页、二次确认)，差异只在仓储、文案与供应商的「添加供应商」。
// 现在面板只有这一份，[showUtenClientPicker] / [showUtenSupplierPicker] 只提供
// [UtenMasterPickerSpec]；表单字段 [UtenMasterPickerField] 同理。
//
// 形态：compact 底部抽屉 / medium+ 右侧滑入面板，使用公共 browse 宽度档位（2026-09-24
// 与货品选择滑窗同步改版：左树无缩进层级色 + 单根提升 + UtenSplitView 可拖分割线，
// 默认左栏宽 = 最长一行实测宽）。列表按业务参数请求服务端 selectableOnly，
// 新选择仅含可选记录，历史筛选可含停用记录；total/totalPages 与 items 使用同一
// 数据库谓词，前端不再二次过滤。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_picker_footer_layout.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_panel_opening_scope.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../models/product_category_node.dart';
import '../models/master_search_context.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'category_tree_search.dart';
import 'master_data_table_view.dart';
import 'uten_category_tree_view.dart';
import '../../../shared/ai/page_context/ai_page_context.dart';

/// 一种主档选择面板的全部差异点。
class UtenMasterPickerSpec<TItem> {
  const UtenMasterPickerSpec({
    required this.title,
    required this.noun,
    required this.loadTree,
    required this.loadCategoryPage,
    required this.search,
    required this.searchContext,
    required this.idOf,
    required this.categoryIdOf,
    required this.labelOf,
    required this.tableColumns,
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

  /// 全局搜索的一页；分类位置由独立元数据查询提供，不拉全业务行。
  final Future<PagedResult<TItem>> Function(String query, int page) search;
  final Future<MasterSearchContext> Function(String query, int page)
  searchContext;
  final String Function(TItem item) idOf;
  final String? Function(TItem item) categoryIdOf;
  final String Function(TItem item) labelOf;

  /// 主档选择器统一使用重点字段表格。
  /// 选择器只使用左侧统一搜索，列不接主档自定义布局或额外筛选。
  final List<MasterColumnDef<TItem>> tableColumns;
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
  final owner = ProviderScope.containerOf(context, listen: false);
  final epoch = owner.read(exportContextEpochProvider);
  List<ProductCategoryNode> tree;
  try {
    tree = await spec.loadTree();
  } catch (_) {
    if (context.mounted) {
      context.appError('${spec.noun}分类加载失败，请稍后重试');
    }
    return null;
  }
  if (!context.mounted || epoch != owner.read(exportContextEpochProvider)) {
    return null;
  }
  // 单根提升：与货品选择滑窗同口径（2026-09-24），单包装根不占一层。
  tree = hoistSingleRootTree(tree);
  // 滑窗宽度口径 2026-10-17：比例优先（browse 档 75% 屏宽），720 只作小屏下限。
  return showUtenAdaptivePanel<TItem>(
    context: context,
    drawerWidth: 720,
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
    extends ConsumerState<_MasterPickerSheet<TItem>>
    with ScopedPagedReadViewMixin<_MasterPickerSheet<TItem>> {
  @override
  void scopedPagedReadOwnerChanged() {
    _retireReader();
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  String? _selectedCategoryId;
  final _keywordCtl = TextEditingController();
  String _globalQuery = '';
  Set<String>? _visibleFilterIds;
  bool _searchLocationLoading = false;
  String? _searchLocationError;
  bool _showingGlobalResults = false;
  String? _categoryContentKeyword;
  int _requestVersion = 0;
  bool _acceptPendingSearch = false;
  int _page = 1;
  int _confirmedPage = 1;
  int _queryRevision = 0;
  List<TItem>? _items;
  int _totalPages = 1;
  String? _publishedScopeVersion;
  late final int _readerEpoch;
  bool _readerRetired = false;
  bool get _currentReader =>
      mounted &&
      !_readerRetired &&
      _readerEpoch == ref.read(exportContextEpochProvider);
  bool _loading = false;
  String? _error;

  /// 已点选(高亮)的记录；点底部「确定」才 pop 返回，取消/关闭则放弃(二次操作契约)。
  TItem? _picked;
  final _pickerRows = MasterDataTableRowsController<TItem>();

  /// 左树自然宽度缓存（与货品选择滑窗同款量宽）。
  double? _naturalTreeWidth;

  UtenMasterPickerSpec<TItem> get _spec => widget.spec;

  @override
  void initState() {
    super.initState();
    _readerEpoch = ref.read(exportContextEpochProvider);
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      _retireReader();
    });
    if (widget.tree.isNotEmpty) {
      _selectedCategoryId = widget.tree.first.id;
      _reloadCategory();
    }
  }

  void _retireReader() {
    if (!mounted || _readerRetired) return;
    setState(() {
      _readerRetired = true;
      ++_requestVersion;
      _items = null;
      _picked = null;
      _keywordCtl.clear();
      _loading = false;
    });
  }

  bool _acceptScope(String? version) {
    if (version == null || version.isEmpty) return true;
    if (_publishedScopeVersion != null && _publishedScopeVersion != version) {
      _retireReader();
      return false;
    }
    _publishedScopeVersion = version;
    return true;
  }

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  void _onCategoryTap(ProductCategoryNode node) {
    if (!_currentReader || _globalQuery.isNotEmpty) return;
    _requestVersion++;
    _acceptPendingSearch = false;
    setState(() {
      _selectedCategoryId = node.id;
      _categoryContentKeyword = null;
      _searchLocationLoading = false;
      _searchLocationError = null;
      _showingGlobalResults = false;
      _resetPageWindow();
    });
    _reloadCategory();
  }

  /// 用户继续输入时立即让正在飞行的旧请求失效(UtenSearchBar 的 300ms 防抖期间
  /// 旧结果不回写)；防抖到期后由 [_onKeywordChanged] 发起替换请求。
  void _onKeywordInputChanged(String v) {
    if (!_currentReader) return;
    setState(() {
      _requestVersion++;
      _acceptPendingSearch = true;
      _globalQuery = v.trim();
      _visibleFilterIds = _globalQuery.isEmpty
          ? null
          : categoryHits(widget.tree, _globalQuery);
      _resetPageWindow();
      _loading = true;
      _error = null;
    });
  }

  /// A changed query starts a new page window; adjacent-page loads keep it.
  void _resetPageWindow() {
    _queryRevision++;
    _page = 1;
    _confirmedPage = 1;
    _items = null;
    _totalPages = 1;
  }

  void _onKeywordChanged(String v) {
    if (!_currentReader || !_acceptPendingSearch) return;
    _acceptPendingSearch = false;
    _applyGlobalSearch(v.trim());
  }

  Future<void> _applyGlobalSearch(String query) async {
    if (!_currentReader) return;
    if (query.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null;
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = false;
        _categoryContentKeyword = null;
        _selectedCategoryId ??= widget.tree.isEmpty
            ? null
            : widget.tree.first.id;
        _resetPageWindow();
      });
      await _reloadCategory();
      return;
    }
    setState(() {
      _globalQuery = query;
      _visibleFilterIds = categoryHits(widget.tree, query);
      _searchLocationLoading = true;
      _searchLocationError = null;
      _showingGlobalResults = true;
      _categoryContentKeyword = null;
      _resetPageWindow();
    });
    await _reloadGlobalSearch();
  }

  Future<void> _reloadCategory({bool useCache = false}) async {
    if (!_currentReader) return;
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
      final spec = _spec, keyword = _categoryContentKeyword;
      final r = await readScopedPage<TItem>(
        _page,
        query: _pagingQuery(),
        currentQuery: _pagingQuery,
        useCache: useCache,
        isCurrent: () => _currentReader,
        fetchPage: (target) =>
            spec.loadCategoryPage(categoryId, target, keyword),
      );
      if (!_currentReader || requestVersion != _requestVersion) return;
      if (!_acceptScope(r.readScopeVersion)) return;
      setState(() {
        _items = r.items;
        _page = r.page;
        _confirmedPage = r.page;
        _totalPages = r.totalPages < 1 ? 1 : r.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!_currentReader || requestVersion != _requestVersion) return;
      setState(() {
        _error = '加载${_spec.noun}失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Object _pagingQuery() => [
    _spec,
    _selectedCategoryId,
    _categoryContentKeyword,
    _globalQuery,
    _showingGlobalResults,
    _queryRevision,
  ];

  bool _stale(int requestVersion, String query, int requestedPage) =>
      !_currentReader ||
      requestVersion != _requestVersion ||
      query != _globalQuery ||
      requestedPage != _page;

  Future<Set<String?>> _readSearchContext(
    String query,
    int version,
    int requestedPage,
    String? expectedScope,
  ) async {
    final ids = <String?>{};
    var page = 1, totalPages = 1;
    int? totalCategories, totalMatches;
    String? contextScope;
    while (page <= totalPages) {
      final context = await _spec.searchContext(query, page);
      if (_stale(version, query, requestedPage)) {
        throw StateError('选择器读取已过期');
      }
      final rawScope = context.readScopeVersion;
      final scope = rawScope?.isNotEmpty == true ? rawScope : null;
      if ((expectedScope?.isNotEmpty == true && expectedScope != scope) ||
          (page > 1 && contextScope != scope)) {
        _retireReader();
        throw StateError('选择范围已变化');
      }
      if (!_acceptScope(scope)) throw StateError('选择范围已变化');
      contextScope = scope;
      totalCategories ??= context.totalCategories;
      totalMatches ??= context.totalMatches;
      if (context.page != page ||
          context.totalCategories != totalCategories ||
          context.totalMatches != totalMatches) {
        throw StateError('分类定位范围已变化，请重试搜索');
      }
      ids.addAll(context.categoryIds);
      totalPages = context.totalPages;
      page++;
    }
    if (ids.length != totalCategories) throw StateError('分类定位不完整，请重试搜索');
    return ids;
  }

  Future<void> _reloadGlobalSearch({bool useCache = false}) async {
    if (!_currentReader) return;
    final query = _globalQuery;
    final requestedPage = _page;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final spec = _spec;
      final result = await readScopedPage<TItem>(
        requestedPage,
        query: _pagingQuery(),
        currentQuery: _pagingQuery,
        useCache: useCache,
        isCurrent: () => _currentReader,
        fetchPage: (target) => spec.search(query, target),
      );
      if (_stale(requestVersion, query, requestedPage)) return;
      if (!_acceptScope(result.readScopeVersion)) return;
      // Authorization proof cannot version category content. Cached business
      // rows still revalidate complete category metadata before publication.
      final context = await _readSearchContext(
        query,
        requestVersion,
        requestedPage,
        result.readScopeVersion,
      );
      if (_stale(requestVersion, query, requestedPage)) return;
      // Rows and metadata are separate reads. A concurrent category move must
      // not hide a category belonging to an actual row already on this page.
      final categories = {...context, ...result.items.map(_spec.categoryIdOf)};
      final resolution = resolveHierarchySearch(
        roots: widget.tree,
        query: query,
        contentCategoryIds: categories,
      );
      setState(() {
        _visibleFilterIds = resolution.visibleIds;
        _searchLocationLoading = false;
        _searchLocationError = null;
        _showingGlobalResults = true;
        _page = result.page;
        _confirmedPage = result.page;
        _items = result.items;
        _totalPages = result.totalPages < 1 ? 1 : result.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!_currentReader || requestVersion != _requestVersion) return;
      setState(() {
        _error = '搜索${_spec.noun}失败，请稍后重试';
        _loading = false;
        _searchLocationLoading = false;
      });
    }
  }

  Future<void> _reloadCurrentPage({
    bool useCache = false,
    bool reloadVisible = false,
  }) async {
    if (reloadVisible && _error == null) {
      _page = _pickerRows.visiblePage ?? _page;
    }
    if (_globalQuery.isNotEmpty && _showingGlobalResults) {
      await _reloadGlobalSearch(useCache: useCache);
    } else {
      await _reloadCategory(useCache: useCache);
    }
  }

  Future<void> _changePage(int page) async {
    _page = page;
    await _reloadCurrentPage(useCache: true);
  }

  Future<void> _quickCreate() async {
    final create = _spec.quickCreate;
    if (create == null) return;
    final created = await create(context);
    if (created == null || !_currentReader) return;
    invalidateScopedPageReads();
    setState(() => _picked = created);
  }

  double _treeNaturalWidth(ThemeData theme) {
    return _naturalTreeWidth ??= measureCategoryTreeNaturalWidth(
      widget.tree,
      theme.textTheme.bodyMedium,
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_readerRetired) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('账号、权限或服务器已变化，请关闭后重新选择'),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }
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
      showSearch: false,
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _globalQuery,
      externalSearchLoading: _searchLocationLoading,
      externalSearchError: _searchLocationError,
      header: _buildUnifiedSearch(),
      flatLevelColors: true,
      onToggleSelect: _onCategoryTap,
    );
    final body = UtenSplitView(
      persistenceKey: 'masterPicker.categoryTree',
      initialLeadingWidth: _treeNaturalWidth(theme),
      // 手动缩窄仍由分栏组件保护分类行按钮和可读标题片段。
      minLeadingWidth: 160,
      maxLeadingWidth: 560,
      selectedLeadingLabel:
          utenTreeSelectionPath(widget.tree, _selectedCategoryId) ?? '全部分类',
      selectedLeadingKey: _selectedCategoryId,
      compactHeader: treePane.header,
      leading: treePane,
      trailing: _buildRightPane(),
    );
    return Column(
      children: [
        UtenPanelHeader(
          title: _spec.title,
          onClose: () => Navigator.of(context).pop(),
          actions: [
            if (_spec.quickCreate != null)
              Padding(
                padding: EdgeInsets.only(
                  right: UtenPanelSpacing.inset(context, UtenSpacing.s4),
                ),
                child: OutlinedButton.icon(
                  onPressed: _quickCreate,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(_spec.quickCreateLabel ?? '添加${_spec.noun}'),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: UtenPanelSpacing.browseBody(context),
            child: UtenPanelDeferredView(builder: (_) => body),
          ),
        ),
        UtenPickerConfirmBar(
          pagination: UtenPickerPageControls(controller: _pickerRows),
          selectedCount: picked == null ? 0 : 1,
          selectedLabel: picked == null ? null : _spec.labelOf(picked),
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }

  Widget _buildRightPane() {
    final columns = _spec.tableColumns;
    final requestVersion = _requestVersion;
    final picked = _picked;
    return MasterDataTableView<TItem>(
      expensiveRowMounts: false,
      columns: columns,
      items: _items ?? <TItem>[],
      rowKeyOf: _spec.idOf,
      rowsController: _pickerRows,
      singleTapRows: true,
      isSelected: (item) =>
          picked != null && _spec.idOf(picked) == _spec.idOf(item),
      onRowTap: (item) {
        if (!_currentReader || _loading || requestVersion != _requestVersion) {
          return;
        }
        setState(() => _picked = item);
      },
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      currentPage: _confirmedPage,
      totalPages: _totalPages,
      onPageChange: _changePage,
      paginationScope: _paginationScope,
      paginationRevision: _queryRevision,
      isLoading: _loading && (_items?.isEmpty ?? true),
      loadingMore: _loading && (_items?.isNotEmpty ?? false),
      error: _error,
      onRetry: () => _reloadCurrentPage(reloadVisible: true),
      emptyMessage: '未找到匹配${_spec.noun}',
      showPaginationControls: false,
      showFullscreenToggle: false,
      showColumnChooser: false,
      showSelectionSummary: false,
      enableTextSelection: false,
    );
  }

  Object get _paginationScope => (
    _queryRevision,
    _selectedCategoryId,
    _globalQuery,
    _showingGlobalResults,
    _categoryContentKeyword,
  );

  Widget _buildUnifiedSearch() {
    return Padding(
      // 与分类树共缘；选择器正文统一负责距滑窗边缘的留白。
      padding: UtenPanelSpacing.search(context),
      child: UtenSearchBar(
        key: _spec.searchKey,
        controller: _keywordCtl,
        hint: '搜索分类/${_spec.noun}',
        onInputChanged: _onKeywordInputChanged,
        onChanged: _onKeywordChanged,
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
    this.allowClear = true,
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
  final bool allowClear;
  final String? errorMessage;

  @override
  State<UtenMasterPickerField<TItem>> createState() =>
      _UtenMasterPickerFieldState<TItem>();
}

class _UtenMasterPickerFieldState<TItem>
    extends State<UtenMasterPickerField<TItem>> {
  late final TextEditingController _ctl;
  String? _id;

  // ADR-150: the chosen record's display name is part of what the AI
  // assistant reads (no setter: choosing a record stays with the user).
  final _aiSlot = AiPageSlot();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _aiSlot.attach(context, AiFieldSource(capture: _aiField));
  }

  AiFieldSnapshot? _aiField(AiCaptureContext ctx) {
    final label = aiSnapshotLabel(widget.label);
    if (!mounted || label == null) return null;
    final requiredEmpty =
        widget.required && _id == null && widget.errorMessage == null;
    return AiFieldSnapshot(
      label: label,
      value: _id == null ? null : aiSnapshotValue(_ctl.text),
      state: widget.errorMessage != null
          ? AiFieldState.error
          : requiredEmpty
          ? AiFieldState.requiredEmpty
          : AiFieldState.normal,
      required: widget.required,
      message: aiSnapshotValue(widget.errorMessage, AiSnapshotLimits.info),
    );
  }

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
    _aiSlot.detach();
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
              suffixIcon: _id != null && widget.allowClear
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
                if (mounted && item != null) _set(item);
              }
            : null,
      ),
    );
  }
}
