import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';

void main() {
  test(
    'file metadata filters stay server-owned across pages and trash scope',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://library.test/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'entries': <Object?>[],
                  'total': 123,
                  'page': 2,
                  'size': 100,
                },
              ),
            );
          },
        ),
      );
      final repository = CompanyFileRepository(ApiClient(dio));
      final result = await repository.list(
        parentId: 'directory',
        trash: true,
        page: 2,
        sort: 'size',
        direction: 'desc',
        search: '模板',
        columnFilters: {
          'search.kind': 'file',
          'search.type': 'pdf',
          'search.size': '>=9007199254740993',
          'search.updated': '2026-10',
          'search.updatedBy': '陈晓 10001',
          'search.name': '采购 模板',
        },
      );
      expect(result.total, 123);
      expect(requests.single.path, '/company-files');
      expect(requests.single.queryParameters, containsPair('page', 2));
      expect(requests.single.queryParameters, containsPair('trash', true));
      expect(
        requests.single.queryParameters,
        containsPair('search.size', '>=9007199254740993'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.updatedBy', '陈晓 10001'),
      );
      expect(requests.single.queryParameters, containsPair('search', '模板'));
      expect(requests.single.queryParameters, containsPair('sort', 'size'));
    },
  );
}
