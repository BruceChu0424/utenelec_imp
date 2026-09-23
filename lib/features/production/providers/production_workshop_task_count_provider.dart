import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/production_execution_workbench_repository.dart';
import '../../../shared/badges/badge_registry.dart';

/// 车间任务分段计数(与顶部分类互斥口径一致)：总数 + 备料中(等待物料) + 生产中。
///
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /production/workshop-tasks/count 同一口径),
/// 不单独轮询; 红徽章 = 等待物料、黄徽章 = 生产中由服务端目录算好, 本 provider 只给
/// 「我的车间任务」页的分类徽章用。
final productionWorkshopTaskCountProvider =
    Provider<WorkshopTaskCountBreakdown>((ref) {
      return WorkshopTaskCountBreakdown(
        count: ref.watch(badgeFactProvider(BadgeFact.workshopTotal)),
        preparing: ref.watch(badgeFactProvider(BadgeFact.workshopPreparing)),
        inProgress: ref.watch(badgeFactProvider(BadgeFact.workshopInProgress)),
      );
    });
