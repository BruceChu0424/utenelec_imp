// 库存面板「出入库流水」分段: 按中式存货明细账排版 (ADR-135 §6.3)。
//
// 列: 日期 | 类型 | 单号(可点回源单) | 往来方 | 仓库 | 颜色 | 收入数量 | 发出数量 | 结存数量 | 单位 |
//     收入重量 | 发出重量 | 结存重量 | 操作人 | 备注。
// 筛选: 日期 (默认近90天) / 仓库(含下级) / 颜色 / 类型 (表头筛选, 服务端 facet) / 显示重量调整。
// 结存数量/结存重量按「仓库(含下级) + 颜色」范围由服务端算好, 与类型筛选无关;
// 合计条: 期初结存 · 本期收入 · 本期发出 · 期末结存 (数量与重量), 全部来自服务端汇总。
// 重量悬停说明来源: 实称 / 按数量(精确) / 按比例分摊 / ≈按库存均重 / ≈按单重估算;
// 重量调整行: 重量起算 / 重量尾差调整 / 盘点定重 / 人工核重 / 撤销盘点重量。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../features/basic_data/models/master_facet.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../measurement/weight_prefs.dart';
import '../../measurement/weight_unit.dart';
import '../../measurement/widgets/weight_text.dart';
import '../../providers/master_name_provider.dart';
import '../../widgets/warehouse_picker_panel.dart';
import '../stock_ledger_models.dart';
import '../stock_ledger_repository.dart';
import '../../../features/stock/models/instant_inventory_scope.dart';

/// 流水分段的起始范围 (余额行「查看流水」带过来的仓库 + 颜色)。
class StockLedgerScope extends InstantInventoryScope {
  const StockLedgerScope({
    super.warehouseId,
    super.colorId,
    super.colorNull,
    super.inventoryOnly = false,
    super.includeDefective,
    super.includeLineSide = true,
  });
}

class GoodsStockLedgerView extends ConsumerStatefulWidget {
  const GoodsStockLedgerView({
    super.key,
    required this.goodsId,
    this.scope = const StockLedgerScope(),
    this.unitName,
    this.reloadTick = 0,
    this.onScopeChanged,
  });

  final String goodsId;
  final InstantInventoryScope scope;
  final ValueChanged<InstantInventoryScope>? onScopeChanged;

  /// 基本单位名 (合计条用; 流水行自带单位名)。
  final String? unitName;
  final int reloadTick;

  @override
  ConsumerState<GoodsStockLedgerView> createState() =>
      _GoodsStockLedgerViewState();
}

class _GoodsStockLedgerViewState extends ConsumerState<GoodsStockLedgerView> {
  /// 默认近90天 (含今天); 每页 50 行 (StockLedgerQuery 默认)。
  static const _defaultDays = 90;

  late DateTime _from;
  late DateTime _to;
  String? _warehouseId;

  /// 颜色表头筛选值 (颜色 UUID 或 [kMasterFilterNullValue] = 无颜色)。
  String? _colorFilter;

  /// 类型表头筛选值 (类型码, 'W' = 重量调整)。
  String? _typeFilter;
  bool _includeAdjustments = false;
  StockLedgerPage? _data;
  bool _loading = false;
  String? _error;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    final today = ChinaDateTime.today();
    _to = DateTime(today.year, today.month, today.day);
    _from = _to.subtract(const Duration(days: _defaultDays - 1));
    _applyScope(widget.scope);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant GoodsStockLedgerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _data = null;
      _applyScope(widget.scope);
      _load(1);
    } else if (oldWidget.reloadTick != widget.reloadTick) {
      _load(_data?.page ?? 1);
    }
  }

  void _applyScope(InstantInventoryScope scope) {
    _warehouseId = scope.warehouseId;
    _colorFilter = scope.colorNull
        ? kMasterFilterNullValue
        : (scope.colorId?.isNotEmpty == true ? scope.colorId : null);
  }

  StockLedgerQuery _query(int page) {
    final type = _typeFilter;
    final adjustmentsOnly = type == 'W';
    return StockLedgerQuery(
      warehouseId: _warehouseId,
      colorId: _colorFilter == kMasterFilterNullValue ? null : _colorFilter,
      colorNull: _colorFilter == kMasterFilterNullValue,
      scope: widget.scope.withDimensions(
        warehouseId: _warehouseId,
        colorId: _colorFilter == kMasterFilterNullValue ? null : _colorFilter,
        colorNull: _colorFilter == kMasterFilterNullValue,
      ),
      dateFrom: _from,
      dateTo: _to,
      movementTypes: type == null ? const [] : [type],
      includeWeightAdjustments: _includeAdjustments || adjustmentsOnly,
      page: page,
    );
  }

  Future<void> _load(int page) async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(goodsStockLedgerRepositoryProvider)
          .ledger(widget.goodsId, _query(page));
      if (!mounted || version != _version) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || version != _version) return;
      setState(() {
        _error = e is ApiException ? e.message : '出入库流水加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      switch (key) {
        case 'type':
          _typeFilter = value;
        case 'color':
          _colorFilter = value;
        case 'warehouse':
          _warehouseId = value == kMasterFilterNullValue ? null : value;
      }
    });
    if (key == 'color' || key == 'warehouse') {
      widget.onScopeChanged?.call(_query(1).scope!);
    }
    _load(1);
  }

  Future<void> _pickDates() async {
    final today = ChinaDateTime.today();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2010),
      lastDate: DateTime(today.year, today.month, today.day),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      helpText: '选择流水日期范围',
      saveText: '应用',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _from = DateTime(picked.start.year, picked.start.month, picked.start.day);
      _to = DateTime(picked.end.year, picked.end.month, picked.end.day);
    });
    _load(1);
  }

  Future<void> _pickWarehouse() async {
    final names = ref.read(masterNameServiceProvider);
    await names.ensureWarehousesLoaded();
    if (!mounted) return;
    final result = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy,
      initialWarehouseId: _warehouseId,
      title: '选择仓库(含下级)',
      includeAll: true,
      allowParent: true,
    );
    if (!mounted || result == null) return;
    final next = result.isAll ? null : result.id;
    if (next == _warehouseId) return;
    setState(() => _warehouseId = next);
    widget.onScopeChanged?.call(_query(1).scope!);
    _load(1);
  }

  void _openSource(StockLedgerRow row) {
    final path = stockLedgerSourcePath(row);
    if (path != null) context.push(path);
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(masterNameServiceProvider);
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final data = _data;
    final rows = data?.items ?? const <StockLedgerRow>[];
    final unit =
        widget.unitName ??
        rows
            .map((r) => r.unitName)
            .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
    return MasterDataTableView<StockLedgerRow>(
      tableKey:
          'shared.stock_ledger.widgets.goods_stock_ledger_view.GoodsStockLedgerViewState.build.1',
      key: const Key('stock-item-ledger-table'),
      // primary:true → 表体拾取联动容器注入的 PrimaryScrollController。
      primary: true,
      columns: _columns(display),
      items: rows,
      rowKeyOf: (row) => '${row.rowKind}:${row.id}',
      facets: {
        'type': data?.facets['movementType'] ?? const [],
        'warehouse': data?.facets['warehouse'] ?? const [],
        'color': data?.facets['color'] ?? const [],
      },
      // 「无颜色」是服务端的普通桶 (值 '__null__' = kMasterFilterNullValue), 不另走空值计数。
      nullCounts: const {},
      filters: {
        if (_typeFilter != null) 'type': _typeFilter,
        if (_warehouseId != null) 'warehouse': _warehouseId,
        if (_colorFilter != null) 'color': _colorFilter,
      },
      onFilterChanged: _onFilterChanged,
      toolbarLeadingActions: [
        OutlinedButton.icon(
          key: const ValueKey('stock-ledger-date-range'),
          onPressed: _pickDates,
          icon: const Icon(Icons.date_range_outlined, size: 18),
          label: Text(
            '${ChinaDateTime.formatDate(_from)} ~ ${ChinaDateTime.formatDate(_to)}',
          ),
        ),
        UtenFilterPickerField(
          key: const ValueKey('stock-ledger-warehouse'),
          label: '仓库(含下级)',
          icon: Icons.warehouse_outlined,
          width: 220,
          value: _warehouseId == null
              ? null
              : names.warehouseEntries[_warehouseId],
          onTap: _pickWarehouse,
        ),
        FilterChip(
          key: const ValueKey('stock-ledger-show-adjustments'),
          label: const Text('显示重量调整'),
          selected: _includeAdjustments,
          onSelected: (v) {
            setState(() => _includeAdjustments = v);
            _load(1);
          },
        ),
      ],
      onRowTap: _openSource,
      canOpenRow: (row) => stockLedgerSourcePath(row) != null,
      isLoading: _loading && data == null,
      loadingMore: _loading && data != null,
      error: _error,
      onRetry: () => _load(1),
      emptyMessage: '所选范围内没有出入库流水',
      summaryBar: data == null
          ? null
          : UtenTotalsSummaryBar(
              key: const ValueKey('stock-ledger-summary'),
              density: true,
              compact: true,
              entries: stockLedgerSummaryEntries(
                data.summary,
                unitName: unit,
                display: display,
              ),
            ),
      currentPage: data?.page ?? 1,
      totalPages: data?.totalPages ?? 1,
      paginationScope: (
        widget.goodsId,
        _warehouseId,
        _colorFilter,
        _typeFilter,
        _from,
        _to,
        _includeAdjustments,
      ),
      onPageChange: _load,
    );
  }

  List<MasterColumnDef<StockLedgerRow>> _columns(WeightDisplay display) {
    final theme = Theme.of(context);
    String? inQty(StockLedgerRow r) =>
        r.isWeightAdjustment || !r.isInbound ? null : _qty(r.qtySigned?.abs());
    String? outQty(StockLedgerRow r) =>
        r.isWeightAdjustment || r.isInbound ? null : _qty(r.qtySigned?.abs());
    bool weightInColumn(StockLedgerRow r, {required bool inbound}) {
      if (r.isWeightAdjustment) {
        final delta = r.weightKgSigned;
        return delta != null && delta != 0 && (delta > 0) == inbound;
      }
      return r.isInbound == inbound;
    }

    Widget weightCell(StockLedgerRow r, {required bool inbound}) {
      if (!weightInColumn(r, inbound: inbound)) return const SizedBox.shrink();
      return WeightText(
        kg: r.weightKgSigned?.abs(),
        source: r.weightSource,
        display: display,
      );
    }

    String weightValue(StockLedgerRow r, {required bool inbound}) {
      if (!weightInColumn(r, inbound: inbound)) return '';
      return formatWeightValue(
        r.weightKgSigned?.abs(),
        display: display,
        estimated: isEstimatedWeightSource(r.weightSource),
      );
    }

    return [
      MasterColumnDef(
        key: 'date',
        label: '日期',
        width: 130,
        type: 'date',
        value: (r) => _date(r.transactionDate),
      ),
      MasterColumnDef(
        key: 'type',
        label: '类型',
        width: 130,
        value: (r) => r.displayType,
        cellBuilder: (_, r) => Text(
          r.displayType,
          style: r.isWeightAdjustment
              ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
              : null,
        ),
      ),
      MasterColumnDef(
        key: 'billNo',
        label: '单号',
        width: 150,
        value: (r) => r.billNo ?? '',
        cellBuilder: (_, r) {
          final text = r.billNo ?? '';
          if (text.isEmpty) return const Text('');
          final linked = stockLedgerSourcePath(r) != null;
          return Text(
            text,
            style: linked
                ? TextStyle(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: theme.colorScheme.primary,
                  )
                : null,
          );
        },
      ),
      MasterColumnDef(
        key: 'counterpart',
        label: '往来方',
        width: 150,
        value: (r) => r.counterpartMasked ? '已隐藏' : (r.counterpartName ?? ''),
        cellBuilder: (_, r) => r.counterpartMasked
            ? Tooltip(
                message: '没有查看来源单据的权限, 往来方已隐藏',
                child: Text(
                  '已隐藏',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            : Text(r.counterpartName ?? ''),
      ),
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库',
        width: 140,
        value: (r) => r.warehouseName ?? '',
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 100,
        value: (r) => r.colorName ?? '',
      ),
      MasterColumnDef(
        key: 'inQty',
        label: '收入数量',
        width: 110,
        type: 'number',
        value: inQty,
      ),
      MasterColumnDef(
        key: 'outQty',
        label: '发出数量',
        width: 110,
        type: 'number',
        value: outQty,
      ),
      MasterColumnDef(
        key: 'balanceQty',
        label: '结存数量',
        width: 120,
        type: 'number',
        value: (r) => _qty(r.balanceQtyAfter),
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 70,
        value: (r) => r.unitName ?? widget.unitName ?? '',
      ),
      MasterColumnDef(
        key: 'inWeight',
        label: '收入重量',
        width: 120,
        type: 'weight',
        value: (r) => weightValue(r, inbound: true),
        cellBuilder: (_, r) => weightCell(r, inbound: true),
      ),
      MasterColumnDef(
        key: 'outWeight',
        label: '发出重量',
        width: 120,
        type: 'weight',
        value: (r) => weightValue(r, inbound: false),
        cellBuilder: (_, r) => weightCell(r, inbound: false),
      ),
      MasterColumnDef(
        key: 'balanceWeight',
        label: '结存重量',
        width: 130,
        type: 'weight',
        value: (r) => formatWeightValue(
          r.balanceWeightKgAfter,
          display: display,
          unknownText: '未知',
        ),
        cellBuilder: (_, r) => WeightText(
          kg: r.balanceWeightKgAfter,
          display: display,
          unknownText: '未知',
        ),
      ),
      MasterColumnDef(
        key: 'operator',
        label: '操作人',
        width: 100,
        value: (r) => r.operatorName ?? '',
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 200,
        value: (r) => r.remark ?? '',
      ),
    ];
  }
}

/// 合计条各项: 期初结存 · 本期收入 · 本期发出 · 期末结存 (数量 + 重量),
/// 有内部调拨/重量尾差时追加; 值全部来自服务端汇总。
List<UtenTotalEntry> stockLedgerSummaryEntries(
  StockLedgerSummary s, {
  String? unitName,
  WeightDisplay display = WeightDisplay.auto,
}) {
  String qty(double? v) {
    final text = _qty(v) ?? '—';
    final unit = unitName?.trim() ?? '';
    return unit.isEmpty || v == null ? text : '$text $unit';
  }

  String balanceWeight(double? kg) =>
      kg == null ? '重量未知' : formatWeight(kg, display: display);

  String flowWeight(double? kg, int unknownRows) {
    if (kg == null || kg == 0) {
      return unknownRows > 0 ? '$unknownRows 行未称' : '';
    }
    final text = formatWeight(kg, display: display);
    return unknownRows > 0 ? '$text (另有 $unknownRows 行未称)' : text;
  }

  String join(String q, String w) => w.isEmpty ? q : '$q · $w';

  return [
    UtenTotalEntry(
      '期初结存',
      join(qty(s.openingQty), balanceWeight(s.openingWeightKg)),
    ),
    UtenTotalEntry(
      '本期收入',
      join(qty(s.inQty ?? 0), flowWeight(s.inWeightKg, s.inWeightUnknownRows)),
    ),
    UtenTotalEntry(
      '本期发出',
      join(
        qty(s.outQty ?? 0),
        flowWeight(s.outWeightKg, s.outWeightUnknownRows),
      ),
    ),
    UtenTotalEntry(
      '期末结存',
      join(qty(s.closingQty), balanceWeight(s.closingWeightKg)),
    ),
    if ((s.internalTransferQty ?? 0) != 0)
      UtenTotalEntry('范围内调拨', qty(s.internalTransferQty)),
    if ((s.residualKg ?? 0) != 0)
      UtenTotalEntry(
        '重量尾差调整',
        '${s.residualKg! > 0 ? '+' : '-'}'
            '${formatWeight(s.residualKg!.abs(), display: display)}',
      ),
  ];
}

String? _qty(double? v) {
  if (v == null || !v.isFinite) return null;
  return NumberFormat('#,##0.####', 'zh_CN').format(v);
}

/// 业务日期: 零点的只显示日期, 带时刻的显示到分钟。
String _date(String? iso) {
  final parsed = ChinaDateTime.tryParse(iso);
  if (parsed == null) return iso ?? '';
  if (parsed.hour == 0 && parsed.minute == 0) {
    return ChinaDateTime.formatDate(parsed);
  }
  return ChinaDateTime.formatDateTime(parsed);
}
