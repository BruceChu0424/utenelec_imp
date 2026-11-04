import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';

Set<String> roots(int count) => {
  for (var i = count - 1; i >= 0; i--) 'root-${i.toString().padLeft(4, '0')}',
};
Map<String, dynamic> goods(String id) => {
  'id': id,
  'code': id,
  'name': id,
  'categoryId': 'child',
};
Map<String, dynamic> page({int page = 1, int size = 20, int total = 2}) => {
  'items': [goods('server-first'), goods('server-second')],
  'page': page,
  'size': size,
  'total': total,
  'totalPages': (total + size - 1) ~/ size,
};

void main() {
  for (final base in ['/master/goods', '/business-references/goods']) {
    test('$base small scopes preserve the GET and search contracts', () async {
      final calls = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            calls.add(r);
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: r.path.endsWith('/search-category-ids')
                    ? ['child', 'child']
                    : page(),
              ),
            );
          },
        ),
      );
      final repo = DioGoodsRepository(ApiClient(dio), queryBasePath: base);
      await repo.search(
        ' 螺丝 M3_20% ',
        page: 2,
        size: 10,
        categoryRootIds: {'root-b', 'root-a'},
        categoryId: 'child',
        includeRelated: true,
        excludeDisabled: true,
        excludeStub: true,
        sort: 'price',
        order: 'desc',
      );
      expect(calls.single.method, 'GET');
      expect(calls.single.path, base);
      expect(calls.single.queryParameters, {
        'page': 2,
        'size': 10,
        'categoryRootIds': ['root-a', 'root-b'],
        'categoryId': 'child',
        'keyword': '螺丝 M3_20%',
        'includeRelated': true,
        'excludeDisabled': true,
        'excludeStub': true,
        'sort': 'price',
        'order': 'desc',
      });
      expect(await repo.searchCategoryIds('螺丝', categoryRootIds: {'root-a'}), {
        'child',
      });
      expect(calls.last.method, 'GET');
      await repo.search('');
      expect(calls.last.queryParameters, isNot(contains('categoryRootIds')));
      expect(calls.last.queryParameters, isNot(contains('keyword')));
      expect(calls.last.queryParameters, isNot(contains('includeRelated')));
    });

    for (final count in [33, 200, 4096]) {
      test(
        '$base $count roots fetch only the requested authorized server page',
        () async {
          final calls = <RequestOptions>[];
          final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (r, h) {
                calls.add(r);
                h.resolve(
                  Response(
                    requestOptions: r,
                    statusCode: 200,
                    data: page(page: 20, size: 10, total: 1000000),
                  ),
                );
              },
            ),
          );
          final repo = DioGoodsRepository(ApiClient(dio), queryBasePath: base);
          final result = await repo.searchColumns(
            ' 螺丝 M3 ',
            categoryRootIds: roots(count),
            categoryId: 'child',
            page: 20,
            size: 10,
            includeRelated: true,
            excludeDisabled: true,
            excludeStub: true,
            filters: {
              'search.name': '螺 丝',
              'paper': kMasterFilterNullValue,
              'colorLegacyId': 'color-uuid',
              'code': 'M3',
            },
            sort: 'price',
            order: 'desc',
          );
          expect(calls, hasLength(1));
          final request = calls.single;
          expect(request.method, 'POST');
          expect(request.path, '$base/search');
          expect(request.queryParameters, isEmpty);
          final body = request.data as Map;
          expect(body['page'], 20);
          expect(body['size'], 10);
          expect(body['sort'], 'price');
          expect(body['order'], 'desc');
          final filter = body['filter'] as Map;
          expect(filter['categoryRootIds'], roots(count).toList()..sort());
          expect(filter['categoryId'], 'child');
          expect(filter['keyword'], '螺丝 M3');
          expect(filter['columnSearch'], {'name': '螺 丝'});
          expect(filter['nullFields'], ['paper']);
          expect(filter['colorRef'], 'color-uuid');
          expect(filter['excludeDisabled'], true);
          expect(filter['excludeStub'], true);
          expect(filter['includeRelated'], true);
          expect(result.items.map((item) => item.id), [
            'server-first',
            'server-second',
          ]);
          expect(result.total, 1000000);
          expect(result.totalPages, 100000);
          expect(result.page, 20);
        },
      );
    }

    test('$base locations and metadata keep large scopes in bodies', () async {
      final calls = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            calls.add(r);
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: r.path.endsWith('/search-category-ids')
                    ? ['child', 'child']
                    : r.path.endsWith('/facet-values')
                    ? <String, dynamic>{'items': <dynamic>[], 'hasMore': true}
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      final repo = DioGoodsRepository(api, queryBasePath: base);
      expect(
        await repo.searchCategoryIds(
          '螺',
          categoryRootIds: roots(65),
          includeRelated: true,
          categoryId: 'child',
        ),
        {'child'},
      );
      await repo.globalFacets(
        categoryId: 'child',
        categoryRootIds: roots(65),
        keyword: '螺',
        filters: {'search.code': 'M3'},
      );
      final values = await GoodsFacetRepository(api, queryBasePath: base)
          .values(
            field: 'colorLegacyId',
            search: '红',
            page: 3,
            categoryRootIds: roots(65),
            categoryId: 'child',
            filters: {'search.code': 'M3'},
          );
      expect(calls, hasLength(3));
      expect(calls.map((r) => r.method), everyElement('POST'));
      expect(
        calls.map(
          (r) => (((r.data as Map)['filter'] as Map)['categoryRootIds'] as List)
              .length,
        ),
        everyElement(65),
      );
      expect(
        calls.take(2).map((r) => r.queryParameters),
        everyElement(isEmpty),
      );
      expect(calls.last.queryParameters, {
        'field': 'colorRef',
        'search': '红',
        'page': 3,
        'size': 50,
      });
      expect(((calls.last.data as Map)['filter'] as Map)['columnSearch'], {
        'code': 'M3',
      });
      expect(((calls[1].data as Map)['filter'] as Map)['categoryId'], 'child');
      expect(((calls[2].data as Map)['filter'] as Map)['categoryId'], 'child');
      expect(values.hasMore, true);
    });
  }

  test(
    'bad scopes fail closed before transport, empty locator never reads the whole catalog',
    () async {
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            calls++;
            h.next(r);
          },
        ),
      );
      final repo = DioGoodsRepository(ApiClient(dio));
      expect(await repo.searchCategoryIds('螺', categoryRootIds: {}), isEmpty);
      await expectLater(
        repo.search('螺', categoryRootIds: {' '}),
        throwsArgumentError,
      );
      await expectLater(
        repo.search('螺', categoryRootIds: roots(4097)),
        throwsArgumentError,
      );
      expect(calls, 0);
    },
  );

  test(
    'a failed large-scope read never falls back to a broad or partial query',
    () async {
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            calls++;
            h.reject(
              DioException(
                requestOptions: r,
                response: Response(
                  requestOptions: r,
                  statusCode: 403,
                  data: {'code': 'FORBIDDEN', 'message': '无权读取'},
                ),
              ),
            );
          },
        ),
      );
      final repo = DioGoodsRepository(ApiClient(dio));
      await expectLater(
        repo.search('螺', categoryRootIds: roots(65)),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FORBIDDEN')),
      );
      expect(calls, 1);
    },
  );

  test(
    'scoped result and location payloads reject missing category identity',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, h) {
            h.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: r.path.endsWith('/search-category-ids')
                    ? ['']
                    : {
                        ...page(),
                        'items': [
                          {'id': 'bad', 'code': 'bad', 'name': 'bad'},
                        ],
                      },
              ),
            );
          },
        ),
      );
      final repo = DioGoodsRepository(ApiClient(dio));
      await expectLater(
        repo.search('螺', categoryRootIds: roots(65)),
        throwsStateError,
      );
      await expectLater(
        repo.searchCategoryIds('螺', categoryRootIds: roots(65)),
        throwsStateError,
      );
    },
  );
}
