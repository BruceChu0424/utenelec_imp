import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_execution_workbench_repository.dart';

/// 生产调度与进度页「进行中」大类的批次计数（大类行显示「进行中 N」纯数字，
/// 不是通知徽章；N = 进行中的最外层分析/根计划批次数，与进行中列表同源）。
///
/// 只取 size=1 的分页 total，属轻量只读请求；无 `production_execution:overview`
/// 权限（含从 /production/schedule 深链进入的纯调度账号）时不发请求、不显示数字。
/// 进行中列表每次加载完成后由面板 invalidate 本 provider 保持数字新鲜。
final productionExecutionGroupCountProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  if (!ref
      .watch(currentPermissionsProvider)
      .contains(Perm.productionExecutionOverview)) {
    return null;
  }
  final page = await ref
      .watch(productionExecutionWorkbenchRepositoryProvider)
      .groups(size: 1);
  return page.total;
});
