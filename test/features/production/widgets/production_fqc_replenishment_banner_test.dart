import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/components/layout/uten_paged_picker_list.dart';
import 'package:uten_imp/features/production/models/production_fqc_replenishment_task.dart';
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
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;

import '../../../support/complete_read_plan_batches.dart';

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

  testWidgets(
    'material tasks complete a clamped scope before opening with zero scroll reads',
    (tester) async {
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
      // The first batch asks for the shared plan's first size; the clamped
      // server answers one task per page and the reader continues on exactly
      // that page size instead of skipping or re-reading rows.
      expect(api.requestedBatches, [
        completeReadPlanBatches(1).single,
        (page: 2, size: _ReplenishmentApi.clampedPageSize),
      ]);
      await tester.tap(find.text('处理待办'));
      await tester.pumpAndSettle();
      final finder = find.byKey(const Key('fqc-replenishment-task-list'));
      final list = tester
          .widget<UtenPagedPickerList<ProductionFqcReplenishmentMaterialTask>>(
            finder,
          );
      expect(list.items.map((row) => row.authorizationId), [
        'authorization-1',
        'authorization-2',
      ]);
      expect(list.rowsController!.visiblePage, 1);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      await _scrollTaskList(tester, toEnd: true);
      expect(find.textContaining('PLAN-2'), findsOneWidget);
      await _scrollTaskList(tester, toEnd: false);
      expect(find.textContaining('PLAN-1'), findsOneWidget);
      expect(api.requestedPages, [1, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '251 material tasks reach the tail on the progressive batch ladder and scroll locally',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ReplenishmentApi(
        status: 'AWAITING_CONFIRMATION',
        totalRows: 251,
      );
      final router = _router();
      addTearDown(router.dispose);
      await _pump(
        tester,
        api: api,
        router: router,
        permissions: const {Perm.productionFqcReplenishmentView},
      );
      expect(api.requestedBatches, completeReadPlanBatches(251));
      await tester.tap(find.text('处理待办'));
      await tester.pumpAndSettle();
      final list = tester
          .widget<UtenPagedPickerList<ProductionFqcReplenishmentMaterialTask>>(
            find.byKey(const Key('fqc-replenishment-task-list')),
          );
      expect(list.items, hasLength(251));
      expect(
        list.items.map((row) => row.authorizationId).toSet(),
        hasLength(251),
      );
      expect(list.items.last.authorizationId, 'authorization-251');
      await _scrollTaskList(tester, toEnd: true);
      expect(find.textContaining('PLAN-251'), findsOneWidget);
      await _scrollTaskList(tester, toEnd: false);
      expect(find.textContaining('PLAN-1'), findsWidgets);
      expect(api.requestedBatches, completeReadPlanBatches(251));
      expect(find.text('确认用料并生成领料'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'later task failure withdraws the progressive rows and retries the whole query from one',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ReplenishmentApi(
        status: 'AWAITING_CONFIRMATION',
        totalRows: 251,
        failFirstPageTwo: true,
        pageTwoGate: Completer<void>(),
      );
      final router = _router();
      addTearDown(router.dispose);
      final ladder = completeReadPlanBatches(251);
      await _pump(
        tester,
        api: api,
        router: router,
        permissions: const {Perm.productionFqcReplenishmentView},
      );
      for (var i = 0; i < 80 && api.requestedPages.length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(api.requestedBatches, ladder.take(2));
      // 2026-11-08 逐批追加：首批校验通过即展示行入口；待办计数（权威汇总）
      // 仍等完整结果，续批未到前不出现。
      expect(find.text('处理待办'), findsOneWidget);
      expect(find.textContaining('项仍需计划确认'), findsNothing);
      expect(find.textContaining('当前任务均已发料就绪'), findsNothing);
      expect(find.textContaining('PLAN-1'), findsNothing);
      api.pageTwoGate!.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      // The failed read takes its progressive rows down as a whole: only the
      // read failure with its retry remains, never a half list or a forged
      // "all ready" summary.
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('处理待办'), findsNothing);
      expect(find.textContaining('当前任务均已发料就绪'), findsNothing);
      api.pageTwoGate = Completer<void>();
      await tester.tap(find.text('重试'));
      for (var i = 0; i < 80 && api.requestedPages.length < 4; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      await tester.pump();
      expect(api.requestedBatches, [...ladder.take(2), ...ladder.take(2)]);
      // The retry grows its first batch again behind the busy overlay, which
      // stays up until the complete result arrives.
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(find.text('处理待办'), findsOneWidget);
      expect(find.text('处理待办').hitTestable(), findsNothing);
      expect(find.textContaining('项仍需计划确认'), findsNothing);
      api.pageTwoGate!.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('251 项仍需计划确认、补料或仓库发料；每一步按真实库存事实推进。'), findsOneWidget);
      await tester.tap(find.text('处理待办'));
      await tester.pumpAndSettle();
      final list = tester
          .widget<UtenPagedPickerList<ProductionFqcReplenishmentMaterialTask>>(
            find.byKey(const Key('fqc-replenishment-task-list')),
          );
      expect(
        list.items.map((row) => row.authorizationId).toSet(),
        hasLength(251),
      );
      expect(list.items.last.authorizationId, 'authorization-251');
      await _scrollTaskList(tester, toEnd: true);
      expect(find.textContaining('PLAN-251'), findsOneWidget);
      expect(api.requestedBatches, [...ladder.take(2), ...ladder]);
      expect(find.text('确认用料并生成领料'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task sheet opened while rows grow follows the complete result and a later failure',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final failing in [false, true]) {
        final api = _ReplenishmentApi(
          status: 'AWAITING_CONFIRMATION',
          totalRows: 251,
          failFirstPageTwo: failing,
          pageTwoGate: Completer<void>(),
        );
        final router = _router();
        await _pump(
          tester,
          api: api,
          router: router,
          permissions: const {Perm.productionFqcReplenishmentView},
        );
        for (var i = 0; i < 80 && api.requestedPages.length < 2; i++) {
          await tester.pump(const Duration(milliseconds: 5));
        }
        // The first validated batch already offers its rows.
        await tester.tap(find.text('处理待办'));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        UtenPagedPickerList<ProductionFqcReplenishmentMaterialTask> list() =>
            tester.widget(find.byKey(const Key('fqc-replenishment-task-list')));
        expect(
          list().items,
          hasLength(CompleteReadBatchPlan.progressive.firstBatchSize),
        );
        api.pageTwoGate!.complete();
        await tester.pump();
        await tester.pumpAndSettle();
        if (failing) {
          // The open sheet withdraws the progressive prefix with the read.
          expect(list().items, isEmpty);
          expect(list().error, isNotNull);
        } else {
          // The open sheet shows the complete result, not the first batch.
          expect(list().items, hasLength(251));
          expect(list().items.last.authorizationId, 'authorization-251');
        }
        expect(api.requestedBatches.first, completeReadPlanBatches(251).first);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      }
      expect(tester.takeException(), isNull);
    },
  );

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

Future<void> _scrollTaskList(WidgetTester tester, {required bool toEnd}) async {
  final list = find.byKey(const Key('fqc-replenishment-task-list'));
  final scrollable = find
      .descendant(of: list, matching: find.byType(Scrollable))
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  for (var i = 0; i < 3; i++) {
    position.jumpTo(
      toEnd ? position.maxScrollExtent : position.minScrollExtent,
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }
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
    this.totalRows,
    this.failFirstConfirmation = false,
    this.becomeReadyAfterFirstLoad = false,
    this.failFirstPageTwo = false,
    this.pageTwoGate,
  }) : super(Dio());

  /// A clamped scope ([pages] > 1) answers one task per page whatever size
  /// was requested; otherwise the server honors the requested batch up to
  /// its page maximum, like `Pageables.of`.
  static const clampedPageSize = 1;

  final String status;
  final int pages;
  final int? totalRows;
  final bool failFirstConfirmation;
  final bool becomeReadyAfterFirstLoad;
  final bool failFirstPageTwo;
  Completer<void>? pageTwoGate;
  bool _pageTwoFailed = false;
  String? createdAuthorizationId;
  int materialTaskLoads = 0;
  final List<int> requestedPages = [];
  final List<int> requestedSizes = [];
  final List<String> confirmationKeys = [];

  List<({int page, int size})> get requestedBatches => [
    for (var i = 0; i < requestedPages.length; i++)
      (page: requestedPages[i], size: requestedSizes[i]),
  ];

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
      'authorizationId': 'authorization-$page',
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
      return {'count': status == 'READY' ? 0 : totalRows ?? pages};
    }
    if (path.endsWith('/material-tasks')) {
      materialTaskLoads += 1;
      final page = (query?['page'] as num?)?.toInt() ?? 1;
      requestedPages.add(page);
      final requestedSize = (query?['size'] as num?)?.toInt() ?? 40;
      requestedSizes.add(requestedSize);
      final count = totalRows ?? pages;
      final size = pages > 1
          ? clampedPageSize
          : requestedSize.clamp(
              1,
              CompleteReadBatchPlan.progressive.maxBatchSize,
            );
      final start = (page - 1) * size;
      if (page == 2 && pageTwoGate != null) await pageTwoGate!.future;
      if (page == 2 && failFirstPageTwo && !_pageTwoFailed) {
        _pageTwoFailed = true;
        throw NetworkException();
      }
      return {
        'items': [
          for (var i = start; i < count && i < start + size; i++)
            materialTask(page: i + 1),
        ],
        'page': page,
        'size': size,
        'total': count,
        'totalPages': (count + size - 1) ~/ size,
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
