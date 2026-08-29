import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality task center exposes IQC and production FQC queues', () {
    final taskCenter = File(
      'lib/features/quality/pages/quality_task_center_page.dart',
    ).readAsStringSync();
    final permissionRoutes = File(
      'lib/core/router/permission_by_path.dart',
    ).readAsStringSync();
    final badge = File(
      'lib/features/dashboard/widgets/module_badge_sum.dart',
    ).readAsStringSync();

    expect(taskCenter, contains('ProductionFqcPendingBadge'));
    expect(taskCenter, contains('productionFqcInspections'));
    expect(permissionRoutes, contains('Perm.productionQualityInspectionView'));
    expect(badge, contains('productionFqcPendingCountProvider'));
  });
}
