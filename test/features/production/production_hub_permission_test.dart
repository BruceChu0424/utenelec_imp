import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/features/production/production_routes.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  // 2026-09-11 起 hub 顶栏挂了「本模块待办累计」徽章，会 watch 生产的计数源，
  // 而那些 provider 走 sharedPreferencesProvider（页面偏好/上次筛选）。
  // 本文件只测权限显隐，给个空的桩即可，不然整页 build 直接抛
  // 「sharedPreferencesProvider must be overridden in main.dart」。
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });
  test('production hub accepts the where-used-only permission', () {
    expect(
      requiredAnyPermFor(RouteName.production),
      contains(Perm.productionWhereUsedView),
    );
  });

  test(
    'plan-create entry = analysis workbench: view gate + either create code',
    () {
      final route = productionRoutes.whereType<GoRoute>().singleWhere(
        (entry) => entry.path == RoutePath.productionPlanNew(),
      );

      // 2026-10-08 起新建生产计划单 = 物料分析工作台(planCreateEntry)：
      // 仍是直接 builder（无重定向）；任一创建码放行(analysis:create 或 plan:create)，
      // 但工作台首屏要读分析数据（仓库字典/联合分析），analysis:view 成为 all 门槛。
      expect(route.redirect, isNull);
      expect(route.builder, isNotNull);
      expect(
        requiredAnyPermFor(RoutePath.productionPlanNew()),
        equals([
          Perm.productionMaterialAnalysisCreate,
          Perm.productionPlanCreate,
        ]),
      );
      expect(
        requiredAllPermsFor(RoutePath.productionPlanNew()),
        equals([Perm.productionMaterialAnalysisView]),
      );
    },
  );

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
    expect(
      productionRoutes.whereType<GoRoute>().any(
        (entry) => entry.path == '/production/material-analyses/:id/summary',
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
          sharedPreferencesProvider.overrideWithValue(preferences),
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

  testWidgets(
    'view-only user sees no create cards (browsing moved to task center)',
    (tester) async {
      await _setDesktopSize(tester);
      await tester.pumpWidget(
        _hubApp(const {Perm.productionPlanView}, preferences),
      );
      await tester.pumpAndSettle();

      // 2026-09-24 三段式：计划浏览收进生产任务中心（调度台历史记录段），
      // hub 不再有「生产计划历史」回退卡；仅持计划查看权限的人看不到新建卡。
      expect(find.text('生产计划历史'), findsNothing);
      expect(find.text('新建生产计划单'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy edit without analysis manage cannot see the create card',
    (tester) async {
      await _setDesktopSize(tester);
      await tester.pumpWidget(
        _hubApp(const {
          Perm.productionPlanView,
          Perm.productionPlanEdit,
        }, preferences),
      );
      await tester.pumpAndSettle();

      expect(find.text('生产计划历史'), findsNothing);
      expect(find.text('新建生产计划单'), findsNothing);
    },
  );

  testWidgets('create code without analysis view hides the create card', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(
      _hubApp(const {
        Perm.productionPlanView,
        Perm.productionMaterialAnalysisCreate,
      }, preferences),
    );
    await tester.pumpAndSettle();

    // 2026-10-08 新建卡落点 = 物料分析工作台，首屏读分析数据：
    // all 契约要求 analysis:view，只有创建码（任一）而无 view 时卡片隐藏。
    expect(find.text('生产计划历史'), findsNothing);
    expect(find.text('新建生产计划单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan create code with analysis view sees the create card', (
    tester,
  ) async {
    await _setDesktopSize(tester);
    await tester.pumpWidget(
      _hubApp(const {
        Perm.productionMaterialAnalysisView,
        Perm.productionPlanCreate,
      }, preferences),
    );
    await tester.pumpAndSettle();

    // 对称用例：直接持 plan:create（不走 analysis:create）+ analysis:view，
    // any/all 双契约都满足，新建卡可见。
    expect(find.text('新建生产计划单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manage user opens the plan-create workbench', (tester) async {
    await _setDesktopSize(tester);
    // 自建桩路由：只验证「新建生产计划单」卡可点且落点是 /production/plans/new，
    // 与真实 builder（物料分析工作台）解耦，工作台自身行为另有页面测试覆盖。
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ProductionHubPage()),
        GoRoute(
          path: RoutePath.productionPlanNew(),
          builder: (_, _) => const Scaffold(body: Text('已进入新建计划')),
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
          sharedPreferencesProvider.overrideWithValue(preferences),
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

    expect(find.text('已进入新建计划'), findsOneWidget);
  });
}

Widget _hubApp(Set<String> permissions, SharedPreferences preferences) =>
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
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
