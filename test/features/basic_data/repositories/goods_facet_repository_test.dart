import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';

class _FakeGoodsRepository extends Fake implements GoodsRepository {}

void main() {
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
