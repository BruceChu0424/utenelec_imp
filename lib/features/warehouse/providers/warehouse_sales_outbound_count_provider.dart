import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/warehouse_sales_outbound.dart';
import '../../../shared/badges/badge_registry.dart';

/// 销售出库仓库作业状态分组计数(出库任务中心「销售出库」小类行: 待出库红徽章 /
/// 已出库中性括号数)。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /warehouse/sales-outbound/counts 同一读范围),
/// 不单独轮询; hub 卡与工作台仓库卡的待办数由服务端目录(warehouseOutboundCenter 入口)
/// 算好。仓库写操作成功后经 invalidateWarehouseTaskCounts 触发汇总重拉。
/// 汇总还没到或当前身份无权时为 null(分段不渲染数字, 不把未知伪装成 0)。
final warehouseSalesOutboundCountsProvider =
    Provider<WarehouseSalesOutboundCounts?>((ref) {
      if (!ref.watch(badgeSourceGrantedProvider('warehouseSalesOutbound'))) {
        return null;
      }
      return WarehouseSalesOutboundCounts(
        pendingPick: ref.watch(
          badgeFactProvider(BadgeFact.warehouseSalesOutboundPendingPick),
        ),
        legacyPending: ref.watch(
          badgeFactProvider(BadgeFact.warehouseSalesOutboundLegacyPending),
        ),
        shipped: ref.watch(
          badgeFactProvider(BadgeFact.warehouseSalesOutboundShipped),
        ),
      );
    });
