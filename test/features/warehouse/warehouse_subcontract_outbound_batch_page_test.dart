import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _permissions = {
  Perm.subcontractOutboundView,
  Perm.subcontractOutboundExecute,
  Perm.subcontractMaterialIssueView,
  Perm.subcontractMaterialIssueEdit,
  Perm.subcontractMaterialIssueApprove,
};

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('员工名称查询缓慢不阻塞出仓明细，原经办人UUID仍保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final employee = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!employee.isCompleted) {
        employee.complete({'id': 'worker-delayed', 'fullName': '延迟经办人'});
      }
    });
    final api = _BatchApi()..employeeResult = employee.future;
    for (final document in api.documents.values) {
      document['workerId'] = 'worker-delayed';
    }
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(employee.isCompleted, isFalse);
    expect(find.byType(SubcontractOutboundDetailTable), findsOneWidget);
    expect(api.employeeLookups, 1);
    employee.complete({'id': 'worker-delayed', 'fullName': '延迟经办人'});
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(
      api.savedBodies.every((body) => body['workerId'] == 'worker-delayed'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final interrupted in [false, true]) {
    testWidgets('完成选中出仓返回任务中心并刷新，未确认结果保留 interrupted=$interrupted', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _BatchApi()..timeoutAfterSecondApproval = interrupted;
      final router = GoRouter(
        initialLocation: '/batch',
        routes: [
          GoRoute(
            path: '/batch',
            builder: (_, _) => const WarehouseSubcontractOutboundBatchPage(
              planIds: ['plan-1', 'plan-2', 'plan-3'],
            ),
          ),
          GoRoute(
            path: RouteName.warehouseOutboundTasks,
            builder: (_, state) => WarehouseOutboundTaskCenterPage(
              initialSection: state.uri.queryParameters['section'],
              initialView: state.uri.queryParameters['view'],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            masterNameServiceProvider.overrideWithValue(_Names(api)),
            currentPermissionsProvider.overrideWithValue(_permissions),
            isSuperAdminProvider.overrideWithValue(false),
            sharedPreferencesProvider.overrideWithValue(_preferences),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await _confirm(tester);
      if (interrupted) {
        expect(router.routeInformationProvider.value.uri.path, '/batch');
        expect(api.taskRequests, 0);
        await tester.tap(find.text('核实处理结果'));
        await tester.pumpAndSettle();
        await _confirm(tester);
      }
      expect(
        router.routeInformationProvider.value.uri.path,
        RouteName.warehouseOutboundTasks,
      );
      expect(find.text('出库任务中心'), findsOneWidget);
      expect(find.byType(SubcontractOutboundDetailTable), findsNothing);
      expect(api.taskRequests, 1);
      expect(api.approvals, ['draft-1', 'draft-2', 'draft-3']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('顶部卡片不含发出仓和备注，表内默认仓及备注按原单同步并准确提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    api.documents['draft-1']!['remark'] = '原单交接说明';
    (api.documents['draft-1']!['items'] as List).add({
      'id': 'extra-line',
      'planItemId': 'extra-plan',
      'orderItemId': 'extra-order',
      'goodsId': 'extra-goods',
      'qty': 400.0,
      'remark': '原行说明',
    });
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final cards = find.byKey(const Key('subcontract-outbound-document-cards'));
    expect(
      find.descendant(of: cards, matching: find.byType(UtenCard)),
      findsNWidgets(3),
    );
    expect(
      find.descendant(
        of: cards,
        matching: find.byType(WarehouseHierarchyDropdown),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: cards, matching: find.text('单据备注')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('subcontract-outbound-document-table')),
      findsNothing,
    );
    var table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows.map((r) => r.documentNo), [
      'EC-1',
      'EC-1',
      'EC-2',
      'EC-3',
    ]);
    expect(table.rows.first.warehouseId, 'actual-leaf');
    expect(table.rows.first.documentRemark!.text, '原单交接说明');
    expect(table.rows[1].draft.remarkController.text, '原行说明');
    table.rows.first.onWarehouseChanged!('actual-leaf-b');
    await tester.pumpAndSettle();
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(
      table.rows.take(2).map((r) => r.warehouseId),
      everyElement('actual-leaf-b'),
    );
    expect(
      table.rows.skip(2).map((r) => r.warehouseId),
      everyElement('actual-leaf'),
    );
    table.rows.first.documentRemark!.text = '整单交接';
    table.rows[1].draft.remarkController.text = '此行防压';
    expect(table.rows[1].documentRemark!.text, '整单交接');
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('subcontract-outbound-batch-confirm')),
          )
          .type,
      UtenButtonType.danger,
    );
    await _confirm(tester);
    expect(api.savedBodies.first['warehouseId'], 'actual-leaf-b');
    expect(api.savedBodies.first['remark'], '整单交接');
    expect(
      (api.savedBodies.first['items'] as List)
          .cast<Map<String, dynamic>>()
          .last['remark'],
      '此行防压',
    );
    expect(api.savedBodies[1]['warehouseId'], 'actual-leaf');
    expect(tester.takeException(), isNull);
  });
  testWidgets('同一EC任意明细勾选联动整单并保存全部行备注', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    (api.documents['draft-1']!['items'] as List).add({
      'id': 'draft-item-extra',
      'planItemId': 'plan-item-extra',
      'orderItemId': 'order-item-extra',
      'goodsId': 'goods-extra',
      'qty': 400.0,
      'weight': 2.25,
      'remark': '保留原行交接记录',
    });
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    var table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    table.onRowSelected!(table.rows.first, false);
    table.onChanged();
    await tester.pumpAndSettle();
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows.take(2).every((row) => !row.draft.selected), isTrue);
    expect(table.rows.skip(2).every((row) => row.draft.selected), isTrue);
    table.onRowSelected!(table.rows[1], true);
    table.onChanged();
    await tester.pumpAndSettle();
    await _confirm(tester);
    final items = (api.savedBodies.first['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(2));
    expect(items.last['remark'], '保留原行交接记录');
    expect(items.last['weight'], 2.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无草稿生成多实际仓EC后只返回核对且保留其它已读草稿编辑', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi()..generateFirst = true;
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    var table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    table.rows[1].draft.qty.text = '1234';
    expect(find.text('生成草稿并核对'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(api.regenerations, 1);
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byType(SubcontractOutboundDetailTable),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(' | '),
    );
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows, hasLength(4));
    expect(table.rows.take(2).map((row) => row.draft.qty.text), [
      '6000',
      '4000',
    ]);
    expect(table.rows.take(2).map((row) => row.warehouse), ['轨道车间', '补充仓']);
    expect(table.rows[2].draft.qty.text, '1234');
    expect(tester.takeException(), isNull);
  });

  testWidgets('PREPARED 已入库10000且ready零的单详情提交原EC与实际叶仓，不生成重复草稿', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('root')),
        ),
        GoRoute(
          path: '/edit',
          builder: (_, _) =>
              const WarehouseSubcontractOutboundEditPage(planId: 'plan-1'),
        ),
        GoRoute(
          path: RouteName.warehouseOutboundTasks,
          builder: (_, _) => const Scaffold(body: Text('出库任务中心')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWithValue(_Names(api)),
          currentPermissionsProvider.overrideWithValue(_permissions),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    router.push<void>('/edit');
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows.single.draft.maxEditableQty, 10000);
    expect(table.rows.single.draft.qty.text, '10000');
    expect(table.rows.single.warehouse, '轨道车间');
    expect(table.selectable, isFalse);
    await tester.scrollUntilVisible(
      find.text('审核出仓'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('审核出仓'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '确认出仓'),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.updates, ['draft-1']);
    expect(api.approvals, ['draft-1']);
    expect(api.regenerations, 0);
    expect(api.savedBodies.single['warehouseId'], 'actual-leaf');
    expect(
      (api.savedBodies.single['items'] as List)
          .cast<Map<String, dynamic>>()
          .single['qty'],
      10000,
    );
    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.warehouseOutboundTasks,
    );
    expect(router.routeInformationProvider.value.uri.queryParameters, {
      'section': 'subcontract',
      'view': 'tasks',
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets('已有草稿全部展示实际仓与准确数量，打开和取消确认均不写单据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows, hasLength(3));
    expect(table.rows.first.draft.maxEditableQty, 10000);
    expect(table.rows.first.warehouse, '轨道车间');
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(api.regenerations, 0);
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(api.updates, isEmpty);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('审核回执超时暂停，GET核实后仅继续未执行单据且不重放成功项', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi()..timeoutAfterSecondApproval = true;
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(api.updates, ['draft-1', 'draft-2']);
    expect(api.approvals, ['draft-1', 'draft-2']);
    expect(api.regenerations, 0);
    expect(find.text('已暂停，请核实'), findsWidgets);
    await tester.tap(find.text('核实处理结果'));
    await tester.pumpAndSettle();
    expect(api.updates, ['draft-1', 'draft-2']);
    expect(api.approvals, ['draft-1', 'draft-2']);
    await _confirm(tester);
    expect(api.updates, ['draft-1', 'draft-2', 'draft-3']);
    expect(api.approvals, ['draft-1', 'draft-2', 'draft-3']);
    expect(
      api.documents.values.every((document) => document['status'] == 1),
      isTrue,
    );
    expect(
      api.savedBodies.every((body) => body['warehouseId'] == 'actual-leaf'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('他人修改已读草稿后禁止覆盖并保留后续未执行项', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    api.documents['draft-1'] = {
      ...api.documents['draft-1']!,
      'workerId': 'changed-worker',
    };
    await _confirm(tester);
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(find.textContaining('单据已被修改或处理'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('缺审核权限时隐藏批量执行，窄屏仍为可横向滚动明细表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchApi();
    await tester.pumpWidget(
      _app(
        api,
        permissions: {
          Perm.subcontractOutboundView,
          Perm.subcontractMaterialIssueView,
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('单据信息'));
    await tester.pumpAndSettle();
    expect(find.byType(SubcontractOutboundDetailTable), findsOneWidget);
    expect(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
      findsNothing,
    );
    expect(api.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('subcontract-outbound-batch-confirm')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '确认批量出库'),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app(_BatchApi api, {Set<String> permissions = _permissions}) =>
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        masterNameServiceProvider.overrideWithValue(_Names(api)),
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(_preferences),
      ],
      child: const MaterialApp(
        home: WarehouseSubcontractOutboundBatchPage(
          planIds: ['plan-1', 'plan-2', 'plan-3'],
        ),
      ),
    );

class _Names extends MasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'actual-leaf', name: '轨道车间'),
    WarehouseDictEntry(id: 'actual-leaf-b', name: '补充仓'),
  ];
  @override
  String warehouse(String? id) => id == 'actual-leaf'
      ? '轨道车间'
      : id == 'actual-leaf-b'
      ? '补充仓'
      : '—';
}

class _BatchApi extends ApiClient {
  _BatchApi() : super(Dio()) {
    for (var index = 1; index <= 3; index++) {
      documents['draft-$index'] = {
        'id': 'draft-$index',
        'billNo': 'EC-$index',
        'billDate': '2026-09-12',
        'status': 0,
        'warehouseId': 'actual-leaf',
        'supplierId': 'supplier-$index',
        'items': [
          {
            'id': 'draft-item-$index',
            'planItemId': 'plan-item-$index',
            'orderItemId': 'order-item-$index',
            'goodsId': 'goods-$index',
            'qty': 10000.0,
          },
        ],
      };
    }
  }
  final documents = <String, Map<String, dynamic>>{};
  final updates = <String>[];
  final approvals = <String>[];
  final savedBodies = <Map<String, dynamic>>[];
  int regenerations = 0;
  int taskRequests = 0;
  Future<Map<String, dynamic>>? employeeResult;
  int employeeLookups = 0;
  bool timeoutAfterSecondApproval = false;
  bool generateFirst = false;
  bool generated = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.employee('worker-delayed') &&
        employeeResult != null) {
      employeeLookups++;
      return employeeResult!;
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundTaskCount) {
      return {
        'count': documents.values
            .where((document) => document['status'] == 0)
            .length,
      };
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundTasks) {
      taskRequests++;
      return {
        'items': <Object>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
      };
    }
    for (var index = 1; index <= 3; index++) {
      if (path ==
          ApiEndpoints.warehouseSubcontractOutboundTask('plan-$index')) {
        return {
          'planId': 'plan-$index',
          'orderId': 'order-$index',
          'orderBillNo': 'EO-$index',
          'status': 'OPEN',
          'supplierId': 'supplier-$index',
          'supplierName': 'Supplier $index',
          'lines': [
            for (final item in documents['draft-$index']!['items'] as List)
              {
                ...Map<String, dynamic>.from(item as Map),
                'goodsName': '目标件 $index',
                'flowMode': 'PREPARED_OUTBOUND',
                'preparationStatus': 'READY_OUTBOUND',
                'plannedQty': 10000,
                'preparedQty': 10000,
                'draftReservedQty': index == 1 && generateFirst && !generated
                    ? 0
                    : 10000,
                'readyOutboundQty': index == 1 && generateFirst && !generated
                    ? 10000
                    : 0,
                'remainingQty': 10000,
              },
          ],
          'drafts': [
            if (index != 1 || !generateFirst || generated)
              {'issueId': 'draft-$index', 'billNo': 'EC-$index', 'status': 0},
            if (index == 1 && generateFirst && generated)
              {'issueId': 'draft-1b', 'billNo': 'EC-1B', 'status': 0},
          ],
        };
      }
    }
    if (path.startsWith('/subcontract/material-issues/')) {
      return Map.of(documents[path.split('/').last]!);
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final id = path.split('/').last;
    final payload = Map<String, dynamic>.from(body! as Map);
    updates.add(id);
    savedBodies.add(payload);
    documents[id] = {...documents[id]!, ...payload};
    return Map.of(documents[id]!);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehouseSubcontractOutboundDraft('plan-1')) {
      regenerations++;
      generated = true;
      final item =
          (documents['draft-1']!['items'] as List).first
              as Map<String, dynamic>;
      documents['draft-1b'] = {
        ...documents['draft-1']!,
        'id': 'draft-1b',
        'billNo': 'EC-1B',
        'warehouseId': 'actual-leaf-b',
        'items': [
          {...item, 'id': 'draft-item-1b', 'qty': 4000.0},
        ],
      };
      documents['draft-1'] = {
        ...documents['draft-1']!,
        'items': [
          {...item, 'qty': 6000.0},
        ],
      };
      return {'draftId': 'draft-1'};
    }
    if (path.endsWith('/approve')) {
      final id = path.split('/')[3];
      approvals.add(id);
      documents[id] = {...documents[id]!, 'status': 1};
      if (id == 'draft-2' && timeoutAfterSecondApproval) {
        timeoutAfterSecondApproval = false;
        throw NetworkTimeoutException();
      }
      return Map.of(documents[id]!);
    }
    regenerations++;
    throw StateError('Unexpected POST $path');
  }
}
