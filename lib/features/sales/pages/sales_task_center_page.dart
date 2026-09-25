// 销售任务中心（/sales/tasks）—— 2026-09-24 模块三段式统一的一站式查看入口。
//
// 职责（docs/01-规划/2026-09-24-模块三段式统一*.md）：销售模块所有单据与任务的
// **查看**集中于此（自己下的单 + 别人流转过来的单）；模块 hub 的「新建单据」区
// 只负责创建。本页大类：
//
//   订货进度（原「订单进度查询」整页能力：进行中/可发货/历史记录 + 六个小类）
//   出货单 / 客户零星发货 / 退货单 / 报价单（各=原列表页整页能力，嵌入态复用）
//   历史其它出货（只读历史）
//
// 徽章口径（准则 14）：
//   · 订货进度大类红数 = salesAttention（财务驳回 + 可分批发货，注册表入口），
//     黄数 = salesOrderInFlight（在途订单，注册表入口）——与 hub「销售任务中心」
//     卡角标同源同数。
//   · 出货/退货/报价大类红数 = 草稿 + 财务已退回（分段计数，读
//     documentStatusCountsProvider，**不进注册表**）；草稿是本人开了头没交出去的活
//     （红），财务已退回要本人改单重报（红）。客户零星发货刻意不挂——其草稿与
//     「出货单」同属 sales_shipments 同表，挂两处是同一批单数两遍（准则 14 §三）。
//   · 历史其它出货是只读历史，不挂数（准则 14 §二）。
//   · 各大类内的小类行计数与独立列表页完全同源（嵌入的是同一份页面代码）。
//
// 旧路由 /sales/progress 与 /sales/:seg 列表页保留（通知深链、新建页「草稿(N)」
// 按钮、行级跳转直达）。进页面不预选大类（未选显示引导空态，不发请求）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/document_status_counts_provider.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../models/sales_doc.dart';
import '../pages/sales_doc_list_page.dart';
import '../pages/sales_order_progress_page.dart';
import '../config/sales_doc_config.dart';

/// 一个大类分段（含待办/在办计数与可见性）。
class _GroupSpec {
  const _GroupSpec({
    required this.value,
    required this.label,
    this.count,
    this.inProgressCount,
  });

  final String value;
  final String label;
  final int? count;
  final int? inProgressCount;
}

class SalesTaskCenterPage extends ConsumerStatefulWidget {
  const SalesTaskCenterPage({super.key, this.initialGroup});

  /// 深链预设大类（?group=progress|shipments|...）。
  final String? initialGroup;

  @override
  ConsumerState<SalesTaskCenterPage> createState() =>
      _SalesTaskCenterPageState();
}

class _SalesTaskCenterPageState extends ConsumerState<SalesTaskCenterPage> {
  /// 当前选中大类；null = 未选择引导态（不发请求）。
  String? _group;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    // 大类可见性 = 对应列表/进度页的路由守卫（view 权限）。
    bool canOpen(String location) =>
        locationAllowedFor(perms, superAdmin, location);

    // 各单据大类的红数 = 草稿(+财务已退回)，与原 hub 单据卡徽章同口径同源
    //（documentStatusCounts 一次分桶；无权限返回空表 → 段不挂数）。
    final shipmentCounts = ref
        .watch(
          documentStatusCountsProvider(
            const DocumentStatusScope(DraftDocKind.salesShipment),
          ),
        )
        .valueOrNull;
    final quoteCounts = ref
        .watch(
          documentStatusCountsProvider(
            const DocumentStatusScope(DraftDocKind.salesQuote),
          ),
        )
        .valueOrNull;
    final returnCounts = ref
        .watch(
          documentStatusCountsProvider(
            const DocumentStatusScope(DraftDocKind.salesReturn),
          ),
        )
        .valueOrNull;
    int? sumCounts(Map<String, int>? counts, List<String> keys) {
      if (counts == null) return null;
      var total = 0;
      for (final key in keys) {
        total += counts[key] ?? 0;
      }
      return total;
    }

    final groups = <_GroupSpec>[
      if (canOpen(RouteName.salesOrderProgress))
        _GroupSpec(
          value: 'progress',
          label: '订货进度',
          count: ref.watch(badgeEntryTodoProvider(BadgeEntry.salesAttention)),
          inProgressCount: ref.watch(
            badgeEntryInProgressProvider(BadgeEntry.salesOrderInFlight),
          ),
        ),
      if (canOpen(SalesRoutePath.list('shipments')))
        _GroupSpec(
          value: 'shipments',
          label: '出货单',
          count: sumCounts(shipmentCounts, const [
            SalesShipmentStage.draft,
            SalesShipmentStage.financeRejected,
          ]),
        ),
      if (canOpen(SalesRoutePath.list('customer-shipments')))
        // 客户零星发货不挂数：草稿与「出货单」同表，出货大类已含这批单。
        const _GroupSpec(value: 'customerShipments', label: '客户零星发货'),
      if (canOpen(SalesRoutePath.list('returns')))
        _GroupSpec(
          value: 'returns',
          label: '退货单',
          count: sumCounts(returnCounts, const [DocumentStatusBucket.draft]),
        ),
      if (canOpen(SalesRoutePath.list('quotes')))
        _GroupSpec(
          value: 'quotes',
          label: '报价单',
          count: sumCounts(quoteCounts, const [DocumentStatusBucket.draft]),
        ),
      if (canOpen(SalesRoutePath.list('other-shipments')))
        const _GroupSpec(value: 'otherShipments', label: '历史其它出货'),
    ];

    if (groups.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('销售任务中心')),
        body: Center(
          child: Text('暂无已授权的销售页面，请联系主管开通。', style: theme.textTheme.bodyMedium),
        ),
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '销售任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.sales),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区（准则 §3.4）：进度徽章定时刷新与拖选并发有 CME 风险。
          selectable: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String>(
                  segmentsKey: const Key('sales-task-center-groups'),
                  segments: [
                    for (final g in groups)
                      UtenFilterSegment(
                        value: g.value,
                        label: g.label,
                        count: g.count,
                        // 大类红数 = 该类等本人动手的单（草稿/财务退回/驳回/可发货）；
                        // 浏览型大类（客户零星发货/历史其它出货）传 null。
                        countForm: UtenSegmentCountForm.actionable,
                        inProgressCount: g.inProgressCount,
                      ),
                  ],
                  selected: _group == null ? const <String>{} : {_group!},
                  onSelectionChanged: (value) => setState(() => _group = value),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: _group == null
                      ? const _GroupPlaceholder()
                      : _buildGroupBody(_group!),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 当前大类的正文：进度页与各单据列表页以嵌入态整体复用（小类行、搜索、
  /// 表格、行级办理动作与独立页完全一致）。
  Widget _buildGroupBody(String group) => switch (group) {
    'progress' => const SalesOrderProgressPage(embedded: true),
    'shipments' => const SalesDocListPage(
      docType: SalesDocType.shipment,
      embedded: true,
    ),
    'customerShipments' => const SalesDocListPage(
      docType: SalesDocType.customerShipment,
      embedded: true,
    ),
    'returns' => const SalesDocListPage(
      docType: SalesDocType.returnDoc,
      embedded: true,
    ),
    'quotes' => const SalesDocListPage(
      docType: SalesDocType.quote,
      embedded: true,
    ),
    // 历史其它出货：只读历史（进入即预选「历史记录」段，时间门控在段内）。
    _ => const SalesDocListPage(
      docType: SalesDocType.otherShipment,
      embedded: true,
      initialHistory: true,
    ),
  };
}

/// 大类未选时的内容区占位：进页面不预选，引导先选分类。
class _GroupPlaceholder extends StatelessWidget {
  const _GroupPlaceholder();

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
            Text('在上方选择分类后开始浏览', style: theme.textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '新建单据请回「销售管理」的新建单据区',
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
