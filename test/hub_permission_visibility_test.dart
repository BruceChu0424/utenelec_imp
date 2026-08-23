import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Widget _app(Widget page, Set<String> permissions) {
  return ProviderScope(
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
}

void main() {
  testWidgets('purchase hub hides every page without its view permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const PurchaseHubPage(), const {Perm.purchaseRequestView}),
    );
    await tester.pump();

    expect(find.text('计划下达的采购申请'), findsOneWidget);
    expect(find.text('采购订货单'), findsNothing);
    expect(find.text('采购收货单'), findsNothing);
    expect(find.text('采购退货单'), findsNothing);
  });

  testWidgets('warehouse hub filters native documents, queries and reports', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockView}),
    );
    await tester.pump();

    expect(find.text('即时库存'), findsOneWidget);
    expect(find.text('库存查询'), findsNWidgets(2));
    expect(find.text('调拨单'), findsNothing);
    expect(find.text('采购收货单'), findsNothing);
  });
}
