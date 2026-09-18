import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('finance shipment auditor sees the merged audit center card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const FinanceHubPage(), const {Perm.financeShipmentAudit}),
    );
    await tester.pumpAndSettle();

    // 2026-09-18 合并：出货财务审核并入「业务审核中心」卡（页内分段），
    // 不再是独立卡；具体队列入口在审核中心分段里。
    expect(find.text('业务审核中心'), findsOneWidget);
    expect(find.text('出货财务审核'), findsNothing);
    expect(find.text('销售订单财务确认'), findsNothing);
  });

  testWidgets('warehouse shipment operator sees the dedicated outbound card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.salesShipmentWarehouseWork}),
    );
    await tester.pumpAndSettle();

    // 2026-09-01 重组：销售出库并入「出库任务中心」卡（页内分段），不再是独立卡。
    expect(find.text('出库任务中心'), findsOneWidget);
    expect(find.text('销售出库'), findsNothing);
    expect(find.text('入库任务中心'), findsNothing);
    expect(find.text('生产领料任务中心'), findsNothing);
    expect(find.text('委外出仓'), findsNothing);
  });
}

Widget _app(Widget page, Set<String> permissions) => ProviderScope(
  overrides: [
    sharedPreferencesProvider.overrideWithValue(_preferences),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: page,
  ),
);
