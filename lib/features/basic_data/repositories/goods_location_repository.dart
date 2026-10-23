import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'goods_repository.dart';

class GoodsLocationRepository {
  GoodsLocationRepository(this.api);
  final ApiClient api;

  Future<int?> locate({
    required String id,
    String? categoryId,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    int size = 20,
    bool excludeDisabled = false,
    bool includeRelated = false,
  }) async {
    final data = await api.get(
      '/master/goods/locate',
      query: {
        'id': id,
        'categoryId': ?categoryId,
        'keyword': ?keyword,
        'size': size,
        'sort': ?sort,
        'order': ?order,
        'excludeDisabled': excludeDisabled,
        'excludeStub': true,
        'includeRelated': includeRelated,
        ...goodsFilterQueryParams(filters),
      },
    );
    return data['found'] == true ? (data['page'] as num).toInt() : null;
  }
}

final goodsLocationRepositoryProvider = Provider<GoodsLocationRepository>(
  (ref) => GoodsLocationRepository(ref.watch(apiClientProvider)),
);
