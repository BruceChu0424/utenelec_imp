// 出库任务中心（/warehouse/tasks/outbound）——仓库出库方向的一站式工作台。
//
// 大类分段：销售出库（待拣/拣货/已拣/异常/已出库 + 历史单据，仓库不能自建销售
// 出库单，任务来自财务放行的销售出货）｜委外出库（待出仓任务 + 历史单据）｜
// 其它出库（新建/历史）｜产成品出库（新建/历史）。徽章口径：只挂真实待办——
// 销售 = 尚未确认出库的放行单、委外 = 待出仓任务（小类行「待出仓任务」段同数）；
// 「委外出库」另挂一枚黄(2026-09-22 ADR-103): 等子件到货的任务, 红角标按 ADR-101
// 不计, 只画黄不画红就会在分段上蒸发; 红黄两枚同出一次请求、互斥、之和 = 列表行数.
// 黄枚只画在分段上, 不登记黄链(那些委外单已在委外任务中心的 IN_PROGRESS 黄数里).
// 通用单据分段只有草稿与历史（草稿不计入待办数）不挂。进页面不预选大类
//（未选时显示引导空态）。角标与 hub「出库任务中心」卡/工作台仓库卡一致
//（WarehouseOutboundTaskBadge）。
//
// 2026-09-03 统一范式：各小类行同样默认不选（未选不发请求）；
// 「历史单据」段一律时间门控（WarehouseHistoryGate：时间段/全部，
// 未选时间显示引导占位不加载）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/stock_doc.dart';
import '../providers/warehouse_count_refresh.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../repositories/warehouse_subcontract_outbound_repository.dart'
    show
        warehouseSubcontractOutboundCountProvider,
        warehouseSubcontractOutboundWaitingComponentCountProvider;
import '../widgets/warehouse_history_gate.dart';
import '../widgets/warehouse_stock_doc_segment.dart';
import '../widgets/warehouse_subcontract_outbound_workbench.dart';
import '../widgets/warehouse_document_history_view.dart';
import '../widgets/warehouse_sales_outbound_workbench.dart';
import '../widgets/warehouse_task_center_scaffold.dart';

class WarehouseOutboundTaskCenterPage extends ConsumerWidget {
  const WarehouseOutboundTaskCenterPage({
    super.key,
    this.initialSection,
    this.initialView,
  });
  final String? initialSection;
  final String? initialView;

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
    final subcontractWaiting = ref.watch(
      warehouseSubcontractOutboundWaitingComponentCountProvider,
    );
    final subcontractWaitingCount = subcontractWaiting.isLoading
        ? null
        : subcontractWaiting.valueOrNull;

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
          inProgressCount: subcontractWaitingCount,
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
      initialSegment: initialSection,
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
          waitingComponentCount: subcontractWaitingCount,
          initialTasks:
              initialSection == 'subcontract' && initialView == 'tasks',
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

/// 委外出库分段：待出仓任务（仓库执行目标件拣货出仓）｜历史单据（时间门控实物视图）。
class _SubcontractOutboundSegment extends StatefulWidget {
  const _SubcontractOutboundSegment({
    required this.keyword,
    required this.refreshTick,
    required this.canTasks,
    required this.canHistory,
    this.taskCount,
    this.waitingComponentCount,
    this.initialTasks = false,
  });

  final String keyword;
  final int refreshTick;
  final bool canTasks;
  final bool canHistory;

  /// 「待出仓任务」小类段红徽章（与父分类徽章同源；null = 加载中不显示）。
  final int? taskCount;

  /// 「待出仓任务」小类段黄徽章: 等子件到货的任务(与父分类黄枚同源)。
  final int? waitingComponentCount;
  final bool initialTasks;

  @override
  State<_SubcontractOutboundSegment> createState() =>
      _SubcontractOutboundSegmentState();
}

class _SubcontractOutboundSegmentState
    extends State<_SubcontractOutboundSegment> {
  static const _tasksMode = 0;
  static const _historyMode = 1;

  /// null = 未选择引导态（2026-09-03 统一范式：小类默认不选，不发请求）。
  int? _mode;

  @override
  void initState() {
    super.initState();
    if (widget.initialTasks && widget.canTasks) _mode = _tasksMode;
  }

  @override
  void didUpdateWidget(covariant _SubcontractOutboundSegment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.initialTasks && widget.initialTasks && widget.canTasks) {
      _mode = _tasksMode;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
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
              // 待出仓 = 仓库必须清空的队列 → 红徽章; 等子件到货的任务仓库办不了
              // → 黄徽章(两枚互斥, 之和 = 列表行数); 历史单据不传 count。
              if (widget.canTasks)
                UtenFilterSegment(
                  value: _tasksMode,
                  label: '待出仓任务',
                  count: widget.taskCount,
                  countForm: UtenSegmentCountForm.actionable,
                  inProgressCount: widget.waitingComponentCount,
                ),
              if (widget.canHistory)
                const UtenFilterSegment(value: _historyMode, label: '历史单据'),
            ],
            selected: mode == null ? const {} : {mode},
            onSelectionChanged: (value) => setState(() => _mode = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: switch (mode) {
            _tasksMode => WarehouseSubcontractOutboundWorkbench(
              keyword: widget.keyword,
              refreshTick: widget.refreshTick,
              embedded: true,
              showHintBanner: false,
            ),
            _historyMode => WarehouseHistoryGate(
              timeKey: const Key('subcontract-outbound-history-time'),
              builder: (time) => WarehouseDocumentHistoryView(
                type: WarehouseDocumentHistoryType.subcontractMaterialIssue,
                keyword: widget.keyword,
                refreshTick: widget.refreshTick,
                embedded: true,
                showBanner: false,
                dateFrom: time.range == null
                    ? null
                    : ChinaDateTime.formatDate(time.range!.start),
                dateTo: time.range == null
                    ? null
                    : ChinaDateTime.formatDate(time.range!.end),
              ),
            ),
            _ => const UtenFilterPlaceholder(
              message: '在上方选择分类后开始办理',
              description: '小类默认不选中；历史单据需先选时间段或「全部」',
            ),
          },
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
