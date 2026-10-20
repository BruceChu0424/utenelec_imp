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
