import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
// 即时库存页（仓库管理 hub 入口，stock:view）。
//
// 左侧分类树 + 右侧库存表，沿用货品资料的可调分栏与窄屏目录。
// 编辑模式复用货品资料的草稿与编辑器，只修改主档库位号、归属仓库。
// - 口径不变：分类「全部」= 不过滤，选任意层级 = 该分类子树聚合，零货品分类
//   自动隐藏；仓库「全部」= 参与核算仓库聚合，选主仓 = 自身 + 全部子仓聚合；
// - 右侧工具栏：货品搜索 + 仓库字段 + 库存范围开关 + 共 N 项；
// - 表格 = 统一 MasterDataTableView：货品识别、库存数量/重量与待处理量在前，
//   主档位置及其他属性在后。库存台账金额列已从页面与预览打印移除
//  （加密导出 Excel 仍由服务端按 goods:cost:view 独立裁列，口径不受本页影响）。
//
// 数据口径（后端 /api/stock/instant-inventory）：
//   数量 = stock_balances 按货品+颜色聚合；多排数量 = 生产计划明细可排余量
//  （老库 View_ProductMore 同口径）。
//   重量 (ADR-135) = 仓库重量账 (千克), 紧跟库存数量: 含估算的前缀「≈」, 有库存但没称过
//   显示「未称」(绝不当 0); 表格工具条「重量单位: 自动▾」切显示单位 (用户级偏好, 与流水/
//   分析页共用)。合计「合计库存重量 ≈3.52 t (另有 12 项未称)」由服务端算好。
//   导出文件的重量列用固定单位 (自动档按千克), 表头带单位, 不混单位。
// 性能：后端一次聚合分页（LIMIT/OFFSET + 排序白名单），前端不拉全量，万级数据秒开。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../components/inputs/uten_filter_chip.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/layout/uten_adaptive_hierarchy_pane.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../components/print/complete_print_snapshot.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../models/instant_inventory_scope.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/repositories/master_inline_edit_repository.dart';
import '../../basic_data/repositories/product_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/product_category_picker_panel.dart';
import '../../basic_data/widgets/uten_category_tree_view.dart';
import '../../basic_data/widgets/goods_related_search_control.dart';
import '../../basic_data/widgets/master_inline_edit.dart';
import '../../basic_data/widgets/master_inline_page_mixin.dart';
import '../models/instant_inventory_summary.dart';
import '../models/stock_query.dart';
import '../../basic_data/models/master_facet.dart';
import '../providers/instant_inventory_prefs_provider.dart';
import '../repositories/stock_query_repository.dart';
import '../widgets/instant_inventory_summary_bar.dart';
import '../widgets/instant_inventory_columns.dart';
import '../widgets/instant_inventory_location_edit.dart';
import '../counts/models/stock_count_request.dart';

class InstantInventoryPage extends ConsumerStatefulWidget {
  const InstantInventoryPage({
    super.key,
    this.initialScope,
    this.initialNavigation,
  }) : assert(initialScope == null || initialNavigation == null);
  final InstantInventoryScope? initialScope;
  final InstantInventoryNavigationContext? initialNavigation;

  @override
  ConsumerState<InstantInventoryPage> createState() =>
      _InstantInventoryPageState();
}

class _InstantInventoryPageState extends ConsumerState<InstantInventoryPage>
    with
        MasterInlinePageMixin<InstantInventoryPage, InstantInventoryRow>,
        ScopedPagedReadViewMixin<InstantInventoryPage> {
  int get _refreshPage => _readingRows.visiblePage ?? (_page?.page ?? _pageNum);

  final _readingRows = MasterDataTableRowsController<InstantInventoryRow>();
  @override
  void scopedPagedReadOwnerChanged() {
    if (!mounted) return;
    inlineClearView();
    if (scopedPagedReadRejection case final error?) {
      setState(() => _error = error.message);
    }
  }

  static const _minTwoPaneWidth = 840.0;
  bool get _compactActions =>
      MediaQuery.sizeOf(context).width < _minTwoPaneWidth;
  bool get _canViewCategories =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.materialCategoryView);

  // 分类树独立滚动，刷新及分类切换不重挂右侧库存表。
  List<ProductCategoryNode>? _tree;
  String? _treeError;
  Map<String, GoodsDetail> _locationSnapshots = const {};
  int _locationLoading = 0;
  int _locationUnavailable = 0;

  // 分类筛选选中态：null = 全部（不过滤）。
  String? _categoryId;
  String? _searchCategoryId;
  String? get _effectiveCategoryId =>
      _searchQuery.isNotEmpty ? _searchCategoryId : _categoryId;
  bool _includeRelated = false;
  int _queryContextVersion = 0;

  // 搜索直接查询库存结果，不再拉取分类定位提示。
  String _searchQuery = '';
  bool _acceptPendingSearch = false;
  Timer? _searchDebounce;
  final _searchRequests = LatestRequestGuard();
  String _keyword = '';

  // 库存表格分页态。
  PagedResult<InstantInventoryRow>? _page;
  String _pageSummaryScopeLabel = '';
  int _pageNum = 1;
  bool _loading = false;
  String? _error;

  /// 合计条过期标记：任何回第 1 页的重查（搜索/筛选/分类/仓库变化）进行中时，
  /// 旧合计不得当作当前值展示（防误开旧范围分析，钉于合计条测试口径）。
  /// 行数据照常保留到新结果落地（keepPreviousData），只有合计条隐藏。
  bool _summaryStale = false;
  final _loadRequests = LatestRequestGuard();

  /// 「返回即刷新」登记用的本页路径（build 首次捕获）。
  String? _myLocation;
  String? _warehouseId; // null = 全部（参与核算仓库聚合）；父仓 = 子树聚合（V476）
  String? _returnTo;

  /// 「含线边仓」(V595)：线边仓是车间直送料架，默认不计入即时库存；仅本页会话内生效。
  bool _includeLineSide = false;
  bool? _restoredIncludeDefective;
  bool get _includeDefective =>
      _restoredIncludeDefective ?? ref.read(instantInventoryPrefsProvider);
  // 列排序态：null=后端默认（库存数量 DESC）。
  String? _sortKey;
  bool _sortAsc = false;

  // 表头筛选态（2026-09-15 起「所属仓库」列；key=列 key，值=仓库 UUID 或
  // kMasterFilterNullValue 哨兵=筛未登记）。服务端过滤+服务端聚合 facet 桶。
  Map<String, String?> _filters = {};

  @override
  bool get inlineCanEdit {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.containsAll({
      Perm.stockView,
      Perm.goodsView,
      Perm.goodsEdit,
    });
  }

  @override
  bool get inlineReadReady => _resultsReady;
  @override
  String get inlineEntityType => 'goods';
  @override
  String inlineIdOf(InstantInventoryRow row) => row.goodsId ?? '';
  @override
  Map<String, MasterInlineField<InstantInventoryRow>> get inlineFields =>
      instantInventoryLocationFields(context, ref);
  @override
  Future<void> inlineReload() => _load(_refreshPage);
  @override
  Future<void> inlineReloadAfterBoundary() => _refresh();
  @override
  void inlineClearView() {
    _searchRequests.begin();
    _loadRequests.begin();
    _searchDebounce?.cancel();
    _page = null;
    _tree = null;
    _error = null;
    _treeError = null;
    _locationSnapshots = const {};
    _loading = false;
    _acceptPendingSearch = false;
    if (mounted) setState(() {});
  }

  @override
  Future<void> saveInline(String id, Map<String, dynamic> patch) async {
    if (!inlineCanEdit || !inlineReadReady) {
      throw StateError('编辑权限或查询结果已变化，请刷新后重试');
    }
    final row = inlineEdit.baselineOf(id);
    final snapshot = _locationSnapshots[id];
    if (row == null || !instantInventoryLocationWritable(row, snapshot)) {
      throw StateError('货品位置资料已变化或不可编辑，请刷新后重试');
    }
    if (!{'stockPlace', 'owningWarehouseId'}.containsAll(patch.keys)) {
      throw StateError('只能编辑库位号和主档归属仓库');
    }
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    await runSensitiveWrite(
      ref,
      isCurrent: () => mounted && inlineCanEdit && inlineReadReady,
      write: () => ref
          .read(masterInlineEditRepositoryProvider)
          .save(
            'goods',
            id,
            changes: patch,
            expected: {'version': snapshot!.version},
          ),
    );
    if (!mounted || ref.read(sensitiveReadBoundaryProvider) != boundary) return;
    ref.invalidate(instantInventoryLocationSnapshotProvider(id));
    await inlineReload();
  }

  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, inlineClearView);
    final navigation =
        widget.initialNavigation ??
        (widget.initialScope == null
            ? null
            : InstantInventoryNavigationContext.fromLegacyScope(
                widget.initialScope!,
              ));
    final scope = navigation?.scope;
    if (scope != null) {
      _categoryId = scope.keyword?.trim().isNotEmpty == true
          ? navigation!.browseCategoryId
          : scope.categoryId;
      _returnTo = navigation!.returnTo;
      _warehouseId = scope.warehouseId;
      _includeLineSide = scope.includeLineSide;
      _restoredIncludeDefective = scope.includeDefective;
      _searchQuery = scope.keyword ?? '';
      _keyword = _searchQuery;
      _searchCategoryId = _searchQuery.isEmpty ? null : scope.categoryId;
      _includeRelated = _searchQuery.isNotEmpty && scope.includeRelated;
      _filters = {
        'owningWarehouse': scope.owningWarehouseNull
            ? kMasterFilterNullValue
            : scope.owningWarehouse,
        'color': scope.colorId,
        'series': scope.series,
        'unit': scope.unitId,
      };
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final ownerCurrent = captureReadOwner(ref);
    final generation = _searchRequests.begin();
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    // Category paths and warehouse labels decorate the server-authored rows;
    // neither is a prerequisite for reading even an empty inventory result.
    unawaited(_loadTree());
    unawaited(_warmWarehouseNames(ownerCurrent));
    if (!ownerCurrent() || !_searchRequests.isCurrent(generation)) return;
    await _applySearch(_searchQuery);
  }

  Future<void> _warmWarehouseNames(bool Function() ownerCurrent) async {
    try {
      await ref.read(masterNameServiceProvider).ensureWarehousesLoaded();
      if (mounted && ownerCurrent()) setState(() {});
    } catch (_) {
      // Row DTOs already carry names; the warehouse picker can retry on open.
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTree() async {
    if (!_canViewCategories) return;
    final ownerCurrent = captureReadOwner(ref);
    final boundary = captureInlineRead();
    try {
      final tree = await ref
          .read(productCategoryRepositoryProvider)
          .treeWithGoodsCounts();
      if (!ownerCurrent() || !inlineAcceptsRead(boundary)) return;
      setState(() {
        _tree = pruneCategoriesWithoutGoods(tree);
        _treeError = null;
      });
    } on ApiException catch (e) {
      if (!ownerCurrent() || !inlineAcceptsRead(boundary)) return;
      setState(() => _treeError = e.message);
    } catch (_) {
      if (!ownerCurrent() || !inlineAcceptsRead(boundary)) return;
      setState(() => _treeError = '加载分类失败'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    _queryContextVersion++;
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final pageRepository = ref.read(stockQueryRepositoryProvider);
      final pageCategoryId = _effectiveCategoryId;
      final pageWarehouseId = _warehouseId;
      final pageIncludeDefective = _includeDefective;
      final pageIncludeLineSide = _includeLineSide;
      final pageKeyword = _keyword.isEmpty ? null : _keyword;
      final pageIncludeRelated = _includeRelated;
      final pageOwningWarehouse = _owningFilterUuid;
      final pageOwningWarehouseNull = _owningFilterIsNull;
      final pageColorId = _columnFilter('color');
      final pageSeries = _columnFilter('series');
      final pageUnitId = _columnFilter('unit');
      final pageSort = _sortKey;
      final pageOrder = _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc');

      final r = await readScopedPage(
        page,
        slot: '_load',
        query: [
          pageRepository,
          pageCategoryId,
          pageWarehouseId,
          pageIncludeDefective,
          pageIncludeLineSide,
          pageKeyword,
          pageIncludeRelated,
          pageOwningWarehouse,
          pageOwningWarehouseNull,
          pageColorId,
          pageSeries,
          pageUnitId,
          pageSort,
          pageOrder,
        ],
        currentQuery: () => [
          ref.read(stockQueryRepositoryProvider),
          _effectiveCategoryId,
          _warehouseId,
          _includeDefective,
          _includeLineSide,
          _keyword.isEmpty ? null : _keyword,
          _includeRelated,
          _owningFilterUuid,
          _owningFilterIsNull,
          _columnFilter('color'),
          _columnFilter('series'),
          _columnFilter('unit'),
          _sortKey,
          _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        ],
        useCache: useCache,
        fetchPage: (target) => pageRepository.instantInventory(
          page: target,
          categoryId: pageCategoryId,
          warehouseId: pageWarehouseId,
          includeDefective: pageIncludeDefective,
          includeLineSide: pageIncludeLineSide,
          keyword: pageKeyword,
          includeRelated: pageIncludeRelated,
          owningWarehouse: pageOwningWarehouse,
          owningWarehouseNull: pageOwningWarehouseNull,
          colorId: pageColorId,
          series: pageSeries,
          unitId: pageUnitId,
          sort: pageSort,
          order: pageOrder,
        ),
      );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      // 「所属仓库」列的名字来自货品字典，先补齐再落表，免得整页先空一拍再跳字。
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _pageSummaryScopeLabel = _summaryScopeLabel;
        _summaryStale = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted && _loadRequests.isCurrent(generation)) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  /// 归属仓筛选值：普通值=仓库 UUID；哨兵=筛未登记。
  String? get _owningFilterUuid {
    final v = _filters['owningWarehouse'];
    return (v == null || v == kMasterFilterNullValue) ? null : v;
  }

  bool get _owningFilterIsNull =>
      _filters['owningWarehouse'] == kMasterFilterNullValue;

  bool get _summaryLoading => _loading || _acceptPendingSearch;
  bool get _summaryHasError => _error != null;
  bool get _resultsReady =>
      _page != null && !_summaryLoading && !_summaryHasError;

  String get _categoryScopeLabel => _effectiveCategoryId == null
      ? '全部分类'
      : utenTreeSelectionPath<ProductCategoryNode>(
              _tree ?? const [],
              _effectiveCategoryId,
            ) ??
            '所选分类';

  String get _summaryScopeLabel {
    final names = ref.read(masterNameServiceProvider);
    final parts = <String>[
      _categoryScopeLabel,
      _warehouseId == null
          ? '全部仓库'
          : names.warehouseEntries[_warehouseId] ?? '所选仓库',
      if (_warehouseId == null || names.warehouseHasChildren(_warehouseId)) ...[
        _includeDefective ? '含不良品仓' : '不含不良品仓',
        _includeLineSide ? '含内料仓' : '不含内料仓',
      ],
      if (_keyword.isNotEmpty) '搜索：$_keyword',
      if (_keyword.isNotEmpty && _includeRelated) '含相关结果',
    ];
    const filterLabels = {
      'owningWarehouse': '归属仓库',
      'color': '颜色',
      'series': '物料系列',
      'unit': '单位',
    };
    for (final filter in _filters.entries) {
      if (filter.value == null) continue;
      String label = filter.value == kMasterFilterNullValue ? '未登记' : '已筛选';
      for (final bucket in _page?.facets[filter.key] ?? <MasterFacetBucket>[]) {
        if (bucket.value == filter.value) label = bucket.display;
      }
      parts.add('${filterLabels[filter.key] ?? filter.key}：$label');
    }
    return parts.join(' · ');
  }

  void _showSummary() {
    final page = _page;
    if (page == null || _summaryLoading || _summaryHasError) return;
    final navigation = _navigationContext;
    context.push(
      Uri(
        path: RouteName.stockInstantInventoryOverview,
        queryParameters: {
          ...navigation.scope.toQuery(),
          'scopeLabel': _pageSummaryScopeLabel,
          'returnTo': _inventoryLocation(navigation),
        },
      ).toString(),
    );
  }

  InstantInventoryNavigationContext get _navigationContext =>
      InstantInventoryNavigationContext(
        scope: InstantInventoryScope(
          categoryId: _effectiveCategoryId,
          warehouseId: _warehouseId,
          includeDefective: _includeDefective,
          includeLineSide: _includeLineSide,
          keyword: _keyword.isEmpty ? null : _keyword,
          includeRelated: _includeRelated,
          owningWarehouse: _owningFilterUuid,
          owningWarehouseNull: _owningFilterIsNull,
          colorId: _columnFilter('color'),
          series: _columnFilter('series'),
          unitId: _columnFilter('unit'),
        ),
        browseCategoryId: _categoryId,
        returnTo: _returnTo,
      );

  String _inventoryLocation(InstantInventoryNavigationContext navigation) =>
      Uri(
        path: RouteName.stockInstantInventory,
        queryParameters: navigation.toQuery(),
      ).toString();

  /// 颜色/系列/单位列筛选值（服务端 facet 桶值：颜色 UUID / 系列文本 / 单位 UUID）。
  /// 这三列不下发空值桶，哨兵值按无过滤处理。
  String? _columnFilter(String key) {
    final v = _filters[key];
    return (v == null || v == kMasterFilterNullValue) ? null : v;
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key); // 选"所有"= 不筛
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _reloadAfterFilterChange();
  }

  /// 导出查询参数 (与 _load 同一口径含表头筛选, 不含 page/size; report 固定
  /// 'instant-inventory' 走后端独立分支)。重量单位用用户显示单位, 「自动」按千克
  /// (文件里的数值列不混单位)。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_effectiveCategoryId != null) 'categoryId': _effectiveCategoryId,
    if (_warehouseId != null) 'warehouseId': _warehouseId,
    'includeDefective': _includeDefective,
    if (_includeLineSide) 'includeLineSide': true,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    if (_keyword.isNotEmpty && _includeRelated) 'includeRelated': true,
    'owningWarehouse': ?_owningFilterUuid,
    if (_owningFilterIsNull) 'owningWarehouseNull': true,
    'colorId': ?_columnFilter('color'),
    'series': ?_columnFilter('series'),
    'unitId': ?_columnFilter('unit'),
    'weightUnit': ref
        .read(warehouseWeightUnitsPrefsProvider)
        .display
        .exportUnit
        .code,
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览数据：按当前筛选口径完整分页读取，列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final contextVersion = _queryContextVersion;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final epoch = ref.read(exportContextEpochProvider);
    final repository = ref.read(stockQueryRepositoryProvider);
    final categoryId = _effectiveCategoryId, warehouseId = _warehouseId;
    final includeDefective = _includeDefective,
        includeLineSide = _includeLineSide;
    final keyword = _keyword.isEmpty ? null : _keyword;
    final related = _includeRelated;
    final owningWarehouse = _owningFilterUuid, owningNull = _owningFilterIsNull;
    final colorId = _columnFilter('color'),
        series = _columnFilter('series'),
        unitId = _columnFilter('unit');
    final sort = _sortKey;
    final order = sort == null ? null : (_sortAsc ? 'asc' : 'desc');
    final columns = _columns();
    bool current() =>
        mounted &&
        contextVersion == _queryContextVersion &&
        _resultsReady &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        epoch == ref.read(exportContextEpochProvider);
    final scope = await boundary.api.captureRequestScope(isCurrent: current);
    final table = await scope.run(
      () => loadCompletePrintSnapshot<InstantInventoryRow>(
        loadPage: (page, size) => repository.instantInventory(
          page: page,
          size: size,
          categoryId: categoryId,
          warehouseId: warehouseId,
          includeDefective: includeDefective,
          includeLineSide: includeLineSide,
          keyword: keyword,
          includeRelated: related,
          owningWarehouse: owningWarehouse,
          owningWarehouseNull: owningNull,
          colorId: colorId,
          series: series,
          unitId: unitId,
          sort: sort,
          order: order,
        ),
        idOf: (row) => '${row.goodsId}|${row.colorId}',
        includeRowIds: false,
        headers: [for (final column in columns) column.label],
        columnKeys: [for (final column in columns) column.key],
        cellsOf: (row) => [
          for (final column in columns) column.value(row) ?? '',
        ],
        factsOf: (row) => {
          'qty': row.qty?.toString(),
          'costAmount': row.costAmount?.toString(),
          'moreQty': row.moreQty?.toString(),
          'pendingQty': row.pendingQty?.toString(),
          'pendingStockInQty': row.pendingStockInQty?.toString(),
          'weight': row.weight?.toString(),
          'unitWeightKg': row.unitWeightKg?.toString(),
        },
        isCurrent: () => current() && scope.isCurrent,
      ),
    );
    await scope.verify();
    return table;
  }

  List<MasterColumnDef<InstantInventoryRow>> _columns() =>
      instantInventoryColumns(
        context,
        weightDisplay: ref.read(warehouseWeightUnitsPrefsProvider).display,
      );

  void _onSearchInput(String raw) {
    _queryContextVersion++;
    _searchDebounce?.cancel();
    _searchRequests.begin();
    _loadRequests.begin();
    final q = raw.trim();
    setState(() {
      _searchQuery = q;
      // 保留旧结果直到新查询落地（keepPreviousData 口径）：此前这里先把 _page
      // 置 null，防抖/网络期间表格立刻闪「暂无库存」空态，数据回来再跳一次。
      if (q.isEmpty) {
        _searchCategoryId = null;
        _includeRelated = false;
      }
      _acceptPendingSearch = true;
      // 合计条走独立的过期口径（_summaryStale）：范围一变立即隐藏旧合计；
      // 行数据保留到新结果落地（keepPreviousData）。
      _summaryStale = true;
      _loading = false;
    });
    // 搜索框会在分栏/抽屉切换时卸载，防抖由页面持有以保留未完成的输入。
    if (q.isEmpty) {
      _onSearchChanged(q);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _onSearchChanged(q),
    );
  }

  void _onSearchChanged(String raw) {
    final q = raw.trim();
    if (!_acceptPendingSearch || q != _searchQuery) return;
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    _applySearch(q);
  }

  Future<void> _applySearch(String q) async {
    setState(() => _keyword = q);
    await _load(1);
  }

  void _selectCategory(String? id) {
    if (id == _effectiveCategoryId) return;
    if (_searchQuery.isNotEmpty) {
      setState(() => _searchCategoryId = id);
      _restartSearch();
      return;
    }
    _searchRequests.begin();
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    setState(() {
      _categoryId = id;
      _keyword = '';
      _summaryStale = true;
    });
    _load(1);
  }

  void _restartSearch() {
    _searchDebounce?.cancel();
    _searchRequests.begin();
    _loadRequests.begin();
    _queryContextVersion++;
    setState(() {
      _acceptPendingSearch = false;
      // 与 _onSearchInput 同口径：旧行保留、旧合计隐藏（此前整页清空闪骨架）。
      _summaryStale = true;
      _pageNum = 1;
      _error = null;
    });
    _applySearch(_searchQuery);
  }

  void _reloadAfterFilterChange() {
    // 仓库/开关/表头列筛选都改合计范围：旧行保留、旧合计隐藏。
    setState(() => _summaryStale = true);
    if (_searchQuery.isNotEmpty) {
      _restartSearch();
    } else {
      _load(1);
    }
  }

  Widget _buildCategoryPane() {
    final theme = Theme.of(context);
    return Builder(
      builder: (paneContext) => ExcludeFocus(
        excluding: inlineEdit.active,
        child: IgnorePointer(
          ignoring: inlineEdit.active,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                key: const Key('instant-inventory-all-categories'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: UtenRadius.controlAll,
                ),
                selected: _effectiveCategoryId == null,
                selectedTileColor: theme.colorScheme.primaryContainer,
                leading: const Icon(Icons.all_inbox_outlined),
                title: const Text('全部分类'),
                onTap: () {
                  _selectCategory(null);
                  UtenHierarchyPanelScope.maybeOf(
                    paneContext,
                  )?.onSelection?.call();
                },
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (_treeError != null)
                TextButton(
                  onPressed: _loadTree,
                  child: Text('$_treeError，重试分类'),
                ),
              if (_tree == null && _treeError == null)
                const LinearProgressIndicator(),
              Expanded(
                child: UtenCategoryTreeView<ProductCategoryNode>(
                  key: const Key('instant-inventory-category-tree'),
                  nodes: _tree ?? const [],
                  selectedIds: {?_effectiveCategoryId},
                  flatLevelColors: true,
                  expandOnRowTap: true,
                  initiallyCollapsedNames: const {'未分类'},
                  searchFieldKey: const Key(
                    'instant-inventory-category-search',
                  ),
                  onNodeTap: (node) => _selectCategory(node.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInventoryLayout() {
    if (!_canViewCategories) return _buildTablePane();
    return UtenSplitView(
      persistenceKey: 'stock.instantInventory',
      initialLeadingWidth: 240,
      minLeadingWidth: 200,
      maxLeadingWidth: 400,
      minTrailingWidth: 520,
      minTwoPaneWidth: _minTwoPaneWidth,
      selectedLeadingLabel: _categoryScopeLabel,
      selectedLeadingKey: _effectiveCategoryId,
      openLeadingButtonKey: const Key('instant-inventory-open-categories'),
      leading: _buildCategoryPane(),
      trailing: _buildTablePane(),
    );
  }

  /// 仓库筛选 = 同一侧滑面板的查询口径（includeAll + allowParent）：
  /// 「全部」= 参与核算仓库聚合（_warehouseId=null）；选主仓 = 自身 + 全部子仓聚合。
  Future<void> _pickWarehouse() async {
    final result = await showUtenWarehousePickerPanel(
      context,
      hierarchy: ref.read(masterNameServiceProvider).warehouseHierarchy,
      initialWarehouseId: _warehouseId,
      title: '选择仓库', // TODO(l10n): 补 arb
      includeAll: true,
      use: WarehouseUse.query,
    );
    if (!mounted || result == null) return;
    final next = result.isAll ? null : result.id;
    if (next == _warehouseId) return;
    setState(() => _warehouseId = next);
    _reloadAfterFilterChange();
  }

  // ---- 右侧工具栏与库存表格（分类切换不重挂，保留列筛选/排序） ------

  Widget _buildTablePane() {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    ref.watch(instantInventoryPrefsProvider);
    final includeDefective = _includeDefective;
    final weightDisplay = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final total = _page?.total ?? 0;
    // 「含不良品仓」只在聚合口径下生效：全部（null）或父仓（多仓聚合）；
    // 选定叶子仓时开关置灰（单仓口径开关无意义）。
    final aggregateWarehouse =
        _warehouseId == null || names.warehouseHasChildren(_warehouseId);
    final locationFields = inlineEdit.active && inlineCanEdit
        ? inlineFields
        : const <String, MasterInlineField<InstantInventoryRow>>{};
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: ExcludeFocus(
        excluding: inlineEdit.active,
        child: IgnorePointer(
          ignoring: inlineEdit.active,
          child: Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String?>(
                  searchKey: const Key('instant-inventory-search'),
                  searchHint: '搜索货品名称 / 编号 / 型号',
                  initialSearchValue: _searchQuery,
                  onSearchInputChanged: _onSearchInput,
                  onSearchSubmitted: _onSearchChanged,
                  trailing: Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      UtenFilterPickerField(
                        key: const Key('instant-inventory-warehouse'),
                        label: '仓库', // TODO(l10n): 补 arb
                        icon: Icons.warehouse_outlined,
                        value: _warehouseId == null
                            ? null
                            : names.warehouseEntries[_warehouseId],
                        onTap: _pickWarehouse,
                      ),
                      UtenFilterChip(
                        label: const Text('含不良品仓'), // TODO(l10n): 补 arb
                        selected: includeDefective,
                        onSelected: !aggregateWarehouse
                            ? null
                            : (v) {
                                final preferenceChanged =
                                    ref.read(instantInventoryPrefsProvider) !=
                                    v;
                                setState(() => _restoredIncludeDefective = v);
                                ref
                                    .read(
                                      instantInventoryPrefsProvider.notifier,
                                    )
                                    .setIncludeDefective(v);
                                if (!preferenceChanged) {
                                  _reloadAfterFilterChange();
                                }
                              },
                      ),
                      // V595：线边仓是车间内部直送的料架，不是现实里的仓库——默认不算进即时库存，
                      // 要看车间料架上还有多少直送料时再打开。选定叶子仓时同样置灰。
                      Tooltip(
                        message: '内料仓是车间的料架, 默认不计入即时库存',
                        child: UtenFilterChip(
                          key: const Key('instant-inventory-line-side'),
                          // 本页其余文案尚未接 arb, 既有 widget 测试不挂本地化代理:
                          // 取不到时回落中文原文, 不因缺代理而抛错。
                          label: Text(
                            Localizations.of<AppLocalizations>(
                                  context,
                                  AppLocalizations,
                                )?.wmIncludeWorkshopStore ??
                                '含内料仓',
                          ),
                          selected: _includeLineSide,
                          onSelected: !aggregateWarehouse
                              ? null
                              : (v) {
                                  setState(() => _includeLineSide = v);
                                  _reloadAfterFilterChange();
                                },
                        ),
                      ),
                      Text(
                        '共 $total 项', // TODO(l10n): 补 arb
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_searchQuery.isNotEmpty)
                  GoodsRelatedSearchControl(
                    value: _includeRelated,
                    onChanged: (value) {
                      setState(() => _includeRelated = value);
                      _restartSearch();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
      body: MasterDataTableView<InstantInventoryRow>(
        rowsController: _readingRows,
        expensiveRowMounts: inlineEdit.active,
        tableKey:
            'features.stock.pages.instant_inventory_page.InstantInventoryPageState._buildTablePane.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        columns: inlineEdit.columns(
          columns: _columns(),
          idOf: inlineIdOf,
          fields: locationFields,
          writableOf: (row) =>
              inlineReadReady &&
              instantInventoryLocationWritable(
                row,
                _locationSnapshots[row.goodsId],
              ),
        ),
        items: _page?.items ?? const [],
        rowKeyOf: (r) => stockCountRowKey(r.goodsId ?? '', r.colorId),
        toolbarActions: [
          if (inlineEdit.active)
            Tooltip(
              message: '仅编辑货品主档的库位号、归属仓库，不移动库存。切换查询前请先保存或取消编辑。',
              child: Text(
                _locationLoading > 0
                    ? '正在核对 $_locationLoading 项货品的编辑权限'
                    : _locationUnavailable > 0
                    ? '$_locationUnavailable 项资料不可编辑或已变化，请刷新核对'
                    : '编辑库位号和主档归属仓库',
              ),
            ),
          // 「重量单位: 自动▾」: 用户级显示偏好 (与库存详情/分析页共用), 只改显示。
          const WeightDisplayUnitButton(),
          // 导出仍受独立权限、限流、行数上限和审计约束；文件密码可选。
          // 预览打印（A4 预览 → 系统打印；与导出口径一致，上限 2000 行）
          UtenPrintPreviewButton(
            enabled: _resultsReady,
            title: '即时库存',
            subtitle: '最多前 2000 行',
            loader: _printLoader,
            exportEndpoint: '/stock/reports/export',
            exportPermission: Perm.stockReportExport,
            exportReport: 'instant-inventory',
            exportQuery: _exportQuery,
            exportFilename: '即时库存',
            type: UtenButtonType.secondary,
            size: UtenButtonSize.medium,
          ),
          UtenExportButton(
            key: ValueKey(('instant-inventory-export', _queryContextVersion)),
            prepareExport: () async {
              final version = _queryContextVersion;
              return UtenExportSelection(
                stillCurrent: () =>
                    mounted && version == _queryContextVersion && _resultsReady,
              );
            },
            enabled: _resultsReady,
            endpoint: '/stock/reports/export',
            requiredPermission: Perm.stockReportExport,
            report: 'instant-inventory',
            queryParams: _exportQuery,
            filename: '即时库存',
            type: UtenButtonType.primary,
            size: UtenButtonSize.medium,
          ),
        ],
        // facet 桶/空值计数由服务端随列表下发（未应用归属筛选的同一口径聚合）。
        facets: _page?.facets ?? const {},
        nullCounts: _page?.facetNullCounts ?? const {},
        filters: _filters,
        onFilterChanged: (key, value) =>
            inlineNavigate(() => _onFilterChanged(key, value)),
        sortColumn: _sortKey,
        sortAscending: _sortAsc,
        onSortChange: inlineEdit.active ? null : _onSortChange,
        // 行点击 → 库存详情页（该货品各仓余额 + 出入库流水；push 保活本页筛选）
        onRowTap: inlineEdit.active
            ? null
            : (r) {
                final gid = r.goodsId;
                if (gid == null || gid.isEmpty) return;
                context.push(
                  RouteName.stockItemDetail(
                    gid,
                    scope: InstantInventoryScope(
                      warehouseId: _warehouseId,
                      colorId: r.colorId,
                      colorNull: r.colorId == null,
                      includeDefective: _includeDefective,
                      includeLineSide: _includeLineSide,
                    ),
                    returnTo: _inventoryLocation(_navigationContext),
                  ),
                );
              },
        isLoading: _loading && _page == null,
        loadingMore: _loading && _page != null,
        error: _error,
        onRetry: () => inlineNavigate(() => _load(_refreshPage)),
        emptyMessage: '暂无库存', // TODO(l10n): 补 arb
        // 页脚收敛为重量 + 详情；分析只消费同一响应的全筛选范围服务端合计。
        // 加载/失败/防抖挂起时禁止打开旧范围的快照，缺失 totals 不伪造本页合计。
        summaryBar:
            (_page == null ||
                _page!.totals.isEmpty ||
                _summaryStale ||
                _acceptPendingSearch)
            ? null
            : InstantInventorySummaryBar(
                summary: InstantInventorySummary(
                  totals: _page!.totals,
                  totalRows: _page!.total,
                ),
                weightDisplay: weightDisplay,
                loading: _summaryLoading,
                hasError: _summaryHasError,
                onDetails: () => inlineNavigate(_showSummary),
              ),
        currentPage: _page?.page ?? 1,
        totalPages: _page?.totalPages ?? 1,
        // 右下悬浮盘点动作组压在表尾上，给滚动的末尾留出让位空间。
        bottomContentPadding:
            inlineCanEdit ||
                inlineEdit.active ||
                (ref
                        .read(currentPermissionsProvider)
                        .contains(stockCountSubmitPermission) &&
                    !_compactActions)
            ? UtenFloatingActionGroup.scrollClearance
            : 0,
        paginationScope: (
          _effectiveCategoryId,
          _warehouseId,
          _includeLineSide,
          _keyword,
          _includeRelated,
          _includeDefective,
        ),
        onPageChange: (p) => inlineNavigate(() => _load(p, useCache: true)),
      ),
    );
  }

  List<Widget> _countActions() => [
    UtenButton(
      key: const Key('stock-count-mode'),
      size: UtenButtonSize.large,
      type: UtenButtonType.secondary,
      icon: Icons.fact_check_outlined,
      onPressed: () => inlineNavigate(
        () => pushPage(
          context,
          Uri(
            path: RouteName.stockCountSession,
            queryParameters: {
              if (_warehouseId != null) 'warehouseId': _warehouseId,
            },
          ).toString(),
        ),
      ),
      child: const Text('盘点模式'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    ref.watch(isSuperAdminProvider);
    final canCount = ref
        .watch(currentPermissionsProvider)
        .contains(stockCountSubmitPermission);
    final snapshots = <String, GoodsDetail>{};
    var locationLoading = 0;
    var locationUnavailable = 0;
    if (inlineEdit.active && inlineCanEdit) {
      final rowsByGoods = {
        for (final row in _page?.items ?? const <InstantInventoryRow>[])
          if (row.goodsId?.isNotEmpty == true) row.goodsId!: row,
      };
      for (final entry in rowsByGoods.entries) {
        final capability = ref.watch(
          instantInventoryLocationSnapshotProvider(entry.key),
        );
        final detail = capability.isLoading || capability.hasError
            ? null
            : capability.value;
        if (detail != null) snapshots[entry.key] = detail;
        if (capability.isLoading) {
          locationLoading++;
        } else if (!instantInventoryLocationWritable(entry.value, detail)) {
          locationUnavailable++;
        }
      }
    }
    _locationSnapshots = snapshots;
    _locationLoading = locationLoading;
    _locationUnavailable = locationUnavailable;
    // 「含不良品仓」偏好变化（点开关 / 服务端同步到达）→ 回第 1 页重查。
    ref.listen(instantInventoryPrefsProvider, (prev, next) {
      if (prev != null && prev != next && mounted) {
        if (inlineEdit.active) {
          // A late preference sync must not change the working query beneath
          // a location draft. Keep this session's scope until explicitly changed.
          _restoredIncludeDefective ??= prev;
          return;
        }
        _reloadAfterFilterChange();
      }
    });
    // 返回即刷新：从库存详情做授权调整等写操作返回后，余额列表静默重拉
    // （此前详情只刷自己，本列表无任何监听，返回看到旧库存）。
    _myLocation ??= currentLocationOr(context, RouteName.warehouse);
    ref.onPageResume(_myLocation!, () {
      if (!inlineEdit.active) _load(_refreshPage);
    });
    return inlineGuard(
      Scaffold(
        appBar: UtenAppBar(
          title: '即时库存', // TODO(l10n): 补 arb
          leading: UtenBackButton(
            onPressed: () => inlineNavigate(
              () => backTo(context, defaultPath: RouteName.warehouse),
            ),
          ),
          actions: [
            if (canCount)
              UtenAppBarActionButton(
                key: const Key('stock-count-history'),
                label: '盘点历史',
                onPressed: () => inlineNavigate(
                  () => pushPage(context, RouteName.stockCountRequests),
                ),
              ),
            UtenRefreshButton(
              // TODO(l10n): 补 arb
              onRefresh: () => inlineNavigate(_refresh),
            ),
            if (_compactActions && canCount) ..._countActions(),
          ],
        ),
        // 窄屏动作交给现有AppBar overflow，保留表格空间；桌面仍常驻右下。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton:
            inlineCanEdit || inlineEdit.active || (canCount && !_compactActions)
            ? inlineFloatingActions(
                additionalActions: canCount && !_compactActions
                    ? _countActions()
                    : const [],
              )
            : null,
        body: SafeArea(
          child: UtenContentContainer.wide(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
            child: _buildInventoryLayout(),
          ),
        ),
      ),
    );
  }
}
