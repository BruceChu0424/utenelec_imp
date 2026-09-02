import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality task center exposes the merged IQC+FQC disposal queue', () {
    final taskCenter = File(
      'lib/features/quality/pages/quality_task_center_page.dart',
    ).readAsStringSync();
    final disposal = File(
      'lib/features/quality/pages/quality_pending_disposal_page.dart',
    ).readAsStringSync();
    final permissionRoutes = File(
      'lib/core/router/permission_by_path.dart',
    ).readAsStringSync();
    final badge = File(
      'lib/features/dashboard/widgets/module_badge_sum.dart',
    ).readAsStringSync();

    // 任务中心只剩一张合并卡：角标 = IQC + FQC 合计，去向待检处置页。
    expect(taskCenter, contains('_QualityDisposalPendingBadge'));
    expect(taskCenter, contains('RouteName.warehouseInspections'));
    expect(taskCenter, isNot(contains('productionFqcInspections')));
    // 待检处置页承载 FQC 队列：分段含「自制产成品」，读 FQC 仓库。
    expect(disposal, contains('自制产成品'));
    expect(disposal, contains('productionFqcRepositoryProvider'));
    expect(permissionRoutes, contains('Perm.productionQualityInspectionView'));
    expect(badge, contains('productionFqcPendingCountProvider'));
  });
}
