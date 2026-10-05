// 仓库任务计数(任务中心分段徽章 / hub 卡 / 工作台仓库卡角标)的统一刷新入口。
//
// 入口数与分段细数都随工作台徽章汇总一次带回(ADR-108), 且与列表同一服务端仓库范围(ADR-149):
// 任何仓库写操作(到货登记/送检、异常一键入库、产成品点收、销售出库交接、委外出仓、领料出入库等)
// 成功后调用 [invalidateWarehouseTaskCounts]，全站汇总单飞重拉一次；任务中心选了某个仓时,
// 按该仓汇总的那一份也一并重拉。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/badges/badge_registry.dart';
import '../../../shared/warehouse/warehouse_task_badges.dart';

/// 仓库写操作成功后(或任务中心返回时)调用：徽章汇总重拉 + 所选仓的汇总重拉。
/// 写请求本身已由网络层推进本端写修订号, 这里不必再记。
void invalidateWarehouseTaskCounts(WidgetRef ref) {
  refreshBadges(ref);
  invalidateSelectedWarehouseBadges(ref);
}
