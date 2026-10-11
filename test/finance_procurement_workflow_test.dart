import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'approval tasks accept compatible envelopes and preserve deep links',
    () async {
      late RequestOptions captured;
      final repository = DioFinanceProcurementWorkflowRepository(
        _api((request) {
          captured = request;
          return <String, dynamic>{
            'data': <String, dynamic>{
              'tasks': <Map<String, dynamic>>[
                <String, dynamic>{
                  'caseId': 'case-1',
                  'workflowTaskId': 'task-1',
                  'documentId': 'order-1',
                  'documentType': 'PURCHASE_ORDER',
                  'documentNo': 'PO-001',
                  'supplier': <String, dynamic>{'name': '示例供应商'},
                  'submittedBy': <String, dynamic>{'name': '采购员甲'},
                  'totalAmount': '9007199254740993.12',
                  'currencyCode': 'CNY',
                },
                <String, dynamic>{
                  'caseId': 'case-2',
                  'taskId': 'task-2',
                  'orderId': 'sub-1',
                  'orderType': 'OUTSOURCE_ORDER',
                  'billNo': 'SO-001',
                },
              ],
              'pageNumber': 2,
              'pageSize': 10,
              'totalElements': 12,
              'totalPages': 2,
            },
          };
        }),
      );

      final result = await repository.approvalTasks(
        page: 2,
        size: 10,
        keyword: ' PO ',
      );

      expect(captured.path, '/finance/procurement-approvals/tasks');
      expect(captured.queryParameters, <String, dynamic>{
        'page': 2,
        'size': 10,
        'keyword': 'PO',
      });
      expect(result.page, 2);
      expect(result.total, 12);
      expect(result.items.first.amount, '9007199254740993.12');
      expect(result.items.first.detailRoute, '/purchase/orders/order-1');
      expect(result.items.last.detailRoute, '/subcontract/orders/sub-1');
    },
  );

  test('approval task parses the exact backend contract', () {
    final task = FinanceProcurementApprovalTask.fromJson(const {
      'caseId': 'case-7',
      'orderType': 'PURCHASE',
      'orderId': 'order-7',
      'billNo': 'PO-007',
      'amount': '9007199254740993.12',
      'supplierName': '精确供应商',
      'warehouseName': '一号仓',
      'expectedDate': '2026-08-10',
      'attempt': 2,
      'version': 5,
      'submittedByEmployeeId': 'employee-7',
      'submittedByName': '采购员乙',
      'submittedAt': '2026-08-02T10:30:00+08:00',
      'allowedActions': ['APPROVE', 'REJECT'],
    });

    expect(task.caseId, 'case-7');
    expect(task.orderType, FinanceProcurementOrderType.purchase);
    expect(task.orderId, 'order-7');
    expect(task.billNo, 'PO-007');
    expect(task.amount, '9007199254740993.12');
    expect(task.supplierName, '精确供应商');
    expect(task.warehouseName, '一号仓');
    expect(task.expectedDate, '2026-08-10');
    expect(task.attempt, 2);
    expect(task.version, 5);
    expect(task.submittedByEmployeeId, 'employee-7');
    expect(task.submittedByName, '采购员乙');
    expect(task.submittedAt, '2026-08-02T10:30:00+08:00');
    expect(task.allowedActions, {'APPROVE', 'REJECT'});
    expect(task.detailRoute, '/purchase/orders/order-7');
    expect(task.decisionItem?.toJson(), {
      'caseId': 'case-7',
      'expectedVersion': 5,
    });
  });

  test('approval decisions use exact atomic batch case contracts', () async {
    final requests = <RequestOptions>[];
    final repository = DioFinanceProcurementWorkflowRepository(
      _api((request) {
        requests.add(request);
        return <String, dynamic>{};
      }),
    );

    await repository.approveOrdersBatch(const [
      FinanceProcurementDecisionItem(caseId: 'case-7', expectedVersion: 7),
    ]);
    await repository.rejectOrdersBatch(const [
      FinanceProcurementDecisionItem(caseId: 'case-8', expectedVersion: 8),
    ], ' 统一退回原因 ');

    expect(
      requests[0].path,
      '/finance/procurement-approvals/tasks/batch-approve',
    );
    expect(requests[0].data, {
      'items': [
        {'caseId': 'case-7', 'expectedVersion': 7},
      ],
    });
    expect(
      requests[1].path,
      '/finance/procurement-approvals/tasks/batch-reject',
    );
    expect(requests[1].data, {
      'items': [
        {'caseId': 'case-8', 'expectedVersion': 8},
      ],
      'reason': '统一退回原因',
    });
    expect(requests, hasLength(2));
  });

  // 2026-10-10 财务订货审批口径：通过请求体带可选 exchangeRate（>0 才进请求体，
  // 驳回不带）——汇率落在本笔审批 case 上（V438 迁移冻结期间订单头汇率禁改）。
  test(
    'batch approve carries the finance exchange rate when provided',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioFinanceProcurementWorkflowRepository(
        _api((request) {
          requests.add(request);
          return <String, dynamic>{};
        }),
      );

      await repository.approveOrdersBatch(const [
        FinanceProcurementDecisionItem(caseId: 'case-9', expectedVersion: 9),
      ], exchangeRate: 6.5);
      await repository.approveOrdersBatch(const [
        FinanceProcurementDecisionItem(caseId: 'case-10', expectedVersion: 10),
      ], exchangeRate: 0);
      await repository.rejectOrdersBatch(const [
        FinanceProcurementDecisionItem(caseId: 'case-11', expectedVersion: 11),
      ], '原因');

      expect(requests[0].data, {
        'items': [
          {'caseId': 'case-9', 'expectedVersion': 9},
        ],
        'exchangeRate': 6.5,
      });
      expect(requests[1].data, {
        'items': [
          {'caseId': 'case-10', 'expectedVersion': 10},
        ],
      }, reason: '非正数汇率不进请求体（服务端按缺省处理）');
      expect(
        (requests[2].data as Map<String, dynamic>).containsKey('exchangeRate'),
        isFalse,
        reason: '驳回不落汇率',
      );
    },
  );

  test('unknown task type remains fail closed', () {
    final task = FinanceProcurementApprovalTask.fromJson(const {
      'taskId': 'task-unknown',
      'orderId': 'order-unknown',
      'orderType': 'UNEXPECTED',
      'orderNo': 'UNKNOWN-1',
    });

    expect(task.canOpen, isFalse);
    expect(task.detailRoute, isNull);
  });

  // 2026-10-10 财务订货审批口径：review 详情响应新增 financeExchangeRate
  // （数值或 null——已批 case = 财务通过时填的汇率；未批 = null 前端用快照兜底）。
  test('review parses finance exchange rate (numeric or null)', () {
    final approved = FinanceProcurementApprovalReview.fromJson(const {
      'caseId': 'case-1',
      'orderId': 'order-1',
      'orderType': 'PURCHASE',
      'billNo': 'PO-001',
      'status': 'APPROVED',
      'financeExchangeRate': 6.85,
      'exchangeRate': '7.1',
    });
    expect(approved.financeExchangeRate, '6.85');
    expect(approved.exchangeRate, '7.1');

    final pending = FinanceProcurementApprovalReview.fromJson(const {
      'caseId': 'case-2',
      'orderId': 'order-2',
      'orderType': 'SUBCONTRACT',
      'billNo': 'SO-001',
      'exchangeRate': '7.1',
    });
    expect(pending.financeExchangeRate, isNull);
  });

  test(
    'pending order detail routes accept business view or finance task view',
    () {
      expect(requiredAnyPermFor('/purchase/orders/order-1'), const [
        Perm.purchaseOrderView,
        Perm.financeOrderApprovalView,
      ]);
      expect(requiredAnyPermFor('/subcontract/orders/order-1'), const [
        Perm.subcontractOrderView,
        Perm.financeOrderApprovalView,
      ]);
    },
  );
}

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
