// 委外领料拣货出仓页(ADR-143 §4.3): 按领料单 id 打开; 明细是领料单原行,
// 数量只能改少(0 ≤ 数量 ≤ 委外提交的领料数量)、不能改多、不能加行; 填 0 = 本次不发,
// 保存时不回传这一行; 每行都 0 拦在保存前; 整单不发走「退回委外(不发)」(必填原因);
// 领料单已被委外撤回(404)时友好提示「无需拣货」; 保存走出仓单编辑端点,
// 审核走审核端点; 没有「补齐出仓单」「不再出仓」。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';

import 'outbound_weight_fakes.dart';
import 'subcontract_outbound_test_support.dart';

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('骨架: 状态横幅 + 事实卡 + 明细表内滚; 回厂委外件列常驻; 按权限显隐动作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1);
    final permissions = StateProvider<Set<String>>(
      (_) => subcontractOutboundPermissions,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fakeWeightRepositoryOverride(),
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(permissions),
          ),
          sharedPreferencesProvider.overrideWithValue(_preferences),
        ],
        child: const MaterialApp(
          home: WarehouseSubcontractOutboundEditPage(issueId: 'issue-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('委外领料拣货出仓'), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-detail-refresh')),
      findsOneWidget,
    );
    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-detail-boundary')),
      findsOneWidget,
    );
    expect(find.text('委外领料待发料'), findsOneWidget);
    expect(find.textContaining('只能改少，不能改多'), findsOneWidget);
    for (final (label, value) in const [
      ('委外订货单', 'EO-1'),
      ('委外商', 'Supplier 1'),
      ('领料单号', 'EC-1'),
      ('领料仓', '轨道车间'),
      ('提交人', '委外小王'),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
      expect(find.text(value), findsWidgets, reason: value);
    }
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.primary, isTrue);
    expect(table.bottomContentPadding, greaterThan(0));
    expect(table.rows.single.draft.maxEditableQty, 100);
    expect(table.rows.single.draft.qty.text, '100');
    final grid = tester.widget<UtenEditableGrid<SubcontractOutboundTableRow>>(
      find.byType(UtenEditableGrid<SubcontractOutboundTableRow>),
    );
    final columns = {for (final column in grid.columns) column.key: column};
    expect(columns['parentGoodsName']?.label, '回厂交回的委外件');
    expect(columns['parentGoodsName']?.textOf?.call(table.rows.single), '委外件');
    expect(columns['requested']?.label, '领料数量');
    expect(columns['place']?.textOf?.call(table.rows.single), 'A-01');
    for (final retired in const ['planned', 'prepared', 'issued', 'maximum']) {
      expect(columns.containsKey(retired), isFalse, reason: retired);
    }
    final order = grid.initialColumnOrder!;
    // 2026-10-10 口径：独立「单位」列删除(数量内联单位)，实称重量紧跟「本次出库」。
    expect(order.indexOf('weight'), order.indexOf('quantity') + 1);
    expect(order.contains('unit'), isFalse);

    // 表单卡进折叠头: 备注和发出仓都在, 发出仓默认 = 领料单的仓。
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-remark')),
      findsOneWidget,
    );
    final warehouse = tester.widget<WarehouseHierarchyDropdown>(
      find.byType(WarehouseHierarchyDropdown),
    );
    expect(warehouse.value, 'actual-leaf');
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-approve')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-return')),
      findsOneWidget,
    );
    // 「不再出仓」与「补齐出仓单」已删除: 结束领料归委外任务中心。
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-close')),
      findsNothing,
    );
    expect(find.text('不再出仓'), findsNothing);
    expect(find.text('生成草稿并核对'), findsNothing);

    // 只有执行+编辑权限: 审核隐藏, 保存拣货仍在。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WarehouseSubcontractOutboundEditPage)),
      listen: false,
    );
    container.read(permissions.notifier).state = {
      Perm.subcontractOutboundView,
      Perm.subcontractOutboundExecute,
      Perm.subcontractMaterialIssueView,
      Perm.subcontractMaterialIssueEdit,
    };
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-approve')),
      findsNothing,
    );

    // 只有出库执行权(没有出仓单编辑权): 只能整单退回委外, 不能保存/审核。
    container.read(permissions.notifier).state = {
      Perm.subcontractOutboundView,
      Perm.subcontractOutboundExecute,
    };
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-return')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsNothing,
    );

    // 只能查看: 表单卡与动作组都没了。
    container.read(permissions.notifier).state = {Perm.subcontractOutboundView};
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-return')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-remark')),
      findsNothing,
    );
    expect(api.updates, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只能改少: 改多被拦在保存前, 改少后按原行保存且不加行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1)
      ..addLine(
        'issue-1',
        pick: outboundPickLine(
          issueItemId: 'issue-item-b',
          planItemId: 'plan-item-b',
          goodsId: 'goods-b',
          goodsCode: 'M-B',
          goodsName: '直属物料 B',
          requestedQty: 80,
        ),
        item: outboundDocItem(
          id: 'issue-item-b',
          planItemId: 'plan-item-b',
          goodsId: 'goods-b',
          qty: 80,
        ),
      );
    final router = await _pumpRouted(tester, api);

    await tester.enterText(
      find.byKey(const ValueKey('subcontract-outbound-issue-item-b-quantity')),
      '81',
    );
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
    );
    await tester.pumpAndSettle();
    expect(api.updates, isEmpty);
    // 顶部通知走 provider 状态(本测试树没挂通知宿主), 直接读消息队列。
    final notices = ProviderScope.containerOf(
      tester.element(find.byType(WarehouseSubcontractOutboundEditPage)),
      listen: false,
    ).read(appNotificationProvider);
    expect(
      notices.map((notice) => notice.message),
      contains(contains('超过了委外提交的领料数量')),
    );

    await tester.enterText(
      find.byKey(const ValueKey('subcontract-outbound-issue-item-b-quantity')),
      '60',
    );
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
    );
    await tester.pumpAndSettle();

    expect(api.updates, ['issue-1']);
    final body = api.savedBodies.single;
    expect(body['warehouseId'], 'actual-leaf');
    expect(body['supplierId'], 'supplier-1');
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((item) => item['id']), ['issue-item-1', 'issue-item-b']);
    expect(items.map((item) => item['planItemId']), [
      'plan-item-1',
      'plan-item-b',
    ]);
    expect(items.map((item) => item['qty']), [100, 60]);
    expect(items.last['colorId'], 'color-1');
    expect(items.last['unitId'], 'unit-1');
    expect(api.approvals, isEmpty);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(tester.takeException(), isNull);
  });

  testWidgets('填 0 = 本次不发: 保存只回传其余行, 服务端删掉这一行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1)
      ..addLine(
        'issue-1',
        pick: outboundPickLine(
          issueItemId: 'issue-item-b',
          planItemId: 'plan-item-b',
          goodsId: 'goods-b',
          goodsCode: 'M-B',
          goodsName: '直属物料 B',
          requestedQty: 80,
        ),
        item: outboundDocItem(
          id: 'issue-item-b',
          planItemId: 'plan-item-b',
          goodsId: 'goods-b',
          qty: 80,
        ),
      );
    await _pumpRouted(tester, api);

    await tester.enterText(
      find.byKey(const ValueKey('subcontract-outbound-issue-item-b-quantity')),
      '0',
    );
    await tester.pumpAndSettle();
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    final skipped = table.rows.last.draft;
    expect(skipped.skipped, isTrue);
    expect(skipped.validate(), isNull, reason: '0 是合法输入(本次不发)');
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
    );
    await tester.pumpAndSettle();

    expect(api.updates, ['issue-1']);
    final items = (api.savedBodies.single['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items.map((item) => item['id']), ['issue-item-1']);
    expect(
      (api.documents['issue-1']!['items'] as List)
          .cast<Map<String, dynamic>>()
          .map((item) => item['id']),
      ['issue-item-1'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('每行都填 0: 拦在保存前, 提示整单不发要退回委外', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1);
    await _pumpRouted(tester, api);

    await tester.enterText(
      find.byKey(const ValueKey('subcontract-outbound-issue-item-1-quantity')),
      '0',
    );
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
    );
    await tester.pumpAndSettle();
    expect(api.updates, isEmpty);
    final notices = ProviderScope.containerOf(
      tester.element(find.byType(WarehouseSubcontractOutboundEditPage)),
      listen: false,
    ).read(appNotificationProvider);
    expect(
      notices.map((notice) => notice.message),
      contains(subcontractOutboundNothingToIssue),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('退回委外(不发): 原因必填, 确认后调退回端点并回出库任务中心', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1);
    final router = await _pumpRouted(tester, api);

    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-return')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('领料单 EC-1整单不发'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-return-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('请填写不发的原因'), findsOneWidget);
    expect(api.returns, isEmpty);

    await tester.enterText(
      find.byKey(const Key('warehouse-subcontract-outbound-return-reason')),
      '物料破损',
    );
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-return-confirm')),
    );
    await tester.pumpAndSettle();
    expect(api.returns.map((entry) => (entry.$1, entry.$2['reason'])), [
      ('issue-1', '物料破损'),
    ]);
    expect(api.updates, isEmpty, reason: '退回不先保存拣货');
    expect(api.approvals, isEmpty);
    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.warehouseOutboundTasks,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('领料单已被委外撤回: 打开显示无需拣货, 「返回待发料」回出库任务中心', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1)..withdraw('issue-1');
    final router = await _pumpRouted(tester, api);

    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-detail-gone')),
      findsOneWidget,
    );
    expect(find.text('这张领料单已被委外撤回或已处理，无需拣货'), findsOneWidget);
    expect(find.text('重新加载'), findsNothing);
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsNothing,
    );
    await tester.tap(find.text('返回待发料'));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.warehouseOutboundTasks,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('审核出仓: 先保存再审核, 弹窗说明发的是直属物料, 完成后回出库任务中心', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SubcontractOutboundFakeApi(issues: 1);
    final router = await _pumpRouted(tester, api);

    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-approve')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('所列直属物料从所选仓库实际出库'), findsOneWidget);
    expect(find.textContaining('目标件'), findsNothing);
    expect(api.updates, isEmpty, reason: '确认前不写单据');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '确认出仓'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.updates, ['issue-1']);
    expect(api.approvals, ['issue-1']);
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

  final changed = <String, void Function(SubcontractOutboundFakeApi)>{
    '领料单已出仓': (api) => api.documents['issue-1']!['status'] = 1,
    '草稿明细与拣货视图对不上': (api) => (api.documents['issue-1']!['items'] as List).add(
      outboundDocItem(id: 'stranger', planItemId: 'plan-stranger'),
    ),
  };
  for (final scenario in changed.entries) {
    testWidgets('${scenario.key}时整页提示单据已变, 不给保存或审核', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = SubcontractOutboundFakeApi(issues: 1);
      scenario.value(api);
      await _pumpRouted(tester, api);

      expect(find.textContaining('请返回列表刷新后再处理'), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
        findsNothing,
      );
      expect(api.updates, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<GoRouter> _pumpRouted(
  WidgetTester tester,
  SubcontractOutboundFakeApi api,
) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('root')),
      ),
      GoRoute(
        path: '/warehouse/subcontract-outbound/:issueId',
        builder: (_, state) => WarehouseSubcontractOutboundEditPage(
          issueId: state.pathParameters['issueId']!,
        ),
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
        fakeWeightRepositoryOverride(),
        apiClientProvider.overrideWithValue(api),
        masterNameServiceProvider.overrideWithValue(OutboundNames(api)),
        currentPermissionsProvider.overrideWithValue(
          subcontractOutboundPermissions,
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  unawaited(router.push<void>('/warehouse/subcontract-outbound/issue-1'));
  await tester.pumpAndSettle();
  return router;
}
