import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('finance shipment auditor sees the dedicated task card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const FinanceHubPage(), const {Perm.financeShipmentAudit}),
    );
    await tester.pumpAndSettle();

    expect(find.text('出货财务审核'), findsOneWidget);
    expect(find.text('销售订单财务确认'), findsNothing);
  });

  testWidgets('warehouse shipment operator sees the dedicated outbound card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.salesShipmentWarehouseWork}),
    );
    await tester.pumpAndSettle();

    expect(find.text('销售出库'), findsOneWidget);
    expect(find.text('委外出仓'), findsNothing);
  });
}

Widget _app(Widget page, Set<String> permissions) => ProviderScope(
  overrides: [
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
