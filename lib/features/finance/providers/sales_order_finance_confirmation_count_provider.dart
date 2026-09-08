import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 销售订货单待财务确认计数（V294 闸门徽标）。
///
/// 服务端按权限接口过滤；前端权限判断只用于避免无权用户发请求。
final salesOrderFinanceConfirmationCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final allowed =
          permissions.contains(Perm.salesOrderFinanceView) ||
          ref.watch(isSuperAdminProvider);
      if (!allowed) return 0;

      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return ref
          .watch(salesOrderFinanceConfirmationRepositoryProvider)
          .pendingCount();
    });

/// Queue badges follow the same refresh generation as the total badge. They
/// mount only inside the finance hub and do not add to the global task total.
final salesOrderFinanceQueueCountProvider = FutureProvider.autoDispose
    .family<int, bool>((ref, changesOnly) async {
      final permissions = ref.watch(currentPermissionsProvider);
      final allowed =
          permissions.contains(Perm.salesOrderFinanceView) ||
          ref.watch(isSuperAdminProvider);
      if (!allowed) return 0;
      final repository = ref.watch(
        salesOrderFinanceConfirmationRepositoryProvider,
      );
      var disposed = false;
      ref.onDispose(() => disposed = true);
      await ref.watch(salesOrderFinanceConfirmationCountProvider.future);
      if (disposed) return 0;
      return repository.pendingCount(changesOnly: changesOnly);
    });
