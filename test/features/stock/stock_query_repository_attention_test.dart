import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';

void main() {
  test('相关模式与完整筛选同源进入库存列表和分类定位', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (r, h) {
          requests.add(r);
          h.resolve(
            Response(
              requestOptions: r,
              statusCode: 200,
              data: r.path.endsWith('search-category-ids')
                  ? ['category']
                  : {
                      'items': [
                        {
                          'goodsId': 'g',
                          'qty': 1,
                          'searchRank': 20,
                          'searchMatchKind': 'PRIMARY',
                        },
                      ],
                      'page': 1,
                      'size': 20,
                      'total': 1,
                      'totalPages': 1,
                    },
            ),
          );
        },
      ),
    );
    final repo = StockQueryRepository(ApiClient(dio));
    final rows = await repo.instantInventory(
      keyword: '螺丝',
      categoryId: 'category',
      warehouseId: 'warehouse',
      includeDefective: true,
      includeLineSide: true,
      includeRelated: true,
      owningWarehouseNull: true,
      colorId: 'red',
      series: 'M3',
      unitId: 'unit',
      attention: 'NEGATIVE_BALANCE',
    );
    await repo.instantInventorySearchCategoryIds(
      '螺丝',
      categoryRootIds: {'root'},
      categoryId: 'category',
      warehouseId: 'warehouse',
      includeDefective: true,
      includeLineSide: true,
      includeRelated: true,
      owningWarehouseNull: true,
      colorId: 'red',
      series: 'M3',
      unitId: 'unit',
      attention: 'NEGATIVE_BALANCE',
    );
    for (final key in [
      'keyword',
      'categoryId',
      'warehouseId',
      'includeDefective',
      'includeLineSide',
      'includeRelated',
      'owningWarehouseNull',
      'colorId',
      'series',
      'unitId',
      'attention',
    ]) {
      expect(
        requests.last.queryParameters[key],
        requests.first.queryParameters[key],
        reason: key,
      );
    }
    expect(rows.items.single.searchRank, 20);
    expect(rows.items.single.isRelatedSearchMatch, isFalse);
    expect(requests.last.path, '/stock/instant-inventory/search-category-ids');
  });
  test(
    'attention drilldown forwards the whole inventory scope and page',
    () async {
      late RequestOptions captured;
      final dio = Dio();
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
                  'page': 3,
                  'size': 12,
                  'total': 31,
                  'totalPages': 3,
                },
              ),
            );
          },
        ),
      );

      final result = await StockQueryRepository(ApiClient(dio))
          .instantInventory(
            page: 3,
            size: 12,
            categoryId: 'category',
            warehouseId: 'warehouse',
            includeDefective: true,
            includeLineSide: true,
            keyword: '螺丝',
            includeRelated: true,
            owningWarehouse: 'owning',
            owningWarehouseNull: true,
            colorId: 'color',
            series: '五金',
            unitId: 'unit',
            attention: 'NEGATIVE_BALANCE',
            sort: 'negativeBalanceCount',
            order: 'desc',
          );

      expect(captured.method, 'GET');
      expect(captured.path, '/stock/instant-inventory/attention');
      expect(captured.queryParameters, {
        'page': 3,
        'size': 12,
        'categoryId': 'category',
        'warehouseId': 'warehouse',
        'includeDefective': true,
        'includeLineSide': true,
        'keyword': '螺丝',
        'includeRelated': true,
        'owningWarehouse': 'owning',
        'owningWarehouseNull': true,
        'colorId': 'color',
        'series': '五金',
        'unitId': 'unit',
        'attention': 'NEGATIVE_BALANCE',
        'sort': 'negativeBalanceCount',
        'order': 'desc',
      });
      expect(result.total, 31);
      expect(result.items, isEmpty);
    },
  );

  test(
    'old server attention 404 fails without a whole-inventory fallback',
    () async {
      final paths = <String>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            paths.add(request.path);
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 404,
                  data: const {'code': 'NOT_FOUND', 'message': '资源不存在'},
                ),
              ),
            );
          },
        ),
      );

      await expectLater(
        StockQueryRepository(
          ApiClient(dio),
        ).instantInventory(attention: 'NEGATIVE_BALANCE'),
        throwsA(isA<ApiException>()),
      );
      expect(paths, ['/stock/instant-inventory/attention']);
    },
  );

  test('ordinary inventory retains its endpoint and omits attention', () async {
    late RequestOptions captured;
    final dio = Dio();
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
    await StockQueryRepository(ApiClient(dio)).instantInventory();
    expect(captured.path, '/stock/instant-inventory');
    expect(captured.queryParameters, isNot(contains('attention')));
  });
}
