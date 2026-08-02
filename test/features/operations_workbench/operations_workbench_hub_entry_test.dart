import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';

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
        child: MaterialApp.router(routerConfig: router),
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
        child: MaterialApp.router(routerConfig: router),
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('委外任务中心'), findsOneWidget);
    expect(find.textContaining('按委外商分解为订货单'), findsOneWidget);
    await tester.tap(find.text('委外任务中心'));
    await tester.pumpAndSettle();

    expect(find.text('委外工作台已打开'), findsOneWidget);
    _expectCurrentLocation(
      router,
      RouteName.operationsSubcontractWorkbench,
      RouteName.subcontract,
    );
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
