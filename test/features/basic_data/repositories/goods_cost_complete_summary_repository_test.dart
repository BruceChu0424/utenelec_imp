import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';
import 'package:uten_imp/shared/search/table_column_query.dart';

Map<String, dynamic> _page(
  RequestOptions request, {
  String revision = 'query-v1',
}) {
  final page = request.queryParameters['page'] as int;
  final size = request.queryParameters['size'] as int;
  final templates = request.path.contains('/templates/');
  final start = (page - 1) * size;
  return {
    'items': [
      for (var index = start; index < math.min(start + size, 1001); index++)
        {
          'id': '${templates ? 'template' : 'cost'}-$index',
          'version': 3,
          'name': '中文重复名称',
          'knownTotal': '90071992547409.0001',
          'versionExact': '9007199254740993',
          'currencyId': 'original-currency',
          'unitName': '原单位',
        },
    ],
    'page': page,
    'size': size,
    'total': 1001,
    'totalPages': (1001 / size).ceil(),
    'scope': 'all',
    'readScopeVersion': 'actor-realm-proof',
    'readSnapshotRevision': revision,
    'readDataVersion': 'facts-v1',
    'facets': {
      'currencyName': [
        {'value': 'original-currency', 'label': '原币', 'count': 1001},
      ],
    },
    'facetNullCounts': {'name': 0},
  };
}

DioGoodsCostRepository _repository(
  List<RequestOptions> requests,
  Map<String, dynamic> Function(RequestOptions request) response,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: response(request),
          ),
        );
      },
    ),
  );
  return DioGoodsCostRepository(ApiClient(dio));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'choosing the latest default reads one candidate while the comparison list still reads all 1001',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, _page);
      final latest = await repository.latestVersionForDefaultRead(
        'goods',
        isCurrent: () => true,
      );
      expect(latest!['id'], 'cost-0');
      expect(requests, hasLength(1));
      expect(requests.single.path, '/master/goods/cost-sheets/versions');
      expect(requests.single.queryParameters, containsPair('size', 1));
      final choices = await repository.completeVersionListForRead(
        'goods',
        isCurrent: () => true,
      );
      expect(choices, hasLength(1001));
      expect(choices.last['id'], 'cost-1000');
      expect(requests, hasLength(3));
    },
  );

  test(
    'complete version list keeps latest ordering and the 1001st exact summary without the old 250 prefix route',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, _page);
      final rows = await repository.completeVersionListForRead(
        'goods',
        isCurrent: () => true,
      );
      expect(rows, hasLength(1001));
      expect(rows.first['id'], 'cost-0');
      expect(rows.last['id'], 'cost-1000');
      expect(rows.last['knownTotal'], '90071992547409.0001');
      expect(rows.last['versionExact'], '9007199254740993');
      expect(requests, hasLength(2));
      expect(
        requests.every(
          (r) => r.path == '/master/goods/cost-sheets/versions/summary',
        ),
        isTrue,
      );
      expect(requests.first.queryParameters, containsPair('sort', 'updatedAt'));
      expect(requests.first.queryParameters, containsPair('order', 'desc'));
      expect(
        requests.first.queryParameters.containsKey('readSnapshotRevision'),
        isFalse,
      );
      expect(
        requests.last.queryParameters,
        containsPair('readSnapshotRevision', 'query-v1'),
      );
    },
  );

  test(
    'complete filtered version table retains first full-scope facets and exact query through every batch',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, _page);
      final result = await repository.completeVersionsForRead(
        'goods',
        isCurrent: () => true,
        columnQuery: const TableColumnQuery(
          searches: {
            'search.name': '中文_%',
            'status': 'CONFIRMED',
            'currencyName': 'original-currency',
          },
          sort: 'updatedAt',
          ascending: false,
        ),
      );
      expect(result.items, hasLength(1001));
      expect(result.total, 1001);
      expect(result.totalPages, 1);
      expect(result.facets['currencyName']!.single.count, 1001);
      expect(result.facetNullCounts['name'], 0);
      expect(result.readScopeVersion, 'actor-realm-proof');
      for (final request in requests) {
        expect(request.queryParameters, containsPair('search.name', '中文_%'));
        expect(request.queryParameters, containsPair('status', 'CONFIRMED'));
        expect(
          request.queryParameters,
          containsPair('currencyId', 'original-currency'),
        );
      }
    },
  );

  test(
    'all 1001 lean templates load without detail fanout and only the explicitly selected template detail is read',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(requests, (request) {
        if (request.path.endsWith('/templates/template-1000')) {
          return {
            'id': 'template-1000',
            'version': 3,
            'input': {
              'name': '中文重复名称',
              'priceColumns': [
                {
                  'key': 'exact-column',
                  'name': '原费用列',
                  'rate': '0.00000000000000000001',
                },
              ],
            },
          };
        }
        return _page(request);
      });
      final rows = await repository.completeTemplatesForRead(
        'goods',
        'client',
        isCurrent: () => true,
      );
      expect(rows, hasLength(1001));
      expect(rows.last['id'], 'template-1000');
      expect(rows.every((r) => !r.containsKey('input')), isTrue);
      expect(requests, hasLength(2));
      expect(
        requests.every((r) => r.path.endsWith('/templates/summary')),
        isTrue,
      );
      final detail = await repository.selectedTemplateForRead(
        rows.last,
        'goods',
        'client',
        isCurrent: () => true,
      );
      expect(requests, hasLength(3));
      expect(
        requests.last.path,
        '/master/goods/cost-sheets/templates/template-1000',
      );
      expect(requests.last.queryParameters, {
        'goodsId': 'goods',
        'clientId': 'client',
      });
      final input = detail['input'] as Map<String, dynamic>;
      final columns = input['priceColumns'] as List<dynamic>;
      final column = columns.single as Map<String, dynamic>;
      expect(column['rate'], '0.00000000000000000001');
    },
  );

  test(
    'same-count changed tail revision fails the entire read and never returns the accepted prefix',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(
        requests,
        (request) => _page(
          request,
          revision: request.queryParameters['page'] == 1
              ? 'query-v1'
              : 'query-v2',
        ),
      );
      await expectLater(
        repository.completeVersionListForRead('goods', isCurrent: () => true),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
        ),
      );
      expect(requests, hasLength(2));
    },
  );

  test(
    'legacy prefix-only response is an explicit unsupported protocol error',
    () async {
      final requests = <RequestOptions>[];
      final repository = _repository(
        requests,
        (_) => {
          'items': [
            {'id': 'only-first'},
          ],
        },
      );
      await expectLater(
        repository.completeTemplatesForRead(
          'goods',
          null,
          isCurrent: () => true,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INCOMPLETE_READ_PROTOCOL',
          ),
        ),
      );
      expect(requests, hasLength(1));
    },
  );
}
