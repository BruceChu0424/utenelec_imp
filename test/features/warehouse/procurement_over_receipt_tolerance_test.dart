// ADR-144 采购允许超收在仓库 / 财务到货侧的展示：
//  - 预计到货明细读出允许超收% 与最多可收，扣已登记待审核量后带进登记预填；
//  - 登记页「最多可收」文字：105(含允许超收 5%)；比例 0 只显示数量；委外「—」；
//  - 到货异常按检出时快照说明「订 Q，允许超收 p%(最多 Q+T)，此前已收 R，本次实到 D，
//    累计 R+D，需审批超量 X」；委外 / 旧异常沿用「实到 / 已批准剩余」；
//  - 登记草稿恢复保留这两项展示事实；
//  - 财务超量到货任务卡与详情按新口径展示。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/arrival_form_draft_codec.dart';
import 'package:uten_imp/features/warehouse/pages/finance_arrival_exception_pages.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_exceptions_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

Map<String, dynamic> _expectationJson({
  String orderType = 'PURCHASE',
  Object? pct = 5,
  Object? maxReceivable = 105,
  num registered = 0,
}) => {
  'id': 'expectation-1',
  'orderType': orderType,
  'orderId': 'order-1',
  'billNo': 'PO-001',
  'supplierId': 'supplier-1',
  'status': 'OPEN',
  'remainingQty': 100,
  'registeredQty': registered,
  'allowedActions': [
    orderType == 'PURCHASE'
        ? 'CREATE_PURCHASE_RECEIPT'
        : 'CREATE_SUBCONTRACT_RECEIPT',
  ],
  'items': [
    {
      'id': 'expectation-item-1',
      'orderItemId': 'order-item-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '铜材',
      'unitRate': 1,
      'orderedQty': 100,
      'acceptedQty': 0,
      'remainingQty': 100,
      'registeredQty': registered,
      'allowedOverReceiptPct': ?pct,
      'maxReceivableQty': ?maxReceivable,
    },
  ],
};

Map<String, dynamic> _exceptionJson({
  String orderType = 'PURCHASE',
  bool withSnapshot = true,
}) => {
  'id': 'exception-1',
  'orderType': orderType,
  'receiptId': 'receipt-1',
  'receiptItemId': 'receipt-item-1',
  'receiptBillNo': 'PR-001',
  'orderId': 'order-1',
  'orderItemId': 'order-item-1',
  'orderBillNo': 'PO-001',
  'supplierName': '示例供应商',
  'warehouseName': '一号仓',
  'goodsCode': 'G-001',
  'goodsName': '铜材',
  'unitName': '吨',
  'declaredQty': 10,
  'approvedRemainingQty': 5,
  'requestedExcessQty': 5,
  'acceptedQty': 0,
  'unacceptedQty': 0,
  'status': 'PENDING_FINANCE',
  'version': 7,
  'allowedActions': ['REJECT_EXCESS', 'APPROVE_CUSTOM', 'APPROVE_ALL'],
  if (withSnapshot) ...{
    'orderQtySnapshot': 100,
    'allowedOverReceiptPctSnapshot': 5,
    'toleranceQtySnapshot': 5,
    'priorNetReceivedQtySnapshot': 100,
  },
};

class _FinanceRepository implements ProcurementInboundRepository {
  const _FinanceRepository(this.task);

  final ProcurementArrivalException task;

  @override
  Future<PagedResult<ProcurementArrivalException>> financeTasks({
    int page = 1,
    int size = 20,
  }) async =>
      PagedResult(items: [task], page: 1, size: size, total: 1, totalPages: 1);

  @override
  Future<ProcurementArrivalException> financeTaskDetail(String id) async =>
      task;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExceptionListApi extends ApiClient {
  _ExceptionListApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.warehouseArrivalExceptions) {
      throw StateError('Unexpected GET $path');
    }
    return {
      'items': [
        _exceptionJson(),
        {
          ..._exceptionJson(orderType: 'SUBCONTRACT', withSnapshot: false),
          'id': 'exception-2',
          'receiptBillNo': 'PR-002',
        },
      ],
      'page': 1,
      'size': 20,
      'total': 2,
      'totalPages': 1,
    };
  }
}

void main() {
  group('预计到货 → 登记预填', () {
    test('采购明细带允许超收与最多可收，扣已登记待审核量', () {
      final expectation = InboundExpectation.fromJson(
        _expectationJson(registered: 10),
      );
      final item = expectation.items.single;
      expect(item.allowedOverReceiptPct, 5);
      expect(item.maxReceivableQty, 105);
      expect(item.effectiveMaxReceivableQty, 95);
      final prefill = expectation.toReceiptPrefill()!.items.single;
      expect(prefill.approvedRemainingQty, 90);
      expect(prefill.maxReceivableQty, 95);
      expect(prefill.hasOverReceiptAllowance, isTrue);
      expect(prefill.maxReceivableLabel, '95(含允许超收 5%)');
    });

    test('比例为 0 只显示数量；委外没有这项显示「—」', () {
      final zero = InboundExpectation.fromJson(
        _expectationJson(pct: 0, maxReceivable: 100),
      ).toReceiptPrefill()!.items.single;
      expect(zero.hasOverReceiptAllowance, isFalse);
      expect(zero.maxReceivableLabel, '100');

      final subcontract = InboundExpectation.fromJson(
        _expectationJson(
          orderType: 'SUBCONTRACT',
          pct: null,
          maxReceivable: null,
        ),
      ).toReceiptPrefill()!.items.single;
      expect(subcontract.maxReceivableQty, isNull);
      expect(subcontract.maxReceivableLabel, '—');
    });

    test('服务端十进制字符串也能读出', () {
      final base = Map<String, dynamic>.from(
        (_expectationJson()['items'] as List).single as Map,
      );
      final item = InboundExpectationItem.fromJson({
        ...base,
        'allowedOverReceiptPct': '2.50',
        'maxReceivableQty': '102.5',
      });
      expect(item.allowedOverReceiptPct, 2.5);
      expect(item.maxReceivableQty, 102.5);
    });

    test('登记草稿恢复保留允许超收与最多可收', () {
      final prefill = InboundExpectation.fromJson(
        _expectationJson(),
      ).toReceiptPrefill()!;
      final restored = restoreArrivalPrefillDraft(arrivalPrefillDraft(prefill));
      final item = restored.items.single;
      expect(item.allowedOverReceiptPct, 5);
      expect(item.maxReceivableQty, 105);
      expect(item.maxReceivableLabel, '105(含允许超收 5%)');
    });
  });

  group('到货异常快照说明', () {
    test('采购按「订 Q，允许超收 p%(最多 Q+T)…」一句说明', () {
      final task = ProcurementArrivalException.fromJson(_exceptionJson());
      expect(task.hasReceiptToleranceSnapshot, isTrue);
      expect(
        task.receiptToleranceFacts,
        '订 100，允许超收 5%(最多 105)，此前已收 100，本次实到 10，累计 110',
      );
      expect(
        task.receiptToleranceSummary,
        '订 100，允许超收 5%(最多 105)，此前已收 100，本次实到 10，累计 110，需审批超量 5',
      );
    });

    test('比例为空按 0% 说明', () {
      final task = ProcurementArrivalException.fromJson({
        ..._exceptionJson(),
        'allowedOverReceiptPctSnapshot': null,
        'toleranceQtySnapshot': 0,
      });
      expect(task.receiptToleranceFacts, startsWith('订 100，允许超收 0%(最多 100)'));
    });

    test('委外与旧异常没有快照，沿用原说法', () {
      expect(
        ProcurementArrivalException.fromJson(
          _exceptionJson(orderType: 'SUBCONTRACT', withSnapshot: false),
        ).receiptToleranceSummary,
        isNull,
      );
      expect(
        ProcurementArrivalException.fromJson(
          _exceptionJson(withSnapshot: false),
        ).receiptToleranceFacts,
        isNull,
      );
    });
  });

  testWidgets('财务超量到货任务卡按允许超收口径说明', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInboundRepositoryProvider.overrideWithValue(
            _FinanceRepository(
              ProcurementArrivalException.fromJson(_exceptionJson()),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FinanceArrivalExceptionTasksPage(embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('订 100，允许超收 5%(最多 105)，此前已收 100，本次实到 10，累计 110'),
      findsOneWidget,
    );
    expect(find.text('需审批超量 5 吨'), findsOneWidget);
    expect(find.textContaining('已批准剩余'), findsNothing);
  });

  testWidgets('财务详情列出订货量、允许超收与累计到货', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInboundRepositoryProvider.overrideWithValue(
            _FinanceRepository(
              ProcurementArrivalException.fromJson(_exceptionJson()),
            ),
          ),
        ],
        child: const MaterialApp(
          home: FinanceArrivalExceptionDetailPage(id: 'exception-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('订货量：'), findsOneWidget);
    expect(find.text('允许超收：'), findsOneWidget);
    expect(find.text('5%(最多可收 105 吨)'), findsOneWidget);
    expect(find.text('此前已收：'), findsOneWidget);
    expect(find.text('累计到货(含本次)：'), findsOneWidget);
    expect(find.text('110 吨'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库到货异常表「允许超收」列：采购显示比例与最多可收，委外「—」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_ExceptionListApi()),
          currentPermissionsProvider.overrideWithValue({
            Perm.warehouseInboundView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: WarehouseArrivalExceptionsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final table = tester
        .widget<MasterDataTableView<ProcurementArrivalException>>(
          find.byWidgetPredicate(
            (widget) =>
                widget is MasterDataTableView<ProcurementArrivalException>,
          ),
        );
    final column = table.columns.singleWhere(
      (column) => column.key == 'allowedOverReceipt',
    );
    expect(table.items.map(column.value), ['5%(最多 105)', '—']);
  });
}
