// 即时库存页（仓库管理 hub 入口，stock:view）。
//
// 2026-09-26：对齐货品资料的左树右表，左侧统一搜索分类/货品并展开定位；
// 分栏可拖动并记忆宽度，窄屏以分类抽屉承载同一棵树。
// - 口径不变：分类「全部」= 不过滤，选任意层级 = 该分类子树聚合，零货品分类
//   自动隐藏；仓库「全部」= 参与核算仓库聚合，选主仓 = 自身 + 全部子仓聚合；
// - 右侧工具栏：当前分类 + 仓库字段 + 库存范围开关 + 共 N 项；
// - 表格 = 统一 MasterDataTableView：所属类型 / 物料编码 / 物料系列 / 库位号 /
//   型号 / 客户型号 / 货品名称 / 规格 / 颜色 / 单位 / 备注 / 库存数量 / 库存重量 /
//   待检量 / 合格待入库 / 多排数量。库存台账金额列已从页面与预览打印移除
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
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_adaptive_hierarchy_pane.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../models/instant_inventory_scope.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/product_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/category_tree_search.dart';
import '../../basic_data/widgets/product_category_picker_panel.dart';
import '../../basic_data/widgets/uten_category_tree_view.dart';
import '../../basic_data/widgets/goods_related_search_control.dart';
import '../models/instant_inventory_summary.dart';
import '../models/stock_query.dart';
import '../../basic_data/models/master_facet.dart';
import '../providers/instant_inventory_prefs_provider.dart';
import '../repositories/stock_query_repository.dart';
import '../widgets/instant_inventory_summary_bar.dart';
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

class _InstantInventoryPageState extends ConsumerState<InstantInventoryPage> {
  static const _minTwoPaneWidth = 840.0;
  bool get _compactActions =>
      MediaQuery.sizeOf(context).width < _minTwoPaneWidth;
  // 分类面板数据源（同一 tree 端点带货品计数；零货品分类在面板里整支隐藏）。
  List<ProductCategoryNode>? _tree;
  List<ProductCategoryNode> _categoryNodes = const [];
  String? _treeError;

  // 分类筛选选中态：null = 全部（不过滤）。
  String? _categoryId;
  String? _searchCategoryId;
  String? get _effectiveCategoryId =>
      _searchQuery.isNotEmpty ? _searchCategoryId : _categoryId;
  bool _includeRelated = false;
  int _queryContextVersion = 0;

  // 左侧统一搜索；只有货品命中才把关键词带进库存列表。
  String _searchQuery = '';
  Set<String>? _visibleCategoryIds;
  bool _searchLoading = false;
  bool _acceptPendingSearch = false;
  Timer? _searchDebounce;
  String? _searchError;
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
  void initState() {
    super.initState();
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
    final generation = _searchRequests.begin();
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    // 字典与分类树互不依赖，并行拉取（此前串行，点刷新要等两段往返）。
    await Future.wait([
      ref.read(masterNameServiceProvider).ensureCommonLoaded(),
      _loadTree(),
    ]);
    if (!mounted || !_searchRequests.isCurrent(generation)) return;
    await _applySearch(_searchQuery);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTree() async {
    try {
      final tree = await ref
          .read(productCategoryRepositoryProvider)
          .treeWithGoodsCounts();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _categoryNodes = hoistSingleRootTree(pruneCategoriesWithoutGoods(tree));
        _treeError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _treeError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _treeError = '加载分类失败'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _load(int page) async {
    _queryContextVersion++;
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(stockQueryRepositoryProvider)
          .instantInventory(
            page: page,
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
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
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

  String get _summaryScopeLabel {
    final names = ref.read(masterNameServiceProvider);
    final parts = <String>[
      findCategoryName(_tree ?? const [], _effectiveCategoryId) ?? '全部分类',
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

  /// 数字格式化：最多 2 位小数，去掉无意义的尾随 0（1.50→1.5；0→0）。
  static String _num(double? v) {
    if (v == null) return '—';
    final s = v.toStringAsFixed(2);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  /// 库存重量没有值时的文案：有库存却没称过 =「未称」；本行本就没有库存 =「—」。
  static String _unknownWeightText(InstantInventoryRow r) =>
      r.weightUnknown || (r.qty ?? 0) != 0 ? weightUnknownText : '—';

  /// 打印预览数据：按当前筛选口径拉全量（上限 2000 行），列/格式化与页面表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final contextVersion = _queryContextVersion;
    final r = await ref
        .read(stockQueryRepositoryProvider)
        .instantInventory(
          size: 2000,
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
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    if (!mounted || contextVersion != _queryContextVersion || !_resultsReady) {
      throw StateError('查询条件已变化，请重新预览');
    }
    // 打印件与页面同列，「所属仓库」同样要先补齐货品字典才有名字可印。
    final cols = _columns();
    return UtenPrintTable(
      columnKeys: [for (final c in cols) c.key],
      factValues: [
        for (final row in r.items)
          {
            'qty': row.qty?.toString(),
            'costAmount': row.costAmount?.toString(),
            'moreQty': row.moreQty?.toString(),
            'pendingQty': row.pendingQty?.toString(),
            'pendingStockInQty': row.pendingStockInQty?.toString(),
            'weight': row.weight?.toString(),
            'unitWeightKg': row.unitWeightKg?.toString(),
          },
      ],
      headers: [for (final c in cols) c.label],
      rows: [
        for (final row in r.items) [for (final c in cols) c.value(row) ?? ''],
      ],
    );
  }

  /// 主档归属由 stock:view 投影直接下发，不能把实物仓库或另一个字典当归属。
  String? _owningWarehouseName(InstantInventoryRow row) {
    final onRow = row.owningWarehouseName?.trim();
    if (onRow != null && onRow.isNotEmpty) return onRow;
    return null;
  }

  List<MasterColumnDef<InstantInventoryRow>> _columns() {
    final weightDisplay = ref.read(warehouseWeightUnitsPrefsProvider).display;
    return <MasterColumnDef<InstantInventoryRow>>[
      MasterColumnDef(
        key: 'category',
        label: '所属类型',
        width: 120,
        value: (r) => r.categoryName ?? '—',
      ),
      // 2026-09-14 全站表格统一：名称 → 编号 → 颜色 三列排在最前，
      // 型号/系列/库位等次要属性排在后面。
      MasterColumnDef(
        key: 'name',
        label: '货品名称',
        width: 220,
        sortable: true,
        value: (r) => r.name ?? '',
        cellBuilder: (context, r) => Row(
          children: [
            Expanded(
              child: Text(
                r.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (r.isRelatedSearchMatch) ...[
              const SizedBox(width: UtenSpacing.s8),
              Text('相关', style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (r) => r.goodsCode ?? '',
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 90,
        value: (r) => r.colorName ?? '',
      ),
      MasterColumnDef(
        key: 'series',
        label: '物料系列',
        width: 90,
        value: (r) => r.series ?? '',
      ),
      MasterColumnDef(
        key: 'stockPlace',
        label: '库位号',
        width: 90,
        value: (r) => r.stockPlace ?? '',
      ),
      // 所属仓库 (V587)：货品平时归哪个仓管的主档归属，只读。
      // 列 key 是 owningWarehouse，不能叫 warehouse —— 本页顶部的仓库筛选是
      // 另一回事 (那是本次看盘的范围仓)，两者绝不是同一个概念。
      MasterColumnDef(
        key: 'owningWarehouse',
        label: '主档归属仓库',
        width: 120,
        info: '货品平时归哪个仓管的主档归属，不是这行库存所在的仓，也不是上面的仓库筛选值。',
        value: (r) => _owningWarehouseName(r) ?? '',
      ),
      MasterColumnDef(
        key: 'model',
        label: '型号',
        width: 110,
        value: (r) => r.model ?? '',
      ),
      MasterColumnDef(
        key: 'cNumber',
        label: '客户型号',
        width: 120,
        value: (r) => r.cNumber ?? '',
      ),
      MasterColumnDef(
        key: 'spec',
        label: '规格',
        width: 120,
        value: (r) => r.spec ?? '',
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 90,
        value: (r) => r.remark ?? '',
      ),
      // 2026-10-10「数量+单位」全站口径：单位内联在数字后（12 PCS），独立
      // 「单位」列退役；实盘数量输入格的后缀在共享输入格（stock_count_inline_editor）。
      MasterColumnDef(
        key: 'qty',
        label: '库存数量',
        width: 185,
        type: 'number',
        sortable: true,
        value: (r) => formatQtyWithUnit(r.qty, r.unitName),
        // ADR-146: 打开「含不良品仓」时, 数量里在不良品仓的部分另标出来。
        cellBuilder: (context, r) {
          final qty = formatQtyWithUnit(r.qty, r.unitName);
          final defective = r.defectiveQty ?? 0;
          if (defective <= 0) return Text(qty);
          return Text(
            '$qty (${AppLocalizations.of(context).instantInventoryDefectivePart(_num(defective))})',
            key: ValueKey(
              'instant-inventory-defective-${r.goodsId}-${r.colorId}',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        },
      ),
      // 重量紧跟数量 (ADR-135)：千克按用户显示单位换算，估算「≈」、没称「未称」。
      MasterColumnDef(
        key: 'weight',
        label: '库存重量',
        width: 120,
        type: 'weight',
        sortable: true,
        value: (r) => formatWeightValue(
          r.weight,
          display: weightDisplay,
          estimated: r.weightEstimated,
          unknownText: _unknownWeightText(r),
        ),
        cellBuilder: (_, r) => WeightText(
          kg: r.weight,
          estimated: r.weightEstimated,
          display: weightDisplay,
          unknownText: _unknownWeightText(r),
        ),
      ),
      MasterColumnDef(
        key: 'pendingQty',
        label: '待检量',
        width: 135,
        type: 'number',
        sortable: true,
        // 待检量>0 = 采购/委外已收货但 IQC 未放行（货在待检隔离区，不在库存内）。
        value: (r) => formatQtyWithUnit(r.pendingQty, r.unitName),
      ),
      MasterColumnDef(
        key: 'pendingStockInQty',
        label: '合格待入库',
        width: 150,
        type: 'number',
        sortable: true,
        // 品质 PASS 只形成仓库任务；仓库确认前不进入库存数量。
        value: (r) => formatQtyWithUnit(r.pendingStockInQty, r.unitName),
      ),
      MasterColumnDef(
        key: 'moreQty',
        label: '多排数量',
        width: 135,
        type: 'number',
        sortable: true,
        value: (r) => formatQtyWithUnit(r.moreQty, r.unitName),
      ),
    ];
  }

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
      _visibleCategoryIds = q.isEmpty ? null : categoryHits(_categoryNodes, q);
      _searchLoading = q.isNotEmpty;
      _searchError = null;
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
    final generation = _searchRequests.begin();
    if (q.isEmpty) {
      setState(() {
        _visibleCategoryIds = null;
        _keyword = '';
        _searchLoading = false;
        _searchError = null;
      });
      await _load(1);
      return;
    }
    setState(() {
      _keyword = q;
      _searchLoading = true;
      _searchError = null;
    });
    // The user-selected search category is explicit; location hints never
    // choose a category or narrow the flat result table automatically.
    final listLoad = _load(1);
    try {
      final roots = (_tree ?? const <ProductCategoryNode>[])
          .where((node) => node.goodsCount != 0)
          .map((node) => node.id)
          .toList(growable: false);
      final contentIds = <String>{};
      // 与货品资料同样按 32 个根分批，但使用库存自己的搜索权限与货品范围。
      for (var offset = 0; offset < roots.length; offset += 32) {
        final end = offset + 32 < roots.length ? offset + 32 : roots.length;
        contentIds.addAll(
          await ref
              .read(stockQueryRepositoryProvider)
              .instantInventorySearchCategoryIds(
                q,
                categoryRootIds: roots.sublist(offset, end).toSet(),
                categoryId: _effectiveCategoryId,
                includeRelated: _includeRelated,
                warehouseId: _warehouseId,
                includeDefective: _includeDefective,
                includeLineSide: _includeLineSide,
                owningWarehouse: _owningFilterUuid,
                owningWarehouseNull: _owningFilterIsNull,
                colorId: _columnFilter('color'),
                series: _columnFilter('series'),
                unitId: _columnFilter('unit'),
              ),
        );
        if (!mounted || !_searchRequests.isCurrent(generation)) return;
      }
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      final result = resolveHierarchySearch(
        roots: _categoryNodes,
        query: q,
        contentCategoryIds: contentIds,
      );
      setState(() {
        _visibleCategoryIds = result.visibleIds;
        _searchLoading = false;
      });
      await listLoad;
    } catch (e) {
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      setState(() {
        _searchLoading = false;
        _searchError = e is ApiException ? '货品定位失败：${e.message}' : '货品定位失败，请重试';
      });
    }
  }

  void _selectCategory(String? id) {
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
      _searchLoading = false;
      _searchError = null;
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

  Set<String>? get _treeVisibleCategoryIds {
    final ids = _visibleCategoryIds;
    if (ids == null || _searchCategoryId == null) return ids;
    final visible = <String>{...ids};
    addAncestors(_categoryNodes, _searchCategoryId!, visible);
    return visible;
  }

  Widget _buildSearchBox() => Padding(
    // 左缘贴 0（2026-10-18 全站分栏口径）：与货品资料等分类页的左栏搜索、
    // 返回键图标共用 x=0 左缘。
    padding: const EdgeInsets.only(
      top: UtenSpacing.s12,
      bottom: UtenSpacing.s8,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSearchBar(
          key: const Key('instant-inventory-search'),
          initialValue: _searchQuery,
          hint: '搜索分类 / 货品名称或编号',
          onInputChanged: _onSearchInput,
          onSubmitted: _onSearchChanged,
        ),
        if (_searchQuery.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '搜索范围：${findCategoryName(_tree ?? const [], _effectiveCategoryId) ?? '全部分类'}',
            key: const Key('instant-inventory-search-scope'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          GoodsRelatedSearchControl(
            value: _includeRelated,
            onChanged: (value) {
              setState(() => _includeRelated = value);
              _restartSearch();
            },
          ),
        ],
      ],
    ),
  );

  Widget _buildCategoryPane({bool closeOnSelect = false}) {
    final theme = Theme.of(context);
    void select(String? id) {
      _selectCategory(id);
      if (closeOnSelect) Navigator.of(context).pop();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBox(),
        Builder(
          builder: (paneContext) => ListTile(
            key: const Key('instant-inventory-category-all'),
            leading: const Icon(Icons.category_outlined),
            title: const Text('全部分类'),
            selected: _effectiveCategoryId == null,
            selectedTileColor: theme.colorScheme.primaryContainer,
            onTap: () {
              select(null);
              UtenHierarchyPanelScope.maybeOf(paneContext)?.onSelection?.call();
            },
          ),
        ),
        const Divider(height: 1),
        if (_treeError != null)
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              children: [
                Text(
                  _treeError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ],
            ),
          ),
        if (_searchError != null)
          TextButton(
            onPressed: () => _applySearch(_searchQuery),
            child: const Text('重试搜索'),
          ),
        Expanded(
          child: _tree == null && _treeError == null
              ? const Center(child: CircularProgressIndicator())
              : UtenCategoryTreeView<ProductCategoryNode>(
                  key: const Key('instant-inventory-category-tree'),
                  nodes: _categoryNodes,
                  selectedIds: {?_effectiveCategoryId},
                  flatLevelColors: true,
                  expandOnRowTap: true,
                  initiallyCollapsedNames: const {'未分类'},
                  showSearch: false,
                  visibleFilterIds: _treeVisibleCategoryIds,
                  externalSearchQuery: _searchQuery,
                  externalSearchLoading: _searchLoading,
                  externalSearchError: _searchError,
                  onNodeTap: (node) => select(node.id),
                  trailingBuilder: (node) => node.goodsCount == null
                      ? null
                      : Text(
                          '${node.goodsCount}',
                          style: theme.textTheme.labelSmall,
                        ),
                ),
        ),
      ],
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
    final countAllowed = ref
        .watch(currentPermissionsProvider)
        .contains(stockCountSubmitPermission);
    ref.watch(instantInventoryPrefsProvider);
    final includeDefective = _includeDefective;
    final weightDisplay = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final total = _page?.total ?? 0;
    // 「含不良品仓」只在聚合口径下生效：全部（null）或父仓（多仓聚合）；
    // 选定叶子仓时开关置灰（单仓口径开关无意义）。
    final aggregateWarehouse =
        _warehouseId == null || names.warehouseHasChildren(_warehouseId);
    // 上滑先把分类/仓库筛选行收完、表格顶到窗格顶再滚表内（全站联动口径；
    // 宽屏在右栏内联动，紧凑态在内容容器内联动）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: UtenFilterToolbar<String?>(
          // 分类树常驻左侧，右栏显示当前范围；Wrap 支持分栏拖窄与手机。
          trailing: Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                findCategoryName(
                      _tree ?? const <ProductCategoryNode>[],
                      _effectiveCategoryId,
                    ) ??
                    '全部分类',
                key: const Key('instant-inventory-current-category'),
                style: theme.textTheme.titleSmall,
              ),
              UtenFilterPickerField(
                key: const Key('instant-inventory-warehouse'),
                label: '仓库', // TODO(l10n): 补 arb
                icon: Icons.warehouse_outlined,
                width: 220,
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
                            ref.read(instantInventoryPrefsProvider) != v;
                        setState(() => _restoredIncludeDefective = v);
                        ref
                            .read(instantInventoryPrefsProvider.notifier)
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
      ),
      body: MasterDataTableView<InstantInventoryRow>(
        tableKey:
            'features.stock.pages.instant_inventory_page.InstantInventoryPageState._buildTablePane.1',
        // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
        primary: true,
        columns: _columns(),
        items: [...?_page?.items],
        rowKeyOf: (r) => stockCountRowKey(r.goodsId ?? '', r.colorId),
        toolbarActions: [
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
            type: UtenButtonType.primary,
            size: UtenButtonSize.large,
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
            size: UtenButtonSize.large,
          ),
        ],
        // facet 桶/空值计数由服务端随列表下发（未应用归属筛选的同一口径聚合）。
        facets: _page?.facets ?? const {},
        nullCounts: _page?.facetNullCounts ?? const {},
        filters: _filters,
        onFilterChanged: _onFilterChanged,
        sortColumn: _sortKey,
        sortAscending: _sortAsc,
        onSortChange: _onSortChange,
        // 行点击 → 库存详情页（该货品各仓余额 + 出入库流水；push 保活本页筛选）
        onRowTap: (r) {
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
        onRetry: () => _load(_pageNum),
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
                onDetails: _showSummary,
              ),
        currentPage: _page?.page ?? 1,
        totalPages: _page?.totalPages ?? 1,
        // 右下悬浮盘点动作组压在表尾上，给滚动的末尾留出让位空间。
        bottomContentPadding: countAllowed && !_compactActions
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
        onPageChange: (p) => _load(p),
      ),
    );
  }

  List<Widget> _countActions() => [
    UtenButton(
      key: const Key('stock-count-history'),
      size: UtenButtonSize.large,
      type: UtenButtonType.secondary,
      icon: Icons.history_outlined,
      onPressed: () => context.push(RouteName.stockCountRequests),
      child: const Text('盘点历史'),
    ),
    UtenButton(
      key: const Key('stock-count-mode'),
      size: UtenButtonSize.large,
      type: UtenButtonType.secondary,
      icon: Icons.fact_check_outlined,
      onPressed: () => context.push(
        Uri(
          path: RouteName.stockCountSession,
          queryParameters: {
            if (_warehouseId != null) 'warehouseId': _warehouseId,
          },
        ).toString(),
      ),
      child: const Text('盘点模式'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final canCount = ref
        .watch(currentPermissionsProvider)
        .contains(stockCountSubmitPermission);
    // 「含不良品仓」偏好变化（点开关 / 服务端同步到达）→ 回第 1 页重查。
    ref.listen(instantInventoryPrefsProvider, (prev, next) {
      if (prev != null && prev != next && mounted) {
        _reloadAfterFilterChange();
      }
    });
    // 返回即刷新：从库存详情做授权调整等写操作返回后，余额列表静默重拉
    // （此前详情只刷自己，本列表无任何监听，返回看到旧库存）。
    _myLocation ??= currentLocationOr(context, RouteName.warehouse);
    ref.onPageResume(_myLocation!, () => _load(_page?.page ?? 1));
    return Scaffold(
      appBar: UtenAppBar(
        title: '即时库存', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: _refresh,
          ),
          if (_compactActions && canCount) ..._countActions(),
        ],
      ),
      // 窄屏动作交给现有AppBar overflow，保留表格空间；桌面仍常驻右下。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: canCount && !_compactActions
          ? UtenFloatingActionGroup(children: _countActions())
          : null,
      body: SafeArea(
        child: SelectionArea(
          child: UtenSplitView(
            persistenceKey: 'stock.instantInventory',
            minTwoPaneWidth: _minTwoPaneWidth,
            selectedLeadingLabel:
                utenTreeSelectionPath(_categoryNodes, _effectiveCategoryId) ??
                '全部分类',
            selectedLeadingKey: _effectiveCategoryId,
            openLeadingButtonKey: const Key(
              'instant-inventory-open-categories',
            ),
            compactHeader: _buildSearchBox(),
            leading: _buildCategoryPane(),
            trailing: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: _buildTablePane(),
            ),
          ),
        ),
      ),
    );
  }
}
