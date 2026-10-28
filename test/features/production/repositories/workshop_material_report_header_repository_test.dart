import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_report_repository.dart';
import 'package:uten_imp/shared/search/table_column_query.dart';

void main() {
  test(
    'workshop ledger transport retains selected bin/period, exact header grammar, type and server order',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': <Object>[],
                  'page': 2,
                  'size': 20,
                  'total': 21,
                  'totalPages': 2,
                },
              ),
            );
          },
        ),
      );
      final result = await DioWorkshopMaterialReportRepository(ApiClient(dio))
          .ledger(
            'bin-authorized',
            from: '2026-10-01',
            to: '2026-10-31',
            page: 2,
            size: 20,
            columnQuery: const TableColumnQuery(
              searches: {
                'search.material': '颗粒_%',
                'search.date': '2026-10-01..2026-10-31',
                'search.qty': '>=90071992547409.0001',
                'kind': '已审核账面修正',
              },
              sort: 'qty',
              ascending: false,
            ),
          );
      expect(
        requests.single.queryParameters,
        containsPair('binId', 'bin-authorized'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('from', '2026-10-01'),
      );
      expect(requests.single.queryParameters, containsPair('to', '2026-10-31'));
      expect(
        requests.single.queryParameters,
        containsPair('search.qty', '>=90071992547409.0001'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.date', '2026-10-01..2026-10-31'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.material', '颗粒_%'),
      );
      expect(requests.single.queryParameters, containsPair('kind', '已审核账面修正'));
      expect(requests.single.queryParameters, containsPair('sort', 'qty'));
      expect(requests.single.queryParameters, containsPair('order', 'desc'));
      expect(result.page, 2);
      expect(result.total, 21);
    },
  );
}
