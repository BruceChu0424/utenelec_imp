import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 销售订货单待财务确认计数（V294 闸门徽标）。
///
/// 服务端按权限接口过滤；前端权限判断只用于避免无权用户发请求。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final salesOrderFinanceConfirmationCountProvider = FutureProvider<int>((
  ref,
) async {
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
