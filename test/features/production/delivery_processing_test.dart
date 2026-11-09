import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/delivery_processing/delivery_processing_repository.dart';
import 'package:uten_imp/features/production/delivery_processing/delivery_processing_tasks_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../support/uten_test_actions.dart';

Map<String, dynamic> _task({int version = 1, bool done = false}) => {
  'componentId': 'component-1',
  'shipmentId': 'shipment-1',
  'shipmentNo': 'SH-001',
  'goodsName': '后座',
  'goodsCode': 'BASE',
  'unitName': '个',
  'requiredQtyExact': '100',
  'completedQtyExact': done ? '100' : '0',
  'remainingQtyExact': done ? '0' : '100',
  'operations': ['LASER'],
  'processingTargets': [
    {
      'path': ['child'],
      'code': 'LASER-PLATE',
      'name': '激光刻字面板',
      'quantityExact': '200',
      'quantityNumerator': '200',
      'quantityDenominator': '1',
      'unitName': '片',
      'operations': ['LASER'],
    },
  ],
  'status': done ? 'COMPLETED' : 'IN_PROGRESS',
  'version': version,
  'workshopDepartmentId': 'workshop',
  'workshopName': '激光车间',
  'startedAt': '2026-11-04T00:00:00Z',
  'canAssign': false,
  'canStart': false,
  'canReport': !done,
};

class _Api extends Fake implements ApiClient {
  int posts = 0;
  bool networkFailure = true, recorded = false;
  final bodies = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts++;
    bodies.add(Map<String, dynamic>.from(body as Map));
    if (networkFailure) throw NetworkTimeoutException();
    return _task(version: 2, done: true);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'recorded': recorded};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _Repository extends DeliveryProcessingRepository {
  _Repository(super.api);
  Completer<DeliveryProcessingTask>? pendingResponse;
  int submits = 0, reads = 0;
  final listQueries = <({int page, int size, String? keyword})>[];
  Future<DeliveryProcessingPage> Function(int page, int size, String? keyword)?
  pages;
  @override
  Future<DeliveryProcessingPage> list(
    String? shipmentId, {
    int page = 1,
    int size = 100,
    String? keyword,
  }) async {
    listQueries.add((page: page, size: size, keyword: keyword));
    return pages?.call(page, size, keyword) ??
        DeliveryProcessingPage([DeliveryProcessingTask(_task())], 1, 1, 1);
  }

  @override
  Future<DeliveryProcessingTask> get(String id) async {
    reads++;
    return DeliveryProcessingTask(_task());
  }

  @override
  Future<DeliveryProcessingTask> submit(
    DeliveryProcessingTask task,
    String action,
    Map<String, dynamic> values,
  ) {
    submits++;
    return pendingResponse?.future ?? super.submit(task, action, values);
  }
}

class _ListApi extends _Api {
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add({...?query});
    final page = query!['page'] as int, size = query['size'] as int;
    return {
      'items': [
        for (
          var index = (page - 1) * size;
          index < page * size && index < 251;
          index++
        )
          {
            ..._task(),
            'componentId': 'transport-$index',
            'remainingQtyExact': '0.000000000000000000000001',
            'futureSource': {'proof': 'kept'},
          },
      ],
      'page': page,
      'size': size,
      'total': 251,
      'totalPages': (251 / size).ceil(),
      'readScopeVersion': 'transport-proof',
      'sourceSnapshot': {'pending': 7},
    };
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repo, {
  bool select = true,
  bool settle = true,
}) async {
  await setUtenTestSurfaceSize(tester, const Size(1280, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(repo.api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'processing-fixture'),
        ),
        deliveryProcessingRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue({
          'production_execution:view',
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repo.api,
            permissions: {'production_execution:view'},
            superAdmin: false,
          ),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        supportedLocales: [Locale('zh')],
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: DeliveryProcessingTasksButton(shipmentId: 'shipment-1'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('交付件加工任务'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }
  if (!select) return;
  await tester.tap(find.widgetWithText(TextButton, '办理').first);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'processing transport keeps complete typed rows, raw subjects and first metadata',
    () async {
      final api = _ListApi(),
          reader = ScopedPagedRead<DeliveryProcessingTask>(
            idOf: (row) => row.id,
          );
      addTearDown(reader.dispose);
      final repository = DeliveryProcessingRepository(api);
      final result = await reader.read(
        1,
        scope: 'transport',
        isCurrent: () => true,
        fetchPage: (page) => repository.list('shipment-1', page: page),
        fetchPageSized: (page, size) =>
            repository.list('shipment-1', page: page, size: size),
      );
      final typed = result as DeliveryProcessingPage;
      expect(typed.items, hasLength(251));
      expect(typed.items.last.id, 'transport-250');
      expect(typed.items.last.remaining, '0.000000000000000000000001');
      expect(typed.items.last.data['futureSource'], {'proof': 'kept'});
      expect(typed.items.last.processingTargets.single.quantity, '200');
      expect(typed.metadata['sourceSnapshot'], {'pending': 7});
      expect(typed.readScopeVersion, 'transport-proof');
      // 2026-11-08 阶梯完整读取：251 行 = 50 → 50 → 100 → 200（末批 51 行）。
      expect(api.queries.map((query) => query['size']), [50, 50, 100, 200]);
      expect(api.queries.map((query) => query['page']), [1, 2, 2, 2]);
      expect(
        api.queries.every((query) => query['shipmentId'] == 'shipment-1'),
        true,
      );
    },
  );
  DeliveryProcessingPage batch(int page, int size) => DeliveryProcessingPage(
    [
      for (
        var index = (page - 1) * size;
        index < page * size && index < 251;
        index++
      )
        DeliveryProcessingTask({
          ..._task(),
          'componentId': 'component-$index',
          'goodsCode': 'ITEM-$index',
          'remainingQtyExact': '0.000000000000000000000001',
          'version': index + 7,
        }),
    ],
    page,
    (251 / size).ceil(),
    251,
    size: size,
    readScopeVersion: 'processing-proof',
    metadata: const {'pendingCount': 7},
  );

  testWidgets(
    'all 251 delivery processing tasks use bounded batches and local scrolling with exact subjects',
    (tester) async {
      final repo = _Repository(_Api())
        ..pages = (page, size, _) async => batch(page, size);
      await _pump(tester, repo, select: false);
      final finder = find.byType(MasterDataTableView<DeliveryProcessingTask>);
      final table = tester.widget<MasterDataTableView<DeliveryProcessingTask>>(
        finder,
      );
      expect(table.items, hasLength(251));
      expect(table.items.last.id, 'component-250');
      expect(table.items.last.remaining, '0.000000000000000000000001');
      expect(table.items.last.processingTargets.single.quantity, '200');
      expect(table.items.last.version, 257);
      expect(table.onPageChange, isNull);
      // 2026-11-08 阶梯完整读取：offset 0/50/100/200 → (1,50),(2,50),(2,100),(2,200)。
      expect(repo.listQueries.map((query) => (query.page, query.size)), [
        (1, 50),
        (2, 50),
        (2, 100),
        (2, 200),
      ]);
      final reads = repo.listQueries.length;
      final position = tester
          .stateList<ScrollableState>(
            find.descendant(of: finder, matching: find.byType(Scrollable)),
          )
          .where(
            (state) =>
                state.position.axis == Axis.vertical &&
                state.position.hasContentDimensions,
          )
          .map((state) => state.position)
          .reduce((a, b) => a.maxScrollExtent > b.maxScrollExtent ? a : b);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      position.jumpTo(0);
      await tester.pumpAndSettle();
      // Scrolling the complete result reads nothing more.
      expect(repo.listQueries, hasLength(reads));
      expect(repo.submits, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed later processing batch publishes no prefix and retries the whole query',
    (tester) async {
      var failing = true;
      final repo = _Repository(_Api())
        ..pages = (page, size, _) async {
          if (page == 2 && failing) throw ApiException('NETWORK', '后续加工任务读取失败');
          return batch(page, size);
        };
      await _pump(tester, repo, select: false);
      final finder = find.byType(MasterDataTableView<DeliveryProcessingTask>);
      expect(
        tester
            .widget<MasterDataTableView<DeliveryProcessingTask>>(finder)
            .items,
        isEmpty,
      );
      expect(repo.listQueries, hasLength(2));
      failing = false;
      tester
          .widget<MasterDataTableView<DeliveryProcessingTask>>(finder)
          .onRetry!();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MasterDataTableView<DeliveryProcessingTask>>(finder)
            .items,
        hasLength(251),
      );
      // 失败读取 (1,50),(2,50)；重试从头整体重读阶梯 50→50→100→200。
      expect(repo.listQueries.map((query) => (query.page, query.size)), [
        (1, 50),
        (2, 50),
        (1, 50),
        (2, 50),
        (2, 100),
        (2, 200),
      ]);
      expect(repo.submits, 0);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing the processing owner abandons held continuation without extra batches',
    (tester) async {
      final gate = Completer<DeliveryProcessingPage>();
      final repo = _Repository(_Api())
        ..pages = (page, size, _) =>
            page == 2 ? gate.future : Future.value(batch(page, size));
      await _pump(tester, repo, select: false, settle: false);
      expect(repo.listQueries, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      gate.complete(batch(2, 100));
      await tester.pumpAndSettle();
      expect(repo.listQueries, hasLength(2));
      expect(repo.submits, 0);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'unknown report retains the exact original UUID, quantity and expected version',
    () async {
      final api = _Api(), repo = DeliveryProcessingRepository(_Api());
      final active = DeliveryProcessingRepository(api);
      final task = DeliveryProcessingTask(_task());
      await expectLater(
        active.submit(task, 'reports', {
          'quantity': '0.000000000000000000000001',
          'operation': 'LASER',
          'evidence': '实测完成',
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      final pending = active.pending[task.id]!;
      expect(pending.body['expectedVersion'], 1);
      expect(pending.body['quantity'], '0.000000000000000000000001');
      expect(await active.reconcile(pending), false);
      expect(active.pending[task.id], same(pending));
      api.networkFailure = false;
      await active.retry(pending);
      expect(api.posts, 2);
      expect(api.bodies[0], api.bodies[1]);
      expect(active.pending, isEmpty);
      expect(repo.pending, isEmpty);
    },
  );

  test(
    'confirmed request reconciliation clears pending without resubmitting',
    () async {
      final api = _Api(), repo = DeliveryProcessingRepository(_Api());
      final active = DeliveryProcessingRepository(api),
          task = DeliveryProcessingTask(_task());
      await expectLater(
        active.submit(task, 'reports', {
          'quantity': '100',
          'operation': 'LASER',
          'evidence': '已加工',
        }),
        throwsA(isA<NetworkTimeoutException>()),
      );
      api.recorded = true;
      expect(await active.reconcile(active.pending[task.id]!), true);
      expect(api.posts, 1);
      expect(active.pending, isEmpty);
      expect(repo.pending, isEmpty);
    },
  );

  testWidgets(
    'real processing form uses a movable window and one waiting layer during report',
    (tester) async {
      final repo = _Repository(ApiClient(Dio()))..pendingResponse = Completer();
      await _pump(tester, repo);
      expect(
        find.byType(UtenFloatingWindow, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('交付件加工办理'), findsOneWidget);
      expect(find.text('激光刻字面板'), findsWidgets);
      expect(repo.reads, 1);
      expect(
        find.byKey(const ValueKey('delivery-processing-evidence')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('delivery-processing-evidence')),
        '激光图样和检验记录',
      );
      await tester.pump();
      await tester.tap(find.text('提交加工报工'));
      await tester.pump();
      expect(repo.submits, 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      repo.pendingResponse!.complete(
        DeliveryProcessingTask(_task(version: 2, done: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('提交加工报工'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('delivery-processing-panel-close')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingWindow), findsOneWidget);
      expect(find.text('交付件加工办理'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('narrow enlarged processing panel keeps the report reachable', (
    tester,
  ) async {
    final repo = _Repository(ApiClient(Dio()))..pendingResponse = Completer();
    await _pump(tester, repo);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.binding.setSurfaceSize(const Size(390, 900));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final evidence = find.byKey(const ValueKey('delivery-processing-evidence'));
    await tester.ensureVisible(evidence);
    await tester.enterText(evidence, '全部面板完成激光并检验');
    await tester.pump();
    await tester.ensureVisible(find.text('提交加工报工'));
    await tester.tap(find.text('提交加工报工'));
    await tester.pump();
    expect(repo.submits, 1);
    repo.pendingResponse!.complete(
      DeliveryProcessingTask(_task(version: 2, done: true)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
