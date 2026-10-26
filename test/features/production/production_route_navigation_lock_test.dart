import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_group_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets(
    'plan host refreshes execution card once after replaced reporting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _PlanVisitApi();
      final router = GoRouter(
        initialLocation: '/production/plans/plan-1',
        routes: [
          GoRoute(
            path: '/production/plans/:id',
            builder: (_, _) => const ProductionPlanDetailPage(id: 'plan-1'),
          ),
          GoRoute(
            path: '/production/daily-reports/new',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.replace('/replacement'),
                child: const Text('replace report'),
              ),
            ),
          ),
          GoRoute(
            path: '/replacement',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.pop(),
                child: const Text('replacement return'),
              ),
            ),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionPlanView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(_PlanVisitNames(api)),
        ],
      );
      final detach = attachPageResume(
        router,
        container.read(pageResumeProvider.notifier),
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        expect(api.planReads, 1);
        expect(api.segmentReads, 1);
        final report = find.byKey(
          const ValueKey('production-execution-report-segment-1'),
        );
        await tester.ensureVisible(report);
        await tester.pumpAndSettle();
        await tester.tap(report);
        await tester.pumpAndSettle();
        await tester.tap(find.text('replace report'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('replacement return'));
        await tester.pumpAndSettle();
        expect(
          api.planReads,
          2,
          reason: 'The host revalidates its accepted detail once.',
        );
        expect(
          api.segmentReads,
          2,
          reason: 'The host remount is the only execution refresh.',
        );
        await tester.ensureVisible(report);
        await tester.pumpAndSettle();
        await tester.tap(report);
        await tester.pumpAndSettle();
        expect(find.text('replace report'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        detach();
        router.dispose();
        container.dispose();
      }
    },
  );
  testWidgets('pending production can reopen after analysis replacement', (
    tester,
  ) async {
    var pendingReads = 0;
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/production/schedule',
      routes: [
        GoRoute(
          path: '/production/schedule',
          builder: (_, _) => const ProductionBoardPage(initialTab: 0),
        ),
        GoRoute(
          path: '/production/material-analysis',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.replace('/replacement'),
              child: const Text('replace analysis'),
            ),
          ),
        ),
        GoRoute(
          path: '/replacement',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.pop(),
              child: const Text('replacement return'),
            ),
          ),
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionMaterialAnalysisCreate,
          Perm.productionMaterialAnalysisRefresh,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productionPlanRepositoryProvider.overrideWithValue(
          _pendingRepository(onRead: () => pendingReads++),
        ),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
    );
    final detach = attachPageResume(
      router,
      container.read(pageResumeProvider.notifier),
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(pendingReads, 1);
      final cell = find.text('ORDER-PENDING');
      await tester.tap(cell);
      await tester.pump();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('replace analysis'), findsOneWidget);
      await tester.tap(find.text('replace analysis'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('replacement return'));
      // The regression leaves the source action's progress spinner alive.
      // Bound the return pumps so the failure identifies the locked row gate.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      final table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
        find.byType(MasterDataTableView<SchedulePendingRow>),
      );
      expect(
        table.canOpenRow!(table.items.first),
        isTrue,
        reason:
            'Pending analysis navigation must release its submitting marker after replacement.',
      );
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      expect(
        pendingReads,
        2,
        reason: 'A return revalidates the pending list once.',
      );
      await tester.tap(cell);
      await tester.pump();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('replace analysis'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      detach();
      router.dispose();
      container.dispose();
    }
  });
  for (final replace in [false, true]) {
    testWidgets(
      'ongoing production can reopen after ${replace ? 'replace then pop' : 'ordinary pop'}',
      (tester) async {
        var groupReads = 0;
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (_, _) => const _Host()),
            GoRoute(
              path: '/production/plans/:id',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      replace ? context.replace('/replacement') : context.pop(),
                  child: const Text('finish child'),
                ),
              ),
            ),
            GoRoute(
              path: '/replacement',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('replacement return'),
                ),
              ),
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionExecutionOverview,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(onRead: () => groupReads++),
            ),
            productionWorkshopTreeProvider.overrideWith((ref) async => []),
          ],
        );
        final detach = attachPageResume(
          router,
          container.read(pageResumeProvider.notifier),
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(
                routerConfig: router,
                builder: (_, child) => UtenContextMenuPolicy(child: child!),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(groupReads, 1);
          final cell = find.text('ROOT PLAN');
          await tester.tap(cell);
          await tester.pump();
          await tester.tap(cell);
          await tester.pumpAndSettle();
          expect(find.text('finish child'), findsOneWidget);
          await tester.tap(find.text('finish child'));
          await tester.pumpAndSettle();
          if (replace) {
            await tester.tap(find.text('replacement return'));
            await tester.pumpAndSettle();
          }
          expect(find.byType(ProductionExecutionGroupPanel), findsOneWidget);
          expect(
            groupReads,
            2,
            reason: 'A return revalidates the ongoing list once.',
          );
          final table = tester
              .widget<MasterDataTableView<ProductionExecutionWorkbenchGroup>>(
                find.byType(
                  MasterDataTableView<ProductionExecutionWorkbenchGroup>,
                ),
              );
          expect(
            table.onRowTap,
            isNotNull,
            reason:
                'Returning must release the navigation-only lock even when replace detached the original push Future.',
          );
          final mouse = await tester.startGesture(
            tester.getCenter(cell),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryButton,
          );
          await mouse.up();
          await tester.pumpAndSettle();
          await tester.tap(find.text('打开生产计划'));
          await tester.pumpAndSettle();
          expect(find.text('finish child'), findsOneWidget);
          router.pop();
          await tester.pumpAndSettle();
          expect(
            groupReads,
            3,
            reason: 'The menu visit also revalidates once.',
          );
          await tester.tap(cell);
          await tester.pump();
          await tester.tap(cell);
          await tester.pumpAndSettle();
          expect(find.text('finish child'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          detach();
          router.dispose();
          container.dispose();
        }
      },
    );
  }
}

class _PlanVisitApi extends ApiClient {
  _PlanVisitApi() : super(Dio());
  int planReads = 0, segmentReads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/plan-1') {
      planReads++;
      return {
        'id': 'plan-1',
        'billNo': 'PLAN-1',
        'status': 1,
        'allowedActions': ['VIEW'],
        'items': <Map<String, dynamic>>[],
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans/plan-1/execution-segments') {
      segmentReads++;
      return [
        {
          'id': 'segment-1',
          'planId': 'plan-1',
          'packageId': 'package-1',
          'sourcePlanItemId': 'plan-item-1',
          'segmentNo': 1,
          'segmentCode': 'SEG-1',
          'productGoodsId': 'goods-1',
          'productCode': 'G-1',
          'productName': 'PRODUCT',
          'plannedQty': 10,
          'reportedQty': 0,
          'remainingQty': 10,
          'ordinaryRemainingQty': 10,
          'status': 'IN_PROGRESS',
          'materialReady': true,
          'materialIssued': true,
          'startRoute': 'FULL_KIT',
          'lockVersion': 1,
        },
      ];
    }
    return [];
  }
}

class _PlanVisitNames extends MasterNameService {
  _PlanVisitNames(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
}

ProductionPlanRepository _pendingRepository({VoidCallback? onRead}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/schedule/pending') onRead?.call();
        handler.next(request);
      },
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: request.path == '/production/schedule/pending'
              ? {
                  'items': [
                    {
                      'orderItemId': 'line-1',
                      'orderId': 'order-1',
                      'orderBillNo': 'ORDER-PENDING',
                      'goodsId': 'goods-1',
                      'goodsCode': 'G-1',
                      'goodsName': 'PRODUCT',
                      'qty': 10,
                      'plannedQty': 0,
                      'needQty': 10,
                      'materialAnalysisId': 'analysis-1',
                      'materialAnalysisVersion': 1,
                      'analysisCoveredQty': 3,
                    },
                  ],
                  'page': 1,
                  'size': 20,
                  'total': 1,
                  'totalPages': 1,
                }
              : <String, dynamic>{},
        ),
      ),
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

class _Host extends ConsumerStatefulWidget {
  const _Host();
  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  int revision = 0;
  @override
  Widget build(BuildContext context) {
    ref.onPageResume('/', () => setState(() => revision++));
    return Scaffold(
      body: ProductionExecutionGroupPanel(
        keyword: '',
        refreshRevision: revision,
      ),
    );
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

ProductionExecutionWorkbenchRepository _repository({VoidCallback? onRead}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path == '/production/execution-workbench') onRead?.call();
        handler.next(request);
      },
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: request.path == '/production/execution-workbench'
              ? {
                  'items': [
                    {
                      'rootType': 'PLAN',
                      'rootId': 'plan-9',
                      'rootLabel': 'ROOT PLAN',
                      'status': 'IN_PROGRESS',
                      'planCount': 1,
                      'segmentCount': 1,
                    },
                  ],
                  'page': 1,
                  'size': 50,
                  'total': 1,
                  'totalPages': 1,
                }
              : <String, dynamic>{},
        ),
      ),
    ),
  );
  return ProductionExecutionWorkbenchRepository(ApiClient(dio));
}
