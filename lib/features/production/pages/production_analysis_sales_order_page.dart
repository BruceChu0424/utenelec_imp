// 物料分析 · 关联销售订货单货品清单(只读专用页，ADR-088)。
//
// 入口：物料分析页顶部卡片「关联销售订单」里点某个订单编号。
//
// 为什么是一张新页而不是跳销售订单详情：销售订单详情是**业务单据页**，带编辑/
// 审核/财务/价格等一整套动作与字段，计划员从物料分析点过去只是想核对「这张单
// 到底订了些什么货、还差多少要生产」。所以本页：
//   · 只要 production_material_analysis:view，不要求 sales_order:view；
//   · 服务端反查 orderId 必须确实被这张分析引用，不是就 404(防止拿分析 id 当
//     通行证遍历全库订单)；
//   · 纯数量口径，**没有任何单价/金额/折扣**——生产口径看不到销售价格；
//   · 全页零写入动作：没有编辑、没有审核、没有右下悬浮按钮。
//
// 表格 = 全站统一 MasterDataTableView(货品身份三列：名称 / 编号 / 颜色各一列)，
// 表体下方挂 UtenTotalsSummaryBar 合计：按单位分组，不同单位的数量绝不相加。
// 本页一次取完整张单的明细(不服务端分页)，所以合计就是全单合计。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/analysis_linked_sales_order.dart';
import '../repositories/production_repository.dart';

class ProductionAnalysisSalesOrderPage extends ConsumerStatefulWidget {
  const ProductionAnalysisSalesOrderPage({
    super.key,
    required this.analysisId,
    required this.orderId,
  });

  /// 来源物料分析 id(服务端据此做「这张订单属于这张分析」的越权校验)。
  final String analysisId;
  final String orderId;

  @override
  ConsumerState<ProductionAnalysisSalesOrderPage> createState() =>
      _ProductionAnalysisSalesOrderPageState();
}

class _ProductionAnalysisSalesOrderPageState
    extends ConsumerState<ProductionAnalysisSalesOrderPage> {
  AnalysisLinkedSalesOrder? _order;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final order = await ref
          .read(productionPlanRepositoryProvider)
          .analysisLinkedSalesOrder(
            analysisId: widget.analysisId,
            orderId: widget.orderId,
          );
      if (!mounted) return;
      setState(() {
        _order = order;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = productionErrorMessage(e, fallback: '加载订单货品清单失败');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final billNo = order?.billNo;
    return Scaffold(
      appBar: UtenAppBar(
        title: billNo == null ? '订单货品清单' : '订单货品清单 · $billNo',
        // 从物料分析页 push 进来，正常一路 pop 回去；栈空(Web 深链/刷新)时
        // 回「生产调度与进度 · 进行中」——用户真实来路就是那一段，退回一张
        // 空白的新建分析页等于把人丢在半路。
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.productionProgress),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              UtenSpacing.s12,
              UtenSpacing.s12,
              UtenSpacing.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (order != null) ...[
                  _headerCard(order),
                  const SizedBox(height: UtenSpacing.s8),
                ],
                Expanded(child: _table(order)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单头事实卡：单号 / 客户 / 跟单员 / 开单与交货日期 / 状态。全部只读文本。
  Widget _headerCard(AnalysisLinkedSalesOrder order) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('analysis-sales-order-header'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _fact('销售单号', order.billNo),
          _fact('客户', order.clientName),
          _fact('跟单员', order.sellerName),
          _fact('开单日期', _date(order.billDate)),
          _fact('交货日期', _date(order.deliverDate)),
          UtenStatusBadge(
            label: order.statusLabel,
            type: order.stopped
                ? UtenStatusBadgeType.danger
                : order.closed
                ? UtenStatusBadgeType.neutral
                : order.status == 1
                ? UtenStatusBadgeType.success
                : UtenStatusBadgeType.warning,
          ),
        ],
      ),
    );
  }

  Widget _fact(String label, String? value) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$label: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            value?.isNotEmpty == true ? value! : '—',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _table(AnalysisLinkedSalesOrder? order) {
    final theme = Theme.of(context);
    final lines = order?.lines ?? const <AnalysisLinkedSalesOrderLine>[];
    return MasterDataTableView<AnalysisLinkedSalesOrderLine>(
      key: const Key('analysis-sales-order-lines'),
      columns: _columns,
      items: lines,
      rowKeyOf: (line) => line.orderItemId,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 本张分析的来源行浅色高亮：一眼看出「这张单里我这次分析的是哪几行」。
      rowColor: (line) => line.inAnalysis
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.28)
          : null,
      isLoading: _loading,
      error: (_error != null && lines.isEmpty) ? _error : null,
      onRetry: _load,
      emptyMessage: '该订单没有货品明细',
      summaryBar: UtenTotalsSummaryBar(
        density: true,
        compact: true,
        entries: [
          UtenTotalEntry('行数', '${lines.length}'),
          utenQuantityTotalEntry(_amounts(lines, (l) => l.qty), label: '合计订货'),
          utenQuantityTotalEntry(
            _amounts(lines, (l) => l.shippedQty),
            label: '合计已发',
          ),
          utenQuantityTotalEntry(
            _amounts(lines, (l) => l.outstandingQty),
            label: '合计未发',
          ),
          utenQuantityTotalEntry(
            _amounts(lines, (l) => l.plannedQty),
            label: '合计已排产',
          ),
          utenQuantityTotalEntry(
            _amounts(lines, (l) => l.unplannedQty),
            label: '合计剩余未排',
          ),
        ],
      ),
    );
  }

  /// 合计一律按 unitId 分组：同一张单里「个」和「箱」不能相加。
  Iterable<MeasuredAmount> _amounts(
    List<AnalysisLinkedSalesOrderLine> lines,
    double Function(AnalysisLinkedSalesOrderLine line) pick,
  ) => lines.map(
    (line) => MeasuredAmount(
      value: pick(line),
      unitId: line.unitId,
      unitName: line.unitName,
    ),
  );

  /// 货品身份三列(名称 / 编号 / 颜色各占一列，全站统一口径)；规格留在名称格副行。
  List<MasterColumnDef<AnalysisLinkedSalesOrderLine>> get _columns => [
    MasterColumnDef(
      key: 'lineNo',
      label: '行号',
      width: 70,
      type: 'number',
      value: (l) => l.lineNo?.toString() ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '货品名称',
      width: 200,
      value: (l) => l.goodsName ?? l.goodsCode ?? '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, l) =>
          UtenGoodsIdentityCell(name: l.goodsName, spec: l.spec),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (l) => UtenGoodsAttributeCell.text(l.goodsCode),
      cellBuilder: (_, l) => UtenGoodsAttributeCell(l.goodsCode),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: (l) => UtenGoodsAttributeCell.text(l.colorName),
      cellBuilder: (_, l) => UtenGoodsAttributeCell(l.colorName),
    ),
    MasterColumnDef(
      key: 'unit',
      label: '单位',
      width: 90,
      value: (l) => l.unitName ?? '未维护',
    ),
    MasterColumnDef(
      key: 'qty',
      label: '订货量',
      width: 100,
      type: 'number',
      value: (l) => _qty(l.qty),
    ),
    MasterColumnDef(
      key: 'shippedQty',
      label: '已发',
      width: 90,
      type: 'number',
      value: (l) => _qty(l.shippedQty),
    ),
    MasterColumnDef(
      key: 'outstandingQty',
      label: '未发',
      width: 90,
      type: 'number',
      info: '未交付量 = 订货 − 已发 + 已退 − 核销。',
      value: (l) => _qty(l.outstandingQty),
    ),
    MasterColumnDef(
      key: 'reservedQty',
      label: '已预留',
      width: 90,
      type: 'number',
      value: (l) => _qty(l.reservedQty),
    ),
    MasterColumnDef(
      key: 'plannedQty',
      label: '已排产',
      width: 90,
      type: 'number',
      value: (l) => _qty(l.plannedQty),
    ),
    MasterColumnDef(
      key: 'producedQty',
      label: '已完工',
      width: 90,
      type: 'number',
      value: (l) => _qty(l.producedQty),
    ),
    MasterColumnDef(
      key: 'unplannedQty',
      label: '剩余未排',
      width: 110,
      type: 'number',
      // 刻意不叫「待排产」：调度台那一屏的「缺口」是扣过活动分析承接量的口径
      // (ADR-088)，同名不同口径会让人拿两屏数字对账。
      info:
          '剩余未排量 = 未交付 − 已预留 − max(已排产 − 已完工, 0)；'
          '链路口径，不扣物料分析承接量，所以可能大于调度台「待排产」段看到的缺口。',
      value: (l) => _qty(l.unplannedQty),
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (l) => _date(l.deliverDate) ?? '—',
    ),
    MasterColumnDef(
      key: 'inAnalysis',
      label: '本次分析',
      width: 100,
      info: '该行是否是当前这张物料分析的来源行。',
      value: (l) => l.inAnalysis ? '是' : '—',
    ),
  ];

  static String _qty(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String? _date(String? value) {
    if (value == null || value.isEmpty) return null;
    return value.length >= 10 ? value.substring(0, 10) : value;
  }
}
