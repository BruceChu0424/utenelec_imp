import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 当前登录人自己的订货审批待办数。
///
/// 服务端必须再次按 assigneeUserId 过滤；前端权限判断只用于避免无权用户发请求。
// 徽章计数 provider 一律**常驻**（不 autoDispose）——2026-09-11 用户反馈：
// 仓库/品质的徽章「进页面要等一会才出现」「冒出来又消失又冒出来」，而采购点进去就有。
// 差别不在后端快慢，在生命周期：采购是常驻 StateNotifier，这些是 autoDispose，
// 离开页面即销毁、回来从零 loading，而 todo_badge_registry 把 loading 记成 0。
// 常驻后 invalidateSelf 刷新期间 AsyncValue 会带住旧值（见 registry 的 valueOrNull），
// 徽章不再闪；没人看时定时器不再续期，也不会空转发请求。
final financeProcurementApprovalCountProvider = FutureProvider<int>((
  ref,
) async {
  final permissions = ref.watch(currentPermissionsProvider);
  final allowed =
      permissions.contains(Perm.financeOrderApprovalView) ||
      ref.watch(isSuperAdminProvider);
  if (!allowed) return 0;

  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref
      .watch(financeProcurementWorkflowRepositoryProvider)
      .pendingApprovalCount();
});
