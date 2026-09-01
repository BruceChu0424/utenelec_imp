// 出库任务中心（/warehouse/tasks/outbound）——仓库出库方向的一站式工作台。
//
// 大类分段：销售出库（待拣/拣货/已拣/异常/已出库历史，仓库不能自建销售出库单，
// 任务来自财务放行的销售出货）｜委外出库（待出仓任务 + 出仓历史）｜其它出库
// （新建/历史）｜产成品出库（新建/历史）。徽章口径：只挂真实待办——销售 =
// 未交接出库的放行单、委外 = 待出仓任务（小类行「待出仓任务」段同数）；
// 通用单据分段只有草稿与历史（草稿不计入待办数）不挂。进页面不预选大类
//（未选时显示引导空态）。角标与 hub「出库任务中心」卡/工作台仓库卡一致
//（WarehouseOutboundTaskBadge）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart'
    show warehouseSubcontractOutboundCountProvider;
import '../widgets/warehouse_stock_doc_segment.dart';
import '../widgets/warehouse_subcontract_outbound_workbench.dart';
import '../widgets/warehouse_document_history_view.dart';
import '../widgets/warehouse_sales_outbound_workbench.dart';
import '../widgets/warehouse_task_center_scaffold.dart';

class WarehouseOutboundTaskCenterPage extends ConsumerWidget {
  const WarehouseOutboundTaskCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => superAdmin || permissions.contains(code);

    final canSales = can(Perm.salesShipmentWarehouseWork);
    final canSubcontract = can(Perm.subcontractOutboundView);
    final canSubcontractHistory = can(
      Perm.warehouseSubcontractOutboundHistoryView,
    );
    final canStockDocs = can(Perm.stockDocView);

    final salesCount = ref.watch(warehouseSalesOutboundPendingCountProvider);
    final subcontractCount = ref.watch(
      warehouseSubcontractOutboundCountProvider,
    );
    final subcontractTaskCount = subcontractCount.isLoading
        ? null
        : subcontractCount.valueOrNull;

    final segments = <WarehouseTaskSegmentSpec>[
      if (canSales)
        WarehouseTaskSegmentSpec(
          value: 'sales',
          label: '销售出库',
          count: salesCount.isLoading ? null : salesCount.valueOrNull,
        ),
      if (canSubcontract || canSubcontractHistory)
        WarehouseTaskSegmentSpec(
          value: 'subcontract',
          label: '委外出库',
          count: subcontractTaskCount,
        ),
      if (canStockDocs)
        const WarehouseTaskSegmentSpec(value: 'otherOut', label: '其它出库'),
      if (canStockDocs)
        const WarehouseTaskSegmentSpec(value: 'finishedOut', label: '产成品出库'),
    ];
    if (segments.isEmpty) {
      return const _NoOutboundPermission();
    }
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseOutboundTasks,
      title: '出库任务中心',
      subtitle: '销售 · 委外 · 其它 · 产成品出库一站式办理',
      searchHint: '搜索单号 / 客户 / 委外商 / 货品',
      segments: segments,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (segment, keyword, refreshTick) => switch (segment) {
        'sales' => WarehouseSalesOutboundWorkbench(
          keyword: keyword,
          refreshTick: refreshTick,
          embedded: true,
          showBoundaryBanner: false,
        ),
        'subcontract' => _SubcontractOutboundSegment(
          keyword: keyword,
          refreshTick: refreshTick,
          canTasks: canSubcontract,
          canHistory: canSubcontractHistory,
          taskCount: subcontractTaskCount,
        ),
        'otherOut' => WarehouseStockDocSegment(
          docType: StockDocType.otherOut,
          keyword: keyword,
          refreshTick: refreshTick,
          createLabel: '新建其它出库',
        ),
        _ => WarehouseStockDocSegment(
          docType: StockDocType.finishedOut,
          keyword: keyword,
          refreshTick: refreshTick,
          createLabel: '新建产成品出库',
        ),
      },
    );
  }
}

/// 委外出库分段：待出仓任务（仓库执行目标件拣货出仓）｜出仓历史（实物视图）。
class _SubcontractOutboundSegment extends StatefulWidget {
  const _SubcontractOutboundSegment({
    required this.keyword,
    required this.refreshTick,
    required this.canTasks,
    required this.canHistory,
    this.taskCount,
  });

  final String keyword;
  final int refreshTick;
  final bool canTasks;
  final bool canHistory;

  /// 「待出仓任务」小类段徽章（与父分类徽章同源；null = 加载中不显示）。
  final int? taskCount;

  @override
  State<_SubcontractOutboundSegment> createState() =>
      _SubcontractOutboundSegmentState();
}

class _SubcontractOutboundSegmentState
    extends State<_SubcontractOutboundSegment> {
  late int _mode = widget.canTasks ? 0 : 1;

  @override
  Widget build(BuildContext context) {
    // 分段无待办/历史语义冲突：小类行始终有选中项（视图切换工具条）。
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
            segmentsKey: const Key('subcontract-outbound-mode'),
            segments: [
              if (widget.canTasks)
                UtenFilterSegment(value: 0, label: '待出仓任务', count: widget.taskCount),
              if (widget.canHistory)
                const UtenFilterSegment(value: 1, label: '出仓历史'),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: _mode == 0
              ? WarehouseSubcontractOutboundWorkbench(
                  keyword: widget.keyword,
                  refreshTick: widget.refreshTick,
                  embedded: true,
                  showHintBanner: false,
                )
              : WarehouseDocumentHistoryView(
                  type: WarehouseDocumentHistoryType.subcontractMaterialIssue,
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

class _NoOutboundPermission extends StatelessWidget {
  const _NoOutboundPermission();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('出库任务中心')),
      body: Center(
        child: Text('暂无已授权的出库页面，请联系仓库主管开通。', style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
