import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/warehouse_quality_result.dart';
import '../repositories/warehouse_quality_result_repository.dart';

/// 品质部检查结果合并页三个数字(红徽章 / 黄徽章 / 页内来源大类分段)唯一的服务端来源。
///
/// actionable = 轮到仓库动手(待入库 + 部分合格 + 需退回);
/// inProgress = 等待检查结果(货已收、结论在品质部手上, 仓库不用动手)。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
//
// 红黄两支改由本支派生(不再各发各的请求): 卡面数字与页内分段从此同源,
// 「卡面 = 各分段之和」由结构保证而不是靠人工对账 —— 两支各走一个端点、
// 口径各自演化, 正是黄色 2 在大类行上蒸发那个 bug 的根因。
final warehouseQualityResultTypeCountsProvider =
    FutureProvider<WarehouseQualityTypeCounts>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      final canView =
          superAdmin ||
          permissions.contains(Perm.warehouseIqcStockInView) ||
          permissions.contains(Perm.warehouseIqcReturnView);
      if (!canView) return WarehouseQualityTypeCounts.empty;
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(warehouseQualityResultRepositoryProvider).typeCounts();
    });

/// 红徽章: 轮到仓库动手的任务数(待入库 + 部分合格 + 需退回, 全来源之和)。
/// 「等待检查结果」球在品质部手上, 2026-09-11 起不计入(后端同口径)。
///
/// 由 [warehouseQualityResultTypeCountsProvider] 派生, **失效要打在源头**;
/// 单独失效本 provider 只会拿回缓存的计数, 不会重拉。
final warehouseQualityResultPendingCountProvider = Provider<AsyncValue<int>>(
  (ref) => _derive(
    ref.watch(warehouseQualityResultTypeCountsProvider),
    (counts) => counts.actionableTotal,
  ),
);

/// 黄徽章: 「等待检查结果」数(进行中, ADR-100)。
///
/// 货已收、等品质部出结论: 还在流程里没结束, 但仓库此刻办不了事, 所以既不进
/// 红徽章也不是中性括号。同样由上面那支派生, 失效打在源头。
final warehouseQualityResultWaitingCountProvider = Provider<AsyncValue<int>>(
  (ref) => _derive(
    ref.watch(warehouseQualityResultTypeCountsProvider),
    (counts) => counts.inProgressTotal,
  ),
);

/// 取两条徽章链要的那一半。**刷新期间必须保住旧值**(准则 §四之三), 所以取值走
/// valueOrNull 而不是 whenData。
///
/// 两者的差别只在一条路上, 但那条路真的会走到: invalidate / refresh 触发的重算是
/// isRefresh, 源头回来的是 AsyncData(isLoading: true), whenData 的 data 分支照样
/// 命中, 旧值不丢; 而依赖重建(本支 watch 的权限集变了)回来的是带 hasValue 的
/// AsyncLoading, whenData 走 loading 分支、返回裸 AsyncLoading, 上一次的数当场丢掉,
/// 徽章闪一次 0。valueOrNull 两条路都取得到, 所以统一用它。
/// 依据: riverpod 2.6.1 common.dart 的 whenData 与 AsyncLoading.copyWithPrevious。
AsyncValue<int> _derive(
  AsyncValue<WarehouseQualityTypeCounts> source,
  int Function(WarehouseQualityTypeCounts) pick,
) {
  final value = source.valueOrNull;
  if (value != null) return AsyncData(pick(value));
  final error = source.error;
  if (error != null) {
    return AsyncError(error, source.stackTrace ?? StackTrace.empty);
  }
  return const AsyncLoading();
}
