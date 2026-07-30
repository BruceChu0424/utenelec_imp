import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_repository.dart';

void main() {
  test('fixed assets request and parse a real server page', () async {
    late RequestOptions captured;
    final repository = FinanceAssetRepository(
      _api((request) {
        captured = request;
        return _pageJson(page: 4, size: 100, total: 301, totalPages: 4);
      }),
    );

    final page = await repository.list(
      FinanceAssetLedger.fixedAsset,
      page: 4,
      size: 100,
    );

    expect(captured.path, '/finance/fixed-assets');
    expect(captured.queryParameters, {'page': 4, 'size': 100});
    expect(page.page, 4);
    expect(page.total, 301);
    expect(page.items.single['code'], 'FA-001');
  });

  test('deferred list and mutations use their isolated endpoint', () async {
    final requests = <RequestOptions>[];
    final repository = FinanceAssetRepository(
      _api((request) {
        requests.add(request);
        if (request.method == 'GET') return _pageJson();
        if (request.path.contains('/amortize')) return {'items': 7};
        return <String, dynamic>{};
      }),
    );

    await repository.list(
      FinanceAssetLedger.deferredExpense,
      page: 2,
      size: 40,
    );
    await repository.create(FinanceAssetLedger.deferredExpense, {
      'code': 'DA-001',
    });
    await repository.update(FinanceAssetLedger.deferredExpense, 'row-1', {
      'name': '装修费',
    });
    await repository.delete(FinanceAssetLedger.deferredExpense, 'row-1');
    final count = await repository.postPeriod(
      FinanceAssetLedger.deferredExpense,
      '2026-07',
    );

    expect(requests[0].path, '/finance/deferred-expenses');
    expect(requests[0].queryParameters, {'page': 2, 'size': 40});
    expect(requests[1].method, 'POST');
    expect(requests[1].data, {'code': 'DA-001'});
    expect(requests[2].path, '/finance/deferred-expenses/row-1');
    expect(requests[2].method, 'PUT');
    expect(requests[3].method, 'DELETE');
    expect(requests[4].path, '/finance/fa/amortize');
    expect(requests[4].queryParameters, {'period': '2026-07'});
    expect(count, 7);
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _pageJson({
  int page = 1,
  int size = 20,
  int total = 1,
  int totalPages = 1,
}) => {
  'items': [
    {'id': 'row-1', 'code': 'FA-001', 'name': '设备'},
  ],
  'page': page,
  'size': size,
  'total': total,
  'totalPages': totalPages,
};
