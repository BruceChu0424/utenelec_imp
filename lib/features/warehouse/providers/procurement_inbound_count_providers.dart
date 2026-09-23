import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/procurement_inbound_repository.dart';

// 预计到货 / 到货异常 / 超量到货财务审批 / 待退回供应商 / IQC 待检的入口数随工作台徽章汇总
// 一次带回(ADR-108), 读 badgeEntryTodoProvider / badgeFactProvider; 这里只剩入库任务中心
// 页内「采购入库 / 委外入库」两个分段要的分来源计数。

/// 预计到货分来源计数（PURCHASE/SUBCONTRACT → count）：入库任务中心
/// 「采购入库 / 委外入库」分段徽章用(后端全量口径)。
///
/// 页内专用、autoDispose: 只在入库任务中心打开期间存活, 不再自带 60s 轮询;
/// 仓库写操作成功后由 invalidateWarehouseTaskCounts 失效重拉。
final warehouseInboundExpectationTypeCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
      if (!ref
              .watch(currentPermissionsProvider)
              .contains(Perm.warehouseInboundView) &&
          !ref.watch(isSuperAdminProvider)) {
        return const {};
      }
      return ref
          .watch(procurementInboundRepositoryProvider)
          .expectationTypeCounts();
    });
