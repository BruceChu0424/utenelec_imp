import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound_execution.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'outbound_weight_fakes.dart';
import '../../helpers/badge_summary_fixture.dart';

const _route = '/warehouse/subcontract-outbound/plan-1';
const _server = 'https://draft-restore.example/api';
const _scope = AuthenticatedScope(userId: 'warehouse-user');
const _permissions = {
  Perm.subcontractOutboundView,
  Perm.subcontractOutboundExecute,
  Perm.subcontractMaterialIssueView,
  Perm.subcontractMaterialIssueEdit,
  Perm.subcontractMaterialIssueApprove,
};

void main() {
  for (final approve in [false, true]) {
    testWidgets('旧本机明细 UUID 恢复后使用最新服务器明细保存，审核=$approve', (tester) async {
      final api = _DraftApi();
      final harness = await _pumpDraft(tester, api, _draftData());
      final row = _table(tester).rows.single.draft;
      expect(find.text('已恢复本机草稿'), findsOneWidget);
      expect(row.draftItemId, 'current-item-1');
      expect(row.qty.text, '500');
      expect(row.weight.kg, 10);
      expect(row.remarkController.text, '本机已核对');
      expect(api.savedBodies, isEmpty);

      await _submit(tester, approve: approve);

      expect(api.savedBodies, hasLength(1));
      final payload =
          (api.savedBodies.single['items'] as List).single
              as Map<String, dynamic>;
      expect(payload['id'], 'current-item-1');
      expect(payload['planItemId'], 'plan-item-1');
      expect(payload['qty'], 500);
      expect(payload['weight'], 10);
      expect(jsonEncode(payload), isNot(contains('old-local-item')));
      expect(api.approvals, approve ? ['server-draft-1'] : isEmpty);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        approve ? RouteName.warehouseOutboundTasks : '/home',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('有来源指纹的同款多行即使本机顺序变化，仍按计划行恢复并保留最新 ID', (tester) async {
    final api = _DraftApi()..addSecondLine();
    await _pumpDraft(
      tester,
      api,
      _draftData(
        rows: [
          {
            ..._localRow(
              planItemId: 'plan-item-2',
              sourceIdentity: _sourceIdentity(api.planLines[1], api.items[1]),
            ),
            'qty': '300',
            'weightKg': 6,
          },
          _localRow(
            sourceIdentity: _sourceIdentity(api.planLines[0], api.items[0]),
          ),
        ],
      ),
    );

    expect(find.text('已恢复本机草稿'), findsOneWidget);
    expect(_table(tester).rows.map((row) => row.draft.qty.text), [
      '500',
      '300',
    ]);
    expect(_table(tester).rows.map((row) => row.draft.weight.kg), [10, 6]);
    await _submit(tester, approve: false);
    final rows = (api.savedBodies.single['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(rows.map((row) => row['id']), ['current-item-1', 'current-item-2']);
    expect(rows.map((row) => row['planItemId']), [
      'plan-item-1',
      'plan-item-2',
    ]);
    expect(rows.map((row) => row['qty']), [500, 300]);
    expect(rows.map((row) => row['weight']), [10, 6]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源行ID未变但他人保存过服务器单据时不覆盖，加载最新后可审核', (tester) async {
    final api = _DraftApi();
    final previousFingerprint = subcontractOutboundDraftFingerprint(
      SubcontractDocDetail.fromJson(api.document),
    );
    api.savedHeader['remark'] = '另一位仓管刚刚保存的交接内容';
    final harness = await _pumpDraft(tester, api, {
      ..._draftData(),
      'serverFingerprint': previousFingerprint,
    });
    await _expectBlockedThenReloadAndApprove(tester, api, harness);
    expect(api.savedBodies.single['remark'], '另一位仓管刚刚保存的交接内容');
  });

  final changedDrafts = <String, Map<String, dynamic> Function()>{
    '服务器出仓单已换': () => _draftData(draftId: 'another-server-draft'),
    '来源计划行已换': () =>
        _draftData(rows: [_localRow(planItemId: 'another-plan-item')]),
    '本机重复来源行': () => _draftData(rows: [_localRow(), _localRow()]),
    '本机增加未识别来源行': () => _draftData(
      rows: [
        _localRow(),
        _localRow(planItemId: 'new-plan-item'),
      ],
    ),
  };
  for (final scenario in changedDrafts.entries) {
    testWidgets('${scenario.key}不套用旧输入，保留原稿后可加载最新并审核', (tester) async {
      final api = _DraftApi();
      if (scenario.key == '本机重复来源行') api.addSecondLine();
      final harness = await _pumpDraft(tester, api, scenario.value());
      await _expectBlockedThenReloadAndApprove(tester, api, harness);
    });
  }

  testWidgets('本机漏掉服务器新增计划行时整份恢复失败，不按同货品套行', (tester) async {
    final api = _DraftApi()..addSecondLine();
    final harness = await _pumpDraft(tester, api, _draftData());
    await _expectBlockedThenReloadAndApprove(tester, api, harness);
  });

  for (final change in <String, Object>{
    'orderItemId': 'changed-order-item',
    'goodsId': 'changed-goods',
    'colorId': 'changed-color',
    'unitId': 'changed-unit',
    'unitRate': 2.0,
    'parentGoodsId': 'changed-parent',
    'parentColorId': 'changed-parent-color',
    'flowMode': 'COMPONENT_OUTBOUND',
  }.entries) {
    testWidgets('同计划行的 ${change.key} 变化不恢复旧输入，重载后使用最新来源', (tester) async {
      final api = _DraftApi();
      final original = _sourceIdentity(api.planLines.single, api.items.single);
      if (change.key == 'unitRate') {
        api.items.single[change.key] = change.value;
      } else {
        api.planLines.single[change.key] = change.value;
        api.items.single[change.key] = change.value;
      }
      final harness = await _pumpDraft(
        tester,
        api,
        _draftData(rows: [_localRow(sourceIdentity: original)]),
      );
      await _expectBlockedThenReloadAndApprove(tester, api, harness);
      if (change.key != 'flowMode') {
        final payload =
            (api.savedBodies.single['items'] as List).first
                as Map<String, dynamic>;
        expect(payload[change.key], change.value);
      }
    });
  }
}

Future<void> _expectBlockedThenReloadAndApprove(
  WidgetTester tester,
  _DraftApi api,
  _Harness harness,
) async {
  expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
  expect(_table(tester).rows.first.draft.qty.text, '1000');
  expect(_table(tester).rows.first.draft.weight.kg, 20);
  expect(api.savedBodies, isEmpty);
  expect(api.approvals, isEmpty);
  final originalRecord = harness.storage.records[harness.storageKey];
  expect(originalRecord, isNotNull);
  expect(harness.container.read(formDraftsProvider), hasLength(1));

  await tester.tap(find.text('保留本机草稿，加载最新单据'));
  await tester.pumpAndSettle();

  expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsNothing);
  expect(find.text('原本机草稿已保留；已读取最新单据，请核对后继续。'), findsOneWidget);
  expect(api.taskReads, 2);
  expect(_table(tester).rows.first.draft.qty.text, '1000');
  expect(_table(tester).rows.first.draft.weight.kg, 20);
  expect(harness.storage.records[harness.storageKey], originalRecord);
  await _submit(tester, approve: true);
  expect(api.approvals, ['server-draft-1']);
  final savedRows = (api.savedBodies.single['items'] as List)
      .cast<Map<String, dynamic>>();
  expect(savedRows.map((row) => row['id']), api.items.map((row) => row['id']));
  expect(savedRows.first['qty'], 1000);
  expect(savedRows.first['weight'], 20);
  expect(harness.storage.records[harness.storageKey], originalRecord);
  expect(harness.container.read(formDraftsProvider).single.id, 'local-draft');
  expect(tester.takeException(), isNull);
}

Future<void> _submit(WidgetTester tester, {required bool approve}) async {
  await tester.tap(
    find.byKey(
      Key(
        'warehouse-subcontract-outbound-action-${approve ? 'approve' : 'save'}',
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (approve) {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '确认出仓'),
      ),
    );
    await tester.pumpAndSettle();
  }
}

SubcontractOutboundDetailTable _table(WidgetTester tester) =>
    tester.widget(find.byType(SubcontractOutboundDetailTable));

Map<String, dynamic> _localRow({
  String planItemId = 'plan-item-1',
  String? sourceIdentity,
}) => {
  'planItemId': planItemId,
  'draftItemId': 'old-local-item',
  'sourceIdentity': ?sourceIdentity,
  'qty': '500',
  'qtyAutofilled': false,
  'weightKg': 10,
  'qtyFromWeight': false,
  'remark': '本机已核对',
  'selected': true,
};

Map<String, dynamic> _draftData({
  String draftId = 'server-draft-1',
  List<Map<String, dynamic>>? rows,
}) => {
  'draftId': draftId,
  'warehouseId': 'actual-leaf',
  'billDate': '2026-09-30',
  'remark': '本机交接说明',
  'rows': rows ?? [_localRow()],
};

String _sourceIdentity(Map<String, dynamic> line, Map<String, dynamic> item) =>
    [
      line['orderItemId'],
      line['goodsId'],
      line['colorId'],
      line['unitId'],
      item['unitRate'],
      line['parentGoodsId'],
      line['parentColorId'],
      line['flowMode'],
    ].join('|');

typedef _Harness = ({
  GoRouter router,
  ProviderContainer container,
  _MemoryStorage storage,
  String storageKey,
});

Future<_Harness> _pumpDraft(
  WidgetTester tester,
  _DraftApi api,
  Map<String, dynamic> data,
) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final spec = FormDraftCatalog.subcontractOutbound.spec(route: _route);
  final draft = FormDraft(
    id: 'local-draft',
    title: spec.title,
    module: spec.module,
    route: spec.route,
    permission: spec.permission,
    draftKind: spec.draftKind,
    updatedAt: DateTime.utc(2026, 9, 30),
    data: data,
    revision: 'original-revision',
  );
  final storage = _MemoryStorage();
  final storageKey = '${formDraftStoragePrefix(_server, _scope)}${draft.id}';
  storage.records[storageKey] = jsonEncode(draft.toJson());
  final container = ProviderContainer(
    overrides: [
      fakeWeightRepositoryOverride(),
      fixedBadgeSummaryOverride(),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(_server),
      masterNameServiceProvider.overrideWithValue(_Names(api)),
      authenticatedScopeProvider.overrideWithValue(_scope),
      currentPermissionsProvider.overrideWithValue(_permissions),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      DraftAwareGoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('返回列表')),
      ),
      DraftAwareGoRoute(
        path: '/warehouse/subcontract-outbound/:planId',
        builder: (_, state) => WarehouseSubcontractOutboundEditPage(
          key: state.pageKey,
          planId: state.pathParameters['planId']!,
        ),
      ),
      DraftAwareGoRoute(
        path: RouteName.warehouseOutboundTasks,
        builder: (_, _) => const Scaffold(body: Text('出库任务中心')),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push(draft.resumeLocation));
  await tester.pumpAndSettle();
  return (
    router: router,
    container: container,
    storage: storage,
    storageKey: storageKey,
  );
}

class _MemoryStorage implements FormDraftStorage {
  final records = <String, String>{};
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async => records[key] = value;
  @override
  Future<void> remove(String key) async => records.remove(key);
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _Names extends MasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'actual-leaf', name: '实物仓'),
  ];
  @override
  String warehouse(String? id) => id == 'actual-leaf' ? '实物仓' : '—';
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _DraftApi extends ApiClient {
  _DraftApi() : super(Dio());
  final planLines = <Map<String, dynamic>>[_planLine(1)];
  final items = <Map<String, dynamic>>[_item(1)];
  final savedBodies = <Map<String, dynamic>>[];
  final approvals = <String>[];
  int taskReads = 0;
  int status = 0;
  Map<String, dynamic> savedHeader = {};

  void addSecondLine() {
    planLines.add(_planLine(2));
    items.add(_item(2));
  }

  static Map<String, dynamic> _planLine(int index) => {
    'planItemId': 'plan-item-$index',
    'orderItemId': 'order-item-$index',
    'goodsId': 'goods-1',
    'goodsCode': 'ITEM-1',
    'goodsName': '同款物料',
    'unitId': 'unit-1',
    'unitName': '个',
    'plannedQty': 1000,
    'issuedQty': 0,
    'draftReservedQty': 1000,
    'flowMode': 'DIRECT_OUTBOUND',
    'preparationStatus': 'READY_OUTBOUND',
    'preparedQty': 1000,
    'readyOutboundQty': 0,
    'remainingQty': 1000,
    'issuableQty': 0,
    'allowedActions': ['HANDLE_OUTBOUND'],
  };

  static Map<String, dynamic> _item(int index) => {
    'id': 'current-item-$index',
    'planItemId': 'plan-item-$index',
    'orderItemId': 'order-item-$index',
    'goodsId': 'goods-1',
    'unitId': 'unit-1',
    'unitRate': 1.0,
    'qty': 1000,
    'weight': 20,
  };

  Map<String, dynamic> get document => {
    'id': 'server-draft-1',
    'billNo': 'EC20261001000001',
    'billDate': '2026-09-30',
    'warehouseId': 'actual-leaf',
    'supplierId': 'supplier-1',
    ...savedHeader,
    'status': status,
    'items': [
      for (final item in items) {...item},
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehouseSubcontractOutboundTask('plan-1')) {
      taskReads++;
      return {
        'planId': 'plan-1',
        'orderId': 'order-1',
        'orderBillNo': 'WW-1',
        'status': 'OPEN',
        'supplierId': 'supplier-1',
        'supplierName': '加工商',
        'lines': planLines,
        'drafts': [
          {
            'issueId': 'server-draft-1',
            'billNo': 'EC20261001000001',
            'status': status,
          },
        ],
      };
    }
    if (path == '/subcontract/material-issues/server-draft-1') return document;
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    if (path != '/subcontract/material-issues/server-draft-1') {
      throw StateError('Unexpected PUT $path');
    }
    final payload = Map<String, dynamic>.from(body as Map<String, dynamic>);
    savedBodies.add(jsonDecode(jsonEncode(payload)) as Map<String, dynamic>);
    final rows = (payload['items'] as List).cast<Map<String, dynamic>>();
    for (final row in rows) {
      final existing = items.singleWhere(
        (item) => item['planItemId'] == row['planItemId'],
      );
      if (row['id'] != existing['id']) {
        throw StateError('Client submitted a stale item ID');
      }
      existing.addAll(Map<String, dynamic>.from(row));
    }
    savedHeader = {...payload}..remove('items');
    return document;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path != '/subcontract/material-issues/server-draft-1/approve') {
      throw StateError('Unexpected POST $path');
    }
    approvals.add('server-draft-1');
    status = 1;
    return document;
  }
}
