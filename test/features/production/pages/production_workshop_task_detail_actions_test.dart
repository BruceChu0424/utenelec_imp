import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';
import '../../../support/filter_segment_tap.dart';

const _permissions = {
  Perm.productionExecutionView,
  Perm.productionExecutionStart,
  Perm.productionDailyReportView,
  Perm.productionDailyReportCreate,
};

final _livePermissionsProvider = StateProvider<Set<String>>(
  (ref) => _permissions,
);

void main() {
  testWidgets('准备可领物料仅显示领料，关闭详情后进入当前任务领料汇总', (tester) async {
    final server = _DetailServer([
      _task('a', status: 'READY', canDraw: true, issued: false),
    ]);
    await _mount(tester, server, category: '开工准备');
    await _openDetail(tester, '产品 A');

    expect(_action('draw', 'a'), findsOneWidget);
    expect(
      find.descendant(of: _action('draw', 'a'), matching: find.text('领料')),
      findsOneWidget,
    );
    expect(_action('start', 'a'), findsNothing);
    expect(_action('report', 'a'), findsNothing);
    await tester.tap(_action('draw', 'a'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('领料任务 a / 7'), findsOneWidget);
    await tester.tap(find.text('领料返回'));
    await tester.pumpAndSettle();
    expect(server.taskLoads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已经申请待仓库发料且无可续领物料时不重复显示领料', (tester) async {
    final server = _DetailServer([
      _task('a', status: 'READY', issued: false)..addAll({
        'drawRequested': true,
        'materialAwaitingWarehouseKindCount': 1,
      }),
    ]);
    await _mount(tester, server, category: '开工准备');
    await _openDetail(tester, '产品 A');
    expect(_action('draw', 'a'), findsNothing);
    expect(_action('start', 'a'), findsNothing);
    expect(_action('report', 'a'), findsNothing);
    expect(find.textContaining('待仓库发料'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('实领可开工任务复用版本化开工并在返回后刷新', (tester) async {
    final server = _DetailServer([_task('a', status: 'READY', canStart: true)]);
    await _mount(tester, server, category: '开工准备');
    await _openDetail(tester, '产品 A');
    expect(_action('start', 'a'), findsOneWidget);
    expect(_action('draw', 'a'), findsNothing);
    await tester.tap(_action('start', 'a'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final request = server.writes.single;
    expect(
      request.path,
      '/production/plans/plan-a/execution-segments/batch-start',
    );
    final item = ((request.data as Map)['items'] as List).single as Map;
    expect(item['segmentId'], 'a');
    expect(item['expectedVersion'], 7);
    expect(item['idempotencyKey'], isNotEmpty);
    expect(server.taskLoads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('持续生产已有投入可开工且能继续领料时保留两项操作并突出开工', (tester) async {
    final server = _DetailServer([
      _task('a', status: 'READY', canStart: true, canDraw: true)
        ..['startRoute'] = 'CONTINUOUS',
    ]);
    await _mount(tester, server, category: '开工准备');
    await _openDetail(tester, '产品 A');
    expect(tester.widget(_action('draw', 'a')), isA<OutlinedButton>());
    expect(tester.widget(_action('start', 'a')), isA<FilledButton>());
    expect(_action('report', 'a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生产中可报工也可补领时继续领料为次操作', (tester) async {
    final server = _DetailServer([
      _task('a', canReport: true, canDraw: true)..['startRoute'] = 'CONTINUOUS',
    ]);
    await _mount(tester, server);
    await _openDetail(tester, '产品 A');
    expect(tester.widget(_action('draw', 'a')), isA<OutlinedButton>());
    expect(find.text('继续领料'), findsOneWidget);
    expect(tester.widget(_action('report', 'a')), isA<FilledButton>());
    expect(_action('start', 'a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final remaining in [8, 0]) {
    testWidgets('生产中待报 $remaining 时服务器允许即保留报工入口', (tester) async {
      final server = _DetailServer([
        _task('a', remaining: remaining, canReport: true),
      ]);
      await _mount(tester, server);
      await _openDetail(tester, '产品 A');
      expect(_action('report', 'a'), findsOneWidget);
      await tester.tap(_action('report', 'a'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('报工任务 a'), findsOneWidget);
      expect(
        server.reportLocations.single.queryParameters['executionSegmentId'],
        'a',
      );
      expect(
        server.reportLocations.single.queryParameters['executionSegmentIds'],
        isNull,
      );
      expect(
        server.reportLocations.single.queryParameters['from'],
        'workshop-tasks',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('其他任务已勾选时详情报工只带当前任务并保持审核返回刷新链路', (tester) async {
    final server = _DetailServer([
      _task('a', canReport: true)..['canBatchReport'] = false,
      _task('b', canReport: true),
    ]);
    await _mount(tester, server);
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
    );
    await tester.pumpAndSettle();
    expect(find.text('批量报工(2)'), findsOneWidget);
    await _openDetail(tester, '产品 A');
    await tester.tap(_action('report', 'a'));
    await tester.pumpAndSettle();
    expect(find.text('报工任务 a'), findsOneWidget);
    expect(
      server.reportLocations.single.queryParameters['executionSegmentIds'],
      isNull,
    );
    await tester.tap(find.text('保存草稿并审核'));
    await tester.pumpAndSettle();
    expect(find.text('审核 saved-report'), findsOneWidget);
    expect(server.reviewOrigin, 'workshop-tasks');
    await tester.tap(find.text('审核返回'));
    await tester.pumpAndSettle();
    expect(server.taskLoads, 2);
    await _openDetail(tester, '产品 A');
    await tester.tap(_action('report', 'a'));
    await tester.pumpAndSettle();
    expect(find.text('报工任务 a'), findsOneWidget, reason: '返回后详情动作必须解除忙碌并可再次进入');
    expect(server.reportLocations, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少本地操作权限时不因服务器旧能力显示领料开工或报工', (tester) async {
    final server = _DetailServer([
      _task('a', status: 'READY', canStart: true, canDraw: true),
      _task('b', canReport: true),
    ]);
    await _mount(
      tester,
      server,
      category: '开工准备',
      permissions: {Perm.productionExecutionView},
    );
    await _openDetail(tester, '产品 A');
    expect(_action('draw', 'a'), findsNothing);
    expect(_action('start', 'a'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();
    await _openDetail(tester, '产品 B');
    expect(_action('report', 'b'), findsNothing);
    expect(server.reportLocations, isEmpty);
    expect(server.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开详情后撤销报工权限时执行重新检查权限', (tester) async {
    final server = _DetailServer([_task('a', canReport: true)]);
    final container = await _mount(tester, server);
    await _openDetail(tester, '产品 A');
    final originalButton = tester.widget<ButtonStyleButton>(
      _action('report', 'a'),
    );
    container.read(_livePermissionsProvider.notifier).state = {
      Perm.productionExecutionView,
    };
    await tester.pumpAndSettle();
    // The dialog may rebuild and remove its action; retain the old callback to
    // prove a stale UI event cannot bypass the current permission check.
    originalButton.onPressed!();
    await tester.pumpAndSettle();
    expect(server.reportLocations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情打开后草稿全量承接待报工时旧按钮不能再进入报工', (tester) async {
    final server = _DetailServer([_task('a', canReport: true)])
      ..draftGate = Completer<void>()
      ..claimedQty = 8;
    await _mount(tester, server);
    await _openDetail(tester, '产品 A');
    final originalButton = tester.widget<ButtonStyleButton>(
      _action('report', 'a'),
    );
    server.draftGate!.complete();
    await tester.pumpAndSettle();
    expect(_action('report', 'a'), findsNothing);
    expect(find.text('草稿待审核 8 件'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('workshop-detail-quantity-remaining')),
        matching: find.text('0 件'),
      ),
      findsOneWidget,
    );
    originalButton.onPressed!();
    await tester.pumpAndSettle();
    expect(server.reportLocations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情打开后草稿部分承接时摘要同步扣减并仍允许报工', (tester) async {
    final server = _DetailServer([_task('a', canReport: true)])
      ..draftGate = Completer<void>()
      ..claimedQty = 3;
    await _mount(tester, server);
    await _openDetail(tester, '产品 A');
    server.draftGate!.complete();
    await tester.pumpAndSettle();
    expect(_action('report', 'a'), findsOneWidget);
    expect(find.text('草稿待审核 3 件'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('workshop-detail-quantity-remaining')),
        matching: find.text('5 件'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Finder _action(String action, String segmentId) =>
    find.byKey(ValueKey('workshop-detail-$action-$segmentId'));

Future<void> _openDetail(WidgetTester tester, String product) async {
  await tester.tap(find.text(product).first);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(product).first);
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _DetailServer server, {
  String category = '生产中',
  Set<String> permissions = _permissions,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const ProductionWorkshopTasksPage(),
      ),
      GoRoute(
        path: '/production/workshop-tasks/draw-request',
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text(
                '领料任务 ${state.uri.queryParameters['segmentIds']} / ${state.uri.queryParameters['versions']}',
              ),
              TextButton(
                onPressed: () => context.pop(),
                child: const Text('领料返回'),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/production/daily-reports/new',
        builder: (context, state) {
          server.reportLocations.add(state.uri);
          return Scaffold(
            body: Column(
              children: [
                Text(
                  '报工任务 ${state.uri.queryParameters['executionSegmentId'] ?? state.uri.queryParameters['executionSegmentIds']}',
                ),
                TextButton(
                  onPressed: () => context.pop('saved-report'),
                  child: const Text('保存草稿并审核'),
                ),
              ],
            ),
          );
        },
      ),
      GoRoute(
        path: '/production/daily-reports/:id',
        builder: (context, state) {
          server.reviewOrigin = state.uri.queryParameters['from'];
          return Scaffold(
            body: Column(
              children: [
                Text('审核 ${state.pathParameters['id']}'),
                TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('审核返回'),
                ),
              ],
            ),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(preferences, web: true),
      ),
      sharedPreferencesProvider.overrideWithValue(preferences),
      isSuperAdminProvider.overrideWithValue(false),
      _livePermissionsProvider.overrideWith((ref) => permissions),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_livePermissionsProvider),
      ),
      productionWorkshopTreeProvider.overrideWith((ref) async => []),
      productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
        ProductionExecutionWorkbenchRepository(server.api),
      ),
      productionPlanRepositoryProvider.overrideWithValue(
        ProductionPlanRepository(server.api),
      ),
      productionDailyReportRepositoryProvider.overrideWithValue(
        ProductionDailyReportRepository(server.api),
      ),
      fixedBadgeSummaryOverride(),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await selectFilterSegment(tester, category);
  await tester.pumpAndSettle();
  return container;
}

Map<String, dynamic> _task(
  String id, {
  String status = 'IN_PROGRESS',
  int remaining = 8,
  bool canReport = false,
  bool canStart = false,
  bool canDraw = false,
  bool issued = true,
}) => {
  'segmentId': id,
  'planId': 'plan-$id',
  'planNo': 'SJ-$id',
  'segmentCode': 'GD-$id',
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '装配一车间',
  'responsibleEmployeeName': '负责人',
  'productCode': 'P-$id',
  'productName': '产品 ${id.toUpperCase()}',
  'productColorName': '本色',
  'productUnitName': '件',
  'plannedQty': 10,
  'reportedQty': status == 'IN_PROGRESS' ? 10 - remaining : 0,
  'remainingReportQty': status == 'IN_PROGRESS' ? remaining : 10,
  'segmentStatus': status,
  'materialStatus': 'KIT_READY',
  'preparationStatus': 'PREPARED',
  'materialReady': true,
  'warehouseReady': true,
  'issued': issued,
  'canStart': canStart,
  'canRequestDraw': canDraw,
  'canReport': canReport,
  'canBatchReport': true,
  'lockVersion': 7,
  'startRoute': 'FULL_KIT',
  'materialKindCount': 1,
  'materialIssuedKindCount': issued ? 1 : 0,
  'materialDrawableKindCount': canDraw ? 1 : 0,
  'materialSupportedOutputQty': issued ? 10 : 0,
};

class _DetailServer {
  _DetailServer(this.tasks) {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.path == '/production/daily-reports' &&
              draftGate != null) {
            await draftGate!.future;
          }
          Object data;
          if (request.method == 'POST') {
            writes.add(request);
            data = <String, dynamic>{};
          } else if (request.path == '/production/workshop-tasks') {
            taskLoads++;
            data = _page(tasks);
          } else if (request.path.endsWith('/materials')) {
            data = <Object>[];
          } else if (request.path == '/production/daily-reports') {
            data = _page(
              claimedQty > 0
                  ? [
                      {'id': 'draft-1', 'billNo': 'SR-DRAFT-1', 'status': 0},
                    ]
                  : [],
            );
          } else if (request.path == '/production/daily-reports/draft-1') {
            data = {
              'id': 'draft-1',
              'billNo': 'SR-DRAFT-1',
              'status': 0,
              'items': [
                {
                  'id': 'draft-item',
                  'executionSegmentId': 'a',
                  'qty': claimedQty,
                  'actualSurplus': false,
                },
              ],
            };
          } else {
            data = <String, dynamic>{};
          }
          handler.resolve(
            Response(requestOptions: request, statusCode: 200, data: data),
          );
        },
      ),
    );
    api = ApiClient(dio);
  }

  final List<Map<String, dynamic>> tasks;
  late final ApiClient api;
  final writes = <RequestOptions>[];
  final reportLocations = <Uri>[];
  String? reviewOrigin;
  int taskLoads = 0;
  double claimedQty = 0;
  Completer<void>? draftGate;

  Map<String, dynamic> _page(List<Map<String, dynamic>> rows) => {
    'items': rows,
    'page': 1,
    'size': 100,
    'total': rows.length,
    'totalPages': 1,
  };
}
