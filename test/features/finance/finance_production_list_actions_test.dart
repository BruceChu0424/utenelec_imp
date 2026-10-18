import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_document_lifecycle_filter.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_list_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

typedef _ListCase = ({
  String name,
  String route,
  String createKey,
  Widget page,
  Set<String> permissions,
});

final _cases = <_ListCase>[
  for (final type in FinanceDocType.values)
    (
      name: 'finance ${type.name}',
      route: '/finance/${type.pathSegment}',
      createKey: 'finance-doc-list-create',
      page: FinanceDocListPage(docType: type),
      permissions: {
        FinanceDocConfig.by(type).listPerm,
        FinanceDocConfig.by(type).createPerm!,
        FinanceDocConfig.by(type).deletePerm!,
      },
    ),
  (
    name: 'production plan',
    route: '/production/plans',
    createKey: 'production-plan-list-create',
    page: const ProductionPlanListPage(),
    permissions: {
      Perm.productionPlanView,
      Perm.productionPlanApprove,
      Perm.productionPlanDelete,
      Perm.productionMaterialAnalysisCreate,
    },
  ),
  (
    name: 'production daily report',
    route: '/production/daily-reports',
    createKey: 'production-daily-list-create',
    page: const ProductionDailyReportListPage(),
    permissions: {
      Perm.productionDailyReportView,
      Perm.productionDailyReportCreate,
      Perm.productionDailyReportDelete,
    },
  ),
];

void main() {
  for (final entry in _cases) {
    testWidgets('${entry.name} keeps one create action below the list', (
      tester,
    ) async {
      await _pump(tester, entry);
      final create = find.byKey(Key(entry.createKey));
      expect(create, findsOneWidget);
      expect(
        find.ancestor(
          of: create,
          matching: find.byType(UtenFloatingActionGroup),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: create, matching: find.byType(UtenAppBar)),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byType(UtenDocumentLifecycleFilter)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(UtenAppBar)).dy),
      );
      expect(
        find.textContaining(RegExp(r'^(收款|付款|费用|收入|转账|计划单|日报) \(')),
        findsNothing,
      );

      await tester.tap(find.text('草稿').first);
      await tester.pumpAndSettle();
      expect(create, findsOneWidget, reason: '草稿分类的新建与批量动作共用唯一悬浮组');
      final createGroup = find.ancestor(
        of: create,
        matching: find.byType(UtenFloatingActionGroup),
      );
      expect(createGroup, findsOneWidget);
      expect(
        find.descendant(of: createGroup, matching: find.textContaining('删除')),
        findsWidgets,
      );
      expect(
        tester
            .widget<Scaffold>(find.byType(Scaffold).first)
            .floatingActionButton,
        isNull,
      );

      await tester.tap(find.text('历史单据').first);
      await tester.pumpAndSettle();
      expect(create, findsOneWidget, reason: '历史只读不剥夺新建当前单据的权限');
      expect(tester.getCenter(create).dy, greaterThan(500));
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.text('new destination'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in [_cases.first, _cases[5], _cases[6]]) {
    testWidgets(
      '${entry.name} create follows permission at narrow large text',
      (tester) async {
        await _pump(tester, entry, narrow: true, permissions: const {});
        expect(find.byKey(Key(entry.createKey)), findsNothing);
        expect(find.text('超产比例审批'), findsNothing);
        expect(find.text('超限产出处置'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('plan review actions belong to the app bar', (tester) async {
    await _pump(tester, _cases[5]);
    for (final label in ['超产比例审批', '超限产出处置']) {
      expect(
        find.descendant(
          of: find.byType(UtenAppBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final (entry, page, createPermission) in [
    (
      _cases[5],
      const ProductionPlanListPage(embedded: true, initialStatus: 'draft'),
      Perm.productionMaterialAnalysisCreate,
    ),
    (
      _cases[6],
      const ProductionDailyReportListPage(
        embedded: true,
        initialStatus: 'draft',
      ),
      Perm.productionDailyReportCreate,
    ),
  ]) {
    testWidgets(
      '${entry.name} embedded create-only user keeps right-bottom action',
      (tester) async {
        await _pump(
          tester,
          entry,
          narrow: true,
          page: Scaffold(body: page),
          permissions: {createPermission},
        );
        final create = find.byKey(Key(entry.createKey));
        expect(create, findsOneWidget);
        expect(find.byType(UtenAppBar), findsNothing);
        expect(tester.getCenter(create).dy, greaterThan(500));
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(find.text('new destination'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _ListCase entry, {
  bool narrow = false,
  Set<String>? permissions,
  Widget? page,
}) async {
  await tester.binding.setSurfaceSize(
    narrow ? const Size(390, 844) : const Size(1500, 1000),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: entry.route,
    routes: [
      GoRoute(path: entry.route, builder: (_, _) => page ?? entry.page),
      GoRoute(
        path: '${entry.route}/new',
        builder: (_, _) => const Scaffold(body: Text('new destination')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(_ListApi()),
        currentPermissionsProvider.overrideWithValue(
          permissions ?? entry.permissions,
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(narrow ? 1.4 : 1)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ListApi extends ApiClient {
  _ListApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('status-counts')) return {'DRAFT': 0};
    if (path.contains('facets')) return {'facets': <String, Object>{}};
    return {'items': <Object>[], 'page': 1, 'total': 0, 'totalPages': 1};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
