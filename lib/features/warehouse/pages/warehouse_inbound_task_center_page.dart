import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/route_names.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_badges.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/warehouse_task_center_repository.dart';
import '../widgets/warehouse_task_center_scaffold.dart';
import '../widgets/warehouse_task_records_view.dart';

/// A source row below the warehouse direction. Lifecycle choices live in the table.
class WarehouseInboundTaskCenterPage extends ConsumerWidget {
  const WarehouseInboundTaskCenterPage({
    super.key,
    this.embedded = false,
    this.externalKeyword,
    this.externalRefreshTick,
    this.externalHeader,
    this.initialSection,
  });
  final bool embedded;
  final String? externalKeyword;
  final int? externalRefreshTick;
  final Widget? externalHeader;
  final String? initialSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool can(String code) => superAdmin || permissions.contains(code);
    final canArrival = can(Perm.warehouseInboundView);
    final canQuality = locationAllowedFor(
      permissions,
      superAdmin,
      RouteName.warehouseQualityResults,
    );
    final canStock = can(Perm.stockDocView);
    final canWorkshop = can(Perm.workshopMaterialView);
    int? fact(String key) => ref.watch(warehouseTaskFactOrNullProvider(key));
    int? sum(int? a, int? b) => a == null || b == null ? null : a + b;
    final sources = <String, String>{
      if (canArrival ||
          canQuality ||
          can(Perm.warehousePurchaseReceiptHistoryView))
        'PURCHASE': '采购入库',
      if (canArrival ||
          canQuality ||
          can(Perm.warehouseSubcontractReceiptHistoryView))
        'SUBCONTRACT': '委外入库',
      if (canStock) 'FINISHED': '产成品入库',
      if (canStock) 'OTHER': '其它入库',
      if (canStock || canWorkshop) 'RETURN': '生产退料',
    };
    if (sources.isEmpty) return const Center(child: Text('暂无已授权的入库单据'));
    final segments = <WarehouseTaskSegmentSpec>[
      for (final entry in sources.entries)
        WarehouseTaskSegmentSpec(
          value: entry.key,
          label: entry.value,
          count: switch (entry.key) {
            'PURCHASE' when canArrival => sum(
              fact(BadgeFact.warehouseInboundExpectationPurchase),
              fact(BadgeFact.warehouseArrivalExceptionPurchase),
            ),
            'SUBCONTRACT' when canArrival => sum(
              fact(BadgeFact.warehouseInboundExpectationSubcontract),
              fact(BadgeFact.warehouseArrivalExceptionSubcontract),
            ),
            'FINISHED' => fact(BadgeFact.finishedInbound),
            'RETURN' => sum(
              canStock ? fact(BadgeFact.productionReturn) : 0,
              canWorkshop ? fact(BadgeFact.workshopMaterialPendingReturn) : 0,
            ),
            _ => null,
          },
        ),
      const WarehouseTaskSegmentSpec(value: 'ALL', label: '全部任务'),
      const WarehouseTaskSegmentSpec(value: 'HISTORY', label: '历史单据'),
    ];
    final initial = switch (initialSection) {
      'purchase' => 'PURCHASE',
      'subcontract' => 'SUBCONTRACT',
      'finishedIn' => 'FINISHED',
      'otherIn' => 'OTHER',
      'wdraw' || 'productionReturn' => 'RETURN',
      'history' || 'HISTORY' => 'HISTORY',
      final String value when sources.containsKey(value) || value == 'ALL' =>
        value,
      _ => null,
    };
    return WarehouseTaskCenterScaffold(
      location: RouteName.warehouseInboundTasks,
      title: '入库任务中心',
      searchHint: '搜索单号 / 供应商 / 委外商 / 货品',
      segments: segments,
      initialSegment: initial,
      embedded: embedded,
      externalKeyword: externalKeyword,
      externalRefreshTick: externalRefreshTick,
      externalHeader: externalHeader,
      onResume: () => invalidateWarehouseTaskCounts(ref),
      bodyBuilder: (source, keyword, refresh, header) =>
          WarehouseTaskRecordsView(
            key: ValueKey(('inbound', source)),
            direction: WarehouseTaskDirection.inbound,
            source: source == 'HISTORY' ? 'ALL' : source,
            view: source == 'HISTORY'
                ? WarehouseTaskView.history
                : WarehouseTaskView.active,
            sources: sources,
            keyword: keyword,
            refreshTick: refresh,
            externalHeader: header,
          ),
    );
  }
}
