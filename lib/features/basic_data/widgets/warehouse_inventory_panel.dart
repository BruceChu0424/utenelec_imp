import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/stock_inventory/instant_inventory_scope.dart';
import '../../../shared/stock_inventory/instant_inventory_row.dart';
import '../../../shared/stock_inventory/instant_inventory_repository.dart';
import '../../../shared/stock_inventory/instant_inventory_columns.dart';
import '../../../shared/report/report_total.dart';
import '../models/master_facet.dart';
import '../models/warehouse_node.dart';
import 'basic_data_l10n.dart';
import 'master_data_table_view.dart';

/// 仓库资料内的真实即时库存。库存数量、颜色及分页均取服务端同一范围，
/// 不用货品所属仓猜实际库存，也不在客户端过滤一页后伪造总数。
class WarehouseInventoryPanel extends ConsumerStatefulWidget {
  const WarehouseInventoryPanel({
    super.key,
    required this.warehouse,
    this.refreshTick = 0,
    this.primary = false,
    this.bottomContentPadding = 0,
    this.navigationEnabled = true,
  });

  final WarehouseDetail warehouse;
  final int refreshTick;

  /// 宿主使用 UtenCollapsingHeaderScrollView 时拾取它的联动滚动控制器。
  final bool primary;
  final double bottomContentPadding;
  final bool navigationEnabled;

  @override
  ConsumerState<WarehouseInventoryPanel> createState() =>
      _WarehouseInventoryPanelState();
}

class _WarehouseInventoryPanelState
    extends ConsumerState<WarehouseInventoryPanel> {
  PagedResult<InstantInventoryRow>? _result;
  String _keyword = '';
  bool _loading = false;
  bool _failed = false;
  bool _openingLedger = false;
  int _page = 1;
  int _size = 30;
  Map<String, String?> _filters = {};
  String? _sortKey;
  bool _sortAscending = false;
  int _requestVersion = 0;
  int _readEpoch = 0;

  bool _canRead(SensitiveReadBoundary boundary) =>
      boundary.permissions.contains(Perm.stockView) || boundary.superAdmin;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous == next) return;
      _clear();
      _scheduleLoad();
    });
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant WarehouseInventoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouse.id != widget.warehouse.id) {
      _clear();
      _scheduleLoad();
    } else if (oldWidget.refreshTick != widget.refreshTick) {
      _requestVersion++;
      _scheduleLoad();
    }
  }

  void _clear() {
    _requestVersion++;
    setState(() {
      _result = null;
      _keyword = '';
      _page = 1;
      _filters = {};
      _sortKey = null;
      _sortAscending = false;
      _loading = false;
      _failed = false;
      _readEpoch++;
    });
  }

  void _scheduleLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(_page);
    });
  }

  bool _isCurrent(int version, SensitiveReadBoundary boundary) =>
      mounted &&
      version == _requestVersion &&
      boundary == ref.read(sensitiveReadBoundaryProvider) &&
      _canRead(boundary);

  bool get _resultsReady => _result != null && !_loading && !_failed;

  String? _filter(String key) {
    final value = _filters[key];
    return value == kMasterFilterNullValue ? null : value;
  }

  Map<String, dynamic> get _exportQuery => {
    'warehouseId': widget.warehouse.id,
    'includeDefective': true,
    'includeLineSide': true,
    'warehouseRelatedOnly': true,
    if (_keyword.isNotEmpty) 'keyword': _keyword,
    'owningWarehouse': ?_filter('owningWarehouse'),
    if (_filters['owningWarehouse'] == kMasterFilterNullValue)
      'owningWarehouseNull': true,
    'colorId': ?_filter('color'),
    'series': ?_filter('series'),
    'weightUnit': ref
        .read(warehouseWeightUnitsPrefsProvider)
        .display
        .exportUnit
        .code,
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAscending ? 'asc' : 'desc',
  };

  Future<PagedResult<InstantInventoryRow>> _fetch(int page, int size) => ref
      .read(instantInventoryRepositoryProvider)
      .instantInventory(
        page: page,
        size: size,
        warehouseId: widget.warehouse.id,
        includeDefective: true,
        includeLineSide: true,
        warehouseRelatedOnly: true,
        keyword: _keyword.isEmpty ? null : _keyword,
        owningWarehouse: _filter('owningWarehouse'),
        owningWarehouseNull:
            _filters['owningWarehouse'] == kMasterFilterNullValue,
        colorId: _filter('color'),
        series: _filter('series'),
        sort: _sortKey,
        order: _sortKey == null ? null : (_sortAscending ? 'asc' : 'desc'),
      );

  void _changeFilter(String key, String? value) {
    // 仅开放端点实际支持的筛选，不能把当前页文本筛选冒充全范围筛选。
    if (!const {'owningWarehouse', 'color', 'series'}.contains(key)) return;
    setState(() {
      _filters = {..._filters};
      if (value == null) {
        _filters.remove(key);
      } else {
        _filters[key] = value;
      }
    });
    _load(1);
  }

  void _changeSort(String? key, bool ascending) {
    if (key != null &&
        !const {
          'name',
          'qty',
          'weight',
          'pendingQty',
          'pendingStockInQty',
          'moreQty',
        }.contains(key)) {
      return;
    }
    setState(() {
      _sortKey = key;
      _sortAscending = ascending;
    });
    _load(1);
  }

  Future<UtenPrintTable> _printLoader() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final version = _requestVersion;
    if (!_resultsReady || !_isCurrent(version, boundary)) {
      throw StateError('库存查询已变化，请重新预览');
    }
    // 端点每次最多 500 行。分批读取前 2000 行，不能把请求 size=2000
    // 但服务端实际返回的 500 行冒充完整预览。
    final rows = <InstantInventoryRow>[];
    for (var page = 1; rows.length < 2000; page++) {
      final result = await _fetch(page, 500);
      if (!_resultsReady || !_isCurrent(version, boundary)) {
        throw StateError('库存查询已变化，请重新预览');
      }
      rows.addAll(result.items.take(2000 - rows.length));
      if (page >= result.totalPages || result.items.isEmpty) break;
    }
    if (!mounted) throw StateError('库存页面已关闭');
    final columns = instantInventoryColumns(
      context,
      weightDisplay: ref.read(warehouseWeightUnitsPrefsProvider).display,
    );
    return UtenPrintTable(
      columnKeys: [for (final column in columns) column.key],
      headers: [for (final column in columns) column.label],
      rows: [
        for (final row in rows)
          [for (final column in columns) column.value(row) ?? ''],
      ],
      factValues: [
        for (final row in rows)
          {
            'qty': row.qty?.toString(),
            'weight': row.weight?.toString(),
            'moreQty': row.moreQty?.toString(),
            'pendingQty': row.pendingQty?.toString(),
            'pendingStockInQty': row.pendingStockInQty?.toString(),
          },
      ],
    );
  }

  Future<void> _load(int page) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    if (!_canRead(boundary)) return;
    final version = ++_requestVersion;
    setState(() {
      _page = page;
      _loading = true;
      _failed = false;
    });
    try {
      final result = await _fetch(page, _size);
      if (!_isCurrent(version, boundary)) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (_) {
      if (!_isCurrent(version, boundary)) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _onSearchInput(String value) {
    // 输入即作废旧查询，防抖等待期间旧响应也不能覆盖当前搜索。
    _requestVersion++;
    setState(() {
      _keyword = value.trim();
      _loading = true;
      _failed = false;
    });
  }

  Future<void> _openLedger(InstantInventoryRow row) async {
    final id = row.goodsId;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    if (!widget.navigationEnabled ||
        _loading ||
        _openingLedger ||
        !_canRead(boundary) ||
        id == null ||
        id.isEmpty) {
      return;
    }
    final warehouseId = widget.warehouse.id;
    setState(() => _openingLedger = true);
    try {
      await context.push(
        RouteName.stockItemDetail(
          id,
          tab: 'ledger',
          scope: InstantInventoryScope(
            warehouseId: warehouseId,
            colorId: row.colorId,
            colorNull: row.colorId == null,
            includeDefective: true,
            includeLineSide: true,
          ),
          returnTo: currentLocationOr(context, RouteName.basicinfoWarehouse),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _openingLedger = false);
        if (warehouseId == widget.warehouse.id &&
            boundary == ref.read(sensitiveReadBoundaryProvider)) {
          _load(_page);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final boundary = ref.watch(sensitiveReadBoundaryProvider);
    final l10n = basicDataL10n(context);
    if (!_canRead(boundary)) {
      return Center(
        key: const Key('warehouse-inventory-no-access'),
        child: Text(l10n.warehouseInventoryNoAccess),
      );
    }
    final theme = Theme.of(context);
    final weightDisplay = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    return Column(
      key: const Key('warehouse-inventory-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.warehouseHubInventoryLive,
                  style: theme.textTheme.titleSmall,
                ),
                if (widget.warehouse.isMain)
                  Text(
                    l10n.warehouseMasterInventorySummaryHint,
                    style: theme.textTheme.bodySmall,
                  ),
                SizedBox(
                  width: constraints.maxWidth.clamp(0.0, 300.0),
                  child: KeyedSubtree(
                    key: ValueKey((widget.warehouse.id, _readEpoch)),
                    child: UtenSearchBar(
                      key: const Key('warehouse-inventory-search'),
                      hint: l10n.warehouseInventorySearchHint,
                      onInputChanged: _onSearchInput,
                      onChanged: (_) => _load(1),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: MasterDataTableView<InstantInventoryRow>(
            key: const Key('warehouse-inventory-table'),
            tableKey: 'master.warehouse.inventory',
            primary: widget.primary,
            bottomContentPadding: widget.bottomContentPadding,
            columns: instantInventoryColumns(
              context,
              weightDisplay: weightDisplay,
              columnSearchEnabled: false,
            ),
            toolbarLeadingActions: [
              const WeightDisplayUnitButton(),
              UtenPrintPreviewButton(
                key: const Key('warehouse-inventory-print'),
                enabled: _resultsReady,
                title:
                    '${widget.warehouse.name ?? widget.warehouse.code ?? ''}即时库存',
                subtitle: '最多前 2000 行',
                loader: _printLoader,
                type: UtenButtonType.primary,
                size: UtenButtonSize.large,
                icon: null,
              ),
              UtenExportButton(
                key: const Key('warehouse-inventory-export'),
                enabled: _resultsReady,
                endpoint: '/stock/reports/export',
                requiredPermission: Perm.stockReportExport,
                report: 'instant-inventory',
                queryParams: _exportQuery,
                filename:
                    '${widget.warehouse.name ?? widget.warehouse.code ?? ''}即时库存',
                prepareExport: () async {
                  final version = _requestVersion;
                  final boundary = ref.read(sensitiveReadBoundaryProvider);
                  return UtenExportSelection(
                    stillCurrent: () =>
                        _resultsReady && _isCurrent(version, boundary),
                  );
                },
                type: UtenButtonType.primary,
                size: UtenButtonSize.large,
                icon: null,
              ),
              Text(
                _resultsReady ? '共 ${_result!.total} 项' : '',
                key: const Key('warehouse-inventory-total'),
              ),
              SizedBox(
                width: 130,
                child: UtenDropdownField(
                  key: const Key('warehouse-inventory-page-size'),
                  value: _size.toString(),
                  allowClear: false,
                  items: [
                    for (final size in const [30, 50, 100])
                      UtenDropdownItem(value: '$size', label: '$size 项/页'),
                  ],
                  onChanged: (value) {
                    final size = int.tryParse(value ?? '');
                    if (size == null ||
                        size == _size ||
                        !const [30, 50, 100].contains(size)) {
                      return;
                    }
                    setState(() => _size = size);
                    _load(1);
                  },
                ),
              ),
            ],
            items: _result?.items ?? const [],
            rowKeyOf: (row) => '${row.goodsId}|${row.colorId}',
            facets: _result?.facets ?? const {},
            nullCounts: _result?.facetNullCounts ?? const {},
            filters: _filters,
            onFilterChanged: _changeFilter,
            sortColumn: _sortKey,
            sortAscending: _sortAscending,
            onSortChange: _changeSort,
            isLoading: _loading && _result == null,
            loadingMore: _loading && _result != null,
            error: _failed ? l10n.warehouseInventoryLoadFailed : null,
            onRetry: () => _load(_page),
            emptyMessage: l10n.warehouseInventoryEmpty,
            currentPage: _result?.page ?? _page,
            totalPages: _result?.totalPages ?? 1,
            onPageChange: _load,
            paginationScope: (
              widget.warehouse.id,
              _keyword,
              _readEpoch,
              _size,
              _filters['owningWarehouse'],
              _filters['color'],
              _filters['series'],
              _sortKey,
              _sortAscending,
            ),
            paginationRevision: widget.refreshTick,
            canOpenRow: (row) =>
                widget.navigationEnabled &&
                !_loading &&
                !_openingLedger &&
                row.goodsId?.isNotEmpty == true,
            onRowTap: _openLedger,
            summaryBar: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_resultsReady)
                  ?reportTotalsBar(
                    _result!.totals
                        .where(
                          (total) => const {
                            'qty',
                            'weight',
                            'weight_unknown_rows',
                            'weight_estimated_rows',
                            'pending_qty',
                            'pending_stock_in_qty',
                            'more_qty',
                            'defective_qty',
                          }.contains(total.key),
                        )
                        .toList(),
                    weightDisplay: weightDisplay,
                  ),
                if (widget.navigationEnabled)
                  Text(
                    l10n.warehouseInventoryOpenLedger,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
