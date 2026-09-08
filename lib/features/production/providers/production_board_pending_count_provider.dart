import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_repository.dart';

/// 生产调度与进度页「待排产」大类的行数计数（大类行显示「待排产 N」纯数字，
/// 不是通知徽章；N = 待排产列表总行数，与列表同源——size=1 只取分页 total，
/// 不带关键词/排序/状态筛选，数字恒等于全量待排产行数）。
///
/// 只读轻量请求；无 `production_plan:view` 权限时不发请求、不显示数字。
/// 待排产列表每次加载完成后由面板 invalidate 本 provider 保持数字新鲜。
final productionBoardPendingCountProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  if (!ref
      .watch(currentPermissionsProvider)
      .contains(Perm.productionPlanView)) {
    return null;
  }
  final page = await ref
      .watch(productionPlanRepositoryProvider)
      .schedulePending(size: 1);
  return page.total;
});
