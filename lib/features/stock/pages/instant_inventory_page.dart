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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../basic_data/models/product_category_node.dart';
import '../../basic_data/repositories/product_category_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/category_tree_search.dart';
import '../../basic_data/widgets/product_category_picker_panel.dart';
import '../../basic_data/widgets/uten_category_tree_view.dart';
import '../../report/shared/report_total.dart';
import '../models/stock_query.dart';
import '../../basic_data/models/master_facet.dart';
import '../providers/instant_inventory_prefs_provider.dart';
import '../repositories/stock_query_repository.dart';

class InstantInventoryPage extends ConsumerStatefulWidget {
  const InstantInventoryPage({super.key});

  @override
  ConsumerState<InstantInventoryPage> createState() =>
      _InstantInventoryPageState();
}

class _InstantInventoryPageState extends ConsumerState<InstantInventoryPage> {
  // 分类面板数据源（同一 tree 端点带货品计数；零货品分类在面板里整支隐藏）。
  List<ProductCategoryNode>? _tree;
  List<ProductCategoryNode> _categoryNodes = const [];
  String? _treeError;

  // 分类筛选选中态：null = 全部（不过滤）。
  String? _categoryId;

  // 左侧统一搜索；只有货品命中才把关键词带进库存列表。
  String _searchQuery = '';
  Set<String>? _visibleCategoryIds;
  Set<String> _contentCategoryIds = {};
  bool _searchLoading = false;
  bool _acceptPendingSearch = false;
  Timer? _searchDebounce;
  String? _searchError;
  final _searchRequests = LatestRequestGuard();
  String _keyword = '';

  // 库存表格分页态。
  PagedResult<InstantInventoryRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  /// 「返回即刷新」登记用的本页路径（build 首次捕获）。
  String? _myLocation;
  String? _warehouseId; // null = 全部（参与核算仓库聚合）；父仓 = 子树聚合（V476）

  /// 「含线边仓」(V595)：线边仓是车间直送料架，默认不计入即时库存；仅本页会话内生效。
  bool _includeLineSide = false;
  // 列排序态：null=后端默认（库存数量 DESC）。
  String? _sortKey;
  bool _sortAsc = false;

  // 表头筛选态（2026-09-15 起「所属仓库」列；key=列 key，值=仓库 UUID 或
  // kMasterFilterNullValue 哨兵=筛未登记）。服务端过滤+服务端聚合 facet 桶。
  Map<String, String?> _filters = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final generation = _searchRequests.begin();
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (!mounted || !_searchRequests.isCurrent(generation)) return;
    await _loadTree();
    if (!mounted || !_searchRequests.isCurrent(generation)) return;
    await _applySearch(_searchQuery, preserveSelection: true);
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
            categoryId: _categoryId,
            warehouseId: _warehouseId,
            includeDefective: ref.read(instantInventoryPrefsProvider),
            includeLineSide: _includeLineSide,
            keyword: _keyword.isEmpty ? null : _keyword,
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
      await _loadOwningWarehouseNames(r.items);
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _page = r);
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
    _load(1); // 表头筛选变化回第 1 页（与主档页同口径）
  }

  /// 导出查询参数 (与 _load 同一口径含表头筛选, 不含 page/size; report 固定
  /// 'instant-inventory' 走后端独立分支)。重量单位用用户显示单位, 「自动」按千克
  /// (文件里的数值列不混单位)。
  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_categoryId != null) 'categoryId': _categoryId,
    if (_warehouseId != null) 'warehouseId': _warehouseId,
    'includeDefective': ref.read(instantInventoryPrefsProvider),
    if (_includeLineSide) 'includeLineSide': true,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
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
    final r = await ref
        .read(stockQueryRepositoryProvider)
        .instantInventory(
          size: 2000,
          categoryId: _categoryId,
          warehouseId: _warehouseId,
          includeDefective: ref.read(instantInventoryPrefsProvider),
          includeLineSide: _includeLineSide,
          keyword: _keyword.isEmpty ? null : _keyword,
          owningWarehouse: _owningFilterUuid,
          owningWarehouseNull: _owningFilterIsNull,
          colorId: _columnFilter('color'),
          series: _columnFilter('series'),
          unitId: _columnFilter('unit'),
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        );
    // 打印件与页面同列，「所属仓库」同样要先补齐货品字典才有名字可印。
    await _loadOwningWarehouseNames(r.items);
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

  /// 「所属仓库」列取值 (V587)：行上自带的字段优先；后端尚未下发时回落货品字典
  /// (lookup 已带 owningWarehouseName)。两边都没有=该货品还没登记归属，显空。
  String? _owningWarehouseName(InstantInventoryRow row) {
    final onRow = row.owningWarehouseName?.trim();
    if (onRow != null && onRow.isNotEmpty) return onRow;
    return ref
        .read(masterNameServiceProvider)
        .goodsInfo(row.goodsId)
        ?.owningWarehouseName;
  }

  /// 补一次本页货品的字典详情，让上面那列有名字可显 (只拉没缓存过的 id)。
  Future<void> _loadOwningWarehouseNames(List<InstantInventoryRow> rows) async {
    final ids = <String>{
      for (final row in rows)
        if ((row.owningWarehouseName ?? '').trim().isEmpty &&
            (row.goodsId ?? '').isNotEmpty)
          row.goodsId!,
    };
    if (ids.isEmpty) return;
    await ref.read(masterNameServiceProvider).loadGoodsDetails(ids);
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
        label: '所属仓库',
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
        key: 'unit',
        label: '单位',
        width: 70,
        value: (r) => r.unitName ?? '',
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 90,
        value: (r) => r.remark ?? '',
      ),
      MasterColumnDef(
        key: 'qty',
        label: '库存数量',
        width: 110,
        type: 'number',
        sortable: true,
        value: (r) => _num(r.qty),
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
        width: 100,
        type: 'number',
        sortable: true,
        // 待检量>0 = 采购/委外已收货但 IQC 未放行（货在待检隔离区，不在库存内）。
        value: (r) => _num(r.pendingQty),
      ),
      MasterColumnDef(
        key: 'pendingStockInQty',
        label: '合格待入库',
        width: 120,
        type: 'number',
        sortable: true,
        // 品质 PASS 只形成仓库任务；仓库确认前不进入库存数量。
        value: (r) => _num(r.pendingStockInQty),
      ),
      MasterColumnDef(
        key: 'moreQty',
        label: '多排数量',
        width: 100,
        type: 'number',
        sortable: true,
        value: (r) => _num(r.moreQty),
      ),
    ];
  }

  void _onSearchInput(String raw) {
    _searchDebounce?.cancel();
    _searchRequests.begin();
    _loadRequests.begin();
    final q = raw.trim();
    setState(() {
      _searchQuery = q;
      _acceptPendingSearch = true;
      _visibleCategoryIds = q.isEmpty ? null : categoryHits(_categoryNodes, q);
      _contentCategoryIds = {};
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

  Future<void> _applySearch(String q, {bool preserveSelection = false}) async {
    final generation = _searchRequests.begin();
    if (q.isEmpty) {
      setState(() {
        _visibleCategoryIds = null;
        _contentCategoryIds = {};
        _keyword = '';
        _searchLoading = false;
        _searchError = null;
      });
      await _load(1);
      return;
    }
    setState(() {
      _searchLoading = true;
      _searchError = null;
    });
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
        _contentCategoryIds = result.contentCategoryIds;
        if (!preserveSelection || !result.visibleIds.contains(_categoryId)) {
          _categoryId = result.selectedId;
        }
        // 只命中分类时展示该分类全部库存；无命中仍发关键词查询，避免展示全库。
        _keyword =
            !result.hasAnyMatches ||
                (_categoryId != null &&
                    hierarchyBranchContainsAny(
                      _categoryNodes,
                      _categoryId!,
                      _contentCategoryIds,
                    ))
            ? q
            : '';
        _searchLoading = false;
      });
      await _load(1);
    } catch (e) {
      if (!mounted || !_searchRequests.isCurrent(generation)) return;
      setState(() {
        _searchLoading = false;
        _searchError = e is ApiException ? '货品定位失败：${e.message}' : '货品定位失败，请重试';
      });
    }
  }

  void _selectCategory(String? id) {
    _searchRequests.begin();
    _searchDebounce?.cancel();
    _acceptPendingSearch = false;
    final keepKeyword =
        id != null &&
        hierarchyBranchContainsAny(_categoryNodes, id, _contentCategoryIds);
    setState(() {
      _categoryId = id;
      _keyword = keepKeyword ? _searchQuery : '';
      _searchLoading = false;
      _searchError = null;
      if (id == null) {
        _searchQuery = '';
        _visibleCategoryIds = null;
        _contentCategoryIds = {};
      }
    });
    _load(1);
  }

  Widget _buildSearchBox() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: UtenSearchBar(
      key: const Key('instant-inventory-search'),
      initialValue: _searchQuery,
      hint: '搜索分类 / 货品名称或编号',
      onInputChanged: _onSearchInput,
      onSubmitted: _onSearchChanged,
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
        ListTile(
          key: const Key('instant-inventory-category-all'),
          leading: const Icon(Icons.category_outlined),
          title: const Text('全部分类'),
          selected: _categoryId == null,
          selectedTileColor: theme.colorScheme.primaryContainer,
          onTap: () => select(null),
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
                  selectedIds: {?_categoryId},
                  flatLevelColors: true,
                  expandOnRowTap: true,
                  initiallyCollapsedNames: const {'未分类'},
                  showSearch: false,
                  visibleFilterIds: _visibleCategoryIds,
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
      allowParent: true,
    );
    if (!mounted || result == null) return;
    final next = result.isAll ? null : result.id;
    if (next == _warehouseId) return;
    setState(() => _warehouseId = next);
    _load(1);
  }

  // ---- 右侧工具栏与库存表格（分类切换不重挂，保留列筛选/排序） ------

  Widget _buildTablePane() {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final includeDefective = ref.watch(instantInventoryPrefsProvider);
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
        padding: const EdgeInsets.only(
          left: UtenSpacing.s4,
          right: UtenSpacing.s4,
          bottom: UtenSpacing.s8,
        ),
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
                      _categoryId,
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
              FilterChip(
                label: const Text('含不良品仓'), // TODO(l10n): 补 arb
                selected: includeDefective,
                onSelected: !aggregateWarehouse
                    ? null
                    : (v) => ref
                          .read(instantInventoryPrefsProvider.notifier)
                          .setIncludeDefective(v),
              ),
              // V595：线边仓是车间内部直送的料架，不是现实里的仓库——默认不算进即时库存，
              // 要看车间料架上还有多少直送料时再打开。选定叶子仓时同样置灰。
              Tooltip(
                message: '内料仓是车间的料架, 默认不计入即时库存',
                child: FilterChip(
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
                          _load(1);
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
        items: _page?.items ?? const [],
        toolbarActions: [
          // 「重量单位: 自动▾」: 用户级显示偏好 (与库存详情/分析页共用), 只改显示。
          const WeightDisplayUnitButton(),
          // 导出仍受独立权限、限流、行数上限和审计约束；文件密码可选。
          // 预览打印（A4 预览 → 系统打印；与导出口径一致，上限 2000 行）
          UtenPrintPreviewButton(
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
          context.push(RouteName.stockItemDetail(gid));
        },
        isLoading: _loading && _page == null,
        loadingMore: _loading && _page != null,
        error: _error,
        onRetry: () => _load(_pageNum),
        emptyMessage: '暂无库存', // TODO(l10n): 补 arb
        // 合计条：值全部来自服务端（/stock/instant-inventory 的 totals），口径与本页
        // 当前的分类/仓库/含不良品仓/关键字筛选完全一致，且覆盖整个结果集而不是当前这一页；
        // 前端一个加法都不做，数量按单位分组显示「12 个 · 3 箱」；重量按显示单位换算，
        // 含估算加「≈」，有未称项追加「(另有 N 项未称)」。
        summaryBar: reportTotalsBar(
          _page?.totals ?? const [],
          weightDisplay: weightDisplay,
        ),
        currentPage: _page?.page ?? 1,
        totalPages: _page?.totalPages ?? 1,
        onPageChange: (p) => _load(p),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.breakpoint == UtenBreakpoint.compact;
    // 「含不良品仓」偏好变化（点开关 / 服务端同步到达）→ 回第 1 页重查。
    ref.listen(instantInventoryPrefsProvider, (prev, next) {
      if (prev != null && prev != next && mounted) {
        _load(1);
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
          if (compact)
            Builder(
              builder: (scaffoldContext) => IconButton(
                key: const Key('instant-inventory-open-categories'),
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '分类树',
                onPressed: () => Scaffold.of(scaffoldContext).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: compact
          ? Drawer(
              child: SafeArea(child: _buildCategoryPane(closeOnSelect: true)),
            )
          : null,
      body: SafeArea(
        child: SelectionArea(
          child: compact
              ? Column(
                  children: [
                    _buildSearchBox(),
                    Expanded(
                      child: UtenContentContainer.wide(
                        child: _buildTablePane(),
                      ),
                    ),
                  ],
                )
              : UtenSplitView(
                  persistenceKey: 'stock.instantInventory',
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
