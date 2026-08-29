import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_fqc_replenishment_repository.dart';
import 'package:uten_imp/features/production/widgets/production_fqc_replenishment_banner.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('planning replenishment endpoint parses PageResponse', () async {
    final result = await ProductionFqcReplenishmentRepository(
      _ReplenishmentApi(status: 'AWAITING_ANALYSIS'),
    ).pending();

    expect(result.total, 1);
    expect(result.items.single.authorizationId, 'authorization-1');
  });

  testWidgets('375px planner creates recovery-only BOM analysis', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ReplenishmentApi(status: 'AWAITING_ANALYSIS');
    final router = _router();
    addTearDown(router.dispose);

    await _pump(
      tester,
      api: api,
      router: router,
      permissions: const {
        Perm.productionFqcReplenishmentView,
        Perm.productionFqcReplenishmentConfirm,
        Perm.productionMaterialAnalysisView,
        Perm.productionMaterialAnalysisCreate,
      },
    );

    expect(find.text('FQC 补产物料任务 1 项'), findsOneWidget);
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();
    expect(find.text('待建立分析'), findsOneWidget);
    expect(find.text('报废补产'), findsOneWidget);

    await tester.tap(find.text('建立补产 BOM 分析'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认建立'));
    await tester.pumpAndSettle();

    expect(api.createdAuthorizationId, 'authorization-1');
    expect(find.text('已进入补产分析 analysis-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view and confirm permissions remain separate', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await _pump(
      tester,
      api: _ReplenishmentApi(status: 'AWAITING_CONFIRMATION'),
      router: router,
      permissions: const {Perm.productionFqcReplenishmentView},
    );
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();

    expect(find.text('待确认用料'), findsOneWidget);
    expect(find.textContaining('当前只读'), findsOneWidget);
    expect(find.text('确认用料并生成领料'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server paging loads the requested material-task page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ReplenishmentApi(status: 'AWAITING_CONFIRMATION', pages: 2);
    final router = _router();
    addTearDown(router.dispose);

    await _pump(
      tester,
      api: api,
      router: router,
      permissions: const {Perm.productionFqcReplenishmentView},
    );
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PLAN-1'), findsOneWidget);

    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();

    expect(api.requestedPages, containsAllInOrder([1, 2]));
    expect(find.textContaining('PLAN-2'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ambiguous confirmation retry reuses the same idempotency key', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ReplenishmentApi(
      status: 'BLOCKED',
      failFirstConfirmation: true,
    );
    final router = _router();
    addTearDown(router.dispose);

    await _pump(
      tester,
      api: api,
      router: router,
      permissions: const {
        Perm.productionFqcReplenishmentView,
        Perm.productionFqcReplenishmentConfirm,
      },
    );
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();

    await _confirmRetry(tester);
    expect(api.confirmationKeys, hasLength(1));
    await _confirmRetry(tester);

    expect(api.confirmationKeys, hasLength(2));
    expect(api.confirmationKeys[1], api.confirmationKeys[0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from DRAW actively reloads the task state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ReplenishmentApi(
      status: 'AWAITING_WAREHOUSE',
      becomeReadyAfterFirstLoad: true,
    );
    final router = _router(includeDraw: true);
    addTearDown(router.dispose);

    await _pump(
      tester,
      api: api,
      router: router,
      permissions: const {
        Perm.productionFqcReplenishmentView,
        Perm.stockDocView,
        Perm.productionPlanView,
      },
    );
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('查看领料单'));
    await tester.pumpAndSettle();
    expect(find.text('领料单 DRAW-1'), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('处理待办'));
    await tester.pumpAndSettle();

    expect(api.materialTaskLoads, greaterThanOrEqualTo(2));
    expect(find.text('物料已发齐'), findsOneWidget);
    expect(find.text('进入生产计划补产报工'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required _ReplenishmentApi api,
  required GoRouter router,
  required Set<String> permissions,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionFqcReplenishmentRepositoryProvider.overrideWithValue(
          ProductionFqcReplenishmentRepository(api),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _confirmRetry(WidgetTester tester) async {
  await tester.tap(find.text('库存补齐后重试确认'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认重试'));
  await tester.pumpAndSettle();
}

GoRouter _router({bool includeDraw = false}) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(body: ProductionFqcReplenishmentBanner()),
    ),
    GoRoute(
      path: '/production/material-analysis',
      builder: (_, state) {
        final seed = state.extra! as ProductionMaterialAnalysisSeed;
        return Scaffold(body: Text('已进入补产分析 ${seed.analysisId}'));
      },
    ),
    if (includeDraw)
      GoRoute(
        path: '/warehouse/:code/:id',
        builder: (_, state) => Scaffold(
          body: Column(
            children: [
              Text('领料单 ${state.pathParameters['id']}'),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('返回'),
                ),
              ),
            ],
          ),
        ),
      ),
  ],
);

class _ReplenishmentApi extends ApiClient {
  _ReplenishmentApi({
    required this.status,
    this.pages = 1,
    this.failFirstConfirmation = false,
    this.becomeReadyAfterFirstLoad = false,
  }) : super(Dio());

  final String status;
  final int pages;
  final bool failFirstConfirmation;
  final bool becomeReadyAfterFirstLoad;
  String? createdAuthorizationId;
  int materialTaskLoads = 0;
  final List<int> requestedPages = [];
  final List<String> confirmationKeys = [];

  Map<String, dynamic> planningTask({String? analysisId}) => {
    'taskId': 'task-1',
    'authorizationId': 'authorization-1',
    'dispositionCode': 'SCRAP',
    'quantity': 2,
    'warehouseId': 'warehouse-1',
    'goodsId': 'goods-1',
    'goodsCode': 'V51043',
    'goodsName': '酸洗插套',
    'unitId': 'unit-1',
    'sourceInspectionId': 'inspection-1',
    'sourceReportItemId': 'report-item-1',
    'sourceReportNo': 'RB-001',
    'materialAnalysisId': analysisId,
    'materialAnalysisItemId': analysisId == null ? null : 'analysis-item-1',
  };

  Map<String, dynamic> materialTask({required int page, String? override}) {
    final effectiveStatus =
        override ??
        (becomeReadyAfterFirstLoad && materialTaskLoads > 1 ? 'READY' : status);
    return {
      'taskId': 'task-$page',
      'authorizationId': 'authorization-1',
      'dispositionCode': 'SCRAP',
      'quantity': 2,
      'warehouseId': 'warehouse-1',
      'sourcePlanItemId': 'plan-item-1',
      'executionSegmentId': 'segment-1',
      'planId': 'plan-1',
      'planNo': 'PLAN-$page',
      'reportMakerId': 'maker-1',
      'sourceReportNo': 'RB-001',
      'materialAnalysisId': effectiveStatus == 'AWAITING_ANALYSIS'
          ? null
          : 'analysis-1',
      'cycleId':
          effectiveStatus == 'AWAITING_ANALYSIS' ||
              effectiveStatus == 'AWAITING_CONFIRMATION'
          ? null
          : 'cycle-1',
      'drawId':
          effectiveStatus == 'AWAITING_WAREHOUSE' || effectiveStatus == 'READY'
          ? 'DRAW-1'
          : null,
      'drawNo':
          effectiveStatus == 'AWAITING_WAREHOUSE' || effectiveStatus == 'READY'
          ? 'DRAW-1'
          : null,
      'drawStatus': effectiveStatus == 'READY' ? 1 : 0,
      'drawIssueStatus': effectiveStatus == 'READY' ? 2 : 0,
      'status': effectiveStatus,
      'blockedReason': effectiveStatus == 'BLOCKED' ? 'V51012 库存不足 1' : null,
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/material-tasks/count')) {
      return {'count': status == 'READY' ? 0 : 1};
    }
    if (path.endsWith('/material-tasks')) {
      materialTaskLoads += 1;
      final page = (query?['page'] as num?)?.toInt() ?? 1;
      requestedPages.add(page);
      return {
        'items': [materialTask(page: page)],
        'page': page,
        'size': 40,
        'total': pages == 1 ? 1 : 41,
        'totalPages': pages,
      };
    }
    if (path.endsWith('/quality-replenishments')) {
      return {
        'items': [planningTask()],
        'page': 1,
        'size': 40,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path.endsWith('/material-analysis')) {
      createdAuthorizationId = 'authorization-1';
      return planningTask(analysisId: 'analysis-1');
    }
    if (path.endsWith('/material-confirmations')) {
      final key = (body! as Map<String, dynamic>)['idempotencyKey'] as String;
      confirmationKeys.add(key);
      if (failFirstConfirmation && confirmationKeys.length == 1) {
        throw NetworkException();
      }
      return materialTask(page: 1, override: 'AWAITING_WAREHOUSE');
    }
    return const {};
  }
}
