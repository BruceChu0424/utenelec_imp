import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('purchase task center card opens its workbench', (tester) async {
    final router = _router(
      hubPath: RouteName.purchase,
      hub: const PurchaseHubPage(),
      workbenchPath: RouteName.operationsPurchaseWorkbench,
      destinationLabel: '采购工作台已打开',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.purchaseRequestView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('采购任务中心'), findsOneWidget);
    await tester.tap(find.text('采购任务中心'));
    await tester.pumpAndSettle();

    expect(find.text('采购工作台已打开'), findsOneWidget);
    _expectCurrentLocation(
      router,
      RouteName.operationsPurchaseWorkbench,
      RouteName.purchase,
    );
  });

  testWidgets('warehouse task center card opens its workbench', (tester) async {
    final router = _router(
      hubPath: RouteName.warehouse,
      hub: const WarehouseHubPage(),
      workbenchPath: RouteName.operationsWarehouseWorkbench,
      destinationLabel: '仓库工作台已打开',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({Perm.stockDocView}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('生产领料任务中心'), findsOneWidget);
    await tester.tap(find.text('生产领料任务中心'));
    await tester.pumpAndSettle();

    expect(find.text('仓库工作台已打开'), findsOneWidget);
    _expectCurrentLocation(
      router,
      RouteName.operationsWarehouseWorkbench,
      RouteName.warehouse,
    );
  });

  testWidgets('subcontract task center card opens its workbench', (
    tester,
  ) async {
    final router = _router(
      hubPath: RouteName.subcontract,
      hub: const SubcontractHubPage(),
      workbenchPath: RouteName.operationsSubcontractWorkbench,
      destinationLabel: '委外工作台已打开',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.subcontractApplicationView,
            Perm.subcontractPreparationView,
            Perm.subcontractOrderView,
            Perm.subcontractOrderCreate,
            Perm.subcontractOutboundView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('委外任务中心'), findsOneWidget);
    expect(find.textContaining('按委外商拆订货'), findsOneWidget);
    expect(find.text('两种下单入口'), findsNothing);
    expect(find.text('直接委外下单'), findsNothing);
    expect(find.text('计划委外申请(只读)'), findsNothing);
    expect(find.text('委外前置自制'), findsNothing);
    expect(find.text('仓库目标件出仓'), findsNothing);
    expect(find.text('委外订货与全链路'), findsOneWidget);
    await tester.tap(find.text('委外任务中心'));
    await tester.pumpAndSettle();

    expect(find.text('委外工作台已打开'), findsOneWidget);
    _expectCurrentLocation(
      router,
      RouteName.operationsSubcontractWorkbench,
      RouteName.subcontract,
    );
  });

  testWidgets('warehouse task center is hidden without its permission', (
    tester,
  ) async {
    final router = _router(
      hubPath: RouteName.warehouse,
      hub: const WarehouseHubPage(),
      workbenchPath: RouteName.operationsWarehouseWorkbench,
      destinationLabel: '仓库工作台已打开',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsNothing);
    expect(find.text('生产领料任务中心'), findsNothing);
  });

  testWidgets('subcontract task center is hidden without its permission', (
    tester,
  ) async {
    final router = _router(
      hubPath: RouteName.subcontract,
      hub: const SubcontractHubPage(),
      workbenchPath: RouteName.operationsSubcontractWorkbench,
      destinationLabel: '委外工作台已打开',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsNothing);
    expect(find.text('委外任务中心'), findsNothing);
  });
}

GoRouter _router({
  required String hubPath,
  required Widget hub,
  required String workbenchPath,
  required String destinationLabel,
}) {
  return GoRouter(
    initialLocation: hubPath,
    routes: [
      GoRoute(path: hubPath, builder: (_, _) => hub),
      GoRoute(
        path: workbenchPath,
        builder: (_, _) => Scaffold(body: Text(destinationLabel)),
      ),
    ],
  );
}

void _expectCurrentLocation(
  GoRouter router,
  String expectedPath,
  String expectedReturnTo,
) {
  final uri = router.routeInformationProvider.value.uri;
  expect(uri.path, expectedPath);
  expect(uri.queryParameters['returnTo'], expectedReturnTo);
}
