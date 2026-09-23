// 生产部待排产数量(工作台「生产管理」卡片红色数字徽章用)。
//
// 口径 = 调度工作台待排产行数：已审订单行的**待排产缺口 > 0**
// (= 剩余未排量 − 活动物料分析已承接量，ADR-088 的 PENDING_NEED_SQL)。
// 服务端徽标 SQL 与列表/facets 共用同一份 WHERE，数字与点进去看到的行数不会漂移。
// 随工作台徽章汇总一次带回(ADR-108, 原端点 /production/schedule/pending-count 同一口径),
// 不单独轮询; 无 production_plan:view 权限时为 0(不渲染徽章)。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/badges/badge_registry.dart';

/// 生产待排产计数（count=待排产行数，urgent=其中 ≤3 天/含逾期行数，overdue=已逾期行数）。
class ProductionPendingCount {
  const ProductionPendingCount(this.count, this.urgent, [this.overdue = 0]);
  final int count;
  final int urgent;
  final int overdue;

  @override
  bool operator ==(Object other) =>
      other is ProductionPendingCount &&
      other.count == count &&
      other.urgent == urgent &&
      other.overdue == overdue;

  @override
  int get hashCode => Object.hash(count, urgent, overdue);
}

/// 待排产计数(取自徽章汇总)。
final productionPendingCountProvider = Provider<ProductionPendingCount>((ref) {
  return ProductionPendingCount(
    ref.watch(badgeFactProvider(BadgeFact.productionScheduleCount)),
    ref.watch(badgeFactProvider(BadgeFact.productionScheduleUrgent)),
    ref.watch(badgeFactProvider(BadgeFact.productionScheduleOverdue)),
  );
});
