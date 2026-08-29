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

  test('count accepts nested aliases and clamps negative values', () async {
    var response = <String, dynamic>{
      'data': <String, dynamic>{'pendingCount': '7'},
    };
    final repository = DioFinanceProcurementWorkflowRepository(
      _api((_) => response),
    );

    expect(await repository.pendingApprovalCount(), 7);
    response = <String, dynamic>{'count': -2};
    expect(await repository.pendingApprovalCount(), 0);
  });

  test(
    'approval decisions use exact action paths, versions and reasons',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioFinanceProcurementWorkflowRepository(
        _api((request) {
          requests.add(request);
          return <String, dynamic>{};
        }),
      );

      await repository.approveOrder(
        FinanceProcurementOrderType.purchase,
        'purchase-1',
        3,
      );
      await repository.rejectOrder(
        FinanceProcurementOrderType.purchase,
        'purchase-1',
        4,
        ' 数量需要复核 ',
      );
      await repository.approveOrder(
        FinanceProcurementOrderType.subcontract,
        'subcontract-1',
        5,
      );
      await repository.rejectOrder(
        FinanceProcurementOrderType.subcontract,
        'subcontract-1',
        6,
        ' 工价需要复核 ',
      );
      await repository.approveOrdersBatch(const [
        FinanceProcurementDecisionItem(caseId: 'case-7', expectedVersion: 7),
      ]);
      await repository.rejectOrdersBatch(const [
        FinanceProcurementDecisionItem(caseId: 'case-8', expectedVersion: 8),
      ], ' 统一退回原因 ');

      expect(requests[0].path, '/purchase/orders/purchase-1/approve');
      expect(requests[0].data, {'expectedVersion': 3});
      expect(requests[1].path, '/purchase/orders/purchase-1/reject');
      expect(requests[1].data, {'expectedVersion': 4, 'reason': '数量需要复核'});
      expect(requests[2].path, '/subcontract/orders/subcontract-1/approve');
      expect(requests[2].data, {'expectedVersion': 5});
      expect(requests[3].path, '/subcontract/orders/subcontract-1/reject');
      expect(requests[3].data, {'expectedVersion': 6, 'reason': '工价需要复核'});
      expect(
        requests[4].path,
        '/finance/procurement-approvals/tasks/batch-approve',
      );
      expect(requests[4].data, {
        'items': [
          {'caseId': 'case-7', 'expectedVersion': 7},
        ],
      });
      expect(
        requests[5].path,
        '/finance/procurement-approvals/tasks/batch-reject',
      );
      expect(requests[5].data, {
        'items': [
          {'caseId': 'case-8', 'expectedVersion': 8},
        ],
        'reason': '统一退回原因',
      });
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
