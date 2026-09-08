import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// 2026-09-05 起「进行中」= 计划统筹视角：双击批次直达物料分析页（不再弹滑窗、
// 不再看板直报）；子计划逐层下钻的导航合同保留在「历史记录」段的计划卡上。
void main() {
  testWidgets('production board child-plan row opens the child plan', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var progressReads = 0;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                Text('已打开计划 ${state.pathParameters['id']}'),
                FilledButton(
                  onPressed: () => context.pop(),
                  child: const Text('返回进度看板'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _repository(onProgressRead: () => progressReads++),
          ),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 历史记录段：先过时间门（全部）才加载已结案/历史计划卡。
    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();

    expect(find.text('SJ-PARENT'), findsOneWidget);
    await tester.tap(find.text('子计划 1 张(点开展示进度)'));
    await tester.pumpAndSettle();
    expect(find.text('SJ-CHILD'), findsOneWidget);
    await tester.tap(find.text('SJ-CHILD'));
    await tester.pumpAndSettle();

    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
    final readsBeforeReturn = progressReads;
    await tester.tap(find.text('返回进度看板'));
    await tester.pumpAndSettle();
    expect(progressReads, greaterThan(readsBeforeReturn));
  });

  testWidgets('compact board child-plan stays usable at 1.3 text scale', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    // 页面级容器为唯一 gutter（面板内层容器已移除），375px 紧凑布局回归验证。
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const ProductionBoardPage(),
        ),
        GoRoute(
          path: '/production/plans/:id',
          builder: (context, state) =>
              Scaffold(body: Text('已打开计划 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final root = find.text('SJ-PARENT');
    await tester.ensureVisible(root);
    expect(root.hitTestable(), findsOneWidget);
    // 1.3 倍字号下展开文案右缘可能溢出视口（按文本中心 tap 会落空），
    // 展开热区是整行 InkWell——点视口左侧的展开箭头图标即命中同一行。
    final expandToggle = find.byIcon(Icons.expand_more_rounded);
    await tester.ensureVisible(expandToggle);
    await tester.pumpAndSettle();
    await tester.tap(expandToggle, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('SJ-CHILD'), findsOneWidget);
    expect(find.text('物料待齐套(0/1 段)'), findsWidgets);
    final child = find.text('SJ-CHILD');
    await tester.ensureVisible(child);
    await tester.pumpAndSettle();
    await tester.tap(child, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('已打开计划 child-plan-1'), findsOneWidget);
  });

  testWidgets('ongoing double-click opens material analysis, no report entry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ProductionBoardPage(initialTab: 1),
        ),
        GoRoute(
          path: '/production/material-analysis',
          builder: (_, state) {
            final seed = state.extra is ProductionMaterialAnalysisSeed
                ? state.extra! as ProductionMaterialAnalysisSeed
                : const ProductionMaterialAnalysisSeed();
            return Scaffold(body: Text('analysis=${seed.analysisId}'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(_repository()),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _workbenchRepository(),
          ),
          // 车间报工三码俱全也不在看板出现报工入口（报工统一在车间任务页）。
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 看板不再提供报工入口与多选（数量摘要列仍会如实显示「报工 2」计数）。
    expect(find.text('报工'), findsNothing);
    expect(find.textContaining('批量报工'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('只看我的车间/负责工单'), findsNothing);
    await _doubleTapRow(tester, find.text('联合分析 SO-A / SO-B'));
    await tester.pumpAndSettle();

    expect(find.text('analysis=analysis-root-1'), findsOneWidget);
  });
}

Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

ProductionPlanRepository _repository({VoidCallback? onProgressRead}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/plans/progress') {
          onProgressRead?.call();
        }
        final data = switch (request.path) {
          '/production/plans/progress/summary' => {
            'count': 1,
            'sumQty': 10,
            'sumInbound': 0,
          },
          '/production/plans/progress/workshops' => <Map<String, dynamic>>[],
          '/production/plans/progress' => {
            'items': [
              {
                'planId': 'parent-plan-1',
                'billNo': 'SJ-PARENT',
                'lineCount': 1,
                'totalQty': 10,
                'inboundQty': 0,
                'materialState': 'PARTIAL',
                'materialSegmentCount': 2,
                'materialReadySegmentCount': 1,
                'materialTotalQty': 10,
                'materialReadyQty': 6,
                'materialPercent': 0.6,
                'canStartNow': true,
                'percent': 0,
                'closed': false,
                'subplans': [
                  {
                    'planId': 'child-plan-1',
                    'billNo': 'SJ-CHILD',
                    'status': 1,
                    'closed': false,
                    'totalQty': 5,
                    'reportedQty': 2,
                    'inboundQty': 1,
                    'materialState': 'WAITING',
                    'materialSegmentCount': 1,
                    'materialReadySegmentCount': 0,
                    'materialTotalQty': 5,
                    'materialReadyQty': 0,
                    'materialPercent': 0,
                    'canStartNow': false,
                    'percent': 0,
                  },
                ],
              },
            ],
            'page': 1,
            'size': 20,
            'total': 1,
            'totalPages': 1,
          },
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

ProductionExecutionWorkbenchRepository _workbenchRepository({
  VoidCallback? onRead,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        onRead?.call();
        final data = switch (request.path) {
          '/production/execution-workbench' => {
            'items': [_workbenchRootJson()],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          },
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}

Map<String, dynamic> _workbenchRootJson() => {
  'rootType': 'ANALYSIS',
  'rootId': 'analysis-root-1',
  'rootLabel': '联合分析 SO-A / SO-B',
  'status': 'PREPARING',
  'salesOrderPreview': 'SO-A / SO-B',
  'salesOrderCount': 2,
  'workOrderPreview': 'SEG-PARENT / SEG-CHILD',
  'workOrderCount': 2,
  'workshopPreview': '装配一车间',
  'workshopCount': 1,
  'productCodePreview': 'P-001 / C-001',
  'productNamePreview': '父产品 / 自制子件',
  'productColorPreview': '本色',
  'productCount': 2,
  'quantitySummary': '件: 计划 15 / 报工 2 / 实收 1',
  'executionUnitCount': 1,
  'planCount': 2,
  'segmentCount': 2,
  'waitingCount': 1,
  'readyCount': 1,
};
