import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_task_center_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_records_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';

const warehouseTestOutboundSources = {
  'SALES': '销售出库',
  'SUBCONTRACT': '委外出库',
  'DRAW': '生产领料',
  'OTHER': '其它出库',
  'FINISHED': '产成品出库',
};
const warehouseTestInboundSources = {
  'PURCHASE': '采购入库',
  'SUBCONTRACT': '委外入库',
  'FINISHED': '产成品入库',
  'OTHER': '其它入库',
  'RETURN': '生产退料',
};

WarehouseTaskCenterRecord warehouseTestRecord({
  required String source,
  required String record,
  required String id,
  required String billNo,
  String? status,
  String? statusLabel,
  String action = 'NONE',
  bool canHandle = false,
  Map<String, dynamic> data = const {},
}) => WarehouseTaskCenterRecord(
  rowKey: '$source:$record:$id',
  id: id,
  sourceType: source,
  recordType: record,
  status: status ?? '${source}_READY',
  statusLabel: statusLabel ?? '$source · 待办理',
  tone: 'accent',
  billNo: billNo,
  sourceDocNo: 'SOURCE-$billNo',
  warehouseName: '原料仓',
  partyName: '示例往来方',
  responsibleName: '仓管甲',
  businessDate: '2026-10-12',
  lineCount: 2,
  action: action,
  canHandle: canHandle,
  targetId: id,
  actionData: data,
);

class WarehouseTaskRecordsCall {
  WarehouseTaskRecordsCall({
    required this.direction,
    required this.source,
    required this.status,
    required this.page,
    required this.scope,
    this.keyword,
    this.billNo,
    this.sort,
    this.order,
  });
  final WarehouseTaskDirection direction;
  final String source;
  final String? status;
  final int page;
  final WarehouseTaskScope scope;
  final String? keyword;
  final String? billNo;
  final String? sort;
  final String? order;
  final result = Completer<WarehouseTaskCenterPageResult>();
}

class WarehouseTaskRecordsFakeGateway implements WarehouseTaskCenterGateway {
  WarehouseTaskRecordsFakeGateway(this.rows, {this.controlled = false});
  final List<WarehouseTaskCenterRecord> rows;
  final bool controlled;
  final calls = <WarehouseTaskRecordsCall>[];

  WarehouseTaskCenterPageResult pageOf(
    List<WarehouseTaskCenterRecord> items, {
    int page = 1,
    int size = 20,
    int? total,
  }) {
    final count = total ?? items.length;
    final statuses = {for (final row in rows) row.status: row.statusLabel};
    return WarehouseTaskCenterPageResult(
      items: items,
      page: page,
      size: size,
      total: count,
      totalPages: (count + size - 1) ~/ size,
      facets: {
        'status': [
          for (final entry in statuses.entries)
            MasterFacetBucket(value: entry.key, label: entry.value, count: 0),
        ],
        'billNo': [
          for (final row in rows)
            MasterFacetBucket(
              value: row.billNo ?? '',
              label: row.billNo,
              count: 1,
            ),
        ],
      },
    );
  }

  @override
  Future<WarehouseTaskCenterPageResult> list({
    required WarehouseTaskDirection direction,
    String source = 'ALL',
    String? status,
    String? keyword,
    String? billNo,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope warehouseScope = const WarehouseTaskScope.all(),
    int page = 1,
    int size = 20,
    String? sort,
    String? order,
  }) async {
    final call = WarehouseTaskRecordsCall(
      direction: direction,
      source: source,
      status: status,
      keyword: keyword,
      billNo: billNo,
      scope: warehouseScope,
      page: page,
      sort: sort,
      order: order,
    );
    calls.add(call);
    if (controlled) return call.result.future;
    final keywordText = keyword?.trim().toLowerCase() ?? '';
    final matching = rows
        .where(
          (row) =>
              (source == 'ALL' || row.sourceType == source) &&
              (status == null || row.status == status) &&
              (billNo == null || row.billNo == billNo) &&
              (keywordText.isEmpty ||
                  '${row.billNo} ${row.statusLabel}'.toLowerCase().contains(
                    keywordText,
                  )),
        )
        .toList();
    return pageOf(
      matching.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: matching.length,
    );
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? lastPath;
  Map<String, dynamic>? lastQuery;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.authMe) {
      // Authenticated fixture identities receive a complete authoritative
      // snapshot, with no delegable surfaces or ordinary document writes.
      return const {
        'session': {
          'delegableSurfaceKeys': <String>[],
          'documentScopes': <String, dynamic>{},
          'preferences': <String, Object?>{},
        },
      };
    }
    lastPath = path;
    lastQuery = Map.of(query ?? const {});
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }
}

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.values);
  final List<FormDraft> values;
  @override
  List<FormDraft> build() => values;
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(super.tableKey, this.seed);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() {
    super.build();
    return seed;
  }

  @override
  void persist() {}
}

class _ViewSpec {
  const _ViewSpec({
    this.direction = WarehouseTaskDirection.outbound,
    this.source = 'ALL',
    this.sources = warehouseTestOutboundSources,
  });
  final WarehouseTaskDirection direction;
  final String source;
  final Map<String, String> sources;
}

final _view = StateProvider<_ViewSpec>((_) => const _ViewSpec());
final _actor = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'actor-a'),
);
final _warehouse = StateProvider<WarehouseTaskScope>(
  (_) => const WarehouseTaskScope.warehouse('warehouse-a'),
);
final _server = StateProvider<String>((_) => 'https://unit.test/api');

class _Harness {
  _Harness(this.container, this.router, this.opened);
  final ProviderContainer container;
  final GoRouter router;
  final List<Uri> opened;
}

Future<_Harness> _pump(
  WidgetTester tester,
  WarehouseTaskRecordsFakeGateway gateway, {
  _ViewSpec spec = const _ViewSpec(),
  List<FormDraft> drafts = const [],
  PlatformTableLayout? layout,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      _view.overrideWith((_) => spec),
      warehouseTaskCenterRepositoryProvider.overrideWithValue(gateway),
      apiClientProvider.overrideWithValue(_Api()),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
      warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_warehouse)),
      currentPermissionsProvider.overrideWithValue({
        Perm.stockDocView,
        Perm.stockDocCreate,
        Perm.stockDocApprove,
        Perm.warehouseInboundView,
        Perm.warehouseInboundStockIn,
        Perm.warehouseSalesOutboundView,
        Perm.warehouseSalesOutboundExecute,
        Perm.subcontractOutboundView,
        Perm.subcontractMaterialIssueEdit,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftsProvider.overrideWith(() => _Drafts(drafts)),
      fixedBadgeSummaryOverride(badgeSummaryFixture()),
      if (layout != null)
        platformTableLayoutProvider(
          'warehouse.task-center.${spec.direction.name}.${spec.source}',
        ).overrideWith(
          () => _Layout(
            'warehouse.task-center.${spec.direction.name}.${spec.source}',
            layout,
          ),
        ),
    ],
  );
  addTearDown(container.dispose);
  final opened = <Uri>[];
  Widget target(GoRouterState state) {
    opened.add(state.uri);
    return const Scaffold(body: Text('已打开原来源'));
  }

  final router = GoRouter(
    initialLocation: '/records',
    routes: [
      GoRoute(
        path: '/records',
        builder: (_, _) => Consumer(
          builder: (context, ref, _) {
            final value = ref.watch(_view);
            return Scaffold(
              body: WarehouseListScope(
                scope: ref.watch(warehouseTaskScopeProvider),
                child: WarehouseTaskRecordsView(
                  key: const Key('same-record-view'),
                  direction: value.direction,
                  source: value.source,
                  sources: value.sources,
                ),
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: RouteName.warehouseArrivalRegistration,
        builder: (_, state) => target(state),
      ),
      GoRoute(
        path: '/warehouse/OTHER_OUT/new',
        builder: (_, state) => target(state),
      ),
      GoRoute(
        path: '/warehouse/sales-outbound/:id',
        builder: (_, state) => target(state),
      ),
      GoRoute(
        path: '/warehouse/subcontract-outbound/:id',
        builder: (_, state) => target(state),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return _Harness(container, router, opened);
}

MasterDataTableView<WarehouseTaskCenterRecord> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<WarehouseTaskCenterRecord>));

Future<void> _doubleTap(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'repository sends source/status/date/scope before server pagination',
    () async {
      final api = _Api();
      await WarehouseTaskCenterRepository(api).list(
        direction: WarehouseTaskDirection.inbound,
        source: 'PURCHASE',
        status: 'PURCHASE_RECEIPT_DRAFT',
        keyword: '  receipt  ',
        billNo: '  PR-001  ',
        dateFrom: '2026-10-01',
        dateTo: '2026-10-12',
        warehouseScope: const WarehouseTaskScope.warehouse('warehouse-2'),
        page: 2,
        sort: 'businessDate',
        order: 'desc',
      );
      expect(api.lastPath, '/warehouse/task-center/inbound');
      expect(api.lastQuery, {
        'source': 'PURCHASE',
        'status': 'PURCHASE_RECEIPT_DRAFT',
        'keyword': 'receipt',
        'billNo': 'PR-001',
        'dateFrom': '2026-10-01',
        'dateTo': '2026-10-12',
        'scopeWarehouseId': 'warehouse-2',
        'page': 2,
        'size': 20,
        'sort': 'businessDate',
        'order': 'desc',
      });
    },
  );

  testWidgets('状态与来源表头查询完整服务端结果，翻页/清空/重排返回正确范围', (tester) async {
    final rows = [
      for (var index = 1; index <= 20; index++)
        warehouseTestRecord(
          source: 'SALES',
          record: 'SALES_SHIPMENT',
          id: 'sales-$index',
          billNo: 'SALES-$index',
        ),
      warehouseTestRecord(
        source: 'OTHER',
        record: 'STOCK_DOC',
        id: 'late-21',
        billNo: 'LATE-21',
        status: 'OTHER_DRAFT',
      ),
    ];
    final gateway = WarehouseTaskRecordsFakeGateway(rows);
    await _pump(tester, gateway);
    expect(find.text('LATE-21'), findsNothing);
    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(gateway.calls.last.page, 2);
    expect(find.text('LATE-21'), findsOneWidget);
    _table(tester).onFilterChanged('status', 'OTHER_DRAFT');
    await tester.pumpAndSettle();
    expect(gateway.calls.last.page, 1);
    expect(gateway.calls.last.status, 'OTHER_DRAFT');
    expect(find.text('LATE-21'), findsOneWidget);
    _table(tester).onFilterChanged('status', 'source:OTHER');
    await tester.pumpAndSettle();
    expect(gateway.calls.last.source, 'OTHER');
    expect(gateway.calls.last.status, isNull);
    _table(tester).onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(gateway.calls.last.source, 'ALL');
    expect(gateway.calls.last.status, isNull);
    expect(_table(tester).totalPages, 2);
    _table(tester).onSortChange!('billNo', false);
    await tester.pumpAndSettle();
    expect(gateway.calls.last.page, 1);
    expect(gateway.calls.last.sort, 'billNo');
    expect(gateway.calls.last.order, 'desc');
    expect(tester.takeException(), isNull);
  });

  for (final boundary in ['source', 'actor', 'warehouse', 'server']) {
    testWidgets('$boundary 变化后迟到旧响应不能覆盖新范围', (tester) async {
      final gateway = WarehouseTaskRecordsFakeGateway(
        const [],
        controlled: true,
      );
      final harness = await _pump(
        tester,
        gateway,
        spec: const _ViewSpec(source: 'SALES'),
        settle: false,
      );
      expect(gateway.calls, hasLength(1));
      switch (boundary) {
        case 'source':
          harness.container.read(_view.notifier).state = const _ViewSpec(
            source: 'SUBCONTRACT',
          );
        case 'actor':
          harness.container.read(_actor.notifier).state =
              const AuthenticatedScope(userId: 'actor-b');
        case 'warehouse':
          harness.container.read(_warehouse.notifier).state =
              const WarehouseTaskScope.warehouse('warehouse-b');
        case 'server':
          harness.container.read(_server.notifier).state =
              'https://other.unit.test/api';
      }
      await tester.pump();
      expect(gateway.calls.length, greaterThanOrEqualTo(2));
      final latest = gateway.calls.last;
      if (boundary == 'source') expect(latest.source, 'SUBCONTRACT');
      if (boundary == 'warehouse')
        expect(latest.scope.warehouseId, 'warehouse-b');
      latest.result.complete(
        gateway.pageOf([
          warehouseTestRecord(
            source: latest.source,
            record: 'STOCK_DOC',
            id: 'new',
            billNo: 'LATEST-$boundary',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      gateway.calls.first.result.complete(
        gateway.pageOf([
          warehouseTestRecord(
            source: 'SALES',
            record: 'SALES_SHIPMENT',
            id: 'old',
            billNo: 'LATE-OLD',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('LATEST-$boundary'), findsOneWidget);
      expect(find.text('LATE-OLD'), findsNothing);
      expect(_table(tester).selectedIds, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('全部单据同UUID/同单号仍按source+record复合ID独立显示与选择', (tester) async {
    final rows = [
      warehouseTestRecord(
        source: 'SALES',
        record: 'SALES_SHIPMENT',
        id: 'same-uuid',
        billNo: 'SAME-NO',
        action: 'SALES_OUTBOUND',
        canHandle: true,
      ),
      warehouseTestRecord(
        source: 'SUBCONTRACT',
        record: 'SUBCONTRACT_MATERIAL_ISSUE',
        id: 'same-uuid',
        billNo: 'SAME-NO',
        action: 'SUBCONTRACT_OUTBOUND',
        canHandle: true,
      ),
      warehouseTestRecord(
        source: 'OTHER',
        record: 'STOCK_DOC',
        id: 'same-uuid',
        billNo: 'SAME-NO',
        action: 'STOCK_EDIT',
        canHandle: true,
        data: {'docType': 'OTHER_OUT'},
      ),
      warehouseTestRecord(
        source: 'FINISHED',
        record: 'STOCK_DOC',
        id: 'same-uuid',
        billNo: 'SAME-NO',
        action: 'STOCK_EDIT',
        canHandle: true,
        data: {'docType': 'FINISHED_OUT'},
      ),
    ];
    await _pump(tester, WarehouseTaskRecordsFakeGateway(rows));
    final table = _table(tester);
    expect(
      table.items.map((row) => table.rowKeyOf!(row)).toSet(),
      hasLength(4),
    );
    expect(find.text('SAME-NO'), findsNWidgets(4));
    table.onSelectedIdsChanged!({rows.first.rowKey});
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, {rows.first.rowKey});
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨办理family勾选不开放批量，不导航也不提交', (tester) async {
    final rows = [
      warehouseTestRecord(
        source: 'SALES',
        record: 'SALES_SHIPMENT',
        id: 'sales',
        billNo: 'SALES-BATCH',
        action: 'SALES_OUTBOUND',
        canHandle: true,
      ),
      warehouseTestRecord(
        source: 'OTHER',
        record: 'STOCK_DOC',
        id: 'other',
        billNo: 'OTHER-BATCH',
        action: 'STOCK_EDIT',
        canHandle: true,
        data: {'docType': 'OTHER_OUT'},
      ),
    ];
    final harness = await _pump(tester, WarehouseTaskRecordsFakeGateway(rows));
    _table(tester).onSelectedIdsChanged!(rows.map((row) => row.rowKey).toSet());
    await tester.pumpAndSettle();
    final button = tester.widget<UtenButton>(
      find.byKey(const Key('warehouse-task-record-batch')),
    );
    expect(button.onPressed, isNull);
    expect(harness.opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定来源入口不能被旧source表头值改成另一来源', (tester) async {
    final gateway = WarehouseTaskRecordsFakeGateway([
      warehouseTestRecord(
        source: 'SALES',
        record: 'SALES_SHIPMENT',
        id: 'sales-only',
        billNo: 'SALES-ONLY',
      ),
    ]);
    await _pump(tester, gateway, spec: const _ViewSpec(source: 'SALES'));
    final before = gateway.calls.length;
    expect(
      _table(
        tester,
      ).facets['status']!.any((bucket) => bucket.value.startsWith('source:')),
      isFalse,
    );
    _table(tester).onFilterChanged('status', 'source:OTHER');
    await tester.pumpAndSettle();
    expect(gateway.calls.length, before);
    expect(gateway.calls.last.source, 'SALES');
    expect(find.text('SALES-ONLY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧布局不能隐藏或后置状态，旧状态查询不能替换来源入口', (tester) async {
    final gateway = WarehouseTaskRecordsFakeGateway([
      warehouseTestRecord(
        source: 'SALES',
        record: 'SALES_SHIPMENT',
        id: 'sales',
        billNo: 'SALES-LAYOUT',
        action: 'SALES_OUTBOUND',
        canHandle: true,
      ),
    ]);
    await _pump(
      tester,
      gateway,
      layout: const PlatformTableLayout(
        order: ['partyName', 'billNo', 'status', 'sourceDocNo'],
        hidden: {'status', 'sourceDocNo'},
        pinned: {'partyName'},
        widths: {'billNo': 225},
        filters: {'status': 'source:OTHER'},
        hasQueryPreferences: true,
      ),
    );
    expect(gateway.calls.every((call) => call.source == 'ALL'), isTrue);
    expect(_table(tester).requiredLeadingColumnKeys, ['status']);
    expect(find.text('来源单据'), findsNothing);
    final status = find.text('状态').hitTestable().first;
    final party = find.text('客户 / 供应商 / 委外商').hitTestable().first;
    expect(tester.getTopLeft(status).dx, lessThan(tester.getTopLeft(party).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('填写草稿仍在原任务行并恢复原批次与draftId', (tester) async {
    const id = 'expectation-a';
    final route = RoutePath.warehouseArrivalRegistration([id]);
    final spec = FormDraftCatalog.arrival.spec(route: route);
    final draft = FormDraft(
      id: 'arrival-input',
      title: '原到货登记',
      module: spec.module,
      route: route,
      permission: spec.permission,
      updatedAt: DateTime.utc(2026, 10, 12),
      data: const {
        'rows': [
          {'expectationId': id},
        ],
      },
    );
    final row = warehouseTestRecord(
      source: 'PURCHASE',
      record: 'EXPECTATION',
      id: id,
      billNo: 'ARRIVAL-ORIGINAL',
      action: 'ARRIVAL_REGISTER',
      canHandle: true,
    );
    final harness = await _pump(
      tester,
      WarehouseTaskRecordsFakeGateway([row]),
      spec: const _ViewSpec(
        direction: WarehouseTaskDirection.inbound,
        source: 'PURCHASE',
        sources: warehouseTestInboundSources,
      ),
      drafts: [draft],
    );
    expect(find.text('采购入库 · 草稿'), findsOneWidget);
    expect(_table(tester).idOf!(row), isNull);
    await _doubleTap(tester, 'ARRIVAL-ORIGINAL');
    expect(harness.opened.single.path, Uri.parse(route).path);
    expect(harness.opened.single.queryParameters['draftId'], 'arrival-input');
    expect(harness.opened.single.queryParameters['expectationIds'], id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已创建stock草稿只绑定对应stock领域，不覆盖同UUID销售单', (tester) async {
    const id = 'shared-id';
    final spec = FormDraftCatalog.stockDocument.spec(
      route: '/warehouse/OTHER_OUT/new',
    );
    final draft = FormDraft(
      id: 'other-creation',
      title: '其它出库填写',
      module: spec.module,
      route: spec.route,
      permission: spec.permission,
      draftKind: spec.draftKind,
      updatedAt: DateTime.utc(2026, 10, 12),
      data: const {'createdDocId': id, 'billNo': 'OTHER-CREATED'},
    );
    final sales = warehouseTestRecord(
      source: 'SALES',
      record: 'SALES_SHIPMENT',
      id: id,
      billNo: 'SALES-SAME-ID',
      action: 'SALES_OUTBOUND',
      canHandle: true,
    );
    final other = warehouseTestRecord(
      source: 'OTHER',
      record: 'STOCK_DOC',
      id: id,
      billNo: 'OTHER-CREATED',
      action: 'STOCK_EDIT',
      canHandle: true,
      data: {'docType': 'OTHER_OUT'},
    );
    final harness = await _pump(
      tester,
      WarehouseTaskRecordsFakeGateway([sales, other]),
      drafts: [draft],
    );
    expect(find.text(sales.statusLabel), findsOneWidget);
    expect(find.text('其它出库 · 草稿'), findsOneWidget);
    expect(_table(tester).idOf!(sales), sales.rowKey);
    expect(_table(tester).idOf!(other), isNull);
    await _doubleTap(tester, 'OTHER-CREATED');
    expect(harness.opened.single.path, '/warehouse/OTHER_OUT/new');
    expect(harness.opened.single.queryParameters['draftId'], 'other-creation');
    expect(tester.takeException(), isNull);
  });
}
