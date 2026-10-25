import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/shared/documents/imported_document_policy.dart';

void main() {
  test('progress and facets explicitly default to CURRENT', () async {
    final requests = <RequestOptions>[];
    final repo = _repository(requests);
    await repo.progress(stage: 'DRAFT');
    await repo.progressFacets(stage: 'DRAFT');
    expect(requests.map((r) => r.path), [
      '/sales/orders/progress',
      '/sales/orders/progress/facets',
    ]);
    for (final request in requests) {
      expect(request.queryParameters['originScope'], 'CURRENT');
      expect(request.queryParameters['stage'], 'DRAFT');
    }
  });

  test(
    'archive list and facets carry ALL with the same date/search scope',
    () async {
      final requests = <RequestOptions>[];
      final repo = _repository(requests);
      await repo.progress(
        origin: BusinessDocumentOrigin.all,
        keyword: ' SO-OLD ',
        dateFrom: '2018-01-01',
        dateTo: '2026-10-25',
      );
      await repo.progressFacets(
        origin: BusinessDocumentOrigin.all,
        keyword: ' SO-OLD ',
        dateFrom: '2018-01-01',
        dateTo: '2026-10-25',
      );
      for (final request in requests) {
        expect(request.queryParameters['originScope'], 'ALL');
        expect(request.queryParameters.containsKey('stage'), isFalse);
        expect(request.queryParameters['keyword'], 'SO-OLD');
        expect(request.queryParameters['dateFrom'], '2018-01-01');
        expect(request.queryParameters['dateTo'], '2026-10-25');
      }
    },
  );
}

SalesRepository _repository(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: request.path.endsWith('/facets')
                ? {'billNo': <dynamic>[]}
                : {'items': <dynamic>[], 'total': 0, 'page': 1, 'size': 20},
          ),
        );
      },
    ),
  );
  return SalesRepository(ApiClient(dio), SalesDocType.order);
}
