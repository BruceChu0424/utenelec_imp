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
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_short_delivery_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_short_delivery_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/subcontract_short_delivery.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';
import 'fake_subcontract_draw_gateway.dart';

void main() {
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

  testWidgets('empty short delivery rows publish while category count waits', (
    tester,
  ) async {
    final repository = _DelayedCounts();
    await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
    final table = _shortTable(tester);
    expect(repository.pending, hasLength(1));
    expect(table.isLoading, isFalse);
    expect(table.items, isEmpty);
    repository.pending.single.completeError(StateError('count offline'));
    await tester.pumpAndSettle();
    expect(_shortTable(tester).isLoading, isFalse);
    expect(_shortTable(tester).error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('obsolete short delivery count cannot replace the newer count', (
    tester,
  ) async {
    final repository = _DelayedCounts();
    await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
    await selectFilterSegment(tester, '分批等待中');
    await tester.pumpAndSettle();
    expect(repository.pending, hasLength(2));
    repository.pending[1].complete(
      const SubcontractShortDeliveryCounts(pending: 7),
    );
    await tester.pumpAndSettle();
    repository.pending[0].complete(
      const SubcontractShortDeliveryCounts(pending: 99),
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('denied short delivery count clears rows and exposes retry', (
    tester,
  ) async {
    final repository = _DelayedCounts();
    await _pump(tester, SubcontractShortDeliveryPage(repository: repository));
    repository.pending.single.completeError(
      ApiException('FORBIDDEN', '无查看权限', httpStatus: 403),
    );
    await tester.pumpAndSettle();
    expect(_shortTable(tester).error, '无查看权限');
    expect(_shortTable(tester).items, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

MasterDataTableView<SubcontractShortDeliveryCase> _shortTable(
  WidgetTester tester,
) => tester.widget(find.byKey(const Key('subcontract-short-delivery-table')));

Future<void> _pump(WidgetTester tester, Widget page, {ApiClient? api}) async {
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
        fixedBadgeSummaryOverride(),
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
  await tester.pumpAndSettle();
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
    final completer = Completer<OperationsWorkbenchData>();
    pending.add(completer);
    return completer.future;
  }
}

class _DelayedCounts extends SubcontractShortDeliveryRepository {
  _DelayedCounts() : super(_NoopApi());
  final pending = <Completer<SubcontractShortDeliveryCounts>>[];

  @override
  Future<SubcontractShortDeliveryCounts> counts() {
    final completer = Completer<SubcontractShortDeliveryCounts>();
    pending.add(completer);
    return completer.future;
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
  }) async =>
      const PagedResult(items: [], page: 1, size: 50, total: 0, totalPages: 0);
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
