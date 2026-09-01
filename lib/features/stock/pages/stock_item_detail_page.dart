// 库存详情页（/stock/item/:goodsId）——即时库存双击货品行进入。
//
// 2026-09-01 库存查询合并：原「库存余额」「出入库流水」两页并入本页——
// 大类分段「库存余额（各仓/颜色余额，受控调整）｜出入库流水（全部来源，双击回源单）」，
// 页级无搜索（后端按货品过滤，前端不制造假关键字）；余额行双击进余额详情弹层
// （查看流水 / 授权余额调整，与原余额页同一弹层组件）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_query.dart';
import '../repositories/stock_query_repository.dart';
import '../widgets/stock_balance_detail_sheet.dart';

class StockItemDetailPage extends ConsumerStatefulWidget {
  const StockItemDetailPage({super.key, required this.goodsId});

  final String goodsId;

  @override
  ConsumerState<StockItemDetailPage> createState() =>
      _StockItemDetailPageState();
}

class _StockItemDetailPageState extends ConsumerState<StockItemDetailPage> {
  static const _pageSize = 50;

  int _segment = 0; // 0 = 库存余额，1 = 出入库流水
  PagedResult<BalanceRow>? _balances;
  PagedResult<MovementRow>? _movements;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;
  String? _myLocation;

  /// onPageResume 首次触发是「进入本页」的导航结算，跳过一次避免进入即重复拉取。
  bool _resumeArmed = false;

  bool get _canAdjust {
    final permissions = ref.read(currentPermissionsProvider);
    return ref.read(isSuperAdminProvider) ||
        permissions.contains(Perm.stockBalanceAdjust);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _loadBalanceNames();
      _load(1);
    });
  }

  Future<void> _loadBalanceNames() async {
    await ref.read(masterNameServiceProvider).loadGoodsDetails([
      widget.goodsId,
    ]);
    if (mounted) setState(() {});
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(stockQueryRepositoryProvider);
      if (_segment == 0) {
        final result = await repo.balances(
          page: page,
          size: _pageSize,
          goodsId: widget.goodsId,
        );
        if (!mounted || version != _requestVersion) return;
        setState(() {
          _balances = result;
          _loading = false;
        });
      } else {
        final result = await repo.movements(
          page: page,
          size: _pageSize,
          goodsId: widget.goodsId,
        );
        if (!mounted || version != _requestVersion) return;
        setState(() {
          _movements = result;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '库存详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _loadFirstPage() => _load(1);

  /// 余额行双击：详情弹层（当前数量/重量 + 授权调整 + 查看流水切换）。
  Future<void> _openBalance(BalanceRow balance) async {
    final names = ref.read(masterNameServiceProvider);
    final goods = names.goodsInfo(widget.goodsId);
    final result = await showStockBalanceDetailSheet(
      context: context,
      balance: balance,
      goodsName: goods?.name ?? '货品',
      unitName: names.unit(goods?.unitId),
      warehouseName: names.warehouse(balance.warehouseId),
      colorName: names.color(balance.colorId),
      canAdjust: _canAdjust,
      onViewMovements: () {
        // 同页切换到「出入库流水」分段（比旧链路跳页更直接）。
        setState(() => _segment = 1);
        _load(1);
      },
      onAdjust: (targetQty, reason, idempotencyKey) => ref
          .read(stockQueryRepositoryProvider)
          .adjustBalance(
            balance: balance,
            targetQty: targetQty,
            reason: reason,
            idempotencyKey: idempotencyKey,
          ),
    );
    if (result == null || !mounted) return;
    await _load(_balances?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    ref.watch(currentPermissionsProvider);
    _myLocation ??= currentLocationOr(context, RouteName.stockItemDetail(widget.goodsId));
    ref.onPageResume(_myLocation!, () {
      if (!_resumeArmed) {
        _resumeArmed = true;
        return;
      }
      _loadFirstPage();
    });
    final goods = names.goodsInfo(widget.goodsId);
    final goodsLabel = [
      goods?.name ?? widget.goodsId,
      if (goods?.code?.isNotEmpty == true) goods!.code,
      if (goods?.series?.isNotEmpty == true) '系列 ${goods!.series}',
      if (goods?.stockPlace?.isNotEmpty == true) '库位 ${goods!.stockPlace}',
    ].join(' · ');
    return Scaffold(
      appBar: UtenAppBar(
        title: '库存详情',
        subtitle: goodsLabel,
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.stockInstantInventory,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _load(
              (_segment == 0 ? _balances?.page : _movements?.page) ?? 1,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: UtenFilterToolbar<int>(
                    segmentsKey: const Key('stock-item-detail-segments'),
                    segments: const [
                      UtenFilterSegment(value: 0, label: '库存余额'),
                      UtenFilterSegment(value: 1, label: '出入库流水'),
                    ],
                    selected: {_segment},
                    onSelectionChanged: (value) {
                      setState(() => _segment = value);
                      _load(1);
                    },
                    trailing: Text(
                      _segment == 0
                          ? '共 ${_balances?.total ?? 0} 条余额 · 双击查看/调整'
                          : '共 ${_movements?.total ?? 0} 条流水 · 双击回源单',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s4,
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: _segment == 0 ? _balanceTable() : _movementTable(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _balanceTable() {
    final rows = _balances?.items ?? const <BalanceRow>[];
    return MasterDataTableView<BalanceRow>(
      key: const Key('stock-item-balance-table'),
      columns: _balanceColumns,
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: _openBalance,
      isLoading: _loading && _balances == null,
      loadingMore: _loading && _balances != null,
      error: rows.isEmpty ? _error : null,
      onRetry: () => _load(1),
      emptyMessage: '该货品暂无库存余额',
      currentPage: _balances?.page ?? 1,
      totalPages: _balances?.totalPages ?? 1,
      onPageChange: _load,
    );
  }

  List<MasterColumnDef<BalanceRow>> get _balanceColumns => [
    MasterColumnDef(
      key: 'warehouse',
      label: '仓库',
      width: 170,
      value: (row) =>
          ref.read(masterNameServiceProvider).warehouse(row.warehouseId),
    ),
    MasterColumnDef(
      key: 'color',
      label: '颜色',
      width: 140,
      value: (row) => ref.read(masterNameServiceProvider).color(row.colorId),
    ),
    MasterColumnDef(
      key: 'qty',
      label: '当前数量',
      width: 140,
      type: 'number',
      sortable: true,
      value: (row) => _formatQty(row.qty) ?? '—',
    ),
    MasterColumnDef(
      key: 'weight',
      label: '库存重量',
      width: 140,
      type: 'number',
      sortable: true,
      value: (row) => _formatQty(row.weight) ?? '—',
    ),
    MasterColumnDef(
      key: 'lastMovementDate',
      label: '最后变动',
      width: 170,
      value: (row) {
        final text = row.lastMovementDate?.replaceAll('T', ' ');
        if (text == null) return '—';
        return text.length >= 16 ? text.substring(0, 16) : text;
      },
    ),
  ];

  Widget _movementTable() {
    final rows = _movements?.items ?? const <MovementRow>[];
    return MasterDataTableView<MovementRow>(
      key: const Key('stock-item-movement-table'),
      columns: _movementColumns,
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (movement) => openStockMovementSourceDoc(context, movement),
      canOpenRow: (movement) =>
          movement.sourceDocId != null && movement.sourceDocId!.isNotEmpty,
      isLoading: _loading && _movements == null,
      loadingMore: _loading && _movements != null,
      error: rows.isEmpty ? _error : null,
      onRetry: () => _load(1),
      emptyMessage: '该货品暂无出入库流水',
      currentPage: _movements?.page ?? 1,
      totalPages: _movements?.totalPages ?? 1,
      onPageChange: _load,
    );
  }

  List<MasterColumnDef<MovementRow>> get _movementColumns => [
    MasterColumnDef(
      key: 'transactionDate',
      label: '日期',
      width: 170,
      type: 'date',
      sortable: true,
      value: (row) => row.transactionDate?.replaceAll('T', ' '),
    ),
    MasterColumnDef(
      key: 'movementType',
      label: '类型',
      width: 120,
      value: (row) => movementTypeLabel(row.movementType),
    ),
    MasterColumnDef(
      key: 'warehouse',
      label: '仓库',
      width: 160,
      value: (row) =>
          ref.read(masterNameServiceProvider).warehouse(row.warehouseId),
    ),
    MasterColumnDef(
      key: 'color',
      label: '颜色',
      width: 130,
      value: (row) => ref.read(masterNameServiceProvider).color(row.colorId),
    ),
    MasterColumnDef(
      key: 'qty',
      label: '数量',
      width: 130,
      type: 'number',
      sortable: true,
      value: (row) =>
          '${(row.direction ?? 0) > 0 ? '+' : ''}${_formatQty(row.qty) ?? '—'}',
    ),
    MasterColumnDef(
      key: 'weight',
      label: '实际重量',
      width: 130,
      type: 'number',
      value: (row) => _formatQty(row.weight) == null
          ? '—'
          : '${(row.direction ?? 0) > 0 ? '+' : ''}${_formatQty(row.weight)}',
    ),
    MasterColumnDef(
      key: 'remark',
      label: '备注',
      width: 200,
      value: (row) => row.remark ?? '',
    ),
  ];
}

String? _formatQty(num? value) => value
    ?.toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

/// 流水行 → 来源单据详情（全类型跳转；无来源/未知类型不动作）。
///
/// 映射口径：sourceDocType（服务端 SRC_* 常量）优先；STOCK_DOC 统一来源按
/// movement_type（字典：1..20）推导仓库单据 code。
void openStockMovementSourceDoc(BuildContext context, MovementRow movement) {
  final sourceId = movement.sourceDocId;
  if (sourceId == null || sourceId.isEmpty) return;
  final t = movement.movementType;
  switch (movement.sourceDocType) {
    case 'PURCHASE_RECEIPT':
      context.push(RoutePath.purchaseDocDetail('receipts', sourceId));
    case 'PURCHASE_RETURN':
      context.push(RoutePath.purchaseDocDetail('returns', sourceId));
    case 'SALES_SHIPMENT':
      context.push(RoutePath.salesDocDetail('shipments', sourceId));
    case 'SALES_RETURN':
      context.push(RoutePath.salesDocDetail('returns', sourceId));
    case 'SALES_OTHER_SHIPMENT':
      context.push(RoutePath.salesDocDetail('other-shipments', sourceId));
    case 'SUBCONTRACT_RECEIPT':
      context.push(RoutePath.subcontractDocDetail('receipts', sourceId));
    case 'SUBCONTRACT_RETURN':
      context.push(RoutePath.subcontractDocDetail('returns', sourceId));
    case 'SUBCONTRACT_MATERIAL_ISSUE':
      context.push(RoutePath.subcontractDocDetail('material-issues', sourceId));
    case 'SUBCONTRACT_MATERIAL_RETURN':
      context.push(
        RoutePath.subcontractDocDetail('material-returns', sourceId),
      );
    case 'SUBCONTRACT_WASTE':
      context.push(RoutePath.subcontractDocDetail('wastes', sourceId));
    case 'STOCK_DOC':
      final code = switch (t) {
        5 => 'DRAW',
        6 => 'WDRAW',
        7 || 8 => 'TRANSFER',
        9 || 10 => 'CHECK',
        11 => 'OTHER_IN',
        12 => 'OTHER_OUT',
        13 => 'FINISHED_IN',
        14 => 'FINISHED_OUT',
        _ => null,
      };
      if (code != null) context.push(RoutePath.stockDocDetail(code, sourceId));
    default:
      break;
  }
}
