import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';

/// 销售出库仓库作业状态分组计数(出库任务中心「销售出库」小类行: 待出库红徽章 /
/// 已出库中性括号数; 父分类与 hub 卡的待办数由它派生), 与仓库销售出库列表同一读范围;
/// 60s 轮询 + 仓库写操作成功/返回任务中心时由 invalidateWarehouseTaskCounts 主动失效重拉.
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final warehouseSalesOutboundCountsProvider =
    FutureProvider<WarehouseSalesOutboundCounts>((ref) async {
      if (!_hasSalesOutboundWork(ref)) {
        return const WarehouseSalesOutboundCounts();
      }
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(warehouseSalesOutboundRepositoryProvider).counts();
    });

/// 销售出库待办计数(出库任务中心父分类 / hub 卡 / 工作台仓库卡角标) = 待出库张数.
///
/// 由 [warehouseSalesOutboundCountsProvider] 派生(同一次请求, 不另发), 因此**失效要打在
/// 源头**: 写 `ref.invalidate(warehouseSalesOutboundCountsProvider)`(或统一入口
/// invalidateWarehouseTaskCounts); 单独失效本 provider 只会拿回缓存的分组计数, 不会重拉
/// (warehouse_count_refresh_contract_test 扫源码拦这种写法).
final warehouseSalesOutboundPendingCountProvider = FutureProvider<int>((
  ref,
) async {
  final counts = await ref.watch(warehouseSalesOutboundCountsProvider.future);
  return counts.pendingPick;
});

bool _hasSalesOutboundWork(Ref ref) {
  return ref
          .watch(currentPermissionsProvider)
          .contains(Perm.salesShipmentWarehouseWork) ||
      ref.watch(isSuperAdminProvider);
}
