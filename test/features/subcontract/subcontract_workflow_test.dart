import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';

void main() {
  test('planning applications are read-only and orders start from tasks', () {
    expect(SubcontractDocConfig.application.allowDirectCreate, isFalse);
    expect(SubcontractDocConfig.application.skipListOnCreate, isFalse);
    expect(SubcontractDocConfig.application.hasSupplier, isFalse);
    expect(SubcontractDocConfig.application.itemHasPrice, isFalse);

    expect(SubcontractDocConfig.order.allowDirectCreate, isFalse);
    expect(SubcontractDocConfig.order.skipListOnCreate, isFalse);
    expect(SubcontractDocConfig.order.supplierRequired, isTrue);
    expect(SubcontractDocConfig.order.linkToApplicationItem, isTrue);
  });

  test('decomposition preview keeps all fourteen server fields', () {
    final line = SubcontractDecompositionLine.fromJson({
      'sourceDocumentId': 'application-2',
      'sourceDocumentNo': 'EA-002',
      'sourceItemId': 'item-9',
      'goodsId': 'goods-3',
      'colorId': 'color-1',
      'unitId': 'unit-1',
      'unitRate': 2,
      'requestedQty': 10,
      'orderedQty': 2,
      'pendingQty': 3,
      'remainingQty': 5,
      'needDate': '2026-08-10',
      'warehouseId': 'warehouse-1',
      'sourcePlanNo': 'PP-001',
    });

    expect(line.sourceDocumentId, 'application-2');
    expect(line.sourceItemId, 'item-9');
    expect(line.unitRate, 2);
    expect(line.pendingQty, 3);
    expect(line.remainingQty, 5);
    expect(line.warehouseId, 'warehouse-1');
    expect(line.sourcePlanNo, 'PP-001');
  });

  test('order detail trusts finance allowedActions from the server', () {
    final detail = SubcontractDocDetail.fromJson({
      'id': 'order-1',
      'status': 0,
      'financeApproval': {
        'caseId': 'case-1',
        'status': 'PENDING',
        'attempt': 1,
        'version': 3,
        'assigneeName': '财务负责人',
        'allowedActions': ['APPROVE', 'REJECT'],
      },
    });

    expect(detail.financeApproval?.isPending, isTrue);
    expect(detail.financeApproval?.version, 3);
    expect(detail.financeApproval?.canApprove, isTrue);
    expect(detail.financeApproval?.canReject, isTrue);
    expect(detail.financeApproval?.canSubmit, isFalse);
  });

  test(
    'repository uses decomposition and finance decision endpoints',
    () async {
      final requests = <RequestOptions>[];
      final repository = SubcontractRepository(
        _api((request) {
          requests.add(request);
          if (request.path.endsWith('/decomposition-preview')) {
            return <Object?>[];
          }
          return {
            'id': 'order-1',
            'financeApproval': {
              'status': 'DRAFT',
              'attempt': 0,
              'version': 0,
              'allowedActions': ['SUBMIT_FINANCE'],
            },
          };
        }),
        SubcontractDocType.order,
      );

      await repository.decompositionPreview(['item-1', 'item-1']);
      await repository.submitFinance('order-1');
      await repository.approveFinance('order-1', expectedVersion: 2);
      await repository.rejectFinance(
        'order-1',
        expectedVersion: 3,
        reason: ' 修改价格 ',
      );

      expect(
        requests[0].path,
        '/subcontract/applications/decomposition-preview',
      );
      expect(requests[0].data, {
        'itemIds': ['item-1'],
      });
      expect(requests[1].path, '/subcontract/orders/order-1/submit-finance');
      expect(requests[2].data, {'expectedVersion': 2});
      expect(requests[3].path, '/subcontract/orders/order-1/reject');
      expect(requests[3].data, {'expectedVersion': 3, 'reason': '修改价格'});
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
