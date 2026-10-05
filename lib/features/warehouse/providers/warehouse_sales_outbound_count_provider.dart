import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/warehouse_sales_outbound.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_badges.dart';

/// 销售出库仓库作业状态分组计数(出库任务中心「销售出库」小类行: 待出库红徽章 /
/// 已出库中性括号数)。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /warehouse/sales-outbound/counts 同一读范围),
/// 不单独轮询; hub 卡与工作台仓库卡的待办数由服务端目录(warehouseOutboundCenter 入口)
/// 算好。与列表同一服务端仓库范围(ADR-149, 任务中心选了仓 = 按所选仓汇总)。
/// 仓库写操作成功后经 invalidateWarehouseTaskCounts 触发汇总重拉。
/// 汇总还没到或当前身份无权时为 null(分段不渲染数字, 不把未知伪装成 0)。
final warehouseSalesOutboundCountsProvider =
    Provider.autoDispose<WarehouseSalesOutboundCounts?>((ref) {
      if (!ref.watch(
        warehouseTaskSourceGrantedProvider('warehouseSalesOutbound'),
      )) {
        return null;
      }
      final summary = ref.watch(warehouseTaskBadgesProvider);
      return WarehouseSalesOutboundCounts(
        pendingPick: summary.fact(BadgeFact.warehouseSalesOutboundPendingPick),
        legacyPending: summary.fact(
          BadgeFact.warehouseSalesOutboundLegacyPending,
        ),
        shipped: summary.fact(BadgeFact.warehouseSalesOutboundShipped),
      );
    });
