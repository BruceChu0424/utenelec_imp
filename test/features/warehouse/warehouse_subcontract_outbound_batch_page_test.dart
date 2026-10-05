// 委外领料批量出库页(ADR-143 §4.3): 按勾选的领料单 id 打开, 只读不写;
// 确认后逐张保存原行(数量只能改少)再审核, 出错暂停并可 GET 核实后继续。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

const _issueIds = ['issue-1', 'issue-2', 'issue-3'];

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
    final api = SubcontractOutboundFakeApi()..employeeResult = employee.future;
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
      final api = SubcontractOutboundFakeApi()
        ..timeoutAfterSecondApproval = interrupted;
      final router = GoRouter(
        initialLocation: '/batch',
        routes: [
          GoRoute(
            path: '/batch',
            builder: (_, _) => const WarehouseSubcontractOutboundBatchPage(
              issueIds: _issueIds,
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
            fakeWeightRepositoryOverride(),
            apiClientProvider.overrideWithValue(api),
            masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
            currentPermissionsProvider.overrideWithValue(
              subcontractOutboundPermissions,
            ),
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
        expect(api.listRequests, 0);
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
      expect(api.listRequests, 1);
      expect(api.approvals, _issueIds);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('实称重量列紧跟单位，录入的千克随草稿保存且不改数量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final grid = tester.widget<UtenEditableGrid<SubcontractOutboundTableRow>>(
      find.byType(UtenEditableGrid<SubcontractOutboundTableRow>),
    );
    final order = grid.initialColumnOrder!;
    expect(order.indexOf('weight'), order.indexOf('unit') + 1);
    expect(find.text('实称重量(kg)'), findsOneWidget);
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    final qtyBefore = table.rows.first.draft.qty.text;
    final quantity = grid.columns.singleWhere(
      (column) => column.key == 'quantity',
    );
    expect(quantity.exactValueOf!(table.rows.first), qtyBefore);
    expect(
      quantity.exactListenableOf!(table.rows.first),
      same(table.rows.first.draft.qty),
    );
    for (final key in ['requested', 'stockAvailable']) {
      expect(
        grid.columns.singleWhere((column) => column.key == key).exactValueOf,
        isNotNull,
      );
    }
    await tester.enterText(
      find.byKey(const ValueKey('weight-cell-input')).first,
      '1500g',
    );
    await tester.pump();
    expect(table.rows.first.draft.weight.kg, 1.5);
    expect(table.rows.first.draft.qty.text, qtyBefore, reason: '数量不按称重改');
    await _confirm(tester);
    final items = (api.savedBodies.first['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items.first['weight'], 1.5);
    expect(items.first['qtyFromWeight'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部卡片不含发出仓和备注，表内默认仓及备注按原单同步并准确提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    api.documents['issue-1']!['remark'] = '原单交接说明';
    api.addLine(
      'issue-1',
      pick: outboundPickLine(
        issueItemId: 'extra-line',
        planItemId: 'extra-plan',
        goodsId: 'extra-goods',
        requestedQty: 400,
      ),
      item: outboundDocItem(
        id: 'extra-line',
        planItemId: 'extra-plan',
        orderItemId: 'extra-order',
        goodsId: 'extra-goods',
        qty: 400,
        remark: '原行说明',
      ),
    );
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
    expect(api.savedBodies.first['supplierId'], 'supplier-1');
    final items = (api.savedBodies.first['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items.map((item) => item['id']), ['issue-item-1', 'extra-line']);
    expect(items.last['remark'], '此行防压');
    expect(items.last['orderItemId'], 'extra-order');
    expect(api.savedBodies[1]['warehouseId'], 'actual-leaf');
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一领料单任意明细勾选联动整单, 不勾的单不保存不审核', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    api.addLine(
      'issue-1',
      pick: outboundPickLine(
        issueItemId: 'issue-item-extra',
        planItemId: 'plan-item-extra',
        goodsId: 'goods-extra',
        requestedQty: 400,
      ),
      item: outboundDocItem(
        id: 'issue-item-extra',
        planItemId: 'plan-item-extra',
        goodsId: 'goods-extra',
        qty: 400,
        weight: 2.25,
        remark: '保留原行交接记录',
      ),
    );
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
    await _confirm(tester);
    expect(api.updates, ['issue-2', 'issue-3']);
    expect(api.approvals, ['issue-2', 'issue-3']);

    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    table.onRowSelected!(table.rows[1], true);
    table.onChanged();
    await tester.pumpAndSettle();
    await _confirm(tester);
    final items = (api.savedBodies.last['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(2));
    expect(items.last['remark'], '保留原行交接记录');
    expect(items.last['weight'], 2.25);
    expect(api.approvals, ['issue-2', 'issue-3', 'issue-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('改多被拦在确认前: 数量只能小于或等于领料数量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    table.rows.first.draft.qty.text = '100.5';
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(api.updates, isEmpty);
    table.rows.first.draft.qty.text = '70';
    await _confirm(tester);
    final first = (api.savedBodies.first['items'] as List).single as Map;
    expect(first['qty'], 70);
    expect(api.approvals, _issueIds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('填 0 的行不回传(服务端删行); 一张单每行都 0 拦在确认前', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    api.addLine(
      'issue-1',
      pick: outboundPickLine(
        issueItemId: 'issue-item-extra',
        planItemId: 'plan-item-extra',
        goodsId: 'goods-extra',
        requestedQty: 400,
      ),
      item: outboundDocItem(
        id: 'issue-item-extra',
        planItemId: 'plan-item-extra',
        goodsId: 'goods-extra',
        qty: 400,
      ),
    );
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    // issue-2 唯一一行填 0：整张单都不发，拦在确认前。
    final issue2 = table.rows.firstWhere(
      (row) => row.draft.draftItemId == 'issue-item-2',
    );
    issue2.draft.qty.text = '0';
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(api.updates, isEmpty);

    // issue-2 改回去；issue-1 的第二行填 0 = 只这一行本次不发。
    issue2.draft.qty.text = '100';
    table.rows
            .firstWhere((row) => row.draft.draftItemId == 'issue-item-extra')
            .draft
            .qty
            .text =
        '0';
    await _confirm(tester);
    expect(api.updates, _issueIds);
    final first = (api.savedBodies.first['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(first.map((item) => item['id']), ['issue-item-1']);
    expect(
      (api.documents['issue-1']!['items'] as List)
          .cast<Map<String, dynamic>>()
          .map((item) => item['id']),
      ['issue-item-1'],
    );
    expect(api.approvals, _issueIds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开和取消确认均不写单据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows, hasLength(3));
    expect(table.rows.first.draft.maxEditableQty, 100);
    expect(table.rows.first.warehouse, '轨道车间');
    expect(api.updates, isEmpty);
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('所列直属物料从所选仓库实际出库'), findsOneWidget);
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
    final api = SubcontractOutboundFakeApi()..timeoutAfterSecondApproval = true;
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(api.updates, ['issue-1', 'issue-2']);
    expect(api.approvals, ['issue-1', 'issue-2']);
    expect(find.text('已暂停，请核实'), findsWidgets);
    await tester.tap(find.text('核实处理结果'));
    await tester.pumpAndSettle();
    expect(api.updates, ['issue-1', 'issue-2']);
    expect(api.approvals, ['issue-1', 'issue-2']);
    await _confirm(tester);
    expect(api.updates, ['issue-1', 'issue-2', 'issue-3']);
    expect(api.approvals, _issueIds);
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
    final api = SubcontractOutboundFakeApi();
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    api.documents['issue-1']!['workerId'] = 'changed-worker';
    await _confirm(tester);
    expect(api.updates, isEmpty);
    expect(api.approvals, isEmpty);
    expect(find.textContaining('单据已被修改或处理'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('勾选的领料单已出仓时整页提示单据已变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
    api.documents['issue-2']!['status'] = 1;
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('单据已被修改或处理'), findsOneWidget);
    expect(find.byType(SubcontractOutboundDetailTable), findsNothing);
    expect(api.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺审核权限时隐藏批量执行，窄屏仍为可横向滚动明细表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi();
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

/// 点右下执行按钮(文字随进度在「确认批量出库 / 继续未执行项」间切换), 再在弹窗里确认。
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

Widget _app(
  SubcontractOutboundFakeApi api, {
  Set<String> permissions = subcontractOutboundPermissions,
}) => ProviderScope(
  overrides: [
    fakeWeightRepositoryOverride(),
    apiClientProvider.overrideWithValue(api),
    masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
    currentPermissionsProvider.overrideWithValue(permissions),
    sharedPreferencesProvider.overrideWithValue(_preferences),
  ],
  child: const MaterialApp(
    home: WarehouseSubcontractOutboundBatchPage(issueIds: _issueIds),
  ),
);
