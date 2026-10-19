import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
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
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_record_actions.dart';
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
  WarehouseTaskLine? line,
}) => WarehouseTaskCenterRecord(
  rowKey: '$source:$record:$id${line == null ? '' : ':${line.key}'}',
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
  line: line,
);

class WarehouseTaskRecordsCall {
  WarehouseTaskRecordsCall({
    required this.direction,
    required this.source,
    required this.status,
    required this.page,
    required this.scope,
    this.view = WarehouseTaskView.active,
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
  final WarehouseTaskView view;
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
    WarehouseTaskView view = WarehouseTaskView.active,
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
      view: view,
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
    this.view = WarehouseTaskView.active,
  });
  final WarehouseTaskDirection direction;
  final String source;
  final Map<String, String> sources;
  final WarehouseTaskView view;
}

final _view = StateProvider<_ViewSpec>((_) => const _ViewSpec());
final _actor = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'actor-a'),
);
final _warehouse = StateProvider<WarehouseTaskScope>(
  (_) => const WarehouseTaskScope.warehouse('warehouse-a'),
);
final _server = StateProvider<String>((_) => 'https://unit.test/api');
final _permissions = StateProvider<Set<String>>((_) => const {});

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
  Set<String>? permissions,
  bool readOnly = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      _view.overrideWith((_) => spec),
      _actor.overrideWith(
        (_) => AuthenticatedScope(userId: 'actor-a', readOnly: readOnly),
      ),
      _permissions.overrideWith(
        (_) =>
            permissions ??
            const {
              Perm.stockDocView,
              Perm.stockDocCreate,
              Perm.stockDocApprove,
              Perm.warehouseInboundView,
              Perm.warehouseInboundStockIn,
              Perm.warehouseSalesOutboundView,
              Perm.warehouseSalesOutboundExecute,
              Perm.subcontractOutboundView,
              Perm.subcontractMaterialIssueEdit,
            },
      ),
      warehouseTaskCenterRepositoryProvider.overrideWithValue(gateway),
      apiClientProvider.overrideWithValue(_Api()),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
      warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_warehouse)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
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
                  view: value.view,
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
        path: RouteName.warehouseProductionFinishedArrivalRegistration,
        builder: (_, state) => target(state),
      ),
      GoRoute(
        path: '/warehouse/OTHER_OUT/new',
        builder: (_, state) => target(state),
      ),
      GoRoute(
        path: '/warehouse/FINISHED_OUT/new',
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
  testWidgets('历史单据向服务器声明历史范围且不混草稿或办理入口', (tester) async {
    final row = warehouseTestRecord(
      source: 'FINISHED',
      record: 'STOCK_DOC',
      id: 'completed',
      billNo: 'FINISHED-CLOSED',
      status: 'FINISHED_POSTED',
      statusLabel: '成品已入库',
      action: 'STOCK_EDIT',
      canHandle: true,
      data: const {'docType': 'FINISHED_IN'},
    );
    final draftSpec = FormDraftCatalog.stockDocument.spec(
      route: '/warehouse/FINISHED_IN/new',
    );
    final draft = FormDraft(
      id: 'local-future-document',
      title: '不能混入历史的填写草稿',
      module: draftSpec.module,
      route: draftSpec.route,
      permission: draftSpec.permission,
      draftKind: draftSpec.draftKind,
      updatedAt: DateTime.utc(2026, 10, 15),
      data: const {'billNo': 'LOCAL-FUTURE'},
    );
    final gateway = WarehouseTaskRecordsFakeGateway([row]);
    await _pump(
      tester,
      gateway,
      spec: const _ViewSpec(
        direction: WarehouseTaskDirection.inbound,
        source: 'FINISHED',
        sources: warehouseTestInboundSources,
        view: WarehouseTaskView.history,
      ),
      drafts: [draft],
    );
    expect(gateway.calls.single.view, WarehouseTaskView.history);
    expect(find.text('FINISHED-CLOSED'), findsOneWidget);
    expect(find.text('LOCAL-FUTURE'), findsNothing);
    expect(find.text('新建产成品入库'), findsNothing);
    expect(_table(tester).selectable, isFalse);
    expect(_table(tester).batchActionsBuilder, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('活动与历史切换清除选择并隔离迟到响应', (tester) async {
    final active = warehouseTestRecord(
      source: 'FINISHED',
      record: 'REPORT',
      id: 'active',
      billNo: 'FUTURE',
      action: 'FINISHED_REGISTER',
      canHandle: true,
    );
    final closed = warehouseTestRecord(
      source: 'FINISHED',
      record: 'STOCK_DOC',
      id: 'closed',
      billNo: 'HISTORICAL',
      status: 'FINISHED_POSTED',
      statusLabel: '成品已入库',
    );
    final gateway = WarehouseTaskRecordsFakeGateway([], controlled: true);
    final harness = await _pump(tester, gateway, settle: false);
    final old = gateway.calls.single;
    harness.container.read(_view.notifier).state = const _ViewSpec(
      view: WarehouseTaskView.history,
    );
    await tester.pump();
    await tester.pump();
    final historical = gateway.calls.last;
    expect(historical.view, WarehouseTaskView.history);
    historical.result.complete(gateway.pageOf([closed]));
    await tester.pumpAndSettle();
    old.result.complete(gateway.pageOf([active]));
    await tester.pumpAndSettle();
    expect(find.text('HISTORICAL'), findsOneWidget);
    expect(find.text('FUTURE'), findsNothing);
    expect(_table(tester).selectable, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy JSON without extra capability keeps inspection-first only',
    (tester) async {
      final row = WarehouseTaskCenterRecord.fromJson({
        'rowKey': 'FINISHED:REPORT:legacy',
        'id': 'legacy',
        'sourceType': 'FINISHED',
        'recordType': 'REPORT',
        'status': 'FINISHED_READY_REGISTER',
        'statusLabel': '待登记',
        'action': 'FINISHED_REGISTER',
        'canHandle': true,
      });
      final harness = await _pump(
        tester,
        WarehouseTaskRecordsFakeGateway([row]),
        permissions: const {
          Perm.stockDocView,
          Perm.productionFinishedInBeforeInspection,
        },
      );
      _table(tester).onSelectedIdsChanged!({row.rowKey});
      await tester.pumpAndSettle();
      expect(find.text('先入库后质检(1)'), findsNothing);
      expect(find.text('先质检后入库(1)'), findsOneWidget);
      await tester.tap(find.text('先质检后入库(1)'));
      await tester.pumpAndSettle();
      expect(harness.opened.single.queryParameters['preStock'], '0');
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in ['ARRIVAL_REGISTER', 'FINISHED_REGISTER']) {
    testWidgets(
      '$action uses every selected server capability, not local special grants',
      (tester) async {
        final source = action == 'ARRIVAL_REGISTER' ? 'PURCHASE' : 'FINISHED';
        final rows = [
          for (final id in ['a', 'b'])
            warehouseTestRecord(
              source: source,
              record: 'REPORT',
              id: id,
              billNo: 'CAP-$id',
              action: action,
              canHandle: true,
              data: {
                'reportId': 'report-$id',
                'canRegisterBeforeInspection': true,
              },
            ),
        ];
        final harness = await _pump(
          tester,
          WarehouseTaskRecordsFakeGateway(rows),
          spec: _ViewSpec(
            direction: WarehouseTaskDirection.inbound,
            source: source,
            sources: warehouseTestInboundSources,
          ),
          permissions: const {Perm.stockDocView, Perm.warehouseInboundStockIn},
        );
        _table(tester).onSelectedIdsChanged!(
          rows.map((row) => row.rowKey).toSet(),
        );
        await tester.pumpAndSettle();
        expect(find.text('先入库后质检(2)'), findsOneWidget);
        expect(find.text('先质检后入库(2)'), findsOneWidget);
        await tester.tap(find.text('先入库后质检(2)'));
        await tester.pumpAndSettle();
        expect(harness.opened.last.queryParameters['preStock'], '1');
        if (action == 'FINISHED_REGISTER') {
          expect(
            harness.opened.last.queryParameters['reportIds'],
            'report-a,report-b',
          );
        } else {
          expect(harness.opened.last.queryParameters['expectationIds'], 'a,b');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final deniedCapability in [false, null, 'true']) {
    testWidgets(
      'mixed or legacy registration capability $deniedCapability fails closed',
      (tester) async {
        final rows = [
          warehouseTestRecord(
            source: 'FINISHED',
            record: 'REPORT',
            id: 'a',
            billNo: 'CAP-A',
            action: 'FINISHED_REGISTER',
            canHandle: true,
            data: {'canRegisterBeforeInspection': true},
          ),
          warehouseTestRecord(
            source: 'FINISHED',
            record: 'REPORT',
            id: 'b',
            billNo: 'CAP-B',
            action: 'FINISHED_REGISTER',
            canHandle: true,
            data: {'canRegisterBeforeInspection': ?deniedCapability},
          ),
        ];
        final harness = await _pump(
          tester,
          WarehouseTaskRecordsFakeGateway(rows),
          permissions: const {
            Perm.stockDocView,
            Perm.productionFinishedInBeforeInspection,
          },
        );
        _table(tester).onSelectedIdsChanged!({rows.first.rowKey});
        await tester.pumpAndSettle();
        final oldButton = tester
            .widget<UtenButton>(
              find.ancestor(
                of: find.text('先入库后质检(1)'),
                matching: find.byType(UtenButton),
              ),
            )
            .onPressed!;
        _table(tester).onSelectedIdsChanged!(
          rows.map((row) => row.rowKey).toSet(),
        );
        await tester.pumpAndSettle();
        expect(find.text('先入库后质检(2)'), findsNothing);
        expect(find.text('先质检后入库(2)'), findsOneWidget);
        oldButton(); // A stale callback must recheck the entire new selection.
        await tester.pumpAndSettle();
        expect(harness.opened, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('foreign family cannot reuse an arrival route capability', (
    tester,
  ) async {
    final row = warehouseTestRecord(
      source: 'SALES',
      record: 'SHIPMENT',
      id: 'a',
      billNo: 'FOREIGN',
      action: 'SALES_OUTBOUND',
      canHandle: true,
      data: {'canRegisterBeforeInspection': true},
    );
    await _pump(tester, WarehouseTaskRecordsFakeGateway([row]));
    _table(tester).onSelectedIdsChanged!({row.rowKey});
    await tester.pumpAndSettle();
    expect(find.textContaining('先入库后质检'), findsNothing);
    expect(find.textContaining('先质检后入库'), findsNothing);
    expect(find.text('核对出库(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final boundary in [
    'permissions',
    'actor',
    'warehouse',
    'server',
    'readOnly',
  ]) {
    testWidgets(
      '$boundary change invalidates cached registration capability and stale button',
      (tester) async {
        final row = warehouseTestRecord(
          source: 'FINISHED',
          record: 'REPORT',
          id: 'a',
          billNo: 'CURRENT-CAP',
          action: 'FINISHED_REGISTER',
          canHandle: true,
          data: {'canRegisterBeforeInspection': true},
        );
        final gateway = WarehouseTaskRecordsFakeGateway([
          row,
        ], controlled: true);
        final harness = await _pump(tester, gateway, settle: false);
        gateway.calls.last.result.complete(gateway.pageOf([row]));
        await tester.pumpAndSettle();
        _table(tester).onSelectedIdsChanged!({row.rowKey});
        await tester.pumpAndSettle();
        final oldButton = tester
            .widget<UtenButton>(
              find.ancestor(
                of: find.text('先入库后质检(1)'),
                matching: find.byType(UtenButton),
              ),
            )
            .onPressed!;
        switch (boundary) {
          case 'permissions':
            harness.container.read(_permissions.notifier).state = const {
              Perm.stockDocView,
            };
          case 'actor':
            harness.container.read(_actor.notifier).state =
                const AuthenticatedScope(userId: 'actor-b');
          case 'warehouse':
            harness.container.read(_warehouse.notifier).state =
                const WarehouseTaskScope.warehouse('warehouse-b');
          case 'server':
            harness.container.read(_server.notifier).state =
                'https://other.unit.test/api';
          case 'readOnly':
            harness.container.read(_actor.notifier).state =
                const AuthenticatedScope(userId: 'actor-a', readOnly: true);
        }
        await tester.pump();
        oldButton();
        await tester.pump();
        expect(harness.opened, isEmpty);
        expect(_table(tester).selectedIds, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final canHandle in [false, true]) {
    testWidgets(
      'readOnly or non-handleable capability does not authorize selection ($canHandle)',
      (tester) async {
        final row = warehouseTestRecord(
          source: 'FINISHED',
          record: 'REPORT',
          id: 'a',
          billNo: 'READONLY',
          action: 'FINISHED_REGISTER',
          canHandle: canHandle,
          data: {'canRegisterBeforeInspection': true},
        );
        await _pump(
          tester,
          WarehouseTaskRecordsFakeGateway([row]),
          readOnly: canHandle,
          permissions: const {
            Perm.productionFinishedInBeforeInspection,
            Perm.stockDocView,
          },
        );
        expect(_table(tester).selectable, isFalse);
        expect(find.textContaining('先入库后质检'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final spec in [
    (
      permissions: <String>{Perm.stockDocCreate},
      readOnly: false,
      allowed: false,
    ),
    (permissions: <String>{Perm.stockDocView}, readOnly: false, allowed: false),
    (
      permissions: <String>{Perm.stockDocView, Perm.stockDocCreate},
      readOnly: false,
      allowed: true,
    ),
    (
      permissions: <String>{Perm.stockDocView, Perm.stockDocCreate},
      readOnly: true,
      allowed: false,
    ),
  ]) {
    testWidgets('new document navigation uses full route policy $spec', (
      tester,
    ) async {
      final harness = await _pump(
        tester,
        WarehouseTaskRecordsFakeGateway(const []),
        permissions: spec.permissions,
        readOnly: spec.readOnly,
      );
      expect(find.text('新建其它出库'), spec.allowed ? findsOneWidget : findsNothing);
      expect(
        find.text('新建产成品出库'),
        spec.allowed ? findsOneWidget : findsNothing,
      );
      if (spec.allowed) {
        await tester.tap(find.text('新建其它出库'));
        await tester.pumpAndSettle();
        expect(harness.opened.single.path, RoutePath.stockDocNew('OTHER_OUT'));
      }
      expect(tester.takeException(), isNull);
    });
  }

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
        'view': 'ACTIVE',
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
      if (boundary == 'warehouse') {
        expect(latest.scope.warehouseId, 'warehouse-b');
      }
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

  testWidgets('同单两货品独立展示选择，按单号筛选，办理只打开一次原单', (tester) async {
    final rows = [
      for (var index = 1; index <= 2; index++)
        warehouseTestRecord(
          source: 'SALES',
          record: 'SALES_SHIPMENT',
          id: 'same-document',
          billNo: 'ONE-DOCUMENT',
          action: 'SALES_OUTBOUND',
          canHandle: true,
          line: WarehouseTaskLine(
            key: 'item-$index',
            itemId: 'item-$index',
            goodsCode: 'CODE-$index',
            goodsName: '货品$index',
            specification: 'M$index',
            colorName: '蓝色',
            quantity: index * 5,
            unitName: '件',
          ),
        ),
    ];
    final gateway = WarehouseTaskRecordsFakeGateway(rows);
    final harness = await _pump(tester, gateway);
    var table = _table(tester);
    expect(table.items, hasLength(2));
    expect(table.items.map(table.rowKeyOf!).toSet(), hasLength(2));
    expect(table.columns.any((column) => column.key == 'lineCount'), isFalse);
    expect(
      table.columns
          .firstWhere((column) => column.key == 'quantity')
          .value(rows.last),
      '10 件',
    );
    expect(find.text('货品1'), findsOneWidget);
    expect(find.text('货品2'), findsOneWidget);
    table.onFilterChanged('billNo', 'ONE-DOCUMENT');
    await tester.pumpAndSettle();
    expect(gateway.calls.last.billNo, 'ONE-DOCUMENT');
    table = _table(tester);
    table.onSelectedIdsChanged!(rows.map((row) => row.rowKey).toSet());
    await tester.pumpAndSettle();
    expect(_table(tester).selectedIds, hasLength(2));
    await tester.tap(find.byKey(const Key('warehouse-task-record-batch')));
    await tester.pumpAndSettle();
    expect(
      harness.opened.single.queryParameters['shipmentIds'],
      'same-document',
    );
    expect(tester.takeException(), isNull);
  });

  test('逐行最终点收按原task去重，继续送检保留各行收货单身份', () {
    final rows = [
      for (var index = 1; index <= 2; index++)
        warehouseTestRecord(
          source: 'FINISHED',
          record: 'FINISHED_COUNT',
          id: 'doc',
          billNo: 'B',
          action: 'FINISHED_COUNT',
          data: {'taskId': 'task', 'pendingQty': 20},
          line: WarehouseTaskLine(key: '$index', quantity: 10),
        ),
    ];
    expect(warehouseTaskCommandTargets(rows), hasLength(1));
    expect(rows.first.documentRowKey, 'FINISHED:FINISHED_COUNT:doc');
    expect(
      warehouseTaskCommandTargets([
        for (final source in ['OTHER', 'FINISHED'])
          warehouseTestRecord(
            source: source,
            record: 'STOCK_DOC',
            id: 'shared-id',
            billNo: 'SAME',
            action: 'STOCK_EDIT',
            canHandle: true,
            data: {'docType': '${source}_OUT'},
          ),
      ]),
      hasLength(2),
    );
  });

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
        hidden: {'status', 'goodsName', 'sourceDocNo'},
        pinned: {'partyName'},
        widths: {'billNo': 225},
        filters: {'status': 'source:OTHER'},
        hasQueryPreferences: true,
      ),
    );
    expect(gateway.calls.every((call) => call.source == 'ALL'), isTrue);
    expect(_table(tester).requiredLeadingColumnKeys, ['status', 'goodsName']);
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
