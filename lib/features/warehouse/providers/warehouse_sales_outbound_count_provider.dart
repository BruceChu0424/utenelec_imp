import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';

/// 销售出库待办计数（出库任务中心分段/汇总角标）：未交接出库的财务放行单，
/// 与仓库销售出库列表同一读范围；60s 轮询 + 返回任务中心时由页面主动失效重拉。
final warehouseSalesOutboundPendingCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      if (!_hasSalesOutboundWork(ref)) return 0;
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(warehouseSalesOutboundRepositoryProvider).pendingCount();
    });

bool _hasSalesOutboundWork(Ref ref) {
  return ref
          .watch(currentPermissionsProvider)
          .contains(Perm.salesShipmentWarehouseWork) ||
      ref.watch(isSuperAdminProvider);
}
