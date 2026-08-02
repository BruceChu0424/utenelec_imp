import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';

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

      final result = await repository.approvalTasks(page: 2, size: 10);

      expect(captured.path, '/finance/procurement-approvals/tasks');
      expect(captured.queryParameters, <String, dynamic>{
        'page': 2,
        'size': 10,
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
    'responsibility API uses fixed endpoints and exact update body',
    () async {
      final captured = <RequestOptions>[];
      final repository = DioFinanceProcurementWorkflowRepository(
        _api((request) {
          captured.add(request);
          if (request.path.endsWith('/reviewers')) {
            return <Map<String, dynamic>>[
              <String, dynamic>{
                'userId': 'user-2',
                'employeeId': 'employee-2',
                'employeeName': '李四',
                'departmentId': 'department-finance',
                'departmentName': '财务部',
                'enabled': true,
              },
              <String, dynamic>{
                'userId': 'user-disabled',
                'name': '停用人员',
                'active': false,
              },
            ];
          }
          if (request.method == 'PUT') {
            return <String, dynamic>{
              'behaviorCode': 'PURCHASE_ORDER_FINANCE_APPROVAL',
              'assigneeUserId': 'user-2',
              'assigneeEmployeeId': 'employee-2',
              'assigneeName': '李四',
              'version': 4,
            };
          }
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'behaviorCode': 'PURCHASE_ORDER_FINANCE_APPROVAL',
              'assigneeUserId': 'user-1',
              'assigneeName': '张三',
              'version': 3,
            },
          ];
        }),
      );

      final responsibilities = await repository.responsibilities();
      final reviewers = await repository.reviewers();
      final updated = await repository.updateResponsibility(
        behaviorCode: 'PURCHASE_ORDER_FINANCE_APPROVAL',
        assigneeUserId: 'user-2',
        expectedVersion: 3,
        password: 'Current-Password',
      );

      expect(responsibilities.single.assigneeName, '张三');
      expect(reviewers.map((reviewer) => reviewer.employeeName), <String>[
        '李四',
      ]);
      expect(reviewers.single.userId, 'user-2');
      expect(reviewers.single.employeeId, 'employee-2');
      expect(reviewers.single.departmentId, 'department-finance');
      expect(updated.assigneeName, '李四');
      expect(updated.version, 4);
      expect(captured[0].path, '/admin/workflow-responsibilities');
      expect(captured[1].path, '/admin/workflow-responsibilities/reviewers');
      expect(
        captured[2].path,
        '/admin/workflow-responsibilities/PURCHASE_ORDER_FINANCE_APPROVAL',
      );
      expect(captured[2].data, <String, dynamic>{
        'assigneeUserId': 'user-2',
        'expectedVersion': 3,
        'password': 'Current-Password',
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
