import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_short_delivery_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_short_delivery_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/subcontract_short_delivery.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';
import 'fake_subcontract_draw_gateway.dart';

void main() {
  testWidgets(
    'shared draw counts render before the direct access gate permits actions',
    (tester) async {
      final draw = _DelayedDrawCounts();
      final badges = FixedBadgeSummaryNotifier(
        badgeSummaryFixture(
          facts: const {
            'subcontractDraw.drawable': 7,
            'subcontractDraw.submitted': 2,
          },
        ),
      );
      await _pump(
        tester,
        SubcontractDecompositionPage(
          repository: _DelayedWorkbench(immediate: true),
          drawRepository: draw,
          initialSegment: 'WAITING_ORDER',
        ),
        badges: badges,
        settle: false,
      );
      final toolbar = tester.widget<UtenFilterToolbar<dynamic>>(
        find.byWidgetPredicate((widget) => widget is UtenFilterToolbar),
      );
      expect(toolbar.segments[1].count, 7);
      expect(toolbar.segments[1].inProgressCount, 2);
      final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
        find.byKey(const Key('subcontract-decomposition-pending-table')),
      );
      table.onSelectedIdsChanged!({'draw-draw-ready'});
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('subcontract-draw-batch')), findsNothing);
      draw.pending.complete((drawable: 7, submitted: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('subcontract-draw-batch')), findsOneWidget);
      expect(draw.countCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nonempty subcontract documents publish before supplier lookup', (
    tester,
  ) async {
    final api = _HangingSupplierLookupApi();
    final router = GoRouter(
      initialLocation: '/subcontract/orders',
      routes: [
        GoRoute(
          path: '/subcontract/orders',
          builder: (_, _) => const SubcontractOrderWorkspacePage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pump(
      tester,
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
      api: api,
    );
    await selectFilterSegment(tester, '进行中');
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final table = tester.widget<MasterDataTableView<SubcontractDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SubcontractDocListItem>,
      ),
    );
    expect(table.items.single.id, 'order-1');
    expect(table.isLoading, isFalse);
    expect(api.lookups, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'history controls and table mount before delayed workbench rows',
    (tester) async {
      final gateway = _DelayedWorkbench();
      await _pump(
        tester,
        SubcontractDecompositionPage(
          repository: gateway,
          drawRepository: FakeSubcontractDrawGateway(),
        ),
      );
      await selectFilterSegment(tester, '历史记录');
      await tester.pump();
      final table = find.byKey(const Key('subcontract-decomposition-table'));
      final time = find.byKey(
        const Key('subcontract-decomposition-history-time'),
      );
      expect(table, findsOneWidget);
      expect(time, findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<OperationsWorkbenchTask>>(table)
            .isLoading,
        isTrue,
      );
      gateway.pending.removeAt(0).complete(_workbenchData);
      await tester.pumpAndSettle();
      final tableElement = tester.element(table);
      await selectFilterSegment(tester, '全部');
      await tester.pump();
      expect(tester.element(table), same(tableElement));
      expect(time, findsOneWidget);
      expect(tester.widget<UtenHistoryTimeFilter>(time).value.all, isTrue);
      gateway.pending.removeAt(0).completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(tester.element(table), same(tableElement));
      expect(time, findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<OperationsWorkbenchTask>>(table)
            .error,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short delivery rows publish with unknown shared counts and no duplicate read',
    (tester) async {
      final repository = _DelayedCounts();
      await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
      final table = _shortTable(tester);
      expect(repository.countCalls, 0);
      expect(table.isLoading, isFalse);
      expect(table.items, isEmpty);
      expect(_shortToolbar(tester).segments.first.count, isNull);
      expect(_shortTable(tester).isLoading, isFalse);
      expect(_shortTable(tester).error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short delivery counts follow the parent snapshot without reloading rows',
    (tester) async {
      final repository = _DelayedCounts();
      final badges = FixedBadgeSummaryNotifier(
        badgeSummaryFixture(
          facts: const {
            'subcontractShortDelivery.pending': 2,
            'subcontractShortDelivery.tolerant': 3,
            'subcontractShortDelivery.waiting': 4,
          },
        ),
      );
      await _pump(
        tester,
        SubcontractShortDeliveryPage(repository: repository),
        badges: badges,
      );
      expect(_shortToolbar(tester).segments.map((s) => s.count).take(3), [
        2,
        3,
        4,
      ]);
      await selectFilterSegment(tester, '分批等待中');
      await tester.pumpAndSettle();
      final rowCalls = repository.rowCalls;
      badges.emit(
        badgeSummaryFixture(
          facts: const {
            'subcontractShortDelivery.pending': 7,
            'subcontractShortDelivery.tolerant': 0,
            'subcontractShortDelivery.waiting': 9,
          },
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = tester
          .widget<UtenFilterToolbar<SubcontractShortDeliverySegment>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is UtenFilterToolbar<SubcontractShortDeliverySegment>,
            ),
          );
      expect(toolbar.segments.first.count, 7);
      expect(repository.rowCalls, rowCalls);
      expect(repository.countCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied short delivery rows clear accepted data and expose retry',
    (tester) async {
      final repository = _DelayedCounts()..rows = [_shortCase];
      await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
      expect(_shortTable(tester).items.single.id, _shortCase.id);
      repository.rowError = ApiException('FORBIDDEN', '无查看权限', httpStatus: 403);
      await selectFilterSegment(tester, '分批等待中');
      await tester.pumpAndSettle();
      expect(_shortTable(tester).error, '无查看权限');
      expect(_shortTable(tester).items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader changes clear accepted short delivery rows and retire old pending reads',
    (tester) async {
      final repository = _DelayedCounts()..rows = [_shortCase];
      await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
      expect(_shortTable(tester).items.single.id, _shortCase.id);
      repository.rowGate =
          Completer<PagedResult<SubcontractShortDeliveryCase>>();
      await selectFilterSegment(tester, '分批等待中');
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(
          find.byKey(const Key('subcontract-short-delivery-table')),
        ),
      );
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(_shortTable(tester).items, isEmpty);
      expect(_shortTable(tester).isLoading, isFalse);
      repository.rowGate!.complete(
        const PagedResult(
          items: [_shortCase],
          page: 1,
          size: 50,
          total: 1,
          totalPages: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(_shortTable(tester).items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

const _shortCase = SubcontractShortDeliveryCase(
  id: 'case-old-reader',
  orderId: 'order-old',
  orderBillNo: 'EO-OLD',
  orderItemId: 'item-old',
  orderedQty: 100,
  deliveredQty: 50,
  shortfallQty: 50,
  shortfallPct: 50,
  severity: 'SEVERE',
  status: 'PENDING_OWNER',
  effectiveStatus: 'PENDING_OWNER',
  version: 1,
);

UtenFilterToolbar<SubcontractShortDeliverySegment> _shortToolbar(
  WidgetTester tester,
) => tester.widget(
  find.byWidgetPredicate(
    (widget) => widget is UtenFilterToolbar<SubcontractShortDeliverySegment>,
  ),
);

MasterDataTableView<SubcontractShortDeliveryCase> _shortTable(
  WidgetTester tester,
) => tester.widget(find.byKey(const Key('subcontract-short-delivery-table')));

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  ApiClient? api,
  FixedBadgeSummaryNotifier? badges,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api ?? _NoopApi()),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        if (badges == null)
          fixedBadgeSummaryOverride()
        else
          badgeSummaryProvider.overrideWith(() => badges),
      ],
      child: page is MaterialApp
          ? page
          : MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: page,
            ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

const _workbenchData = OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: OperationsWorkbenchSummary(
    totalTasks: 0,
    overdueTasks: 0,
    openTasks: 0,
    openQty: 0,
    statusCounts: {},
  ),
  items: [],
  page: 1,
  size: 50,
  total: 0,
  totalPages: 0,
  capabilities: OperationsWorkbenchCapabilities(),
);

class _DelayedWorkbench
    implements OperationsWorkbenchGateway, OperationsWorkbenchOverviewGateway {
  _DelayedWorkbench({this.immediate = false});
  final bool immediate;
  final pending = <Completer<OperationsWorkbenchData>>[];

  @override
  Future<OperationsWorkbenchData> loadOverview({
    required OperationsWorkbenchDepartment department,
    String? keyword,
  }) async => _workbenchData;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) {
    if (immediate) return Future.value(_workbenchData);
    final completer = Completer<OperationsWorkbenchData>();
    pending.add(completer);
    return completer.future;
  }
}

class _DelayedDrawCounts extends FakeSubcontractDrawGateway {
  _DelayedDrawCounts() : super(rows: [drawRow('draw-ready')]);
  final pending = Completer<({int drawable, int submitted})>();

  @override
  Future<({int drawable, int submitted})> drawCounts() {
    countCalls++;
    return pending.future;
  }
}

class _DelayedCounts extends SubcontractShortDeliveryRepository {
  _DelayedCounts() : super(_NoopApi());
  int countCalls = 0;
  int rowCalls = 0;
  Object? rowError;
  List<SubcontractShortDeliveryCase> rows = const [];
  Completer<PagedResult<SubcontractShortDeliveryCase>>? rowGate;

  @override
  Future<SubcontractShortDeliveryCounts> counts() {
    countCalls++;
    return Future.error(StateError('Counts must come from the shared summary'));
  }

  @override
  Future<PagedResult<SubcontractShortDeliveryCase>> list({
    String segment = 'PENDING',
    String? keyword,
    String? supplierId,
    String? orderId,
    String? dateFrom,
    String? dateTo,
    int page = 1,
    int size = 50,
    String? sort,
    String? order,
    String? orderBillNo,
    Map<String, String?> columnFilters = const {},
  }) async {
    rowCalls++;
    if (rowError != null) throw rowError!;
    if (rowGate != null) return rowGate!.future;
    return PagedResult(
      items: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: rows.isEmpty ? 0 : 1,
    );
  }
}

class _NoopApi extends ApiClient {
  _NoopApi() : super(Dio(BaseOptions(baseUrl: 'http://localhost/api')));

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _HangingSupplierLookupApi extends _NoopApi {
  int lookups = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/subcontract/orders') {
      return {
        'items': [
          {
            'id': 'order-1',
            'billNo': 'EO-1',
            'supplierId': 'supplier-1',
            'status': 1,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) {
    if (path == '/master/suppliers/lookup') {
      lookups++;
      return Completer<List<Map<String, dynamic>>>().future;
    }
    return Future.value([]);
  }
}
