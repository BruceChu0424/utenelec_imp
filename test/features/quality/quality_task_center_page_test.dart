import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/quality/pages/quality_task_center_page.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/production_fqc_pending_count_provider.dart';

void main() {
  test(
    'workbench keeps one quality hub and removes the legacy lab placeholder',
    () {
      final source = File(
        'lib/features/dashboard/widgets/workbench_module_area.dart',
      ).readAsStringSync();

      expect(source, isNot(contains("location: '/lab/test'")));
      expect(source, isNot(contains("label: '检测记录'")));
      expect(RegExp("label: '品质任务中心'").allMatches(source), hasLength(1));
    },
  );

  test('quality hub records card uses the real records route', () {
    final source = File(
      'lib/features/quality/pages/quality_task_center_page.dart',
    ).readAsStringSync();

    expect(source, contains('location: RouteName.qualityInspectionRecords'));
    expect(source, isNot(contains("location: '/lab/test'")));
  });

  test('records route is registered and guarded by either quality view', () {
    expect(
      requiredAnyPermFor(RouteName.qualityInspectionRecords),
      unorderedEquals([
        Perm.procurementInspectionView,
        Perm.productionQualityInspectionView,
      ]),
    );
    expect(requiredAllPermsFor(RouteName.qualityInspectionRecords), isEmpty);
    final router = File('lib/core/router/app_router.dart').readAsStringSync();
    expect(router, contains('path: RouteName.qualityInspectionRecords'));
    expect(router, contains("name: 'quality-inspection-records'"));
  });

  testWidgets('IQC-only permission shows the merged task and records entry', (
    tester,
  ) async {
    await _pumpTaskCenter(tester, {Perm.procurementInspectionView});

    expect(find.text('待检处置'), findsOneWidget);
    expect(find.text('生产成品质检'), findsNothing);
    expect(find.text('检测记录'), findsOneWidget);
    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('查询与记录'), findsOneWidget);
  });

  testWidgets('FQC-only permission still shows the merged task entry', (
    tester,
  ) async {
    await _pumpTaskCenter(tester, {Perm.productionQualityInspectionView});

    expect(find.text('待检处置'), findsOneWidget);
    expect(find.text('生产成品质检'), findsNothing);
    expect(find.text('检测记录'), findsOneWidget);
  });

  testWidgets(
    'both quality permissions show one merged task card and records entry',
    (tester) async {
      await _pumpTaskCenter(tester, {
        Perm.procurementInspectionView,
        Perm.productionQualityInspectionView,
      });

      expect(find.text('待检处置'), findsOneWidget);
      expect(find.text('生产成品质检'), findsNothing);
      expect(find.text('检测记录'), findsOneWidget);
      expect(find.textContaining('检测记录页仅供只读查询'), findsOneWidget);
      expect(find.textContaining('撤销历史会完整保留'), findsOneWidget);
    },
  );

  testWidgets('merged card badge sums IQC and FQC pending counts', (
    tester,
  ) async {
    await _pumpTaskCenter(tester, {
      Perm.procurementInspectionView,
      Perm.productionQualityInspectionView,
    }, iqcCount: 2, fqcCount: 3);

    // 红圆数字徽章显示两域合计；单域数字 2/3 不应独立出现。
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('no quality permission shows a locked empty state only', (
    tester,
  ) async {
    await _pumpTaskCenter(tester, const <String>{});

    expect(find.text('待检处置'), findsNothing);
    expect(find.text('生产成品质检'), findsNothing);
    expect(find.text('检测记录'), findsNothing);
    expect(find.text('任务中心'), findsNothing);
    expect(find.text('查询与记录'), findsNothing);
    expect(find.text('暂无已授权的品质页面'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });
}

Future<void> _pumpTaskCenter(
  WidgetTester tester,
  Set<String> permissions, {
  int iqcCount = 0,
  int fqcCount = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        procurementInspectionPendingCountProvider.overrideWith(
          (ref) async => iqcCount,
        ),
        productionFqcPendingCountProvider.overrideWith((ref) async => fqcCount),
      ],
      child: const MaterialApp(home: QualityTaskCenterPage()),
    ),
  );
  await tester.pumpAndSettle();
}
