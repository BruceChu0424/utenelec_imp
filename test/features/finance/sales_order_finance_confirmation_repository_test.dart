import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';

void main() {
  test(
    'single and batch finance decisions retain reviewed version and lease UUID together',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioSalesOrderFinanceConfirmationRepository(
        _api((request) {
          requests.add(request);
          return <String, Object?>{};
        }),
      );
      await repository.confirm(
        'order-a',
        expectedRevision: 7,
        expectedClaimId: 'claim-a',
      );
      await repository.reject(
        'order-a',
        reason: ' 修改待核对 ',
        expectedRevision: 7,
        expectedClaimId: 'claim-a',
      );
      await repository.confirmBatch(
        ['order-b', 'order-a'],
        expectedRevisions: {'order-a': 7, 'order-b': 9},
        expectedClaimIds: {'order-a': 'claim-a', 'order-b': 'claim-b'},
      );
      expect(requests[0].data, {
        'expectedRevision': 7,
        'expectedClaimId': 'claim-a',
      });
      expect(requests[1].data, {
        'reason': '修改待核对',
        'expectedRevision': 7,
        'expectedClaimId': 'claim-a',
      });
      expect(requests[2].data, {
        'orderIds': ['order-a', 'order-b'],
        'expectedRevisions': {'order-a': 7, 'order-b': 9},
        'expectedClaimIds': {'order-a': 'claim-a', 'order-b': 'claim-b'},
      });
    },
  );
  test(
    'pending sends trimmed server-side keyword with rejected filter',
    () async {
      late RequestOptions captured;
      final repository = DioSalesOrderFinanceConfirmationRepository(
        _api((request) {
          captured = request;
          return {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 0,
          };
        }),
      );

      await repository.pending(page: 2, rejected: false, keyword: ' 远硕 ');

      expect(captured.path, '/sales/orders/finance-confirmation/pending');
      expect(captured.queryParameters, {
        'page': 2,
        'size': 20,
        'rejected': false,
        'keyword': '远硕',
      });
    },
  );

  test(
    'confirmBatch sends one POST with sorted unique ids and trimmed remark',
    () async {
      final requests = <RequestOptions>[];
      final repository = DioSalesOrderFinanceConfirmationRepository(
        _api((request) {
          requests.add(request);
          return <String, Object?>{};
        }),
      );

      await repository.confirmBatch([
        'order-b',
        ' order-a ',
        'order-b',
        '',
      ], remark: ' 已逐笔核对 ');

      expect(requests, hasLength(1));
      expect(requests.single.path, '/sales/orders/finance-confirmation/batch');
      expect(requests.single.method, 'POST');
      expect(requests.single.data, {
        'orderIds': ['order-a', 'order-b'],
        'remark': '已逐笔核对',
      });
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
