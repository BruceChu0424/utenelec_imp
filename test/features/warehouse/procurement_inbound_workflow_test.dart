import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/pages/finance_arrival_exception_pages.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  test('finance arrival task parses exact quantities, money and actions', () {
    final task = ProcurementArrivalException.fromJson(_financeTaskJson());

    expect(task.id, 'exception-1');
    expect(task.orderType, ProcurementInboundOrderType.purchase);
    expect(task.status, 'PENDING_FINANCE');
    expect(task.declaredQty, 100);
    expect(task.approvedRemainingQty, 10);
    expect(task.requestedExcessQty, 90);
    expect(task.unitPrice, '9007199254740993.1234');
    expect(task.declaredAmountOriginal, '900719925474099312.34');
    expect(task.declaredAmountLocal, '6485183463413515048.85');
    expect(task.excessAmountLocal, '5836665117072163543.97');
    expect(task.financeAssigneeName, '财务审核员甲');
    expect(task.detectedByEmployeeName, '仓管员乙');
    expect(task.canRejectExcess, isTrue);
    expect(task.canApproveCustom, isTrue);
    expect(task.canApproveAll, isTrue);
    expect(task.canCompleteReturn, isFalse);
  });

  test('missing allowedActions remains fail closed', () {
    final task = ProcurementArrivalException.fromJson({
      ..._financeTaskJson(),
      'allowedActions': null,
    });

    expect(task.canFinanceDecide, isFalse);
    expect(task.canCompleteReturn, isFalse);
  });

  test('return completion is the owner task only action', () {
    final task = ProcurementArrivalException.fromJson({
      ..._financeTaskJson(),
      'status': 'RETURN_REQUIRED',
      'acceptedQty': 15,
      'unacceptedQty': 85,
      'allowedActions': ['COMPLETE_RETURN'],
      'returnTask': {
        'id': 'return-1',
        'qty': 85,
        'status': 'PENDING_RETURN',
        'version': 2,
      },
    });

    expect(task.canFinanceDecide, isFalse);
    expect(task.canCompleteReturn, isTrue);
    expect(task.returnTask?.qty, 85);
  });

  test(
    'repository uses exact finance and owner endpoints and bodies',
    () async {
      final captured = <RequestOptions>[];
      final repository = DioProcurementInboundRepository(
        _api((request) {
          captured.add(request);
          if (request.path.endsWith('/count')) return {'count': 3};
          if (request.path.endsWith('/tasks')) {
            return {
              'items': <Map<String, dynamic>>[],
              'page': 1,
              'size': 20,
              'total': 0,
              'totalPages': 1,
            };
          }
          return _financeTaskJson();
        }),
      );

      await repository.financeTasks(page: 2, size: 5);
      await repository.financeTaskCount();
      await repository.financeTaskDetail('exception-1');
      await repository.financeDecide(
        id: 'exception-1',
        expectedVersion: 7,
        decision: FinanceArrivalDecision.approveCustom,
        customApprovedExcessQty: 5,
        financeReason: '临时补货已核准',
      );
      await repository.ownerTasks(
        page: 3,
        size: 10,
        orderType: ProcurementInboundOrderType.purchase,
      );
      await repository.ownerTaskCount(
        orderType: ProcurementInboundOrderType.subcontract,
      );
      await repository.ownerTaskDetail('exception-1');
      await repository.completeReturn(
        returnTaskId: 'return-1',
        expectedVersion: 2,
        completionNote: '供应商司机已带回',
      );

      expect(captured[0].path, '/finance/procurement-arrival-exceptions/tasks');
      expect(captured[0].queryParameters, {'page': 2, 'size': 5});
      expect(captured[1].path, '/finance/procurement-arrival-exceptions/count');
      expect(
        captured[2].path,
        '/finance/procurement-arrival-exceptions/exception-1',
      );
      expect(
        captured[3].path,
        '/finance/procurement-arrival-exceptions/exception-1/decision',
      );
      expect(captured[3].data, {
        'expectedVersion': 7,
        'decision': 'APPROVE_CUSTOM',
        'customApprovedExcessQty': 5,
        'financeReason': '临时补货已核准',
      });
      expect(captured[4].path, '/procurement/arrival-exceptions/tasks');
      expect(captured[4].queryParameters, {
        'page': 3,
        'size': 10,
        'orderType': 'PURCHASE',
      });
      expect(captured[5].path, '/procurement/arrival-exceptions/count');
      expect(captured[5].queryParameters, {'orderType': 'SUBCONTRACT'});
      expect(captured[6].path, '/procurement/arrival-exceptions/exception-1');
      expect(
        captured[7].path,
        '/procurement/arrival-exceptions/return-tasks/return-1/complete',
      );
      expect(captured[7].data, {
        'expectedVersion': 2,
        'completionNote': '供应商司机已带回',
      });
    },
  );

  test('finance decision omits optional values for reject excess', () async {
    late RequestOptions captured;
    final repository = DioProcurementInboundRepository(
      _api((request) {
        captured = request;
        return _financeTaskJson();
      }),
    );

    await repository.financeDecide(
      id: 'exception-1',
      expectedVersion: 7,
      decision: FinanceArrivalDecision.rejectExcess,
      financeReason: '   ',
    );

    expect(captured.data, {'expectedVersion': 7, 'decision': 'REJECT_EXCESS'});
  });

  testWidgets(
    'finance page has no default, safe option first, and custom input is conditional',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            procurementInboundRepositoryProvider.overrideWithValue(
              _FinanceDetailRepository(
                ProcurementArrivalException.fromJson(_financeTaskJson()),
              ),
            ),
          ],
          child: const MaterialApp(
            home: FinanceArrivalExceptionDetailPage(id: 'exception-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('系统不会预选，必须由您主动确认。'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(find.textContaining('只批准订单剩余，超出退回（推荐）'), findsOneWidget);
      expect(
        find.byKey(const Key('finance-arrival-custom-excess')),
        findsNothing,
      );
      expect(find.text('确认财务决定'), findsOneWidget);

      await tester.tap(find.text('自定义批准超量'));
      await tester.pump();

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(
        find.byKey(const Key('finance-arrival-custom-excess')),
        findsOneWidget,
      );
      expect(find.text('财务理由（必填）'), findsOneWidget);
      expect(find.text('确认财务决定'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('finance-arrival-custom-excess')),
        '5',
      );
      await tester.tap(find.text('确认财务决定'));
      await tester.pump();
      expect(find.text('再次确认财务决定'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('finance-arrival-reason')),
        '临时补货已核准',
      );
      await tester.tap(find.text('确认财务决定'));
      await tester.pumpAndSettle();

      expect(find.text('再次确认财务决定'), findsOneWidget);
      expect(find.text('预计允许入库：15 吨'), findsOneWidget);
      expect(find.text('预计退回供应商：85 吨'), findsOneWidget);
      expect(find.text('检测时超量金额快照：5836665117072163543.97'), findsOneWidget);
    },
  );

  test('expectation prefill is enabled only by server allowedActions', () {
    final allowed = InboundExpectation.fromJson({
      'id': 'expectation-1',
      'orderType': 'PURCHASE',
      'orderId': 'order-1',
      'billNo': 'PO-001',
      'supplierId': 'supplier-1',
      'warehouseId': 'warehouse-1',
      'status': 'OPEN',
      'remainingQty': 10,
      'allowedActions': ['CREATE_PURCHASE_RECEIPT'],
      'items': [
        {
          'id': 'expectation-item-1',
          'orderItemId': 'order-item-1',
          'goodsId': 'goods-1',
          'goodsCode': 'G-001',
          'goodsName': '铜材',
          'unitRate': 1,
          'orderedQty': 10,
          'acceptedQty': 0,
          'remainingQty': 10,
        },
      ],
    });
    final denied = InboundExpectation.fromJson({
      'id': 'expectation-1',
      'orderType': 'PURCHASE',
      'orderId': 'order-1',
      'billNo': 'PO-001',
      'supplierId': 'supplier-1',
      'warehouseId': 'warehouse-1',
      'status': 'OPEN',
      'remainingQty': 10,
      'items': [
        {
          'id': 'expectation-item-1',
          'orderItemId': 'order-item-1',
          'goodsId': 'goods-1',
          'remainingQty': 10,
        },
      ],
    });

    expect(allowed.canCreateReceipt, isTrue);
    expect(allowed.toReceiptPrefill()?.items.single.approvedRemainingQty, 10);
    expect(denied.canCreateReceipt, isFalse);
    expect(denied.toReceiptPrefill(), isNull);
  });

  // 到货登记编辑页「来源订货单」可点跳详情：prefill 必须同时携带
  // 编号（billNo，展示）与权威订货单 id（orderId，跳转目标）。
  test('receipt prefill carries order id alongside readable bill no', () {
    final expectation = InboundExpectation.fromJson({
      'id': 'expectation-1',
      'orderType': 'PURCHASE',
      'orderId': 'order-1',
      'billNo': 'PO-001',
      'supplierId': 'supplier-1',
      'warehouseId': 'warehouse-1',
      'status': 'OPEN',
      'remainingQty': 10,
      'allowedActions': ['CREATE_PURCHASE_RECEIPT'],
      'items': [
        {
          'id': 'expectation-item-1',
          'orderItemId': 'order-item-1',
          'goodsId': 'goods-1',
          'remainingQty': 10,
        },
      ],
    });
    final prefill = expectation.toReceiptPrefill();
    expect(prefill, isNotNull);
    expect(prefill!.orderBillNo, 'PO-001');
    expect(prefill.orderId, 'order-1');
    expect(prefill.supplierId, 'supplier-1');
  });
}

Map<String, dynamic> _financeTaskJson() => {
  'id': 'exception-1',
  'orderType': 'PURCHASE',
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
  'declaredQty': 100,
  'approvedRemainingQty': 10,
  'requestedExcessQty': 90,
  'acceptedQty': 0,
  'unacceptedQty': 0,
  'status': 'PENDING_FINANCE',
  'financeAssigneeUserId': 'user-finance-1',
  'financeAssigneeEmployeeId': 'employee-finance-1',
  'financeAssigneeName': '财务审核员甲',
  'detectedByEmployeeName': '仓管员乙',
  'unitPrice': '9007199254740993.1234',
  'declaredAmountOriginal': '900719925474099312.34',
  'declaredAmountLocal': '6485183463413515048.85',
  'excessAmountLocal': '5836665117072163543.97',
  'version': 7,
  'allowedActions': ['REJECT_EXCESS', 'APPROVE_CUSTOM', 'APPROVE_ALL'],
};

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

class _FinanceDetailRepository implements ProcurementInboundRepository {
  const _FinanceDetailRepository(this.task);

  final ProcurementArrivalException task;

  @override
  Future<ProcurementArrivalException> financeTaskDetail(String id) async =>
      task;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
