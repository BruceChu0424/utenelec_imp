import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/features/production/production_routes.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('production hub accepts the where-used-only permission', () {
    expect(
      requiredAnyPermFor(RouteName.production),
      contains(Perm.productionWhereUsedView),
    );
  });

  test('legacy new-plan route redirects instead of opening the old editor', () {
    final route = productionRoutes.whereType<GoRoute>().singleWhere(
      (entry) => entry.path == RoutePath.productionPlanNew(),
    );

    expect(route.redirect, isNotNull);
    expect(
      requiredAnyPermFor(RoutePath.productionPlanNew()),
      equals([Perm.productionMaterialAnalysisCreate]),
    );
  });

  test('material analysis history route requires view only', () {
    expect(
      requiredAnyPermFor(RouteName.productionMaterialAnalysisHistory),
      equals([Perm.productionMaterialAnalysisView]),
    );
    expect(
      productionRoutes.whereType<GoRoute>().any(
        (entry) => entry.path == RouteName.productionMaterialAnalysisHistory,
      ),
      isTrue,
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
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: ProductionHubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('物料反查产成品'), findsOneWidget);
    expect(find.text('生产调度与进度'), findsNothing);
    expect(find.text('新建生产计划单'), findsNothing);
    expect(find.text('生产日报表'), findsNothing);
    expect(find.text('计划明细'), findsNothing);
    expect(find.text('计划汇总'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view-only user keeps a visible history entry', (tester) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(_hubApp(const {Perm.productionPlanView}));
    await tester.pumpAndSettle();

    expect(find.text('生产计划历史'), findsOneWidget);
    expect(find.text('新建生产计划单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy edit without analysis manage also stays on history', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(
      _hubApp(const {Perm.productionPlanView, Perm.productionPlanEdit}),
    );
    await tester.pumpAndSettle();

    expect(find.text('生产计划历史'), findsOneWidget);
    expect(find.text('新建生产计划单'), findsNothing);
  });

  testWidgets('manage user opens the independent new-analysis page', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ProductionHubPage()),
        GoRoute(
          path: RouteName.productionMaterialAnalysis,
          builder: (_, _) => const Scaffold(body: Text('已进入新建物料分析')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionMaterialAnalysisCreate,
            Perm.productionMaterialAnalysisView,
          }),
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

    await tester.tap(find.text('新建生产计划单'));
    await tester.pumpAndSettle();

    expect(find.text('已进入新建物料分析'), findsOneWidget);
  });
}

Widget _hubApp(Set<String> permissions) => ProviderScope(
  overrides: [currentPermissionsProvider.overrideWithValue(permissions)],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale('zh'),
    home: ProductionHubPage(),
  ),
);

Future<void> _setDesktopSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
