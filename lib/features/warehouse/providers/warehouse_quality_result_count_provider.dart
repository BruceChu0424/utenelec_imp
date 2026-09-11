import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../repositories/warehouse_quality_result_repository.dart';

/// 品质部检查结果合并页角标（口径 = 轮到仓库动手：待入库 + 需退回；
/// 「等待检查结果」不计入——那一档在品质部手上，仓库点进去办不了事）。
/// 与页内父分类分段徽章、hub 卡、工作台仓库卡同源同口径。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final warehouseQualityResultPendingCountProvider = FutureProvider<int>((
  ref,
) async {
  final permissions = ref.watch(currentPermissionsProvider);
  final superAdmin = ref.watch(isSuperAdminProvider);
  final canView =
      superAdmin ||
      permissions.contains(Perm.warehouseIqcStockInView) ||
      permissions.contains(Perm.warehouseIqcReturnView);
  if (!canView) return 0;
  final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(warehouseQualityResultRepositoryProvider).pendingCount();
});

/// 父分类（来源类型）分段计数：各来源未完结任务数（页内大类徽章用；
/// 「父分类徽章 = 其子类待办之和」，此处即该来源全部未完结状态之和）。
final warehouseQualityResultTypeCountsProvider =
    FutureProvider<Map<WarehouseIqcStockInReceiptType, int>>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final superAdmin = ref.watch(isSuperAdminProvider);
      final canView =
          superAdmin ||
          permissions.contains(Perm.warehouseIqcStockInView) ||
          permissions.contains(Perm.warehouseIqcReturnView);
      if (!canView) {
        return const <WarehouseIqcStockInReceiptType, int>{};
      }
      final timer = Timer(const Duration(seconds: 60), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(warehouseQualityResultRepositoryProvider).typeCounts();
    });
