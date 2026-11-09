import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';

class _FakeGoodsRepository extends Fake implements GoodsRepository {}

void main() {
  test(
    'reference buckets retain saved table keys and replace legacy-only null counts',
    () {
      final facets = GoodsFacets.fromJson({
        'colorLegacyId': [
          {'value': '99', 'count': 1, 'label': '旧快照'},
        ],
        'unitLegacyId': <Map<String, dynamic>>[],
        'colorRef': [
          {'value': 'color-uuid', 'count': 3, 'label': '现代黑色'},
        ],
        'unitRef': [
          {'value': 'unit-uuid', 'count': 3, 'label': '现代个'},
        ],
        'nullCounts': {
          'colorLegacyId': 3,
          'unitLegacyId': 3,
          'colorRef': 0,
          'unitRef': 1,
        },
      });
      expect(facets.fields['colorLegacyId']!.single.value, 'color-uuid');
      expect(facets.fields['unitLegacyId']!.single.display, '现代个');
      expect(facets.nullCounts['colorLegacyId'], 0);
      expect(facets.nullCounts['unitLegacyId'], 1);
    },
  );
  test(
    'UUID candidates and selected filters use reference API without changing keyword columns',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: options.path.endsWith('facet-values')
                    ? {
                        'items': [
                          {'value': 'unit-uuid', 'count': 2, 'label': '现代个'},
                        ],
                        'hasMore': false,
                      }
                    : {
                        'items': <Map<String, dynamic>>[],
                        'total': 0,
                        'page': 1,
                        'size': 20,
                        'totalPages': 1,
                      },
              ),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      await GoodsFacetRepository(api).values(
        field: 'unitLegacyId',
        search: '现代',
        filters: {
          'colorLegacyId': 'color-uuid',
          'unitLegacyId': 'unit-uuid',
          'search.colorLegacyId': '黑色',
        },
      );
      expect(requests.last.queryParameters['field'], 'unitRef');
      expect(requests.last.queryParameters['colorRef'], 'color-uuid');
      expect(requests.last.queryParameters['unitRef'], 'unit-uuid');
      expect(requests.last.queryParameters['search.colorLegacyId'], '黑色');
      expect(requests.last.queryParameters.containsKey('unitLegacyId'), false);
      await DioGoodsRepository(api).list(
        null,
        filters: {
          'colorLegacyId': 'color-uuid',
          'unitLegacyId': kMasterFilterNullValue,
        },
      );
      expect(requests.last.queryParameters['colorRef'], 'color-uuid');
      expect(requests.last.queryParameters['nullFields'], ['unitRef']);
    },
  );
  test('fake or legacy repository exposes no remote candidate capability', () {
    final container = ProviderContainer(
      overrides: [
        goodsRepositoryProvider.overrideWithValue(_FakeGoodsRepository()),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(goodsFacetRepositoryProvider), isNull);
  });
  test(
    'assembly buckets keep server labels and travel as the hasBom list, facet and candidate parameter',
    () async {
      final facets = GoodsFacets.fromJson({
        'hasBom': [
          {'value': 'true', 'count': 5, 'label': '有组装信息'},
          {'value': 'false', 'count': 0, 'label': '无组装信息'},
        ],
        'nullCounts': {'series': 1},
      });
      expect(facets.fields['hasBom']!.map((bucket) => bucket.value), [
        'true',
        'false',
      ]);
      expect(facets.fields['hasBom']!.map((bucket) => bucket.display), [
        '有组装信息',
        '无组装信息',
      ]);
      expect(facets.fields['hasBom']!.map((bucket) => bucket.count), [5, 0]);
      expect(facets.nullCounts.containsKey('hasBom'), isFalse);
      // Older servers omit the key; the header simply has no candidates.
      expect(GoodsFacets.fromJson({}).fields['hasBom'], isEmpty);

      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: options.path.endsWith('facet-values')
                    ? {
                        'items': [
                          {'value': 'true', 'count': 5, 'label': '有组装信息'},
                        ],
                        'hasMore': false,
                      }
                    : options.path.endsWith('facets')
                    ? <String, dynamic>{}
                    : {
                        'items': <Map<String, dynamic>>[],
                        'total': 0,
                        'page': 1,
                        'size': 20,
                        'totalPages': 1,
                      },
              ),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      final page = await GoodsFacetRepository(api).values(
        field: 'hasBom',
        search: '有',
        categoryId: 'finished',
        filters: {'series': 'S1', 'hasBom': 'false'},
      );
      expect(requests.last.path, endsWith('/master/goods/facet-values'));
      expect(requests.last.queryParameters['field'], 'hasBom');
      expect(requests.last.queryParameters['search'], '有');
      expect(requests.last.queryParameters['series'], 'S1');
      expect(requests.last.queryParameters['hasBom'], 'false');
      expect(page.items.single.display, '有组装信息');

      await DioGoodsRepository(
        api,
      ).list('finished', filters: {'hasBom': 'true'});
      expect(requests.last.path, endsWith('/master/goods'));
      expect(requests.last.queryParameters['hasBom'], 'true');
      expect(
        requests.last.queryParameters.keys.where(
          (key) => key.startsWith('search.'),
        ),
        isEmpty,
      );
      await DioGoodsRepository(
        api,
      ).facets('finished', filters: {'hasBom': 'false'});
      expect(requests.last.path, endsWith('/master/goods/facets'));
      expect(requests.last.queryParameters['hasBom'], 'false');
    },
  );
  test(
    'candidate search carries authorized list scope and a separate candidate keyword',
    () async {
      late RequestOptions request;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'items': [
                    {'value': 'V4一开', 'count': 2, 'label': 'V4一开'},
                  ],
                  'hasMore': true,
                },
              ),
            );
          },
        ),
      );
      final page = await GoodsFacetRepository(ApiClient(dio)).values(
        field: 'name',
        search: ' v4 ',
        page: 2,
        categoryId: 'selected',
        keyword: '开关',
        includeRelated: true,
        excludeStub: true,
        filters: {'model': '80-B', 'paper': kMasterFilterNullValue},
      );
      expect(request.path, endsWith('/master/goods/facet-values'));
      expect(request.queryParameters, containsPair('search', 'v4'));
      expect(request.queryParameters, containsPair('keyword', '开关'));
      expect(request.queryParameters, containsPair('categoryId', 'selected'));
      expect(request.queryParameters, containsPair('model', '80-B'));
      expect(request.queryParameters, containsPair('nullFields', ['paper']));
      expect(request.queryParameters, containsPair('page', 2));
      expect(page.items.single.value, 'V4一开');
      expect(page.hasMore, true);
    },
  );
}
