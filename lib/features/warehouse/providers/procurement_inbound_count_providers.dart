import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
const _pollInterval = Duration(seconds: 60);

final warehouseInboundExpectationCountProvider = FutureProvider<int>((
  ref,
) async {
  if (!_has(ref, Perm.warehouseInboundView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(procurementInboundRepositoryProvider).expectationCount();
});

final warehouseArrivalExceptionCountProvider = FutureProvider<int>((ref) async {
  if (!_has(ref, Perm.warehouseInboundView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref
      .watch(procurementInboundRepositoryProvider)
      .warehouseExceptionCount();
});

/// 预计到货分来源计数（PURCHASE/SUBCONTRACT → count）：入库任务中心
/// 「采购入库 / 委外入库」分段徽章用（后端全量口径，60s 轮询）。
final warehouseInboundExpectationTypeCountsProvider =
    FutureProvider<Map<String, int>>((ref) async {
      if (!_has(ref, Perm.warehouseInboundView)) return const {};
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(procurementInboundRepositoryProvider)
          .expectationTypeCounts();
    });

final financeArrivalExceptionCountProvider = FutureProvider<int>((ref) async {
  if (!_has(ref, Perm.financeOrderApprovalView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(procurementInboundRepositoryProvider).financeTaskCount();
});

final procurementArrivalReturnCountProvider =
    FutureProvider.family<int, ProcurementInboundOrderType>((
      ref,
      orderType,
    ) async {
      if (!_has(ref, Perm.supplierReturnTaskView)) return 0;
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(procurementInboundRepositoryProvider)
          .ownerTaskCount(orderType: orderType);
    });

/// 品质任务中心「待检处置」角标：仍有 PENDING/PARTIAL 明细的收货单张数（60s 轮询）。
final procurementInspectionPendingCountProvider = FutureProvider<int>((
  ref,
) async {
  if (!_has(ref, Perm.procurementInspectionView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(procurementInspectionRepositoryProvider).pendingCount();
});

bool _has(Ref ref, String permission) {
  return ref.watch(currentPermissionsProvider).contains(permission) ||
      ref.watch(isSuperAdminProvider);
}
