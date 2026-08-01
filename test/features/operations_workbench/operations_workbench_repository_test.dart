import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

void main() {
  test(
    'loads action status and sends the server-side exception filter',
    () async {
      late RequestOptions captured;
      final repository = OperationsWorkbenchRepository(
        _api((request) {
          captured = request;
          return {
            'items': [
              {
                'taskId': 'task-1',
                'packageId': 'package-1',
                'planId': 'plan-1',
                'planNo': 'PP-20260731-001',
                'warehouseName': '原材料仓',
                'goodsCode': 'MAT-001',
                'goodsName': '轴套',
                'spec': 'φ20',
                'colorName': '本色',
                'unitName': '件',
                'supplyRoute': 'PURCHASE',
                'requiredQty': 10,
                'allocatedQty': 4,
                'fulfilledQty': 2,
                'supplyPeggedQty': 4,
                'openQty': 8,
                'taskStatus': 'OPEN',
                'needDate': '2026-08-01',
                'expectedDate': null,
                'exceptionCode': 'SHORTAGE',
                'updatedAt': '2026-07-31T10:00:00+08:00',
                'actionDocType': 'PURCHASE_REQUEST',
                'actionDocId': 'request-1',
                'actionDocNo': 'PR-001',
                'actionDocItemId': 'request-item-1',
                'actionDocStatus': '1',
                'actionDocCanView': true,
                'actionDocCanEdit': false,
                'actionDocRestricted': false,
              },
            ],
            'page': 1,
            'size': 20,
            'total': 1,
            'totalPages': 1,
            'summary': {
              'totalTasks': 1,
              'overdueTasks': 0,
              'openTasks': 1,
              'openQty': 8,
              'statusCounts': {'OPEN': 1},
              'exceptionCounts': {'SHORTAGE': 1, 'OVERDUE_SHORTAGE': 2},
            },
            'capabilities': {'canCreatePurchaseOrder': true},
          };
        }),
      );

      final data = await repository.load(
        department: OperationsWorkbenchDepartment.purchase,
        keyword: ' 轴套 ',
        status: 'OPEN',
        exception: 'OVERDUE_ANY',
      );

      expect(captured.path, '/operations/workbench/purchase');
      expect(captured.queryParameters, {
        'page': 1,
        'size': 20,
        'keyword': '轴套',
        'status': 'OPEN',
        'exception': 'OVERDUE_ANY',
      });
      expect(data.summary.openQty, 8);
      expect(data.summary.exceptionCounts['OVERDUE_SHORTAGE'], 2);
      expect(data.items.single.goodsCode, 'MAT-001');
      expect(data.items.single.actionDocItemId, 'request-item-1');
      expect(
        data.items.single.actionDocument?.path,
        '/purchase/requests/request-1',
      );
      expect(data.items.single.actionDocument?.status, '1');
      expect(data.items.single.actionDocument?.canView, isTrue);
      expect(data.items.single.actionDocument?.canEdit, isFalse);
      expect(data.items.single.actionDocumentRestricted, isFalse);
      expect(data.capabilities.canCreatePurchaseOrder, isTrue);
      expect(data.items.single.actionDocument?.label, '已审采购申请 PR-001');
      expect(data.items.single.statusLabel, '采购申请已审核，待下单');
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
