import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

const _pollInterval = Duration(seconds: 60);

final warehouseInboundExpectationCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      if (!_has(ref, Perm.warehouseInboundView)) return 0;
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(procurementInboundRepositoryProvider).expectationCount();
    });

final warehouseArrivalExceptionCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  if (!_has(ref, Perm.warehouseInboundView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref
      .watch(procurementInboundRepositoryProvider)
      .warehouseExceptionCount();
});

final financeArrivalExceptionCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  if (!_has(ref, Perm.financeOrderApprovalView)) return 0;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(procurementInboundRepositoryProvider).financeTaskCount();
});

final procurementArrivalReturnCountProvider = FutureProvider.autoDispose
    .family<int, ProcurementInboundOrderType>((ref, orderType) async {
      if (!_has(ref, Perm.supplierReturnTaskView)) return 0;
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(procurementInboundRepositoryProvider)
          .ownerTaskCount(orderType: orderType);
    });

/// 品质任务中心「待检处置」角标：仍有 PENDING/PARTIAL 明细的收货单张数（60s 轮询）。
final procurementInspectionPendingCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      if (!_has(ref, Perm.procurementInspectionView)) return 0;
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref.watch(procurementInspectionRepositoryProvider).pendingCount();
    });

bool _has(Ref ref, String permission) {
  return ref.watch(currentPermissionsProvider).contains(permission) ||
      ref.watch(isSuperAdminProvider);
}
