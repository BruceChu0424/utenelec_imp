import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_results_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/finance/pages/finance_audit_center_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_records_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';

final _scope = StateProvider((ref) => const WarehouseTaskScope.all());
final _permissions = StateProvider<Set<String>>((ref) => const {});

class _Read {
  _Read(this.path, Map<String, dynamic>? query) : query = Map.of(query ?? {});
  final String path;
  final Map<String, dynamic> query;
  String get kind => '${query['source'] ?? query['status'] ?? 'ALL'}';
  String get scope => '${query['scopeWarehouseId'] ?? 'default'}';
}

class _Api extends ApiClient {
  _Api({this.scheduleTotal = 1}) : super(Dio());
  final int scheduleTotal;
  final reads = <_Read>[];
  final held = <String, Completer<void>>{};
  Completer<void>? counts;
  Completer<void>? facets;
  String revision = 'OLD';
  int active = 0, maximumActive = 0;
  final writes = <String>[];

  List<_Read> requests(String path, {String? kind, String? scope}) => reads
      .where(
        (read) =>
            read.path == path &&
            (kind == null || read.kind == kind) &&
            (scope == null || read.scope == scope),
      )
      .toList();

  void release() {
    for (final pending in held.values) {
      if (!pending.isCompleted) pending.complete();
    }
    if (counts != null && !counts!.isCompleted) counts!.complete();
    if (facets != null && !facets!.isCompleted) facets!.complete();
  }

  Map<String, dynamic> _page(
    List<Map<String, dynamic>> items,
    _Read read, {
    int? total,
  }) => {
    'items': items,
    'page': read.query['page'] ?? 1,
    'size': read.query['size'] ?? 50,
    'total': total ?? items.length,
    'totalPages': ((total ?? items.length) / (read.query['size'] as int? ?? 50))
        .ceil(),
    'facets': const <String, Object>{},
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final read = _Read(path, query);
    reads.add(read);
    final stamp = revision;
    if (path == '/warehouse/quality-results/status-counts') {
      await counts?.future;
      return const {
        'TASK_ALL_PASSED': 0,
        'TASK_PARTIAL_PASSED': 0,
        'TASK_RETURN_REQUIRED': 0,
        'TASK_WAITING_INSPECTION': 0,
        'COMPLETED': 0,
      };
    }
    if (path == '/production/schedule/pending/facets') {
      await facets?.future;
      return const {};
    }
    final isRows =
        path.startsWith('/warehouse/task-center/') ||
        const {
          '/warehouse/quality-results',
          '/production/schedule/pending',
          '/production/execution-workbench',
          '/production/workshop-tasks',
          '/stock/count-requests',
        }.contains(path);
    if (!isRows) return _page(const [], read);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      await held['$path|${read.kind}|${read.scope}']?.future;
      if (path.startsWith('/warehouse/task-center/')) {
        return _page([
          {
            'id': '${read.kind}-${read.scope}',
            'rowKey': '${read.kind}-${read.scope}',
            'sourceType': read.kind,
            'recordType': 'OTHER_OUT',
            'status': 'OTHER_DRAFT',
            'statusLabel': '只读测试任务',
            'billNo': '$stamp-W-${read.kind}-${read.scope}',
            'canHandle': false,
          },
        ], read);
      }
      if (path == '/warehouse/quality-results') {
        return _page([
          {
            'receiptType': 'PURCHASE',
            'receiptId': 'receipt-${read.kind}',
            'billNo': '$stamp-Q-${read.kind}',
            'supplierName': '预热供应商',
            'warehouseName': '原料仓',
            'workStatus': 'ALL_PASSED',
          },
        ], read);
      }
      if (path == '/production/schedule/pending') {
        final offset =
            ((query?['page'] as int? ?? 1) - 1) *
            (query?['size'] as int? ?? 100);
        return _page(
          List.generate(
            (scheduleTotal - offset).clamp(0, query?['size'] as int? ?? 100),
            (i) => {
              'orderItemId': 'item-${offset + i}',
              'orderId': 'order-${offset + i}',
              'orderBillNo': '$stamp-SCHEDULE-${offset + i}',
              'goodsName': '产品-${offset + i}',
              'qty': 12,
              'needQty': 12,
              'unitName': '件',
            },
          ),
          read,
          total: scheduleTotal,
        );
      }
      if (path == '/production/execution-workbench') {
        return _page([
          {
            'rootId': 'analysis-1',
            'rootType': 'ANALYSIS',
            'rootLabel': '$stamp-GROUP',
            'productNamePreview': '预热批次',
          },
        ], read);
      }
      if (path == '/production/workshop-tasks') {
        return _page([
          {
            'segmentId': 'segment-${read.kind}',
            'planId': 'plan-1',
            'planNo': 'PLAN-1',
            'segmentCode': 'TASK-${read.kind}',
            'productName': 'WORKSHOP-${read.kind}',
            'segmentStatus': read.kind,
            'plannedQty': 10,
            'remainingReportQty': 10,
            'isOwnWorkshop': true,
          },
        ], read);
      }
      return _page([
        {
          'id': 'count-1',
          'requestNo': '$stamp-COUNT',
          'warehouseId': 'bin-1',
          'warehouseName': '车间内料仓',
          'reviewRoute': 'WAREHOUSE',
          'status': 'PENDING',
          'lines': <Object>[],
        },
      ], read);
    } finally {
      active--;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(_Read(path, query));
    if (path == '/workshop-material/task-status') {
      return [
        {
          'workshopDepartmentId': 'workshop-1',
          'workshopName': '$revision-车间',
          'status': 'PERIODIC',
          'periodicEnabled': true,
          'binWarehouseId': 'bin-1',
          'binWarehouseName': '内料仓',
          'currentPeriod': {
            'id': 'period-1',
            'periodNo': 1,
            'startDate': '2026-11-01',
            'status': 'OPEN',
            'closeState': 'BLOCKED',
          },
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (isBusinessWrite(RequestOptions(path: path, method: 'POST'))) {
      writes.add(path);
    }
    return const {};
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  Widget page,
  Set<String> permissions, {
  WarehouseTaskScope scope = const WarehouseTaskScope.all(),
}) async {
  tester.view.physicalSize = const Size(1800, 1050);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        _permissions.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'preparation-review'),
        ),
        _scope.overrideWith((ref) => scope),
        warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        myWarehouseScopeProvider.overrideWith(
          (ref) async => const MyWarehouseScope(
            role: WarehouseScopeRole.supervisor,
            canSelectAll: true,
            warehouseParticipant: true,
            selectable: [
              WarehouseScopeOption(id: 'w1', name: '一仓'),
              WarehouseScopeOption(id: 'w2', name: '二仓'),
            ],
          ),
        ),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: page,
      ),
    ),
  );
  await _frames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

Future<void> _close(WidgetTester tester, _Api api) async {
  api.release();
  await _frames(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('sales category entry makes no unselected business row HTTP', (
    tester,
  ) async {
    final api = _Api();
    await _mount(tester, api, const SalesTaskCenterPage(), {
      Perm.salesOrderView,
      Perm.salesShipmentView,
    });
    expect(api.reads.where((read) => read.path.startsWith('/sales/')), isEmpty);
    expect(api.writes, isEmpty);
    await _close(tester, api);
  });
  testWidgets(
    'finance audit category entry makes no unselected business row HTTP',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, const FinanceAuditCenterPage(), {
        Perm.salesQuoteFinanceView,
        Perm.salesOrderFinanceView,
      });
      expect(
        api.reads.where(
          (read) =>
              read.path.startsWith('/sales/') ||
              read.path.startsWith('/finance/'),
        ),
        isEmpty,
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'warehouse parent sends zero unselected row reads and selected source completes once',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, const WarehouseTaskCenterPage(), {
        Perm.stockDocView,
      });
      const path = '/warehouse/task-center/outbound';
      expect(find.byType(WarehouseTaskRecordsView), findsNothing);
      expect(api.requests(path), isEmpty);
      await tester.tap(find.text('出库'));
      await _frames(tester);
      await tester.tap(find.text('其它出库'));
      await _frames(tester);
      expect(find.text('OLD-W-OTHER-default'), findsOneWidget);
      expect(api.requests(path, kind: 'OTHER'), hasLength(1));
      expect(api.maximumActive, lessThanOrEqualTo(2));
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'mixed history grants produce no unselected source rows or ALL read',
    (tester) async {
      final api = _Api();
      await _mount(
        tester,
        api,
        const WarehouseTaskCenterPage(initialGroup: 'inbound'),
        {Perm.stockDocView, Perm.warehousePurchaseReceiptHistoryView},
      );
      final reads = api.requests('/warehouse/task-center/inbound');
      expect(reads, isEmpty);
      expect(reads.map((read) => read.kind), isNot(contains('PURCHASE')));
      expect(reads.map((read) => read.kind), isNot(contains('ALL')));
      expect(reads.every((read) => read.query['view'] == 'ACTIVE'), isTrue);
      await _close(tester, api);
    },
  );

  testWidgets(
    'late warehouse scope w1 cannot publish after w2 and grant revocation',
    (tester) async {
      final api = _Api()
        ..held['/warehouse/task-center/outbound|DRAW|w1'] = Completer<void>();
      final container = await _mount(
        tester,
        api,
        const WarehouseTaskCenterPage(initialGroup: 'outbound'),
        {Perm.stockDocView},
        scope: const WarehouseTaskScope.warehouse('w1'),
      );
      await tester.tap(find.text('生产领料'));
      await _frames(tester);
      container.read(_scope.notifier).state =
          const WarehouseTaskScope.warehouse('w2');
      await _frames(tester);
      expect(find.text('OLD-W-DRAW-w2'), findsOneWidget);
      api.release();
      await _frames(tester);
      expect(find.text('OLD-W-DRAW-w1'), findsNothing);
      container.read(_permissions.notifier).state = const {};
      await _frames(tester);
      expect(find.byType(WarehouseTaskRecordsView), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await _close(tester, api);
    },
  );

  testWidgets(
    'quality status aggregate remains independent and only selected phases are read',
    (tester) async {
      final api = _Api()..counts = Completer<void>();
      await _mount(tester, api, const WarehouseQualityResultsPage(), {
        Perm.warehouseIqcStockInView,
      });
      expect(find.text('OLD-Q-ALL'), findsOneWidget);
      expect(api.counts!.isCompleted, isFalse);
      expect(
        api.requests('/warehouse/quality-results/status-counts'),
        hasLength(1),
      );
      expect(
        api.requests('/warehouse/quality-results', kind: 'ALL'),
        hasLength(1),
      );
      await tester.tap(find.text('全部合格'));
      await _frames(tester);
      expect(find.text('OLD-Q-ALL_PASSED'), findsOneWidget);
      expect(
        api.requests('/warehouse/quality-results', kind: 'ALL_PASSED'),
        hasLength(1),
      );
      expect(
        api.reads.where((read) => read.query['view'] == 'HISTORY'),
        isEmpty,
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'production selects complete100000 summary with bounded100 batches and no unselected group reads',
    (tester) async {
      final api = _Api(scheduleTotal: 100000)..facets = Completer<void>();
      await _mount(tester, api, const ProductionBoardPage(), {
        Perm.productionPlanView,
        Perm.productionExecutionOverview,
      });
      expect(api.requests('/production/schedule/pending'), isEmpty);
      expect(api.requests('/production/execution-workbench'), isEmpty);
      await tester.tap(find.text('待排产'));
      await tester.pumpAndSettle(const Duration(milliseconds: 1));
      final table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
        find.byType(MasterDataTableView<SchedulePendingRow>),
      );
      final page = table.paginationRevision as PagedResult<SchedulePendingRow>;
      expect(page.items, hasLength(100000));
      expect(page.total, 100000);
      expect(page.totalPages, 1);
      expect(table.rowsController!.items, hasLength(100000));
      expect(page.items.last.orderItemId, 'item-99999');
      expect(api.requests('/production/schedule/pending'), hasLength(1000));
      expect(
        api
            .requests('/production/schedule/pending')
            .every((read) => read.query['size'] == 100),
        isTrue,
      );
      expect(api.facets!.isCompleted, isFalse);
      expect(table.isLoading, isFalse);
      expect(
        api
            .requests('/production/schedule/pending')
            .where((read) => read.query['page'] == 1),
        hasLength(1),
      );
      expect(
        api.reads.where((read) => read.path == '/production/plans/progress'),
        isEmpty,
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'workshop sends no unselected stage reads and only selected stage loads',
    (tester) async {
      final api = _Api();
      await _mount(tester, api, const ProductionWorkshopTasksPage(), {
        Perm.productionExecutionView,
      });
      const path = '/production/workshop-tasks';
      expect(api.requests(path), isEmpty);
      await tester.tap(find.text('开工准备'));
      await _frames(tester);
      expect(find.text('WORKSHOP-PREPARING'), findsOneWidget);
      expect(api.requests(path, kind: 'PREPARING'), hasLength(1));
      expect(
        api.requests(path).every((read) => read.query['size'] == 100),
        isTrue,
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'materialbin reads no unselected rows; chosen review and period aggregate refresh remain authoritative',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        const WarehouseTaskCenterPage(initialGroup: 'workshopMaterial'),
        {
          Perm.workshopMaterialView,
          Perm.workshopMaterialCount,
          Perm.stockCountWarehouseReview,
        },
      );
      expect(api.requests('/stock/count-requests'), isEmpty);
      expect(api.requests('/workshop-material/task-status'), isEmpty);
      await tester.tap(find.text('盘点审核'));
      await _frames(tester);
      expect(find.text('OLD-COUNT'), findsOneWidget);
      expect(api.requests('/stock/count-requests'), hasLength(1));
      await tester.tap(find.text('周期盘点'));
      await _frames(tester);
      expect(find.text('OLD-车间'), findsOneWidget);
      expect(api.requests('/workshop-material/task-status'), hasLength(1));
      api.revision = 'SCOPE';
      container.read(readScopeRevisionProvider.notifier).state++;
      await _frames(tester);
      expect(find.text('SCOPE-车间'), findsOneWidget);
      expect(find.text('OLD-车间'), findsNothing);
      container.read(dataWriteRevisionProvider.notifier).state++;
      api.revision = 'NEW';
      final refresh = Future<void>.sync(
        tester
            .widget<UtenRefreshButton>(find.byType(UtenRefreshButton).first)
            .onRefresh,
      );
      await _frames(tester);
      await refresh;
      expect(find.text('NEW-车间'), findsOneWidget);
      expect(
        api.requests('/workshop-material/task-status').length,
        greaterThan(1),
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'warehouse explicit refresh after write retirement starts one fresh current-source GET',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        const WarehouseTaskCenterPage(initialGroup: 'outbound'),
        {Perm.stockDocView},
      );
      await tester.tap(find.text('其它出库'));
      await _frames(tester);
      const path = '/warehouse/task-center/outbound';
      final before = api.requests(path, kind: 'OTHER').length;
      container.read(dataWriteRevisionProvider.notifier).state++;
      api.revision = 'NEW';
      api.held['$path|OTHER|default'] = Completer<void>();
      final refresh = Future<void>.sync(
        tester
            .widget<UtenRefreshButton>(find.byType(UtenRefreshButton).first)
            .onRefresh,
      );
      await _frames(tester);
      expect(api.requests(path, kind: 'OTHER').length - before, 1);
      api.release();
      await _frames(tester);
      await refresh;
      expect(find.text('NEW-W-OTHER-default'), findsOneWidget);
      expect(api.requests(path, kind: 'OTHER').length - before, 1);
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  testWidgets(
    'production board explicit refresh after write retirement starts one fresh schedule GET',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        const ProductionBoardPage(initialTab: 0),
        {Perm.productionPlanView},
      );
      const path = '/production/schedule/pending';
      final before = api
          .requests(path)
          .where((read) => read.query['page'] == 1)
          .length;
      container.read(dataWriteRevisionProvider.notifier).state++;
      api.revision = 'NEW';
      api.held['$path|ALL|default'] = Completer<void>();
      await tester.tap(find.byKey(const Key('production-pending-refresh')));
      await _frames(tester);
      expect(
        api.requests(path).where((read) => read.query['page'] == 1).length -
            before,
        1,
      );
      api.release();
      await _frames(tester);
      expect(find.text('NEW-SCHEDULE-0'), findsOneWidget);
      expect(
        api.requests(path).where((read) => read.query['page'] == 1).length -
            before,
        1,
      );
      expect(api.writes, isEmpty);
      await _close(tester, api);
    },
  );

  test(
    'same-api repository replacement performs a new selected read without a shared preparation',
    () async {
      final api = _Api();
      final first = ProductionExecutionWorkbenchRepository(api);
      final second = ProductionExecutionWorkbenchRepository(api);
      await first.groups();
      await first.workshopTasks(status: 'PREPARING');
      api.revision = 'NEW';
      final next = await second.groups();
      expect(next.items.single.rootLabel, 'NEW-GROUP');
      await second.workshopTasks(status: 'PREPARING');
      expect(api.requests('/production/execution-workbench'), hasLength(2));
      expect(api.requests('/production/workshop-tasks'), hasLength(2));
    },
  );
}
