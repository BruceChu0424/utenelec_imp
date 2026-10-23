import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_badges.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_task_center_repository.dart';
import '../widgets/warehouse_task_center_scaffold.dart';
import '../widgets/warehouse_task_records_view.dart';

class WarehouseOutboundTaskCenterPage extends ConsumerWidget {
  const WarehouseOutboundTaskCenterPage({
    super.key,
    this.embedded = false,
    this.externalKeyword,
    this.externalRefreshTick,
    this.externalHeader,
    this.initialSection,
    this.initialView,
  });
  final bool embedded;
  final String? externalKeyword;
  final int? externalRefreshTick;
  final Widget? externalHeader;
  final String? initialSection;
  final String? initialView;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => superAdmin || permissions.contains(code);
    final canStock = can(Perm.stockDocView);
    final canWorkshop = can(Perm.workshopMaterialView);
    int? fact(String key) => ref.watch(warehouseTaskFactOrNullProvider(key));
    final sources = <String, String>{
      if (can(Perm.warehouseSalesOutboundView)) 'SALES': '销售出库',
      if (can(Perm.subcontractOutboundView) ||
          can(Perm.warehouseSubcontractOutboundHistoryView))
        'SUBCONTRACT': '委外出库',
      if (canStock || canWorkshop) 'DRAW': '生产领料',
      if (canStock) 'OTHER': '其它出库',
      if (canStock) 'FINISHED': '产成品出库',
    };
    if (sources.isEmpty) return const Center(child: Text('暂无已授权的出库单据'));
    final segments = <WarehouseTaskSegmentSpec>[
      for (final entry in sources.entries)
        WarehouseTaskSegmentSpec(
          value: entry.key,
          label: entry.value,
          count: switch (entry.key) {
            'SALES' => fact(BadgeFact.warehouseSalesOutboundPendingPick),
            'SUBCONTRACT' => fact(BadgeFact.subcontractOutbound),
            'DRAW' => _sumAuthorized([
              if (canStock) fact(BadgeFact.productionDraw),
              if (canWorkshop) fact(BadgeFact.workshopMaterialPendingIssue),
            ]),
            _ => null,
          },
        ),
      const WarehouseTaskSegmentSpec(value: 'ALL', label: '全部任务'),
      const WarehouseTaskSegmentSpec(value: 'HISTORY', label: '历史单据'),
    ];
    final initial = switch (initialSection) {
      'sales' => 'SALES',
      'subcontract' => 'SUBCONTRACT',
      'draw' || 'pending' => 'DRAW',
      'otherOut' => 'OTHER',
      'finishedOut' => 'FINISHED',
      'history' || 'HISTORY' => 'HISTORY',
      final String value when sources.containsKey(value) || value == 'ALL' =>
        value,
      _ => null,
    };
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseOutboundTasks,
      title: '出库任务中心',
      searchHint: '搜索单号 / 客户 / 委外商 / 货品',
      segments: segments,
      initialSegment: initial,
      embedded: embedded,
      externalKeyword: externalKeyword,
      externalRefreshTick: externalRefreshTick,
      externalHeader: externalHeader,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      trailingBuilder: !can(Perm.workshopMaterialIssue)
          ? null
          : (source) => source != 'DRAW'
                ? const SizedBox.shrink()
                : UtenButton(
                    icon: Icons.local_shipping_outlined,
                    onPressed: () async {
                      await context.push(
                        RoutePath.workshopMaterialDirectIssue(),
                      );
                      if (context.mounted) invalidateWarehouseTaskCounts(ref);
                    },
                    child: const Text('直接发料'),
                  ),
      bodyBuilder: (source, keyword, refresh, header) =>
          WarehouseTaskRecordsView(
            key: ValueKey(('outbound', source)),
            direction: WarehouseTaskDirection.outbound,
            source: source == 'HISTORY' ? 'ALL' : source,
            view: source == 'HISTORY'
                ? WarehouseTaskView.history
                : WarehouseTaskView.active,
            sources: sources,
            initialStatus: source == 'SUBCONTRACT' && initialView == 'tasks'
                ? 'SUBCONTRACT_PENDING'
                : null,
            keyword: keyword,
            refreshTick: refresh,
            externalHeader: header,
          ),
    );
  }
}

int? _sumAuthorized(List<int?> counts) => counts.any((count) => count == null)
    ? null
    : counts.fold<int>(0, (sum, count) => sum + count!);
