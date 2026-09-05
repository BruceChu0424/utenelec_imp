import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_segments_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('execution segment model decodes warehouse issue progress', () {
    final segment = ProductionExecutionSegmentView.fromJson(
      _segmentJson(
        status: 'DISPATCHED',
        materialDemandCount: 3,
        materialIssued: false,
      ),
    );

    expect(segment.materialDemandCount, 3);
    expect(segment.fullyIssuedDemandCount, 2);
    expect(segment.materialIssued, isFalse);
  });

  testWidgets('empty execution result stays neutral and offers refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var reads = 0;

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'READY',
          empty: true,
          onRead: () => reads++,
        ),
        permissions: const {},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('production-execution-segments-empty')),
      findsOneWidget,
    );
    expect(find.text('执行子计划'), findsOneWidget);
    expect(find.textContaining('当前尚未形成执行子计划'), findsOneWidget);
    expect(find.textContaining('物料分析准备'), findsOneWidget);
    expect(find.textContaining('补 BOM'), findsNothing);
    expect(find.text('刷新执行状态'), findsOneWidget);
    expect(reads, 1);

    await tester.tap(find.text('刷新执行状态'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row tap opens execution segment details for read-only users', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('操作已直接显示在卡片上'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
    expect(find.text('成品灯 · P-001'), findsWidgets);
    expect(find.text('当前账号可查看详情，但没有生产操作权限。'), findsOneWidget);
    expect(find.text('调整分配'), findsNothing);
    expect(find.text('派工'), findsNothing);
    expect(find.textContaining('可开工'), findsNothing);
    expect(find.text('备料完毕·可报工'), findsWidgets);
  });

  testWidgets('detail shows only actions allowed by status and permission', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {Perm.productionExecutionAssign},
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('production-execution-assign-segment-1')),
      findsOneWidget,
    );
    expect(find.text('派工'), findsNothing);
    expect(find.text('确认开工'), findsNothing);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('调整分配'), findsOneWidget);
    expect(find.text('派工'), findsNothing);
    expect(find.text('分批报工'), findsNothing);
  });

  testWidgets('legacy dispatch permission does not expose retired actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {Perm.productionExecutionDispatch},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('派工'), findsNothing);
    expect(find.text('确认开工'), findsNothing);
    expect(find.text('调整分配'), findsNothing);
  });

  testWidgets(
    'report action requires daily report view and create permissions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          repository: _repository(status: 'IN_PROGRESS'),
          permissions: const {Perm.productionDailyReportEdit},
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('production-execution-report-segment-1')),
        findsNothing,
      );
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();
      expect(find.text('分批报工'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _app(
          repository: _repository(status: 'IN_PROGRESS'),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('production-execution-report-segment-1')),
        findsOneWidget,
      );
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();
      expect(find.text('分批报工'), findsOneWidget);
    },
  );

  testWidgets('fully reported segment waits for FQC without report action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'IN_PROGRESS',
          reportedQty: 10,
          remainingQty: 0,
          ordinaryRemainingQty: 0,
          fqcPendingQty: 10,
        ),
        permissions: const {
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已报完·待品质'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();
    expect(find.text('分批报工'), findsNothing);
    expect(find.text('待检 10'), findsWidgets);
    expect(find.textContaining('待品质判定 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all-zero warehouse rejection shows a redelivery task without report action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          repository: _repository(
            status: 'IN_PROGRESS',
            reportedQty: 10,
            remainingQty: 0,
            ordinaryRemainingQty: 0,
            fqcPassedQty: 10,
            finishedInboundPendingQty: 10,
            finishedInboundRejectedQty: 10,
          ),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('仓库拒收·待重新交付'), findsOneWidget);
      expect(find.textContaining('通过 10'), findsOneWidget);
      expect(find.textContaining('PASS'), findsNothing);
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();
      expect(find.text('分批报工'), findsNothing);
      expect(find.textContaining('仓库拒收 10'), findsWidgets);
      expect(find.textContaining('已保留同源重新交付任务'), findsOneWidget);
      expect(find.textContaining('待仓库点收 10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary remaining keeps normal reporting primary before replacement lot',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          repository: _repository(
            status: 'IN_PROGRESS',
            reportedQty: 4,
            remainingQty: 6,
            ordinaryRemainingQty: 5,
            fqcPassedQty: 4,
            fqcFailedQty: 1,
            fqcRecoveryAvailableQty: 1,
            fqcReplacementAvailableQty: 1,
          ),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('生产中·可继续报工'), findsOneWidget);
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();
      expect(find.text('分批报工'), findsOneWidget);
      expect(find.text('补产完工报工'), findsNothing);
      expect(find.textContaining('报废/拒收补产待齐套 1'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('REWORK authorization exposes explicit reinspection reporting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'IN_PROGRESS',
          reportedQty: 8,
          remainingQty: 2,
          ordinaryRemainingQty: 0,
          fqcFailedQty: 2,
          fqcRecoveryAvailableQty: 2,
          fqcReworkAvailableQty: 2,
        ),
        permissions: const {
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('返工再检·待报工'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();
    expect(find.text('返工再检报工'), findsOneWidget);
    expect(find.textContaining('返工再检待报 2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SCRAP replacement stays blocked from ordinary reporting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'IN_PROGRESS',
          reportedQty: 8,
          remainingQty: 2,
          ordinaryRemainingQty: 0,
          fqcFailedQty: 2,
          fqcRecoveryAvailableQty: 2,
          fqcReplacementAvailableQty: 2,
        ),
        permissions: const {
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('补产待齐套/发料'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();
    expect(find.text('分批报工'), findsNothing);
    expect(find.textContaining('等待重新齐套和发料后才能报工'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('V415 material-ready replacement enables explicit reporting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'IN_PROGRESS',
          reportedQty: 8,
          remainingQty: 2,
          ordinaryRemainingQty: 0,
          fqcFailedQty: 2,
          fqcRecoveryAvailableQty: 2,
          fqcReplacementAvailableQty: 2,
          fqcReplacementReadyQty: 2,
        ),
        permissions: const {
          Perm.productionDailyReportView,
          Perm.productionDailyReportCreate,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('补产物料已发·待报工'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();
    expect(find.text('补产完工报工'), findsOneWidget);
    expect(find.textContaining('补产物料已发待报 2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual defer can be released and rechecked', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RequestOptions? command;

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'WAITING',
          autoPromoteWhenReady: false,
          onCommand: (request) => command = request,
        ),
        permissions: const {Perm.productionExecutionReleaseDefer},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('人工暂缓'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('production-execution-release-segment-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认解除'));
    await tester.pumpAndSettle();

    expect(command?.path, endsWith('/release-defer'));
    expect(command?.data, containsPair('expectedVersion', 1));
  });

  testWidgets('execution-segment deep link opens one detail dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
        initialSegmentId: 'segment-1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
  });

  testWidgets(
    'fully issued confirmed segments expose direct report without start controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          repository: _repository(status: 'READY'),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('production-execution-start-selection-toolbar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('production-execution-report-segment-1')),
        findsOneWidget,
      );
      expect(find.text('派工'), findsNothing);
      expect(find.text('确认开工'), findsNothing);
    },
  );

  testWidgets('repeated row taps do not stack detail dialogs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SEG-001'));
    await tester.tap(find.text('SEG-001'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
  });

  testWidgets(
    'confirmed segment shows preparation and blocks report until issue',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          repository: _repository(
            status: 'DISPATCHED',
            fullyIssuedDemandCount: 1,
            materialIssued: false,
          ),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('物料齐套·备料中'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('production-execution-report-segment-1')),
        findsNothing,
      );
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();

      expect(find.text('待发料 · 1/2 项'), findsOneWidget);
      expect(find.textContaining('全部实物出库前不能报工'), findsOneWidget);
    },
  );

  testWidgets(
    'fully issued segment enables direct report and explains first report',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          repository: _repository(status: 'DISPATCHED'),
          permissions: const {
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('SEG-001'));
      await tester.pumpAndSettle();

      expect(find.text('已全部发料 · 2/2 项'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('production-execution-report-segment-1')),
        findsWidgets,
      );
      expect(find.textContaining('首次报工会在同一事务中登记实际开工'), findsOneWidget);
    },
  );

  testWidgets('compact assignment dialog remains usable at 1.3 text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {Perm.productionExecutionAssign},
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('production-execution-assign-segment-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('调整 SEG-001'), findsOneWidget);
    expect(find.text('保存分配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from report creation reloads execution status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var reads = 0;
    final router = GoRouter(
      initialLocation: '/plan',
      routes: [
        GoRoute(
          path: '/plan',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(
              child: ProductionExecutionSegmentsCard(
                planId: 'plan-1',
                canAssign: false,
                canReleaseDefer: false,
                canReport: true,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/production/daily-reports/new',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: context.pop,
                child: const Text('返回生产计划'),
              ),
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
            _repository(status: 'IN_PROGRESS', onRead: () => reads++),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.tap(
      find.byKey(const ValueKey('production-execution-report-segment-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('返回生产计划'), findsOneWidget);

    await tester.tap(find.text('返回生产计划'));
    await tester.pumpAndSettle();
    expect(reads, 2);
  });
}

Widget _app({
  required ProductionPlanRepository repository,
  required Set<String> permissions,
  String? initialSegmentId,
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [productionPlanRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProductionExecutionSegmentsCard(
            planId: 'plan-1',
            canAssign: permissions.contains(Perm.productionExecutionAssign),
            canReleaseDefer: permissions.contains(
              Perm.productionExecutionReleaseDefer,
            ),
            canReport:
                permissions.contains(Perm.productionDailyReportView) &&
                permissions.contains(Perm.productionDailyReportCreate),
            initialSegmentId: initialSegmentId,
          ),
        ),
      ),
    ),
  );
}

ProductionPlanRepository _repository({
  required String status,
  bool empty = false,
  bool autoPromoteWhenReady = true,
  int materialDemandCount = 2,
  int fullyIssuedDemandCount = 2,
  bool materialIssued = true,
  double reportedQty = 3,
  double remainingQty = 7,
  double? ordinaryRemainingQty,
  double fqcPendingQty = 0,
  double fqcPassedQty = 0,
  double fqcFailedQty = 0,
  double finishedInboundPendingQty = 0,
  double inboundQty = 0,
  double finishedInboundRejectedQty = 0,
  double fqcRecoveryAvailableQty = 0,
  double fqcReworkAvailableQty = 0,
  double fqcReplacementAvailableQty = 0,
  double fqcReplacementReadyQty = 0,
  void Function(RequestOptions request)? onCommand,
  void Function()? onRead,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final isRead = request.method == 'GET';
        final isBatchStart = request.path.endsWith('/batch-start');
        if (isRead) onRead?.call();
        if (!isRead) onCommand?.call(request);
        return handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: isRead
                ? empty
                      ? <Map<String, dynamic>>[]
                      : [
                          _segmentJson(
                            status: status,
                            autoPromoteWhenReady: autoPromoteWhenReady,
                            materialDemandCount: materialDemandCount,
                            fullyIssuedDemandCount: fullyIssuedDemandCount,
                            materialIssued: materialIssued,
                            reportedQty: reportedQty,
                            remainingQty: remainingQty,
                            ordinaryRemainingQty:
                                ordinaryRemainingQty ?? remainingQty,
                            fqcPendingQty: fqcPendingQty,
                            fqcPassedQty: fqcPassedQty,
                            fqcFailedQty: fqcFailedQty,
                            finishedInboundPendingQty:
                                finishedInboundPendingQty,
                            inboundQty: inboundQty,
                            finishedInboundRejectedQty:
                                finishedInboundRejectedQty,
                            fqcRecoveryAvailableQty: fqcRecoveryAvailableQty,
                            fqcReworkAvailableQty: fqcReworkAvailableQty,
                            fqcReplacementAvailableQty:
                                fqcReplacementAvailableQty,
                            fqcReplacementReadyQty: fqcReplacementReadyQty,
                          ),
                        ]
                : isBatchStart
                ? [
                    _segmentJson(
                      status: 'IN_PROGRESS',
                      materialDemandCount: materialDemandCount,
                      fullyIssuedDemandCount: fullyIssuedDemandCount,
                      materialIssued: materialIssued,
                      reportedQty: reportedQty,
                      remainingQty: remainingQty,
                      ordinaryRemainingQty:
                          ordinaryRemainingQty ?? remainingQty,
                    ),
                  ]
                : _segmentJson(
                    status: status,
                    materialDemandCount: materialDemandCount,
                    fullyIssuedDemandCount: fullyIssuedDemandCount,
                    materialIssued: materialIssued,
                    reportedQty: reportedQty,
                    remainingQty: remainingQty,
                    ordinaryRemainingQty: ordinaryRemainingQty ?? remainingQty,
                    fqcPendingQty: fqcPendingQty,
                    fqcPassedQty: fqcPassedQty,
                    fqcFailedQty: fqcFailedQty,
                    finishedInboundPendingQty: finishedInboundPendingQty,
                    inboundQty: inboundQty,
                    finishedInboundRejectedQty: finishedInboundRejectedQty,
                    fqcRecoveryAvailableQty: fqcRecoveryAvailableQty,
                    fqcReworkAvailableQty: fqcReworkAvailableQty,
                    fqcReplacementAvailableQty: fqcReplacementAvailableQty,
                    fqcReplacementReadyQty: fqcReplacementReadyQty,
                  ),
          ),
        );
      },
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

Map<String, dynamic> _segmentJson({
  required String status,
  bool autoPromoteWhenReady = true,
  int materialDemandCount = 2,
  int fullyIssuedDemandCount = 2,
  bool materialIssued = true,
  double reportedQty = 3,
  double remainingQty = 7,
  double ordinaryRemainingQty = 7,
  double fqcPendingQty = 0,
  double fqcPassedQty = 0,
  double fqcFailedQty = 0,
  double finishedInboundPendingQty = 0,
  double inboundQty = 0,
  double finishedInboundRejectedQty = 0,
  double fqcRecoveryAvailableQty = 0,
  double fqcReworkAvailableQty = 0,
  double fqcReplacementAvailableQty = 0,
  double fqcReplacementReadyQty = 0,
}) => {
  'id': 'segment-1',
  'packageId': 'package-1',
  'planId': 'plan-1',
  'sourcePlanItemId': 'plan-item-1',
  'segmentNo': 1,
  'segmentCode': 'SEG-001',
  'productGoodsId': 'goods-1',
  'productCode': 'P-001',
  'productName': '成品灯',
  'productColorId': null,
  'productUnitId': 'unit-1',
  'plannedQty': 10,
  'reportedQty': reportedQty,
  'remainingQty': remainingQty,
  'ordinaryRemainingQty': ordinaryRemainingQty,
  'status': status,
  'autoPromoteWhenReady': autoPromoteWhenReady,
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '装配一车间',
  'teamDepartmentId': 'team-1',
  'teamName': '甲班',
  'responsibleEmployeeId': 'employee-1',
  'responsibleEmployeeName': '张三',
  'planBeginDate': '2026-08-01',
  'planEndDate': '2026-08-02',
  'materialKindCount': 2,
  'shortageKindCount': 0,
  'materialReady': true,
  'materialDemandCount': materialDemandCount,
  'fullyIssuedDemandCount': fullyIssuedDemandCount,
  'materialIssued': materialIssued,
  'fqcPendingQty': fqcPendingQty,
  'fqcPassedQty': fqcPassedQty,
  'fqcFailedQty': fqcFailedQty,
  'finishedInboundPendingQty': finishedInboundPendingQty,
  'inboundQty': inboundQty,
  'finishedInboundRejectedQty': finishedInboundRejectedQty,
  'fqcRecoveryAvailableQty': fqcRecoveryAvailableQty,
  'fqcReworkAvailableQty': fqcReworkAvailableQty,
  'fqcReplacementAvailableQty': fqcReplacementAvailableQty,
  'fqcReplacementReadyQty': fqcReplacementReadyQty,
  'lockVersion': 1,
};
