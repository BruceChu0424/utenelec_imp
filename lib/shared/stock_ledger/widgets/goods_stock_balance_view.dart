// 库存面板「库存余额」分段: 该货品各仓库 (x 颜色) 的余额。
//
// 列: 仓库 | 颜色 | 库存数量 | 单位 | 库存重量 (≈ 估算、未称 = 没称过, 绝不当 0) | 最后变动 | 操作。
// 操作: 查看流水 (流水分段按这个仓库 + 颜色筛好) · 调整 (stock:balance:adjust, 余额详情弹层) ·
// 核重 (stock:weight:manage, 只改重量)。行双击 = 打开余额详情弹层。
// 按重量计的货品 (基本单位是重量单位) 重量随数量换算, 不出现核重。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../../features/stock/models/stock_query.dart';
import '../../../features/stock/repositories/stock_query_repository.dart';
import '../../../features/stock/widgets/stock_balance_detail_sheet.dart';
import '../../auth/permissions.dart';
import '../../measurement/weight_params.dart';
import '../../measurement/weight_prefs.dart';
import '../../measurement/widgets/weight_text.dart';
import '../../models/paged_result.dart';
import '../../providers/master_name_provider.dart';

class GoodsStockBalanceView extends ConsumerStatefulWidget {
  const GoodsStockBalanceView({
    super.key,
    required this.goodsId,
    required this.onViewLedger,
    this.onChanged,
    this.reloadTick = 0,
  });

  final String goodsId;

  /// 查看流水: 切到流水分段并筛到这个仓库 + 颜色 (colorId 为 null = 无颜色维度)。
  final void Function(String? warehouseId, String? colorId) onViewLedger;

  /// 调整/核重成功后通知宿主 (刷新 KPI 等)。
  final VoidCallback? onChanged;
  final int reloadTick;

  @override
  ConsumerState<GoodsStockBalanceView> createState() =>
      _GoodsStockBalanceViewState();
}

class _GoodsStockBalanceViewState extends ConsumerState<GoodsStockBalanceView> {
  static const _pageSize = 50;

  PagedResult<BalanceRow>? _balances;
  bool _loading = false;
  String? _error;
  int _version = 0;

  /// 货品按重量计 (基本单位是重量单位): 重量随数量精确换算, 不核重。
  bool _weightExact = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load(1);
      _loadWeightParams();
    });
  }

  @override
  void didUpdateWidget(covariant GoodsStockBalanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick ||
        oldWidget.goodsId != widget.goodsId) {
      _load(_balances?.page ?? 1);
    }
  }

  Future<void> _loadWeightParams() async {
    try {
      final map = await ref.read(weightRepositoryProvider).params([
        WeightParamsLine(goodsId: widget.goodsId),
      ]);
      final params = map[WeightParams.keyOf(widget.goodsId, null)];
      if (!mounted || params == null) return;
      setState(() => _weightExact = params.isExact);
    } catch (_) {
      // 取不到单重参数只影响「核重」按钮的隐藏判断, 服务端仍会拦按重量计的货品。
    }
  }

  Future<void> _load(int page) async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(stockQueryRepositoryProvider)
          .balances(page: page, size: _pageSize, goodsId: widget.goodsId);
      if (!mounted || version != _version) return;
      setState(() {
        _balances = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _version) return;
      setState(() {
        _error = '库存余额加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  bool _can(String permission) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(permission);

  bool get _canAdjust => _can(Perm.stockBalanceAdjust);

  bool get _canSetWeight =>
      !_weightExact &&
      (ref.read(isSuperAdminProvider) || ref.read(weightManageAllowedProvider));

  String _unitName() {
    final names = ref.read(masterNameServiceProvider);
    return names.unit(names.goodsInfo(widget.goodsId)?.unitId);
  }

  Future<void> _open(
    BalanceRow balance, {
    StockBalanceSheetMode mode = StockBalanceSheetMode.details,
  }) async {
    final names = ref.read(masterNameServiceProvider);
    final goods = names.goodsInfo(widget.goodsId);
    final changed = await showStockBalanceDetailSheet(
      context: context,
      balance: balance,
      goodsName: goods?.name ?? '货品',
      unitName: _unitName(),
      warehouseName: names.warehouse(balance.warehouseId),
      colorName: names.color(balance.colorId),
      canAdjust: _canAdjust,
      canSetWeight: _canSetWeight,
      weightExact: _weightExact,
      initialMode: mode,
      onViewMovements: () =>
          widget.onViewLedger(balance.warehouseId, balance.colorId),
      onAdjust: (targetQty, targetWeightKg, reason, key) => ref
          .read(stockQueryRepositoryProvider)
          .adjustBalance(
            balance: balance,
            targetQty: targetQty,
            targetWeightKg: targetWeightKg,
            reason: reason,
            idempotencyKey: key,
          ),
      onSetWeight: (targetWeightKg, reason, key) async {
        await ref
            .read(weightRepositoryProvider)
            .setBalanceWeight(
              WeightBalanceSetRequest(
                warehouseId: balance.warehouseId ?? '',
                goodsId: widget.goodsId,
                colorId: balance.colorId,
                expectedWeightKg: balance.weight,
                targetWeightKg: targetWeightKg,
                reason: reason,
                idempotencyKey: key,
              ),
            );
      },
    );
    if (changed != true || !mounted) return;
    await _load(_balances?.page ?? 1);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(masterNameServiceProvider);
    ref.watch(currentPermissionsProvider);
    ref.watch(warehouseWeightUnitsPrefsProvider);
    final rows = _balances?.items ?? const <BalanceRow>[];
    return MasterDataTableView<BalanceRow>(
      key: const Key('stock-item-balance-table'),
      columns: _columns(),
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (row) => _open(row),
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

  List<MasterColumnDef<BalanceRow>> _columns() {
    final names = ref.read(masterNameServiceProvider);
    final display = ref.read(warehouseWeightUnitsPrefsProvider).display;
    final unitName = _unitName();
    return [
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库',
        width: 170,
        value: (row) => names.warehouse(row.warehouseId),
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 130,
        value: (row) => names.color(row.colorId),
      ),
      MasterColumnDef(
        key: 'qty',
        label: '库存数量',
        width: 130,
        type: 'number',
        sortable: true,
        value: (row) => _formatQty(row.qty) ?? '—',
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 70,
        value: (_) => unitName,
      ),
      MasterColumnDef(
        key: 'weight',
        label: '库存重量',
        width: 140,
        type: 'weight',
        sortable: true,
        value: (row) => formatWeightValue(
          row.weight,
          display: display,
          estimated: row.weightEstimated,
        ),
        cellBuilder: (_, row) => WeightText(
          kg: row.weight,
          estimated: row.weightEstimated,
          display: display,
        ),
      ),
      MasterColumnDef(
        key: 'lastMovementDate',
        label: '最后变动',
        width: 160,
        value: (row) {
          final text = row.lastMovementDate?.replaceAll('T', ' ');
          if (text == null) return '—';
          return text.length >= 16 ? text.substring(0, 16) : text;
        },
      ),
      MasterColumnDef(
        key: 'actions',
        label: '操作',
        width: 200,
        value: (_) => '',
        cellBuilderHandlesSemantics: true,
        cellBuilder: (_, row) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _action(
              'balance-view-ledger-${row.id}',
              '查看流水',
              () => widget.onViewLedger(row.warehouseId, row.colorId),
            ),
            if (_canAdjust)
              _action(
                'balance-adjust-${row.id}',
                '调整',
                () => _open(row, mode: StockBalanceSheetMode.adjust),
              ),
            if (_canSetWeight)
              _action(
                'balance-weigh-${row.id}',
                '核重',
                () => _open(row, mode: StockBalanceSheetMode.weigh),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _action(String key, String label, VoidCallback onPressed) =>
      TextButton(
        key: ValueKey(key),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
          minimumSize: const Size(0, 32),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onPressed,
        child: Text(label),
      );
}

String? _formatQty(num? value) => value
    ?.toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
