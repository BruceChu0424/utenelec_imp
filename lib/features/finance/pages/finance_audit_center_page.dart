// 业务审核中心（/finance/audits）——财务全部审核/审批队列的一站式工作台。
//
// 原钱流管理 hub 的审核卡合并为一张
// 「业务审核中心」卡，本页以大类分段承接全部队列。布局对齐仓库任务中心三页范式
// （WarehouseTaskCenterScaffold）：UtenFilterToolbar 大类分段在上（每段右侧红色
// 待办徽章，取后端全量口径），各分段内容自带小类行与搜索在下；进页面不预选大类
// （未选择时显示引导空态）。
//
// 徽章口径（docs/00-项目准则/14-徽章与计数口径.md）：
//   · 每段红徽章 = 该队列「等我处理」数；销售订单内首次/修改是互斥状态，
//     父级只使用总数一次(服务端徽章目录 financeAuditCenter 入口)。
//   · 刷新按钮/返回本页：递增 refreshTick 传给当前分段（分段页据此重拉列表），
//     并重拉徽章汇总(分段徽章与上级角标同源，ADR-108)。
//   · 旧队列路由（/finance/sales-order-confirmations 等）全部保留：通知深链与
//     其它模块入口仍直达具体队列，页面与本页分段共用同一组件（embedded 模式）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart';
import '../../sales/widgets/sales_shipment_task_workbench.dart';
import '../../warehouse/pages/finance_arrival_exception_pages.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../../../shared/drafts/review_task_draft.dart';
import 'finance_procurement_approval_tasks_page.dart';
import 'finance_sales_order_confirmation_page.dart';
import '../../../shared/badges/badge_registry.dart';

/// 一个大类分段（value + 标签 + 待办数；null = 加载中不显徽章）。
class _AuditSegment {
  const _AuditSegment({required this.value, required this.label, this.count});

  final String value;
  final String label;
  final int? count;
}

class FinanceAuditCenterPage extends ConsumerStatefulWidget {
  const FinanceAuditCenterPage({
    super.key,
    this.initialSegment,
    this.initialSalesState,
    this.initialProcurementStatus,
  });

  /// 深链直落某分段（?segment=xxx；无效值按未预选处理）。
  final String? initialSegment;
  final String? initialSalesState;
  final String? initialProcurementStatus;

  @override
  ConsumerState<FinanceAuditCenterPage> createState() =>
      _FinanceAuditCenterPageState();
}

class _FinanceAuditCenterPageState
    extends ConsumerState<FinanceAuditCenterPage> {
  String? _segment;
  int _refreshTick = 0;
  String? _myLocation;

  @override
  void initState() {
    super.initState();
    _segment = widget.initialSegment == 'salesChanges'
        ? 'salesConfirm'
        : widget.initialSegment;
  }

  void _refresh() {
    setState(() => _refreshTick++);
    refreshBadges(ref);
    ref.invalidate(salesOrderFinanceQueueCountProvider);
  }

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(context, RouteName.financeAudits);
    ref.onPageResume(_myLocation!, _refresh);

    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => superAdmin || permissions.contains(code);

    final canSales = can(Perm.salesOrderFinanceView);
    final canShipment = can(Perm.salesShipmentFinanceView);
    final canProcurement = can(Perm.financeOrderApprovalView);
    final canIqc = can(Perm.procurementIqcRejectionView);

    // 各队列待办数随工作台徽章汇总带回(ADR-108, 与业务审核中心卡同源)。
    int? fact(String key) => ref.watch(badgeFactOrNullProvider(key));
    final segments = <_AuditSegment>[
      if (canSales)
        _AuditSegment(
          value: 'salesConfirm',
          label: '销售订单确认',
          count: fact(BadgeFact.salesOrderFinance),
        ),
      if (canShipment)
        _AuditSegment(
          value: 'shipment',
          label: '出货审核',
          count: fact(BadgeFact.shipmentFinance),
        ),
      if (canProcurement)
        _AuditSegment(
          value: 'procurement',
          label: '订货审批',
          count: fact(BadgeFact.procurementApproval),
        ),
      if (canProcurement)
        _AuditSegment(
          value: 'arrival',
          label: '超量到货审批',
          count: fact(BadgeFact.financeArrivalException),
        ),
      if (canIqc)
        _AuditSegment(
          value: 'iqc',
          label: 'IQC 退回贷项',
          count: fact(BadgeFact.iqcRejectionOpen),
        ),
    ];

    return Scaffold(
      appBar: UtenAppBar(
        title: '业务审核中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            key: const Key('finance-audit-center-refresh'),
            tooltip: '刷新',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: segments.isEmpty
            ? const _NoAuditPermission()
            : UtenContentContainer.wide(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  // 大类行（2026-09-24 用户口径「表格滑到顶」）：选中分段后它随
                  // 正文一起进折叠头滚走；未选分段时仍钉在占位区上方。
                  child:
                      _segment == null ||
                          !segments.any((segment) => segment.value == _segment)
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _categoryBar(segments),
                            const SizedBox(height: UtenSpacing.s8),
                            const Expanded(child: _SegmentPlaceholder()),
                          ],
                        )
                      : _buildSegment(
                          _segment!,
                          externalHeader: _categoryBar(segments),
                        ),
                ),
              ),
      ),
    );
  }

  Widget _categoryBar(List<_AuditSegment> segments) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFilterToolbar<String>(
        segmentsKey: const Key('finance-audit-center-segments'),
        segments: [
          // 大类计数只有待办语义：各队列「等我审」之和 = hub 卡角标。
          for (final segment in segments)
            UtenFilterSegment(
              value: segment.value,
              label: segment.label,
              count: segment.count,
              countForm: UtenSegmentCountForm.actionable,
            ),
        ],
        selected: _segment == null ? const <String>{} : {_segment!},
        onSelectionChanged: (value) => setState(() => _segment = value),
      ),
      const TaskDraftRecoveryNotice(
        scope: FormDraftCategoryScope(
          module: BadgeModule.finance,
          routePrefixes: {
            '/finance/sales-order-confirmations/',
            '/finance/procurement-approvals/',
            '/finance/quote-review/',
            '/finance/sales-shipment-audits/',
          },
        ),
      ),
    ],
  );

  Widget _buildSegment(String value, {Widget? externalHeader}) =>
      switch (value) {
        'salesConfirm' => FinanceSalesOrderConfirmationPage(
          initialState:
              widget.initialSalesState ??
              (widget.initialSegment == 'salesChanges' ? 'changes' : null),
          embedded: true,
          refreshTick: _refreshTick,
          externalHeader: externalHeader,
        ),
        'shipment' => SalesShipmentTaskWorkbench(
          mode: SalesShipmentTaskWorkbenchMode.financeAudit,
          embedded: true,
          refreshTick: _refreshTick,
          externalHeader: externalHeader,
        ),
        'procurement' => FinanceProcurementApprovalTasksPage(
          initialStatus: widget.initialProcurementStatus,
          embedded: true,
          refreshTick: _refreshTick,
          externalHeader: externalHeader,
        ),
        'arrival' => FinanceArrivalExceptionTasksPage(
          embedded: true,
          refreshTick: _refreshTick,
          externalHeader: externalHeader,
        ),
        _ => ProcurementIqcRejectionListPage(
          source: 'finance',
          embedded: true,
          refreshTick: _refreshTick,
          externalHeader: externalHeader,
        ),
      };
}

/// 大类未选时的内容区占位：进页面不预选，引导先选分类。
class _SegmentPlaceholder extends StatelessWidget {
  const _SegmentPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '请先在上方选择分类',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text('在上方选择分类后开始审核', style: theme.textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '分段右侧数字徽章为该队列的待办数量',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoAuditPermission extends StatelessWidget {
  const _NoAuditPermission();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text('暂无已授权的审核队列，请联系财务主管开通。', style: theme.textTheme.bodyMedium),
    );
  }
}
