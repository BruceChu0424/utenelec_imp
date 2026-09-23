import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';

/// 生产调度与进度页「进行中」大类行的批次计数(N = 进行中的最外层分析/根计划
/// 批次数，与进行中列表同源)。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /production/execution-workbench/count),
/// 与「生产管理」卡的黄色在办数同一个数; 不单独请求。无
/// `production_execution:overview` 权限(含从 /production/schedule 深链进入的纯调度账号)
/// 时返回 null——未知不伪装成 0，徽章同样不渲染。
final productionExecutionGroupCountProvider = Provider<int?>((ref) {
  if (!ref
      .watch(currentPermissionsProvider)
      .contains(Perm.productionExecutionOverview)) {
    return null;
  }
  return ref.watch(badgeFactProvider(BadgeFact.productionExecution));
});
