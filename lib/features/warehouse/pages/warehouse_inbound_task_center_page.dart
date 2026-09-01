// 入库任务中心（/warehouse/tasks/inbound）——仓库入库方向的一站式工作台。
//
// 大类分段：采购入库（预计到货｜到货异常｜收货历史，到货登记在预计到货详情里
// 按任务执行，仓库不凭空新建采购收货单）｜委外入库（预计到货｜收货历史）｜
// 产成品入库（待点收任务｜产成品进仓单：新建/历史）｜其它入库（新建/历史）。
// 徽章口径：只挂真实待办（父分类 = 其子类待办之和，小类行同数）——采购 =
// 采购来源预计到货 + 到货异常；委外 = 委外来源预计到货；产成品 = 待点收任务数；
// 其它入库只有草稿与历史（草稿不计入待办数）不挂。进页面不预选大类
//（未选时显示引导空态）。角标与 hub「入库任务中心」卡/工作台仓库卡一致
//（WarehouseInboundTaskBadge）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart'
    show ProcurementInboundOrderType;
import '../config/warehouse_document_history_config.dart';
import '../models/stock_doc.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/production_finished_inbound_tasks_view.dart';
import '../widgets/warehouse_arrival_exceptions_view.dart';
import '../widgets/warehouse_document_history_view.dart';
import '../widgets/warehouse_inbound_expectations_view.dart';
import '../widgets/warehouse_stock_doc_segment.dart';
import '../widgets/warehouse_task_center_scaffold.dart';

class WarehouseInboundTaskCenterPage extends ConsumerWidget {
  const WarehouseInboundTaskCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => superAdmin || permissions.contains(code);

    final canInbound = can(Perm.warehouseInboundView);
    final canPurchaseHistory = can(Perm.warehousePurchaseReceiptHistoryView);
    final canSubcontractHistory = can(
      Perm.warehouseSubcontractReceiptHistoryView,
    );
    final canStockDocs = can(Perm.stockDocView);

    final typeCounts = ref.watch(warehouseInboundExpectationTypeCountsProvider);
    final exceptions = ref.watch(warehouseArrivalExceptionCountProvider);
    final finished = ref.watch(
      warehouseProductionFinishedInboundPendingCountProvider,
    );
    int? sum(int? a, int? b) => a == null || b == null ? null : a + b;
    final purchaseExpectation = typeCounts.isLoading || typeCounts.hasError
        ? null
        : typeCounts.valueOrNull?['PURCHASE'] ?? 0;
    final subcontractExpectation = typeCounts.isLoading || typeCounts.hasError
        ? null
        : typeCounts.valueOrNull?['SUBCONTRACT'] ?? 0;
    final exceptionCount = exceptions.isLoading || exceptions.hasError
        ? null
        : exceptions.valueOrNull ?? 0;
    final finishedCount = finished.isLoading || finished.hasError
        ? null
        : finished.valueOrNull ?? 0;

    final segments = <WarehouseTaskSegmentSpec>[
      if (canInbound || canPurchaseHistory)
        WarehouseTaskSegmentSpec(
          value: 'purchase',
          label: '采购入库',
          count: sum(purchaseExpectation, exceptionCount),
        ),
      if (canInbound || canSubcontractHistory)
        WarehouseTaskSegmentSpec(
          value: 'subcontract',
          label: '委外入库',
          count: subcontractExpectation,
        ),
      if (canStockDocs)
        WarehouseTaskSegmentSpec(
          value: 'finishedIn',
          label: '产成品入库',
          count: finishedCount,
        ),
      if (canStockDocs)
        const WarehouseTaskSegmentSpec(value: 'otherIn', label: '其它入库'),
    ];
    if (segments.isEmpty) {
      return const _NoInboundPermission();
    }
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseInboundTasks,
      title: '入库任务中心',
      subtitle: '采购 · 委外 · 产成品 · 其它入库一站式办理',
      searchHint: '搜索单号 / 供应商 / 委外商 / 货品',
      segments: segments,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (segment, keyword, refreshTick) => switch (segment) {
        'purchase' => _PurchaseInboundSegment(
          keyword: keyword,
          refreshTick: refreshTick,
          canExpectations: canInbound,
          canExceptions: canInbound,
          canHistory: canPurchaseHistory,
          expectationCount: purchaseExpectation,
          exceptionCount: exceptionCount,
        ),
        'subcontract' => _SubcontractInboundSegment(
          keyword: keyword,
          refreshTick: refreshTick,
          canExpectations: canInbound,
          canHistory: canSubcontractHistory,
          expectationCount: subcontractExpectation,
        ),
        'finishedIn' => _FinishedInSegment(
          keyword: keyword,
          refreshTick: refreshTick,
          canTasks: canStockDocs,
          taskCount: finishedCount,
        ),
        _ => WarehouseStockDocSegment(
          docType: StockDocType.otherIn,
          keyword: keyword,
          refreshTick: refreshTick,
          createLabel: '新建其它入库',
        ),
      },
    );
  }
}

/// 采购入库分段：预计到货（含到货登记/继续送检）｜到货异常（按批准量处理）｜收货历史。
/// 小类行「预计到货/到货异常」挂各自待办徽章（与父分类徽章组成部分同源）。
class _PurchaseInboundSegment extends StatefulWidget {
  const _PurchaseInboundSegment({
    required this.keyword,
    required this.refreshTick,
    required this.canExpectations,
    required this.canExceptions,
    required this.canHistory,
    this.expectationCount,
    this.exceptionCount,
  });

  final String keyword;
  final int refreshTick;
  final bool canExpectations;
  final bool canExceptions;
  final bool canHistory;

  /// 「预计到货」段徽章 = 采购来源预计到货数；null = 加载中不显示。
  final int? expectationCount;

  /// 「到货异常」段徽章；null = 加载中不显示。
  final int? exceptionCount;

  @override
  State<_PurchaseInboundSegment> createState() =>
      _PurchaseInboundSegmentState();
}

class _PurchaseInboundSegmentState extends State<_PurchaseInboundSegment> {
  late int _mode = widget.canExpectations ? 0 : (widget.canExceptions ? 1 : 2);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            bottom: UtenSpacing.s8,
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
          ),
          child: UtenFilterToolbar<int>(
            segmentsKey: const Key('purchase-inbound-mode'),
            segments: [
              if (widget.canExpectations)
                UtenFilterSegment(
                  value: 0,
                  label: '预计到货',
                  count: widget.expectationCount,
                ),
              if (widget.canExceptions)
                UtenFilterSegment(
                  value: 1,
                  label: '到货异常',
                  count: widget.exceptionCount,
                ),
              if (widget.canHistory)
                const UtenFilterSegment(value: 2, label: '收货历史'),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: switch (_mode) {
            0 => WarehouseInboundExpectationsView(
              fixedOrderType: ProcurementInboundOrderType.purchase,
              keyword: widget.keyword,
              refreshTick: widget.refreshTick,
              embedded: true,
            ),
            1 => WarehouseArrivalExceptionsView(
              keyword: widget.keyword,
              refreshTick: widget.refreshTick,
              embedded: true,
            ),
            _ => WarehouseDocumentHistoryView(
              type: WarehouseDocumentHistoryType.purchaseReceipt,
              keyword: widget.keyword,
              refreshTick: widget.refreshTick,
              embedded: true,
              showBanner: false,
            ),
          },
        ),
      ],
    );
  }
}

/// 委外入库分段：预计到货（目标件回厂）｜收货历史。
class _SubcontractInboundSegment extends StatefulWidget {
  const _SubcontractInboundSegment({
    required this.keyword,
    required this.refreshTick,
    required this.canExpectations,
    required this.canHistory,
    this.expectationCount,
  });

  final String keyword;
  final int refreshTick;
  final bool canExpectations;
  final bool canHistory;

  /// 「预计到货」段徽章 = 委外来源预计到货数；null = 加载中不显示。
  final int? expectationCount;

  @override
  State<_SubcontractInboundSegment> createState() =>
      _SubcontractInboundSegmentState();
}

class _SubcontractInboundSegmentState
    extends State<_SubcontractInboundSegment> {
  late int _mode = widget.canExpectations ? 0 : 1;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            bottom: UtenSpacing.s8,
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
          ),
          child: UtenFilterToolbar<int>(
            segmentsKey: const Key('subcontract-inbound-mode'),
            segments: [
              if (widget.canExpectations)
                UtenFilterSegment(
                  value: 0,
                  label: '预计到货',
                  count: widget.expectationCount,
                ),
              if (widget.canHistory)
                const UtenFilterSegment(value: 1, label: '收货历史'),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: _mode == 0
              ? WarehouseInboundExpectationsView(
                  fixedOrderType: ProcurementInboundOrderType.subcontract,
                  keyword: widget.keyword,
                  refreshTick: widget.refreshTick,
                  embedded: true,
                )
              : WarehouseDocumentHistoryView(
                  type: WarehouseDocumentHistoryType.subcontractReceipt,
                  keyword: widget.keyword,
                  refreshTick: widget.refreshTick,
                  embedded: true,
                  showBanner: false,
                ),
        ),
      ],
    );
  }
}

/// 产成品入库分段：待点收任务（FQC 放行后逐行实收）｜产成品进仓单（新建/历史）。
/// 「产成品进仓单」段不挂徽章（草稿不计入待办数）。
class _FinishedInSegment extends StatefulWidget {
  const _FinishedInSegment({
    required this.keyword,
    required this.refreshTick,
    required this.canTasks,
    this.taskCount,
  });

  final String keyword;
  final int refreshTick;
  final bool canTasks;

  /// 「待点收任务」段徽章；null = 加载中不显示。
  final int? taskCount;

  @override
  State<_FinishedInSegment> createState() => _FinishedInSegmentState();
}

class _FinishedInSegmentState extends State<_FinishedInSegment> {
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            bottom: UtenSpacing.s8,
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
          ),
          child: UtenFilterToolbar<int>(
            segmentsKey: const Key('finished-in-mode'),
            segments: [
              UtenFilterSegment(
                value: 0,
                label: '待点收任务',
                count: widget.taskCount,
              ),
              const UtenFilterSegment(value: 1, label: '产成品进仓单'),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: _mode == 0
              ? ProductionFinishedInboundTasksView(
                  keyword: widget.keyword,
                  refreshTick: widget.refreshTick,
                  embedded: true,
                )
              : WarehouseStockDocSegment(
                  docType: StockDocType.finishedIn,
                  keyword: widget.keyword,
                  refreshTick: widget.refreshTick,
                  createLabel: '新建产成品入库',
                ),
        ),
      ],
    );
  }
}

class _NoInboundPermission extends StatelessWidget {
  const _NoInboundPermission();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('入库任务中心')),
      body: Center(
        child: Text('暂无已授权的入库页面，请联系仓库主管开通。', style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
