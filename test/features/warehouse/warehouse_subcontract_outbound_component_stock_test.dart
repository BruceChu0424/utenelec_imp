// ADR-103 §2.4 仓库侧: 单一子件直发(COMPONENT_OUTBOUND)的计划, 子件分批到货时
// 拣货页预填可发量、可发 0 的行禁用并直说「等子件到货」、「发出仓」预填建议发料仓;
// 批量页按行放行, 整单都没货才阻断且文案说「子件还没到货」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_outbound_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';

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

  testWidgets('拣货页: 预填可发量, 等子件的行禁用并直说原因, 发出仓预填建议发料仓', (tester) async {
    // 列多(建议发料仓 / 仓内可动用 / 本次最多 …)时窄视口点不到操作列, 记忆口径 3000 宽。
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ComponentApi();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('root')),
        ),
        GoRoute(
          path: '/edit',
          builder: (_, _) =>
              const WarehouseSubcontractOutboundEditPage(planId: 'plan-c'),
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
          sharedPreferencesProvider.overrideWithValue(_preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    router.push<void>('/edit');
    await tester.pumpAndSettle();

    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows, hasLength(2));
    final waiting = table.rows.firstWhere(
      (row) => row.draft.line.planItemId == 'plan-item-waiting',
    );
    final ready = table.rows.firstWhere(
      (row) => row.draft.line.planItemId == 'plan-item-ready',
    );
    // 此前预填计划余量 5000 / 上限 0 / 红框; 现在预填可发量。
    expect(ready.draft.qty.text, '300');
    expect(ready.draft.maxEditableQty, 300);
    expect(ready.draft.waitingComponentStock, isFalse);
    expect(waiting.draft.waitingComponentStock, isTrue);
    expect(
      find.byKey(
        const ValueKey('subcontract-outbound-plan-item-waiting-quantity'),
      ),
      findsNothing,
      reason: '等子件到货的行不给填数量',
    );
    expect(
      find.byKey(
        const ValueKey(
          'subcontract-outbound-plan-item-waiting-waiting-component',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('等子件到货 (仓内可动用 0)'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('subcontract-outbound-plan-item-ready-quantity'),
      ),
      findsOneWidget,
    );
    // 「建议发料仓」列出列, 「发出仓」按服务端算好的 stockWarehouseId 预填。
    expect(find.text('建议发料仓'), findsOneWidget);
    expect(find.text('回厂交回的委外件'), findsOneWidget);
    final dropdown = tester.widget<WarehouseHierarchyDropdown>(
      find.byKey(const ValueKey('warehouse_actual-leaf-b')),
    );
    expect(dropdown.value, 'actual-leaf-b');

    // 审核确认弹窗对发子件的单据说清楚: 出库的是子件, 回厂登记的是委外件。
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-approve')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('子件从所选仓库实际出库'), findsOneWidget);
    expect(find.textContaining('目标件从所选仓库出库'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '确认出仓'),
      ),
    );
    await tester.pumpAndSettle();
    // 无草稿: 等子件的行不参与校验, 直接走补草稿; 服务端按此刻库存建草稿。
    expect(api.regenerations, ['plan-c']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拣货页: 全部行都在等子件时补草稿 409 原话直达仓库', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ComponentApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWithValue(_Names(api)),
          currentPermissionsProvider.overrideWithValue(_permissions),
          sharedPreferencesProvider.overrideWithValue(_preferences),
        ],
        child: const MaterialApp(
          home: WarehouseSubcontractOutboundEditPage(planId: 'plan-w'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 全部行都在等子件: 横幅给黄色在办提示, 不是「可发 X」。
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-waiting-component')),
      findsOneWidget,
    );
    expect(find.textContaining('可发 '), findsNothing);
    await tester.tap(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
    );
    await tester.pumpAndSettle();
    expect(api.regenerations, ['plan-w']);
    // 顶部通知走 provider 状态(本测试树没挂通知宿主), 直接读消息队列。
    final notices = ProviderScope.containerOf(
      tester.element(find.byType(WarehouseSubcontractOutboundEditPage)),
      listen: false,
    ).read(appNotificationProvider);
    expect(
      notices.map((notice) => notice.message),
      contains(contains('子件还没到货, 仓里一件都没有')),
    );
    expect(notices.map((notice) => notice.message), isNot(contains('出仓明细为空')));
    expect(notices.map((notice) => notice.message), isNot(contains('请选择发出仓')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('拣货页骨架: 折叠头(状态横幅+事实卡) + 明细表内滚 + 悬浮动作组按权限显隐', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ComponentApi();
    // 文件级 _permissions 没有关闭权限, 骨架用例从「三枚齐」起步。
    final permissions = StateProvider<Set<String>>(
      (_) => {..._permissions, Perm.subcontractOutboundClose},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWithValue(_Names(api)),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(permissions),
          ),
          sharedPreferencesProvider.overrideWithValue(_preferences),
        ],
        child: const MaterialApp(
          home: WarehouseSubcontractOutboundEditPage(planId: 'plan-c'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 骨架: 与销售出库详情同款——顶栏副标题 + 刷新, 折叠头里状态横幅 + 事实卡,
    // 明细表放 body 内滚(primary), 动作在右下悬浮组。
    expect(find.text('委外拣货出仓'), findsOneWidget);
    expect(find.text('仓库作业视图'), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-detail-refresh')),
      findsOneWidget,
    );
    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-detail-boundary')),
      findsOneWidget,
    );
    expect(find.text('出仓中'), findsWidgets);
    expect(find.text('可发 300'), findsOneWidget);
    expect(find.text('委外订货单'), findsOneWidget);
    expect(find.text('EO-C'), findsOneWidget);
    expect(find.text('委外商'), findsOneWidget);
    expect(find.text('Supplier C'), findsOneWidget);
    expect(find.text('出仓明细 (2)'), findsOneWidget);
    final table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.primary, isTrue);
    expect(table.bottomContentPadding, greaterThan(0));
    // 表单卡进折叠头: 备注和发出仓都在。
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-remark')),
      findsOneWidget,
    );
    expect(find.byType(WarehouseHierarchyDropdown), findsOneWidget);
    // 旧版的三张 Card + 底部按钮行没有了。
    expect(find.text('不再出仓(关闭剩余计划)'), findsNothing);
    expect(find.text('委外目标件出仓明细'), findsNothing);
    // 全权限: 三枚按钮齐。
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-approve')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-close')),
      findsOneWidget,
    );
    expect(find.text('保存草稿'), findsOneWidget);
    expect(find.text('审核出仓'), findsOneWidget);
    expect(find.text('不再出仓'), findsOneWidget);

    // 只有执行+编辑权限: 审核与关闭两枚隐藏, 保存草稿仍在。
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
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-close')),
      findsNothing,
    );

    // 只有关闭权限: 表单卡与保存/审核都没了, 只剩「不再出仓」。
    container.read(permissions.notifier).state = {
      Perm.subcontractOutboundView,
      Perm.subcontractOutboundClose,
    };
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-save')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-action-close')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-subcontract-outbound-remark')),
      findsNothing,
    );
    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量页: 等子件的行默认不勾且标原因, 其余行照常; 整单没货才阻断', (tester) async {
    await tester.binding.setSurfaceSize(const Size(3000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ComponentApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterNameServiceProvider.overrideWithValue(_Names(api)),
          currentPermissionsProvider.overrideWithValue(_permissions),
          sharedPreferencesProvider.overrideWithValue(_preferences),
        ],
        child: const MaterialApp(
          home: WarehouseSubcontractOutboundBatchPage(
            planIds: ['plan-c', 'plan-w'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(table.rows, hasLength(3));
    final waiting = table.rows.firstWhere(
      (row) => row.draft.line.planItemId == 'plan-item-waiting',
    );
    final ready = table.rows.firstWhere(
      (row) => row.draft.line.planItemId == 'plan-item-ready',
    );
    expect(waiting.draft.selected, isFalse);
    expect(waiting.draft.qty.text, '0');
    expect(ready.draft.selected, isTrue);
    expect(ready.draft.qty.text, '300');
    expect(find.text('等子件到货 (仓内可动用 0)'), findsNWidgets(2));
    // 整单都在等子件的 plan-w 阻断, 文案是「子件还没到货」而不是「没有可出库明细」。
    expect(find.textContaining('EO-W: 子件还没到货'), findsOneWidget);
    expect(find.textContaining('当前没有可出库明细'), findsNothing);
    // 整单联动勾选不把等子件的行勾上。
    table.onRowSelected!(ready, false);
    table.onChanged();
    await tester.pumpAndSettle();
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    table.onRowSelected!(
      table.rows.firstWhere(
        (row) => row.draft.line.planItemId == 'plan-item-ready',
      ),
      true,
    );
    table.onChanged();
    await tester.pumpAndSettle();
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    expect(
      table.rows
          .firstWhere((row) => row.draft.line.planItemId == 'plan-item-waiting')
          .draft
          .selected,
      isFalse,
    );

    expect(find.text('生成草稿并核对'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('subcontract-outbound-batch-confirm')),
    );
    await tester.pumpAndSettle();
    // 只对有货的 plan-c 补草稿; 补出来的草稿只含有货的那一行。
    expect(api.regenerations, ['plan-c']);
    table = tester.widget<SubcontractOutboundDetailTable>(
      find.byType(SubcontractOutboundDetailTable),
    );
    final drafted = table.rows.where((row) => row.documentNo == 'EC-C');
    expect(drafted.map((row) => row.draft.line.planItemId), [
      'plan-item-ready',
    ]);
    expect(drafted.single.draft.qty.text, '300');
    expect(drafted.single.warehouseId, 'actual-leaf-b');
    expect(find.textContaining('EO-W: 子件还没到货'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

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

Map<String, dynamic> _componentLine({
  required String planItemId,
  required double issuableQty,
  required double stockAvailableQty,
  String? stockWarehouseId,
  String? stockWarehouseName,
  double draftReservedQty = 0,
}) => {
  'planItemId': planItemId,
  'orderItemId': 'order-$planItemId',
  'parentGoodsId': 'subcontract-goods',
  'parentGoodsCode': 'SC001',
  'parentGoodsName': '委外件',
  'goodsId': 'component-$planItemId',
  'goodsCode': 'C-$planItemId',
  'goodsName': '采购子件 $planItemId',
  'flowMode': 'COMPONENT_OUTBOUND',
  'preparationStatus': 'READY_OUTBOUND',
  'plannedQty': 5000,
  'preparedQty': 5000,
  'issuedQty': 0,
  'readyOutboundQty': 5000 - draftReservedQty,
  'draftReservedQty': draftReservedQty,
  'remainingQty': 5000 - draftReservedQty,
  'issuableQty': issuableQty,
  'stockAvailableQty': stockAvailableQty,
  'stockWarehouseId': stockWarehouseId,
  'stockWarehouseName': stockWarehouseName,
  'allowedActions': const ['HANDLE_OUTBOUND'],
};

class _ComponentApi extends ApiClient {
  _ComponentApi() : super(Dio());

  final regenerations = <String>[];
  bool draftedC = false;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehouseSubcontractOutboundTaskCount) {
      return const {'count': 0};
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundTask('plan-c')) {
      return {
        'planId': 'plan-c',
        'orderId': 'order-c',
        'orderBillNo': 'EO-C',
        'status': 'OPEN',
        'supplierId': 'supplier-c',
        'supplierName': 'Supplier C',
        'lines': [
          _componentLine(
            planItemId: 'plan-item-waiting',
            issuableQty: 0,
            stockAvailableQty: 0,
          ),
          _componentLine(
            planItemId: 'plan-item-ready',
            issuableQty: draftedC ? 0 : 300,
            stockAvailableQty: draftedC ? 0 : 300,
            stockWarehouseId: 'actual-leaf-b',
            stockWarehouseName: '补充仓',
            draftReservedQty: draftedC ? 300 : 0,
          ),
        ],
        'drafts': [
          if (draftedC)
            const {'issueId': 'draft-c', 'billNo': 'EC-C', 'status': 0},
        ],
      };
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundTask('plan-w')) {
      return {
        'planId': 'plan-w',
        'orderId': 'order-w',
        'orderBillNo': 'EO-W',
        'status': 'OPEN',
        'supplierId': 'supplier-w',
        'supplierName': 'Supplier W',
        'lines': [
          _componentLine(
            planItemId: 'plan-item-w',
            issuableQty: 0,
            stockAvailableQty: 0,
          ),
        ],
        'drafts': const <Object>[],
      };
    }
    if (path == '/subcontract/material-issues/draft-c') {
      return const {
        'id': 'draft-c',
        'billNo': 'EC-C',
        'billDate': '2026-09-22',
        'status': 0,
        'warehouseId': 'actual-leaf-b',
        'supplierId': 'supplier-c',
        'items': [
          {
            'id': 'draft-item-ready',
            'planItemId': 'plan-item-ready',
            'orderItemId': 'order-plan-item-ready',
            'goodsId': 'component-plan-item-ready',
            'qty': 300.0,
          },
        ],
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.warehouseSubcontractOutboundDraft('plan-c')) {
      regenerations.add('plan-c');
      draftedC = true;
      return const {'draftId': 'draft-c'};
    }
    if (path == ApiEndpoints.warehouseSubcontractOutboundDraft('plan-w')) {
      regenerations.add('plan-w');
      // 服务端三档 409 之一(ADR-103 §2.4), 客户端原样显示。
      throw ApiException(
        'CONFLICT',
        '子件还没到货, 仓里一件都没有; 子件入库后系统会自动补草稿并通知仓库',
        httpStatus: 409,
      );
    }
    throw StateError('Unexpected POST $path');
  }
}
