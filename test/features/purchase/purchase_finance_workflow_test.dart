import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';

void main() {
  test(
    'business order detail keeps finance status but exposes no decision helper',
    () {
      final pending = PurchaseDocDetail.fromJson({
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
      expect(pending.financeApproval?.isPending, isTrue);
      expect(pending.financeApproval?.canSubmit, isFalse);
      expect(pending.financeApproval?.allowedActions, {'APPROVE', 'REJECT'});
    },
  );

  test('business repository only sends the submit-finance command', () async {
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

    expect(requests, hasLength(1));
    expect(requests.single.path, '/purchase/orders/order-1/submit-finance');
    expect(requests.single.data, isNull);
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
