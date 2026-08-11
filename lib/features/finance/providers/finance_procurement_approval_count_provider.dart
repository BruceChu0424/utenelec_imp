import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 当前登录人自己的订货审批待办数。
///
/// 服务端必须再次按 assigneeUserId 过滤；前端权限判断只用于避免无权用户发请求。
final financeProcurementApprovalCountProvider = FutureProvider.autoDispose<int>(
  (ref) async {
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
  },
);
