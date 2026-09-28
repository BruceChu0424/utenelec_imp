// 到货登记「实称重量」契约 (ADR-135 §3.1):
//  1. 重量列跟在数量组(本次实收 + 单位)之后, 表头随录入单位「实称重量(kg)」;
//  2. 带单位后缀输入(20g) 以千克 4 位提交, 幂等键带上重量: 改了重量是另一个请求;
//  3. 按本单供应商学到的单重核对, 偏差超出容差出「称重核对」标签, 表尾「实称 / 称重偏差」;
//  4. 行单位本身是重量单位时只读「=5 kg」, 提交不带重量;
//  5. 称重计数「按称重改数量」回填整数数量(黄框)并带 qtyFromWeight。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_receipt_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_place_suggestion_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import 'arrival_weight_test_support.dart';

const _goodsId = 'goods-screw';
const _itemId = 'order-item-screw';

ProcurementReceiptPrefill _prefill({
  String? unitId,
  String unitName = '个',
  num approvedRemainingQty = 5,
}) => ProcurementReceiptPrefill(
  expectationId: 'expectation-weight',
  orderType: ProcurementInboundOrderType.subcontract,
  orderBillNo: 'SC-PO-WEIGHT',
  supplierId: 'supplier-1',
  supplierName: '测试委外商',
  warehouseId: 'warehouse-1',
  suggestedWarehouseId: 'warehouse-1',
  items: [
    ProcurementReceiptPrefillItem(
      orderItemId: _itemId,
      goodsId: _goodsId,
      goodsCode: 'SCR-01',
      goodsName: '螺丝',
      unitId: unitId,
      unitName: unitName,
      unitRate: 1,
      approvedRemainingQty: approvedRemainingQty,
    ),
  ],
);

Future<({_Api api, FakeWeightRepository weights})> _open(
  WidgetTester tester, {
  required ProcurementReceiptPrefill prefill,
  Map<String, WeightUnit> massUnits = const {},
  bool failFirstArrival = false,
}) async {
  tester.view.physicalSize = const Size(2200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _Api(failFirstArrival: failFirstArrival);
  final weights = FakeWeightRepository(
    api,
    byGoods: const {_goodsId: learnedTwoGramParams},
  );
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('任务中心')),
      GoRoute(
        path: '/receipt',
        builder: (_, _) =>
            WarehouseArrivalReceiptPage(prefill: prefill, canRegister: true),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.warehouseInboundView,
          Perm.warehouseInboundStockIn,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ...warehouseWeightTestOverrides(
          api,
          repository: weights,
          massUnits: massUnits,
        ),
        employeeRepositoryProvider.overrideWithValue(
          DioEmployeeRepository(api),
        ),
        procurementInboundRepositoryProvider.overrideWithValue(
          DioProcurementInboundRepository(api),
        ),
        warehousePlaceSuggestionRepositoryProvider.overrideWithValue(
          WarehousePlaceSuggestionRepository(api),
        ),
        departmentCodeIdMapProvider.overrideWith(
          (ref) async => <String, String>{},
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  router.push<void>('/receipt');
  await tester.pumpAndSettle();
  return (api: api, weights: weights);
}

Finder _grid() => find.byKey(const Key('warehouse-arrival-lines-grid'));

Finder _weightInput() => find.descendant(
  of: _grid(),
  matching: find.byKey(const ValueKey('weight-cell-input')),
);

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.text('先质检后入库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认登记送检'));
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _item(Map<String, dynamic> body) =>
    (body['items'] as List).cast<Map<String, dynamic>>().single;

void main() {
  testWidgets('实称重量: 后缀换千克提交, 幂等键带重量, 偏差出称重核对标签', (tester) async {
    final (:api, :weights) = await _open(
      tester,
      prefill: _prefill(),
      failFirstArrival: true,
    );

    // 列序: 本次实收 → 单位 → 实称重量(kg) → 称重核对 → 入库仓库。
    final grid = tester.widget<UtenEditableGrid<EditableGridRow>>(_grid());
    final labels = grid.columns.map((column) => column.label).toList();
    final unit = labels.indexOf('单位');
    expect(labels.indexOf('本次实收'), unit - 1);
    expect(labels[unit + 1], '实称重量(kg)');
    expect(labels[unit + 2], '称重核对');
    expect(labels[unit + 3], '入库仓库');
    // 单重参数按「货品 × 本单供应商」取。
    expect(weights.requests.first.single.goodsId, _goodsId);
    expect(weights.requests.first.single.supplierId, 'supplier-1');

    // 5 个 × 约 2 g = 约 10 g; 称了 20 g → 偏多约 5 个, 出琥珀/红标签。
    await tester.enterText(_weightInput(), '20g');
    await tester.pump();
    final chip = find.byKey(
      const ValueKey('warehouse-arrival-weight-check-$_itemId'),
    );
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.textContaining('偏多约')),
      findsOneWidget,
    );
    // 表尾: 实称 20 g, 称重偏差 1 行。
    final totals = find.byKey(const Key('warehouse-arrival-totals'));
    expect(
      find.descendant(of: totals, matching: find.text('20 g')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: totals, matching: find.text('1 行')),
      findsWidgets,
    );

    // 第一次提交丢响应: 重量以千克 4 位提交, 没按称重改数量不带标记。
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(1));
    final first = api.arrivalBodies.single;
    expect(_item(first)['weight'], 0.02);
    expect(_item(first)['qty'], 5);
    expect(_item(first).containsKey('qtyFromWeight'), isFalse);

    // 改了重量再提交是另一个请求 (幂等键不同)。
    await tester.enterText(_weightInput(), '19g');
    await tester.pump();
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(2));
    final second = api.arrivalBodies.last;
    expect(_item(second)['weight'], 0.019);
    expect(second['idempotencyKey'], isNot(first['idempotencyKey']));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('任务中心'), findsOneWidget);
  });

  testWidgets('行单位本身是重量单位: 只读「=5 kg」, 提交不带重量', (tester) async {
    final (:api, weights: _) = await _open(
      tester,
      prefill: _prefill(unitId: 'unit-kg', unitName: 'kg'),
      massUnits: const {'unit-kg': WeightUnit.kg},
    );

    expect(
      find.descendant(
        of: _grid(),
        matching: find.byKey(const ValueKey('weight-cell-exact')),
      ),
      findsOneWidget,
    );
    expect(find.text('=5 kg'), findsOneWidget);
    expect(_weightInput(), findsNothing);

    await _submit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(api.arrivalBodies, hasLength(1));
    expect(_item(api.arrivalBodies.single).containsKey('weight'), isFalse);
  });

  testWidgets('称重计数「按称重改数量」: 数量黄框回填并带 qtyFromWeight', (tester) async {
    final (:api, weights: _) = await _open(
      tester,
      prefill: _prefill(approvedRemainingQty: 10000),
    );

    await tester.tap(
      find.descendant(
        of: _grid(),
        matching: find.byKey(const ValueKey('weight-cell-weigh')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('weigh-count-gross-0')),
      '19.3',
    );
    await tester.pumpAndSettle();
    // 到货默认「只记重量」; 次按钮「按称重改数量」按估算数量入账。
    await tester.tap(find.byKey(const ValueKey('weigh-count-secondary')));
    await tester.pumpAndSettle();

    final qtyField = tester.widget<TextField>(
      find.byKey(const ValueKey('warehouse-arrival-qty-$_itemId')),
    );
    final qty = qtyField.controller! as UtenAutofillTextController;
    expect(qty.text, '9654');
    expect(qty.autofilled, isTrue);

    await _submit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final item = _item(api.arrivalBodies.single);
    expect(item['qty'], 9654);
    expect(item['weight'], 19.3);
    expect(item['qtyFromWeight'], isTrue);
  });
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'user-me',
      code: 'USR-ME',
      name: '仓管员',
      employeeId: 'emp-me',
    ),
  );
}

class _Api extends ApiClient {
  _Api({this.failFirstArrival = false}) : super(Dio());

  final bool failFirstArrival;
  final List<Map<String, dynamic>> arrivalBodies = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => throw ApiException('TEST_UNEXPECTED_GET', path);

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
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
      arrivalBodies.add(Map<String, dynamic>.from(body! as Map));
      if (failFirstArrival && arrivalBodies.length == 1) {
        throw NetworkException('响应中断，请使用原请求重试');
      }
      return const {
        'outcome': 'SUBMITTED_FOR_INSPECTION',
        'receiptId': 'sc-receipt-1',
        'receiptBillNo': 'SC-SR-001',
      };
    }
    if (path == '/warehouse/inbound/goods-profile-hints') {
      return const {'updated': 0};
    }
    if (path == '/warehouse/place-suggestions') {
      return const {'items': <Map<String, dynamic>>[]};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}
