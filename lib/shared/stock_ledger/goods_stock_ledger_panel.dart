// 单货品库存面板 (ADR-135 §6.3): 库存详情页 (/stock/item/:goodsId?tab=balance|ledger|weight)
// 与货品详情「库存与出入库」页签共用同一个面板。
//
// 结构: 顶部 KPI 条 + 三个分段「库存余额 | 出入库流水 | 单重学习」+ 工具条「重量单位: 自动▾」。
// - 库存余额: 各仓库 (x 颜色) 余额; 行操作 查看流水 (切到流水并筛到该仓库 + 颜色) /
//   调整 (stock:balance:adjust) / 核重 (stock:weight:manage)。
// - 出入库流水: 存货明细账 (服务端算结存与期初期末), 单号点回源单。
// - 单重学习: 当前单重卡片 + 称重记录/各供应商/学习设置。
// 放在 lib/shared: 基础资料 (货品详情) 与库存两个 feature 都从这里取, 不新增 feature 依赖边。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../components/layout/uten_filter_toolbar.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/stock/models/stock_query.dart';
import '../../features/stock/repositories/stock_query_repository.dart';
import '../models/paged_result.dart';
import '../measurement/weight_prefs.dart';
import '../widgets/warehouse_picker_panel.dart';
import '../widgets/warehouse_selection.dart';
import '../measurement/widgets/weight_text.dart';
import '../providers/master_name_provider.dart';
import 'stock_ledger_models.dart';
import '../../features/stock/models/instant_inventory_scope.dart';
import 'widgets/goods_stock_inventory_overview.dart';
import 'widgets/goods_stock_balance_view.dart';
import 'widgets/goods_stock_kpi_strip.dart';
import 'widgets/goods_stock_ledger_view.dart';
import 'widgets/goods_weight_learning_view.dart';

class GoodsStockLedgerPanel extends ConsumerStatefulWidget {
  const GoodsStockLedgerPanel({
    super.key,
    required this.goodsId,
    this.initialSegment = GoodsStockLedgerSegment.balance,
    this.onSegmentChanged,
    this.initialScope = const InstantInventoryScope.full(),
    this.onScopeChanged,
    this.onGoodsLoaded,
  });

  final String goodsId;
  final GoodsStockLedgerSegment initialSegment;
  final InstantInventoryScope initialScope;
  final ValueChanged<InstantInventoryScope>? onScopeChanged;
  final ValueChanged<InstantInventoryRow>? onGoodsLoaded;

  /// 分段切换通知 (宿主需要时同步地址栏等)。
  final ValueChanged<GoodsStockLedgerSegment>? onSegmentChanged;

  @override
  ConsumerState<GoodsStockLedgerPanel> createState() =>
      GoodsStockLedgerPanelState();
}

class GoodsStockLedgerPanelState extends ConsumerState<GoodsStockLedgerPanel> {
  late GoodsStockLedgerSegment _segment = widget.initialSegment;

  /// 每次刷新 +1, 各分段与 KPI 条据此重取 (保留各自的筛选与分页)。
  int _reloadTick = 0;

  /// 流水分段的起始范围 (余额行「查看流水」带过来)。
  late InstantInventoryScope _scope = widget.initialScope;
  InstantInventoryScope get scope => _scope;
  PagedResult<InstantInventoryRow>? _context;
  bool _contextLoading = false;
  String? _contextError;
  int _contextVersion = 0;

  GoodsStockLedgerSegment get segment => _segment;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadNames();
      _loadContext();
    });
  }

  @override
  void didUpdateWidget(covariant GoodsStockLedgerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialScope != widget.initialScope) {
      _scope = widget.initialScope;
      _loadContext();
    }
    if (oldWidget.initialSegment != widget.initialSegment) {
      _segment = widget.initialSegment;
    }
    if (oldWidget.goodsId != widget.goodsId) {
      _loadNames();
      _loadContext();
    }
  }

  Future<void> _loadNames() async {
    final names = ref.read(masterNameServiceProvider);
    try {
      await names.ensureCommonLoaded();
    } catch (_) {
      /* Values remain supplied by stock:view context. */
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadContext() async {
    final version = ++_contextVersion;
    setState(() {
      _contextLoading = true;
      _contextError = null;
      _context = null;
    });
    try {
      final result = await ref
          .read(stockQueryRepositoryProvider)
          .goodsInventoryContext(widget.goodsId, _scope);
      if (!mounted || version != _contextVersion) return;
      if (result.items.isEmpty) throw StateError('货品库存投影未返回主档资料');
      setState(() {
        _context = result;
        _contextLoading = false;
      });
      widget.onGoodsLoaded?.call(result.items.first);
    } catch (_) {
      if (!mounted || version != _contextVersion) return;
      setState(() {
        _contextLoading = false;
        _contextError = '库存概况读取失败，数量暂无法核对';
      });
    }
  }

  void selectScope(InstantInventoryScope next) {
    if (_scope == next) return;
    setState(() => _scope = next);
    _loadContext();
    widget.onScopeChanged?.call(next);
  }

  Future<void> _pickWarehouse() async {
    final names = ref.read(masterNameServiceProvider);
    await names.ensureWarehousesLoaded();
    if (!mounted) return;
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy,
      initialWarehouseId: _scope.warehouseId,
      title: '查询仓库范围（含下级）',
      includeAll: true,
      use: WarehouseUse.query,
    );
    if (!mounted || picked == null) return;
    selectScope(
      _scope.withDimensions(
        warehouseId: picked.isAll ? null : picked.id,
        colorId: _scope.colorId,
        colorNull: _scope.colorNull,
      ),
    );
  }

  /// 整个面板重取 (页面刷新按钮 / 返回即刷新)。
  void reload() {
    _loadNames();
    _loadContext();
    setState(() => _reloadTick++);
  }

  void selectSegment(GoodsStockLedgerSegment segment) {
    if (segment == _segment) return;
    setState(() => _segment = segment);
    widget.onSegmentChanged?.call(segment);
  }

  /// 切到流水分段并筛到某个仓库 + 颜色 ([colorId] 为 null = 无颜色维度)。
  void showLedger({String? warehouseId, String? colorId}) {
    setState(() {
      _segment = GoodsStockLedgerSegment.ledger;
    });
    selectScope(
      _scope.withDimensions(
        warehouseId: warehouseId,
        colorId: colorId,
        colorNull: colorId == null,
      ),
    );
    widget.onSegmentChanged?.call(_segment);
  }

  /// 分段内写操作 (调整/核重/称样...) 已自行重取, 这里只刷新 KPI 条。
  int _kpiTick = 0;

  void _changed() {
    setState(() => _kpiTick++);
    _loadContext();
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(masterNameServiceProvider);
    final goods = _context?.items.firstOrNull;
    final unit = goods?.unitName;
    final goodsTitle = [
      goods?.name ?? widget.goodsId,
      if (goods?.goodsCode?.isNotEmpty == true) goods!.goodsCode!,
    ].join(' ');
    // 上滑先把分段行+KPI 条收完、表格顶到屏顶再滚表内（全站联动口径）。
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '查询仓库范围：${_scope.label(warehouseName: names.warehouse(_scope.warehouseId), colorName: names.color(_scope.colorId), warehouseHasChildren: names.warehouseHasChildren(_scope.warehouseId))}',
            key: const ValueKey('stock-inventory-scope-label'),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('stock-inventory-warehouse'),
                onPressed: _pickWarehouse,
                icon: const Icon(Icons.warehouse_outlined),
                label: const Text('选择查询仓库'),
              ),
              if (_scope.inventoryOnly || _scope.warehouseId != null)
                TextButton(
                  key: const ValueKey('stock-inventory-all-warehouses'),
                  onPressed: () => selectScope(_scope.allWarehouses),
                  child: const Text('切到全部仓库（含非核算仓）'),
                ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  key: ValueKey((
                    'stock-inventory-color',
                    _scope.colorId,
                    _scope.colorNull,
                  )),
                  initialValue:
                      _scope.colorId ??
                      (_scope.colorNull ? '__null__' : '__all__'),
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '查询颜色范围'),
                  items: [
                    const DropdownMenuItem(
                      value: '__all__',
                      child: Text('全部颜色'),
                    ),
                    const DropdownMenuItem(
                      value: '__null__',
                      child: Text('无颜色'),
                    ),
                    for (final entry in names.colorEntries.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    if (_scope.colorId != null &&
                        !names.colorEntries.containsKey(_scope.colorId))
                      DropdownMenuItem(
                        value: _scope.colorId,
                        child: Text(_scope.colorId!),
                      ),
                  ],
                  onChanged: (value) => selectScope(
                    _scope.withDimensions(
                      warehouseId: _scope.warehouseId,
                      colorId: value == '__all__' || value == '__null__'
                          ? null
                          : value,
                      colorNull: value == '__null__',
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          GoodsStockInventoryOverview(
            data: _context,
            loading: _contextLoading,
            error: _contextError,
            onRetry: _loadContext,
            weightDisplay: ref.watch(warehouseWeightUnitsPrefsProvider).display,
            showQuantities: _segment == GoodsStockLedgerSegment.balance,
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (_segment == GoodsStockLedgerSegment.weight)
            const Text('单重学习是货品级参数，不按当前仓库或颜色拆分。'),
          UtenFilterToolbar<GoodsStockLedgerSegment>(
            segmentsKey: const Key('stock-item-detail-segments'),
            segments: [
              for (final s in GoodsStockLedgerSegment.values)
                UtenFilterSegment(value: s, label: s.label),
            ],
            selected: {_segment},
            onSelectionChanged: selectSegment,
            trailing: const WeightDisplayUnitButton(),
          ),
          // KPI 概览条只在「库存余额」分段出现 (2026-09-29 用户口径), 挪到分段行下面。
          if (_segment == GoodsStockLedgerSegment.balance) ...[
            const SizedBox(height: UtenSpacing.s8),
            GoodsStockKpiStrip(
              goodsId: widget.goodsId,
              unitName: unit,
              reloadTick: _reloadTick + _kpiTick,
              showInventory: false,
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
        ],
      ),
      body: switch (_segment) {
        GoodsStockLedgerSegment.balance => GoodsStockBalanceView(
          goodsId: widget.goodsId,
          scope: _scope,
          goodsName: goods?.name,
          unitName: unit,
          reloadTick: _reloadTick,
          onViewLedger: (warehouseId, colorId) =>
              showLedger(warehouseId: warehouseId, colorId: colorId),
          onChanged: _changed,
        ),
        GoodsStockLedgerSegment.ledger => GoodsStockLedgerView(
          goodsId: widget.goodsId,
          scope: _scope,
          onScopeChanged: selectScope,
          unitName: unit,
          reloadTick: _reloadTick,
        ),
        GoodsStockLedgerSegment.weight => GoodsWeightLearningView(
          goodsId: widget.goodsId,
          goodsTitle: goodsTitle,
          unitName: unit,
          reloadTick: _reloadTick,
          onChanged: _changed,
        ),
      },
    );
  }
}
