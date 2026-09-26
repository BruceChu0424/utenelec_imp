import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('finance hub shows IQC credit task only with exact view', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const FinanceHubPage(), const {}));
    await tester.pumpAndSettle();
    expect(find.text('业务审核中心'), findsNothing);

    // 2026-09-18 合并：IQC 退回队列并入「业务审核中心」卡（页内分段）。
    await tester.pumpWidget(
      _app(const FinanceHubPage(), const {Perm.procurementIqcRejectionView}),
    );
    await tester.pumpAndSettle();
    expect(find.text('业务审核中心'), findsOneWidget);
    expect(find.text('IQC 不合格退回与贷项'), findsNothing);
    expect(find.text('订货审批任务'), findsNothing);
  });

  testWidgets(
    'warehouse merged card covers return view, rejection-only not shown',
    (tester) async {
      // 2026-09-24 仓库任务中心合并：hub 只有一张「仓库任务中心」卡（品质检查
      // 结果并入合并页大类），任一仓库视图权限可见。
      await tester.pumpWidget(_app(const WarehouseHubPage(), const {}));
      await tester.pumpAndSettle();
      expect(find.text('仓库任务中心'), findsNothing);

      await tester.pumpWidget(
        _app(const WarehouseHubPage(), const {Perm.warehouseIqcReturnView}),
      );
      await tester.pumpAndSettle();
      expect(find.text('仓库任务中心'), findsOneWidget);

      // 只有拒收案件视图（财务/品质侧）不点亮仓库合并卡。
      await tester.pumpWidget(
        _app(const WarehouseHubPage(), const {
          Perm.procurementIqcRejectionView,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('仓库任务中心'), findsNothing);
    },
  );
}

Widget _app(Widget page, Set<String> permissions) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
    fixedBadgeSummaryOverride(
      badgeSummaryFixture(facts: {BadgeFact.iqcRejectionOpen: 2}),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: page,
  ),
);
