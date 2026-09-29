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

import '../../components/layout/uten_filter_toolbar.dart';
import '../../core/theme/uten_tokens.dart';
import '../measurement/widgets/weight_text.dart';
import '../providers/master_name_provider.dart';
import 'stock_ledger_models.dart';
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
  });

  final String goodsId;
  final GoodsStockLedgerSegment initialSegment;

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
  StockLedgerScope _ledgerScope = const StockLedgerScope();

  GoodsStockLedgerSegment get segment => _segment;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNames());
  }

  Future<void> _loadNames() async {
    final names = ref.read(masterNameServiceProvider);
    await Future.wait([
      names.ensureLoaded(),
      names.loadGoodsDetails([widget.goodsId]),
    ]);
    if (mounted) setState(() {});
  }

  /// 整个面板重取 (页面刷新按钮 / 返回即刷新)。
  void reload() {
    _loadNames();
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
      _ledgerScope = StockLedgerScope(
        warehouseId: warehouseId,
        colorId: colorId,
        colorNull: warehouseId != null && colorId == null,
      );
      _segment = GoodsStockLedgerSegment.ledger;
    });
    widget.onSegmentChanged?.call(_segment);
  }

  /// 分段内写操作 (调整/核重/称样...) 已自行重取, 这里只刷新 KPI 条。
  int _kpiTick = 0;

  void _changed() => setState(() => _kpiTick++);

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(masterNameServiceProvider);
    final goods = names.goodsInfo(widget.goodsId);
    final unitName = goods?.unitId == null ? null : names.unit(goods!.unitId);
    final unit = unitName == null || unitName == '—' ? null : unitName;
    final goodsTitle = [
      goods?.name ?? names.goods(widget.goodsId),
      if (goods?.code?.isNotEmpty == true) goods!.code!,
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GoodsStockKpiStrip(
          goodsId: widget.goodsId,
          unitName: unit,
          reloadTick: _reloadTick + _kpiTick,
        ),
        const SizedBox(height: UtenSpacing.s8),
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
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: switch (_segment) {
            GoodsStockLedgerSegment.balance => GoodsStockBalanceView(
              goodsId: widget.goodsId,
              reloadTick: _reloadTick,
              onViewLedger: (warehouseId, colorId) =>
                  showLedger(warehouseId: warehouseId, colorId: colorId),
              onChanged: _changed,
            ),
            GoodsStockLedgerSegment.ledger => GoodsStockLedgerView(
              goodsId: widget.goodsId,
              scope: _ledgerScope,
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
        ),
      ],
    );
  }
}
