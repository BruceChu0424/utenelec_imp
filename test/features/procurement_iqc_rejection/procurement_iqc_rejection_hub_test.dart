import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

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
      // 2026-09-01 合并：仓库 hub 只有「品质部检查结果」一张卡，任一仓库视图权限可见。
      await tester.pumpWidget(_app(const WarehouseHubPage(), const {}));
      await tester.pumpAndSettle();
      expect(find.text('品质部检查结果'), findsNothing);

      await tester.pumpWidget(
        _app(const WarehouseHubPage(), const {Perm.warehouseIqcReturnView}),
      );
      await tester.pumpAndSettle();
      expect(find.text('品质部检查结果'), findsOneWidget);

      // 只有拒收案件视图（财务/品质侧）不点亮仓库合并卡。
      await tester.pumpWidget(
        _app(const WarehouseHubPage(), const {
          Perm.procurementIqcRejectionView,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('品质部检查结果'), findsNothing);
    },
  );
}

Widget _app(Widget page, Set<String> permissions) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
    procurementIqcRejectionOpenCountProvider.overrideWith((ref) async => 2),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: page,
  ),
);
