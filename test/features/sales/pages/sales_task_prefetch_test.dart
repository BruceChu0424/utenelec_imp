import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import '../../../helpers/badge_summary_fixture.dart';

const _progressPath = '/sales/orders/progress';
const _allPermissions = <String>{
  Perm.salesOrderView,
  Perm.salesQuoteView,
  Perm.salesShipmentView,
  Perm.salesOtherShipmentView,
  Perm.salesReturnView,
};

class _Read {
  _Read(this.path, this.query);

  final String path;
  final Map<String, dynamic> query;
  String get stage => (query['stage'] ?? query['bucket'] ?? '').toString();

  @override
  String toString() => '$path $query';
}

class _PrefetchApi extends ApiClient {
  _PrefetchApi({this.progressRows = 1, this.progressTotal = 1}) : super(Dio());

  final int progressRows;
  final int progressTotal;
  String responseRevision = '';
  final businessWrites = <String>[];

  final rows = <_Read>[];
  final deferredRows = <String, Completer<void>>{};
  Completer<void>? deferredCounts;
  Completer<void>? deferredStatusCounts;
  int stageCountReads = 0;
  int activeRows = 0;
  int maximumActiveRows = 0;

  List<_Read> forStage(String stage) =>
      rows.where((read) => read.stage == stage).toList();

  void releaseRows() {
    for (final pending in deferredRows.values) {
      if (!pending.isCompleted) pending.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '$_progressPath/stage-counts') {
      stageCountReads++;
      await deferredCounts?.future;
      return const {
        'DRAFT': 2,
        'TASK_DRAFT': 2,
        'REJECTED': 1,
        'TASK_REJECTED': 1,
        'PRODUCING': 3,
        'TASK_PRODUCING': 3,
      };
    }
    if (path == '/documents/status-counts') {
      await deferredStatusCounts?.future;
      return const {'DRAFT': 0, 'ACTIONABLE_DRAFT': 0};
    }
    if (path == _progressPath ||
        const {
          '/sales/shipments',
          '/sales/quotes',
          '/sales/returns',
          '/sales/other-shipments',
        }.contains(path)) {
      final read = _Read(path, Map.of(query ?? const {}));
      final revision = responseRevision.isEmpty ? '' : '$responseRevision-';
      rows.add(read);
      activeRows++;
      if (activeRows > maximumActiveRows) maximumActiveRows = activeRows;
      try {
        await deferredRows['$path:${read.stage}']?.future;
        return {
          'items': path == _progressPath
              ? List.generate(progressRows, (index) {
                  final offset =
                      ((query?['page'] as int? ?? 1) - 1) *
                          (query?['size'] as int? ?? 50) +
                      index;
                  final suffix = progressRows == 1 ? '' : '-$offset';
                  return {
                    'orderId': 'progress-${read.stage}$suffix',
                    'billNo': '${revision}PROGRESS-${read.stage}$suffix',
                    'clientName': '进度预载客户',
                    'stage': read.stage == 'DRAFT' ? 'DRAFT' : 'PRODUCING',
                    'orderQty': 12,
                    'producedQty': 4,
                    'plannedQty': 12,
                    'shippedQty': 0,
                    'reservedQty': 0,
                  };
                })
              : [
                  {
                    'id': '${path.split('/').last}-${read.stage}',
                    'billNo':
                        '${revision}DOC-${path.split('/').last}-${read.stage}',
                    'billDate': '2026-11-03',
                    'clientName': '单据预载客户',
                    'status': 0,
                  },
                ],
          'page': query?['page'] ?? 1,
          'size': query?['size'] ?? 20,
          'total': path == _progressPath ? progressTotal : 1,
          'totalPages': path == _progressPath
              ? (progressTotal / (query?['size'] as int? ?? 50)).ceil()
              : 1,
        };
      } finally {
        activeRows--;
      }
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  void _recordWrite(String method, String path) {
    if (isBusinessWrite(RequestOptions(path: path, method: method))) {
      businessWrites.add('$method $path');
    }
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    _recordWrite('POST', path);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    _recordWrite('PUT', path);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) async {
    _recordWrite('PATCH', path);
    return const {};
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    _recordWrite('DELETE', path);
  }
}

Future<void> _mount(
  WidgetTester tester,
  _PrefetchApi api, {
  Set<String> permissions = _allPermissions,
  String? initialGroup,
  int draftCount = 0,
  ValueNotifier<Widget>? pageHost,
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
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'prefetch-sales'),
        ),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {
              'salesStage.DRAFT': draftCount,
              'salesStage.REJECTED': 0,
              'salesStage.PENDING': 0,
              'salesStage.PRODUCING': 0,
              'salesStage.SHIPPABLE': 0,
              'salesStage.SHIPMENT_PENDING': 0,
              'salesStage.WAREHOUSE_PENDING': 0,
            },
          ),
        ),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: pageHost == null
            ? SalesTaskCenterPage(initialGroup: initialGroup)
            : ValueListenableBuilder<Widget>(
                valueListenable: pageHost,
                builder: (context, page, child) => page,
              ),
      ),
    ),
  );
  await _pumpReads(tester);
}

Future<void> _pumpReads(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Finder _segment(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenSegmentBadgeLabel && widget.label == label,
);

Future<void> _close(WidgetTester tester, _PrefetchApi api) async {
  api.releaseRows();
  final counts = api.deferredCounts;
  if (counts != null && !counts.isCompleted) counts.complete();
  final statusCounts = api.deferredStatusCounts;
  if (statusCounts != null && !statusCounts.isCompleted) {
    statusCounts.complete();
  }
  await _pumpReads(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('进页预热首个授权大类，选择阶段复用已完成的首屏', (tester) async {
    final api = _PrefetchApi();
    await _mount(tester, api);

    expect(find.text('在上方选择分类后开始浏览'), findsOneWidget);
    expect(api.rows.map((read) => read.stage).toSet(), {
      'DRAFT',
      'IN_PROGRESS',
      'READY_TO_SHIP',
    });
    expect(api.rows.every((read) => read.path == _progressPath), isTrue);
    expect(api.rows.every((read) => read.query['page'] == 1), isTrue);
    expect(api.rows.every((read) => read.query['size'] == 50), isTrue);
    expect(
      api.rows.every((read) => read.query['originScope'] == 'CURRENT'),
      isTrue,
    );
    expect(api.stageCountReads, 0);

    await tester.tap(find.text('订货进度'));
    await _pumpReads(tester);
    final draft = tester.widget<UtenSegmentBadgeLabel>(_segment('草稿'));
    expect(draft.count, 0);
    expect(api.stageCountReads, 0, reason: '子分类采用父分类已加载的同源计数');
    expect(find.text('PROGRESS-IN_PROGRESS'), findsNothing);

    await tester.tap(find.text('进行中'));
    await _pumpReads(tester);
    expect(api.forStage('IN_PROGRESS'), hasLength(1));
    expect(find.text('PROGRESS-IN_PROGRESS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });

  testWidgets('选择可采纳进行中的预热，慢徽章计数不阻塞表格', (tester) async {
    final api = _PrefetchApi()
      ..deferredStatusCounts = Completer<void>()
      ..deferredRows['/sales/shipments:ACTIVE'] = Completer<void>();
    await _mount(tester, api, initialGroup: 'shipments');
    expect(api.forStage('ACTIVE'), hasLength(1));

    await tester.tap(find.text('待办与进行中'));
    await _pumpReads(tester);
    expect(api.forStage('ACTIVE'), hasLength(1));
    expect(find.text('DOC-shipments-ACTIVE'), findsNothing);

    api.deferredRows['/sales/shipments:ACTIVE']!.complete();
    await _pumpReads(tester);
    expect(find.text('DOC-shipments-ACTIVE'), findsOneWidget);
    expect(api.deferredStatusCounts!.isCompleted, isFalse);
    expect(api.forStage('ACTIVE'), hasLength(1));
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });

  testWidgets('非历史首屏预热最多两条并发，完成后继续剩余阶段', (tester) async {
    final api = _PrefetchApi();
    for (final stage in ['DRAFT', 'IN_PROGRESS', 'READY_TO_SHIP']) {
      api.deferredRows['$_progressPath:$stage'] = Completer<void>();
    }
    await _mount(tester, api, initialGroup: 'progress');
    expect(api.rows, hasLength(2));
    expect(api.activeRows, 2);
    expect(api.maximumActiveRows, 2);

    api.deferredRows['$_progressPath:${api.rows.first.stage}']!.complete();
    await _pumpReads(tester);
    expect(api.rows, hasLength(3));
    expect(api.maximumActiveRows, 2);
    await _close(tester, api);
  });

  testWidgets('红数自动选中草稿也采用同一首屏请求', (tester) async {
    final api = _PrefetchApi();
    await _mount(tester, api, initialGroup: 'progress', draftCount: 2);
    expect(api.forStage('DRAFT'), hasLength(1));
    expect(find.text('PROGRESS-DRAFT'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });

  testWidgets('只预热已选大类，保留单据原首屏大小且不读取历史', (tester) async {
    final api = _PrefetchApi();
    await _mount(tester, api, initialGroup: 'quotes');
    expect(api.rows, isNotEmpty);
    expect(api.rows.every((read) => read.path == '/sales/quotes'), isTrue);
    expect(api.rows.every((read) => read.query['page'] == 1), isTrue);
    expect(api.rows.every((read) => read.query['size'] == 20), isTrue);
    expect(
      api.rows.every(
        (read) =>
            read.stage.isNotEmpty &&
            !const {'APPROVED', 'REVERSED'}.contains(read.stage) &&
            read.query['dateFrom'] == null &&
            read.query['dateTo'] == null,
      ),
      isTrue,
    );
    expect(find.text('在上方选择状态或历史记录后开始浏览'), findsOneWidget);
    await _close(tester, api);
  });

  testWidgets('仅出货查看权限时不预热订货和其他业务列表', (tester) async {
    final api = _PrefetchApi();
    await _mount(tester, api, permissions: const {Perm.salesShipmentView});
    expect(api.rows, isNotEmpty);
    expect(api.rows.every((read) => read.path == '/sales/shipments'), isTrue);
    expect(api.stageCountReads, 0);
    expect(
      api.rows.every((read) => read.query['shipmentKind'] == null),
      isTrue,
    );
    expect(api.rows.map((read) => read.stage), isNot(contains('SHIPPED')));
    expect(api.rows.map((read) => read.stage), isNot(contains('REVERSED')));
    expect(find.text('订货进度'), findsNothing);
    expect(find.text('报价单'), findsNothing);
    await _close(tester, api);
  });

  testWidgets('快速切父分类后，旧分类迟到表格不能覆盖新分类', (tester) async {
    final api = _PrefetchApi()
      ..deferredRows['$_progressPath:IN_PROGRESS'] = Completer<void>();
    await _mount(tester, api, initialGroup: 'progress');
    await tester.tap(find.text('进行中'));
    await _pumpReads(tester);

    await tester.tap(find.text('报价单'));
    await _pumpReads(tester);
    await tester.tap(find.text('待办与进行中'));
    await _pumpReads(tester);
    expect(find.text('DOC-quotes-ACTIVE'), findsOneWidget);

    api.deferredRows['$_progressPath:IN_PROGRESS']!.complete();
    await _pumpReads(tester);
    expect(find.text('PROGRESS-IN_PROGRESS'), findsNothing);
    expect(find.text('DOC-quotes-ACTIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });

  testWidgets('历史专用大类只按选中的历史时间范围读取，不做额外预热', (tester) async {
    final api = _PrefetchApi();
    await _mount(
      tester,
      api,
      permissions: const {Perm.salesOtherShipmentView},
      initialGroup: 'otherShipments',
    );
    final history = api.rows.where(
      (read) => read.path == '/sales/other-shipments',
    );
    expect(history, hasLength(1));
    expect(history.single.query['dateFrom'], isNotNull);
    expect(history.single.query['dateTo'], isNotNull);
    expect(history.single.query['originScope'], 'ALL');
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });

  testWidgets('十万条分页元数据及完整50行预热首屏保留，真实滚动可到末行', (tester) async {
    final api = _PrefetchApi(progressRows: 50, progressTotal: 100000);
    await _mount(tester, api, initialGroup: 'progress');
    await tester.tap(find.text('进行中'));
    await _pumpReads(tester);

    final table = tester.widget<MasterDataTableView<SalesOrderProgressRow>>(
      find.byType(MasterDataTableView<SalesOrderProgressRow>),
    );
    final page = table.paginationRevision as PagedResult<SalesOrderProgressRow>;
    expect(page.items, hasLength(50));
    expect(page.size, 50);
    expect(page.total, 100000);
    expect(page.totalPages, 2000);
    expect(table.totalPages, 2000);
    expect(
      table.rowsController!.items.map((row) => row.orderId).toSet(),
      containsAll({for (var i = 0; i < 50; i++) 'progress-IN_PROGRESS-$i'}),
    );
    expect(find.text('PROGRESS-IN_PROGRESS-0'), findsOneWidget);
    expect(
      api.forStage('IN_PROGRESS').where((read) => read.query['page'] == 1),
      hasLength(1),
    );

    final lastRow = find.text('PROGRESS-IN_PROGRESS-49');
    bool lastRowVisible() {
      if (lastRow.evaluate().isEmpty) return false;
      final bounds = tester.getRect(lastRow);
      return bounds.top >= 128 && bounds.bottom < 1050;
    }

    for (var i = 0; i < 30 && !lastRowVisible(); i++) {
      await tester.dragFrom(const Offset(900, 780), const Offset(0, -300));
      // Mount work is deliberately spread across frames. Deliver those frames
      // between gestures instead of skipping a whole viewport in one frame.
      await _pumpReads(tester);
    }
    expect(
      lastRow,
      findsOneWidget,
      reason: tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .map(
            (state) =>
                '${state.widget.axisDirection}:${state.position.pixels}/${state.position.maxScrollExtent}',
          )
          .join(', '),
    );
    expect(lastRowVisible(), isTrue);
    expect(tester.takeException(), isNull);
    expect(api.businessWrites, isEmpty);
    await _close(tester, api);
  });

  testWidgets('连续20次父类切换与阶段连点，迟到结果及离开重进不会复活旧数据或写入', (tester) async {
    final api = _PrefetchApi()
      ..responseRevision = 'OLD'
      ..deferredRows['$_progressPath:IN_PROGRESS'] = Completer<void>()
      ..deferredRows['$_progressPath:READY_TO_SHIP'] = Completer<void>();
    final pages = ValueNotifier<Widget>(
      const SalesTaskCenterPage(initialGroup: 'quotes'),
    );
    addTearDown(pages.dispose);
    await _mount(tester, api, pageHost: pages);

    for (var i = 0; i < 10; i++) {
      await tester.tap(find.text('订货进度'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.text('进行中'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.text('可发货'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.text('报价单'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.tap(find.text('待办与进行中'));
      await tester.pump(const Duration(milliseconds: 1));
    }
    await _pumpReads(tester);
    expect(find.text('OLD-DOC-quotes-ACTIVE'), findsOneWidget);

    api.deferredRows['$_progressPath:IN_PROGRESS']!.complete();
    await _pumpReads(tester);
    expect(find.text('OLD-PROGRESS-IN_PROGRESS'), findsNothing);
    expect(find.text('OLD-DOC-quotes-ACTIVE'), findsOneWidget);

    pages.value = const Scaffold(body: Text('LEFT-SALES-TASKS'));
    await _pumpReads(tester);
    api.deferredRows['$_progressPath:READY_TO_SHIP']!.complete();
    await _pumpReads(tester);
    expect(find.text('LEFT-SALES-TASKS'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text('LEFT-SALES-TASKS')),
    );
    // Model a confirmed business-data change while the page is absent. This
    // retires the retained read leases without executing a business command.
    container.read(dataWriteRevisionProvider.notifier).state++;
    api.responseRevision = 'NEW';
    pages.value = const SalesTaskCenterPage(initialGroup: 'progress');
    await _pumpReads(tester);
    await tester.tap(find.text('进行中'));
    await _pumpReads(tester);
    expect(find.text('NEW-PROGRESS-IN_PROGRESS'), findsOneWidget);
    expect(find.text('OLD-PROGRESS-IN_PROGRESS'), findsNothing);

    api.responseRevision = 'REFRESHED';
    tester
        .widget<MasterDataTableView<SalesOrderProgressRow>>(
          find.byType(MasterDataTableView<SalesOrderProgressRow>),
        )
        .onRetry!();
    await _pumpReads(tester);
    expect(find.text('REFRESHED-PROGRESS-IN_PROGRESS'), findsOneWidget);
    expect(find.text('NEW-PROGRESS-IN_PROGRESS'), findsNothing);
    expect(api.businessWrites, isEmpty);
    expect(tester.takeException(), isNull);
    await _close(tester, api);
  });
}
