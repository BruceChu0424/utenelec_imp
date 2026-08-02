import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';

void main() {
  test('order actions are accepted only from the server projection', () {
    final assigned = PurchaseDocDetail.fromJson({
      'id': 'order-1',
      'financeApproval': {
        'caseId': 'case-1',
        'status': 'PENDING',
        'attempt': 1,
        'version': 3,
        'assigneeUserId': 'finance-user',
        'assigneeName': '财务张三',
        'allowedActions': ['APPROVE', 'REJECT'],
      },
    });
    final unassigned = PurchaseDocDetail.fromJson({
      'id': 'order-1',
      'financeApproval': {
        'caseId': 'case-1',
        'status': 'PENDING',
        'attempt': 1,
        'version': 3,
        'assigneeUserId': 'finance-user',
        'assigneeName': '财务张三',
        'allowedActions': <String>[],
      },
    });

    expect(assigned.financeApproval?.canApprove, isTrue);
    expect(assigned.financeApproval?.canReject, isTrue);
    expect(unassigned.financeApproval?.canApprove, isFalse);
    expect(unassigned.financeApproval?.canReject, isFalse);
  });

  test(
    'repository sends submit, approve and reject with exact contracts',
    () async {
      final requests = <RequestOptions>[];
      final repository = PurchaseRepository(
        _api((request) {
          requests.add(request);
          return <String, dynamic>{
            'id': 'order-1',
            'financeApproval': <String, dynamic>{
              'status': 'PENDING',
              'attempt': 1,
              'version': 4,
              'allowedActions': <String>[],
            },
          };
        }),
        PurchaseDocType.order,
      );

      await repository.submitFinance('order-1');
      await repository.approveFinance('order-1', expectedVersion: 4);
      await repository.rejectFinance(
        'order-1',
        expectedVersion: 4,
        reason: ' 数量需要确认 ',
      );

      expect(requests[0].path, '/purchase/orders/order-1/submit-finance');
      expect(requests[0].data, isNull);
      expect(requests[1].path, '/purchase/orders/order-1/approve');
      expect(requests[1].data, {'expectedVersion': 4});
      expect(requests[2].path, '/purchase/orders/order-1/reject');
      expect(requests[2].data, {'expectedVersion': 4, 'reason': '数量需要确认'});
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
