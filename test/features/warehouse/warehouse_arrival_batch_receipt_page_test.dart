// 2026-09-06 入库任务中心批量送检新契约：
//  ① 「预计到货」多选不再只限「已登记 · 待送检」断点行——2026-09-05
//     「登记并送检」一步化后该状态基本不再出现，只放开断点行使多选形同虚设。
//     待登记（canCreateReceipt）行同样可勾选，批量动作升级为「批量登记送检」。
//  ② 批量登记页（/warehouse/inbound/receipts/batch）：多张订货单明细汇成行级表，
//     本次实收默认=批准剩余，入库仓库行级必填（建议仓预填）；2026-09-11 起
//     表头上方的批量按钮全撤，改为**勾选多行后改其中任意一行 = 整批落值**。
//     提交按「订货单 × 入库仓库」分组逐张登记（同幂等键范式）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_batch_receipt_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_expectations_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'disabled remembered warehouse is cleared before a new arrival and hidden in the picker',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BatchApi(disabledFirst: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sessionProvider.overrideWith(_TestSessionNotifier.new),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          ],
          child: MaterialApp(
            home: WarehouseArrivalBatchReceiptPage(
              prefills: _prefills(),
              canRegister: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('成品仓'), findsNothing);
      expect(find.text('必选 · 点击选择'), findsNWidgets(3));
      // 2026-09-11 起表头上方不再有「批量设置入库仓库」按钮：直接点行内仓库格
      // （未勾选任何行 = 只改这一行）。
      await tester.ensureVisible(
        find.byKey(const Key('warehouse-arrival-batch-wh-batch-item-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-arrival-batch-wh-batch-item-1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-picker-entry-warehouse-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
        findsOneWidget,
      );
      expect(api.arrivalPostBodies, isEmpty);
    },
  );

  testWidgets('预计到货：待登记行可勾选，批量登记送检按钮随选择计数', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _ExpectationsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseInboundExpectationsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 待登记行（无草稿收货单）现在可勾选——修复「多选都选不了」。
    final table = tester.widget<MasterDataTableView<InboundExpectation>>(
      find.byKey(const Key('inbound-expectation-task-table')),
    );
    expect(table.selectable, isTrue);
    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('批量登记送检'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('批量登记送检(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量登记页：行级仓库必填+统一设仓+按订货单分组登记送检', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _BatchApi();
    final router = GoRouter(
      initialLocation: RouteName.warehouseArrivalReceiptBatch,
      routes: [
        GoRoute(
          path: RouteName.warehouseArrivalReceiptBatch,
          builder: (_, _) => WarehouseArrivalBatchReceiptPage(
            prefills: _prefills(),
            canRegister: true,
          ),
        ),
        GoRoute(
          path: RouteName.warehouseInboundExpectations,
          builder: (_, _) => const Scaffold(body: Text('预计到货任务中心')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 行级仓库：建议仓订单的行预填「成品仓」，无建议订单的行留空必选。
    expect(find.text('成品仓'), findsOneWidget);
    expect(find.text('必选 · 点击选择'), findsNWidgets(2));
    expect(find.text('入库仓库（默认）'), findsNothing);

    // 2026-09-11 新交互：点**其中任意一行**的仓库格选「原料仓」，全部勾选行
    // 一起落仓（覆盖建议仓预填）。表头上方不再有批量按钮。
    // 2026-09-17 起明细进页默认全选，不再需要先点表头全选框。
    expect(
      find.byKey(const Key('warehouse-arrival-batch-apply-warehouse-all')),
      findsNothing,
      reason: '「批量设置入库仓库」常驻按钮已撤',
    );
    expect(find.text('移出本次登记 (0)'), findsNothing, reason: '「移出本次登记」已搬进行右键');
    final headerSelectAll = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    expect(headerSelectAll, findsWidgets);
    // 行框树序在表头框之前（3 行 + 表头 = 4 框），默认全选。
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).at(0)).value,
      isTrue,
      reason: '明细行进页默认全选',
    );

    // 2026-09-14「编号」列上移到名称后面（全站列序统一），仓库格右移出视口：
    // 与本文件其它格子一样先 ensureVisible 再点。
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-batch-wh-batch-item-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('warehouse-arrival-batch-wh-batch-item-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('先选主仓，再选子仓'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('原料仓'),
      findsNWidgets(3),
      reason: '勾了 3 行就该 3 行一起落仓，而不是只改点到的那一行',
    );
    expect(find.text('必选 · 点击选择'), findsNothing);

    // One batch can contain normal arrivals and physically returned replacements.
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-batch-source-batch-item-1')),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const Key('warehouse-arrival-batch-source-batch-item-1'),
        ),
        matching: find.text('自动识别'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('正常到货').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-batch-source-batch-item-2')),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const Key('warehouse-arrival-batch-source-batch-item-2'),
        ),
        matching: find.text('自动识别'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('先补退货').last);
    await tester.pumpAndSettle();

    // 提交：两张订货单 × 同一仓库 → 两张收货单（3 条明细分单）；幂等键内容派生。
    await tester.tap(find.byKey(const Key('warehouse-arrival-batch-submit')));
    await tester.pumpAndSettle();
    expect(find.text('确认登记送检'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(api.arrivalPostBodies, hasLength(2));
    expect(api.arrivalPostBodies.map((body) => body['warehouseId']).toSet(), {
      'warehouse-2',
    });
    final orderItemIds = <String>{};
    for (final body in api.arrivalPostBodies) {
      expect(
        body['idempotencyKey'] as String?,
        matches(r'^warehouse-arrival-create-[0-9a-f]{16}$'),
      );
      expect(body['receiverEmployeeId'], 'emp-me');
      orderItemIds.addAll(
        ((body['items'] as List).cast<Map<String, dynamic>>()).map(
          (item) => item['orderItemId'] as String,
        ),
      );
    }
    // 采购员按各自订货单带出。
    expect(api.arrivalPostBodies.map((body) => body['purchaserId']).toSet(), {
      'purchaser-1',
      'purchaser-2',
    });
    expect(orderItemIds, {'batch-item-1', 'batch-item-2', 'batch-item-3'});
    final sources = {
      for (final body in api.arrivalPostBodies)
        for (final item in (body['items'] as List).cast<Map<String, dynamic>>())
          item['orderItemId']: item['replacementIntent'],
    };
    expect(sources, {
      'batch-item-1': 'NORMAL',
      'batch-item-2': 'RETURN_REPLACEMENT',
      'batch-item-3': null,
    });
    // 登记完成回任务中心。
    expect(find.text('预计到货任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量登记页：明细默认全选，没勾行时提交置灰，只提交勾选行', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _BatchApi();
    final router = GoRouter(
      initialLocation: RouteName.warehouseArrivalReceiptBatch,
      routes: [
        GoRoute(
          path: RouteName.warehouseArrivalReceiptBatch,
          builder: (_, _) => WarehouseArrivalBatchReceiptPage(
            prefills: _prefills(),
            canRegister: true,
          ),
        ),
        GoRoute(
          path: RouteName.warehouseInboundExpectations,
          builder: (_, _) => const Scaffold(body: Text('预计到货任务中心')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          // 「先入库后质检」按钮需要独立权限点（与「登记并送检」并排验证置灰）。
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Column(
            children: [
              const AppNotificationHost(),
              Expanded(child: child ?? const SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final submit = find.byKey(const Key('warehouse-arrival-batch-submit'));
    UtenButton submitButton() => tester.widget<UtenButton>(submit);
    // 进页默认全选 → 提交可点。
    expect(submitButton().onPressed, isNotNull);

    // 表头全选框再点一次 = 清空全部勾选 → 两个提交按钮置灰，灰态点击说明原因。
    final headerSelectAll = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(headerSelectAll.first);
    await tester.pumpAndSettle();
    expect(submitButton().onPressed, isNull);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('warehouse-arrival-stock-in-first')),
          )
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(find.textContaining('请先勾选要登记送检的明细行'), findsOneWidget);

    // 只勾第一行（订货单 A，建议仓已预填）→ 可提交；确认弹窗写明未勾选行去向。
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(submitButton().onPressed, isNotNull);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('有 2 行未勾选'), findsOneWidget);
    expect(find.text('确认登记送检'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 只提交勾选的那一行（订货单 A × 成品仓 = 1 张收货单）。
    expect(api.arrivalPostBodies, hasLength(1));
    final items = (api.arrivalPostBodies.single['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items.map((item) => item['orderItemId']), ['batch-item-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预计到货：多选「先入库后质检」直达批量登记页并带 preStock=1', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? batchLocation;
    Object? batchExtra;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const Scaffold(body: WarehouseInboundExpectationsView()),
        ),
        GoRoute(
          path: RouteName.warehouseArrivalReceiptBatch,
          builder: (_, state) {
            batchLocation = state.uri.toString();
            batchExtra = state.extra;
            return const Scaffold(body: Text('批量登记页落点'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_ExpectationsApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 列表级批量按钮与「批量登记送检」并排（有独立权限才显示）。
    expect(find.text('先入库后质检'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('先入库后质检(1)'), findsOneWidget);
    await tester.tap(find.text('先入库后质检(1)'));
    await tester.pumpAndSettle();
    expect(find.text('批量登记页落点'), findsOneWidget);
    expect(
      batchLocation,
      '${RouteName.warehouseArrivalReceiptBatch}?preStock=1',
    );
    final prefillList = batchExtra;
    expect(prefillList, isA<List<ProcurementReceiptPrefill>>());
    expect(
      (prefillList! as List<ProcurementReceiptPrefill>).single.orderBillNo,
      'PO-001',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('预计到货：无先入库后质检权限时不显示批量按钮', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_ExpectationsApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseInboundExpectationsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('批量登记送检'), findsOneWidget);
    expect(find.text('先入库后质检'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量登记页：preStock 直达进页即「上架库位(必填)」', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _BatchApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp(
          home: WarehouseArrivalBatchReceiptPage(
            prefills: _prefills(),
            canRegister: true,
            initialStockInBeforeInspection: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 进页即先入库后质检模式：库位列必填红框口径（不再是普通「库位号」）。
    // 列头在横向滚动视口外未必构建，直接断言列定义。
    final grid = tester.widget<UtenEditableGrid<dynamic>>(
      find.byWidgetPredicate((widget) => widget is UtenEditableGrid),
    );
    final stockPlaceColumn = grid.columns
        .where((column) => column.key == 'stockPlace')
        .single;
    expect(stockPlaceColumn.label, '上架库位(必填)');
    expect(stockPlaceColumn.required, isTrue);
    expect(find.text('先入库后质检'), findsOneWidget);
    expect(find.text('登记并送检'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<ProcurementReceiptPrefill> _prefills() => const [
  // 订货单 A：带建议仓（成品仓）——行预填。
  ProcurementReceiptPrefill(
    expectationId: 'expectation-batch-1',
    orderType: ProcurementInboundOrderType.purchase,
    orderBillNo: 'PO-BATCH-001',
    orderId: 'order-batch-1',
    supplierId: 'supplier-1',
    supplierName: '测试供应商',
    warehouseId: null,
    suggestedWarehouseId: 'warehouse-1',
    suggestedWarehouseName: '成品仓',
    purchaserId: 'purchaser-1',
    items: [
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-1',
        goodsId: 'goods-1',
        goodsCode: 'G-001',
        goodsName: '轴套',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 5,
      ),
    ],
  ),
  // 订货单 B：无建议仓——行必选待填。
  ProcurementReceiptPrefill(
    expectationId: 'expectation-batch-2',
    orderType: ProcurementInboundOrderType.purchase,
    orderBillNo: 'PO-BATCH-002',
    orderId: 'order-batch-2',
    supplierId: 'supplier-2',
    supplierName: '测试供应商二',
    warehouseId: null,
    purchaserId: 'purchaser-2',
    items: [
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-2',
        goodsId: 'goods-2',
        goodsCode: 'G-002',
        goodsName: '端盖',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 8,
      ),
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-3',
        goodsId: 'goods-3',
        goodsCode: 'G-003',
        goodsName: '垫片',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 20,
      ),
    ],
  ),
];

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'user-me',
      code: 'USR-ME',
      name: '仓管员',
      roles: [],
      employeeId: 'emp-me',
    ),
  );
}

/// 预计到货列表桩：一条「待登记」采购任务（无草稿收货单）。
class _ExpectationsApi extends ApiClient {
  _ExpectationsApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/inbound/expectations') {
      return {
        'items': [
          {
            'id': 'expectation-1',
            'orderType': 'PURCHASE',
            'orderId': 'order-1',
            'billNo': 'PO-001',
            'supplierId': 'supplier-1',
            'supplierName': '测试供应商',
            'status': 'OPEN',
            'remainingQty': 5,
            'registeredQty': 0,
            'allowedActions': ['CREATE_PURCHASE_RECEIPT'],
            'draftReceiptIds': const <dynamic>[],
            'pendingInspectionReceipts': 0,
            'openArrivalExceptions': 0,
            'items': [
              {
                'id': 'expectation-item-1',
                'orderItemId': 'order-item-1',
                'goodsId': 'goods-1',
                'goodsCode': 'G-001',
                'goodsName': '轴套',
                'unitRate': 1,
                'orderedQty': 5,
                'acceptedQty': 0,
                'remainingQty': 5,
                'registeredQty': 0,
              },
            ],
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
      };
    }
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

/// 批量登记页桩：主档字典 + 登记端点回执。
class _BatchApi extends ApiClient {
  _BatchApi({this.disabledFirst = false}) : super(Dio());
  final bool disabledFirst;

  final List<Map<String, dynamic>> arrivalPostBodies = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return [
        {
          'id': 'warehouse-1',
          'name': '成品仓',
          'status': disabledFirst ? '禁用' : '使用',
          'accountable': true,
        },
        {'id': 'warehouse-2', 'name': '原料仓'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/inbound/arrivals') {
      arrivalPostBodies.add(Map<String, dynamic>.from(body! as Map));
      return const {
        'outcome': 'SUBMITTED_FOR_INSPECTION',
        'receiptId': 'po-receipt-1',
        'receiptBillNo': 'PO-SR-001',
      };
    }
    if (path == '/warehouse/inbound/goods-profile-hints') {
      return const {'updated': 0};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}
