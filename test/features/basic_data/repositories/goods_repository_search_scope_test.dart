import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';

void main() {
  test(
    'global goods search forwards deterministic category root scope',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': <dynamic>[],
                  'page': 2,
                  'size': 20,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );

      final repository = DioGoodsRepository(ApiClient(dio));
      await repository.search(
        'G-100',
        page: 2,
        categoryRootIds: const {'root-b', 'root-a'},
        excludeDisabled: true,
        excludeStub: true,
      );

      expect(captured.method, 'GET');
      expect(captured.path, '/master/goods');
      expect(captured.queryParameters, {
        'page': 2,
        'size': 20,
        'categoryRootIds': ['root-a', 'root-b'],
        'keyword': 'G-100',
        'excludeDisabled': true,
        'excludeStub': true,
      });
    },
  );

  test(
    'ordinary unscoped search does not send an empty root parameter',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': <dynamic>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );

      await DioGoodsRepository(ApiClient(dio)).search('bolt');

      expect(captured.queryParameters, isNot(contains('categoryRootIds')));
    },
  );

  test(
    'lightweight location search forwards the same fail-closed scope',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const ['category-a', 'category-b', 'category-a'],
              ),
            );
          },
        ),
      );

      final ids = await DioGoodsRepository(ApiClient(dio)).searchCategoryIds(
        'G-100',
        categoryRootIds: const {'root-b', 'root-a'},
        excludeDisabled: true,
        excludeStub: true,
      );

      expect(ids, {'category-a', 'category-b'});
      expect(captured.method, 'GET');
      expect(captured.path, '/master/goods/search-category-ids');
      expect(captured.queryParameters, {
        'categoryRootIds': ['root-a', 'root-b'],
        'keyword': 'G-100',
        'excludeDisabled': true,
        'excludeStub': true,
      });
    },
  );

  test('oversized location scope is split into fail-closed batches', () async {
    final capturedScopes = <List<String>>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final scope = (request.queryParameters['categoryRootIds'] as List)
              .cast<String>();
          capturedScopes.add([...scope]);
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: [scope.first, 'shared-category'],
            ),
          );
        },
      ),
    );
    final roots = {
      for (var i = 0; i < 65; i++) 'root-${i.toString().padLeft(2, '0')}',
    };

    final result = await DioGoodsRepository(ApiClient(dio)).searchCategoryIds(
      'G-',
      categoryRootIds: roots,
      excludeDisabled: true,
      excludeStub: true,
    );

    expect(capturedScopes.map((scope) => scope.length), [32, 32, 1]);
    expect(
      capturedScopes.expand((scope) => scope).toList(),
      roots.toList()..sort(),
    );
    expect(result, {'root-00', 'root-32', 'root-64', 'shared-category'});
  });

  test(
    'oversized goods scope merges all batch pages, de-duplicates, then paginates',
    () async {
      final calls = <({List<String> roots, int page, int size})>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final roots = (request.queryParameters['categoryRootIds'] as List)
                .cast<String>();
            final page = request.queryParameters['page'] as int;
            final size = request.queryParameters['size'] as int;
            calls.add((roots: [...roots], page: page, size: size));

            final List<Map<String, dynamic>> items;
            final int totalPages;
            if (roots.first == 'root-00') {
              items = page == 1
                  ? [_goodsJson('goods-a'), _goodsJson('goods-b')]
                  : [_goodsJson('goods-b'), _goodsJson('goods-c')];
              totalPages = 2;
            } else if (roots.first == 'root-32') {
              items = [_goodsJson('goods-c'), _goodsJson('goods-d')];
              totalPages = 1;
            } else {
              items = [_goodsJson('goods-e')];
              totalPages = 1;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': items,
                  'page': page,
                  'size': size,
                  'total': items.length,
                  'totalPages': totalPages,
                },
              ),
            );
          },
        ),
      );
      final roots = {
        for (var i = 0; i < 65; i++) 'root-${i.toString().padLeft(2, '0')}',
      };

      final result = await DioGoodsRepository(ApiClient(dio)).search(
        'G-',
        page: 2,
        size: 2,
        categoryRootIds: roots,
        excludeDisabled: true,
        excludeStub: true,
      );

      expect(calls.map((call) => call.roots.length), [32, 32, 32, 1]);
      expect(calls.every((call) => call.roots.length <= 32), isTrue);
      expect(calls.every((call) => call.size == 100), isTrue);
      expect(calls.map((call) => (call.roots.first, call.page)), [
        ('root-00', 1),
        ('root-00', 2),
        ('root-32', 1),
        ('root-64', 1),
      ]);
      expect(result.items.map((item) => item.id), ['goods-c', 'goods-d']);
      expect(result.page, 2);
      expect(result.size, 2);
      expect(result.total, 5);
      expect(result.totalPages, 3);
    },
  );

  test(
    'empty locator scope returns zero matches without unscoped request',
    () async {
      var requestCount = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requestCount++;
            handler.next(request);
          },
        ),
      );

      final result = await DioGoodsRepository(
        ApiClient(dio),
      ).searchCategoryIds('G-', categoryRootIds: const {});

      expect(result, isEmpty);
      expect(requestCount, 0);
    },
  );
}

Map<String, dynamic> _goodsJson(String id) => {
  'id': id,
  'code': id,
  'name': id,
  'categoryId': 'category-$id',
};
