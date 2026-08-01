import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('production hub accepts the where-used-only permission', () {
    expect(
      requiredAnyPermFor(RouteName.production),
      contains(Perm.productionWhereUsedView),
    );
  });

  testWidgets('where-used-only user sees only the where-used production card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionWhereUsedView,
          }),
        ],
        child: const MaterialApp(home: ProductionHubPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('物料反查产成品'), findsOneWidget);
    expect(find.text('生产调度与进度'), findsNothing);
    expect(find.text('生产计划单'), findsNothing);
    expect(find.text('生产日报表'), findsNothing);
    expect(find.text('计划明细'), findsNothing);
    expect(find.text('计划汇总'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
