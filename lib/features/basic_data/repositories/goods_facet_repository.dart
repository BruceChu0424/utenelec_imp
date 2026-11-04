import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/master_facet.dart';
import 'goods_repository.dart';

/// Searches one header's distinct values before pagination, never the current
/// goods page or the preview buckets returned by /facets.
class GoodsFacetRepository {
  GoodsFacetRepository(this.api, {this.queryBasePath = ApiEndpoints.goods});
  final ApiClient api;
  final String queryBasePath;

  Future<MasterFacetPage> values({
    required String field,
    required String search,
    int page = 1,
    String? categoryId,
    Set<String> categoryRootIds = const {},
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    final roots = goodsSearchCategoryRoots(categoryRootIds);
    final filter = <String, dynamic>{
      'categoryId': ?categoryId,
      if (roots.isNotEmpty) 'categoryRootIds': roots,
      if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
      if (includeRelated && keyword?.trim().isNotEmpty == true)
        'includeRelated': true,
      if (excludeDisabled) 'excludeDisabled': true,
      if (excludeStub) 'excludeStub': true,
      ...goodsFilterQueryParams(filters),
    };
    final candidates = <String, dynamic>{
      'field': goodsFacetField(field),
      'search': search.trim(),
      'page': page,
      'size': 50,
    };
    final json = roots.length > 32
        ? await api.post(
            '$queryBasePath/facet-values',
            body: goodsSearchReadBody(filter),
            query: candidates,
          )
        : await api.get(
            '$queryBasePath/facet-values',
            query: {...filter, ...candidates},
          );
    return MasterFacetPage.fromJson(json);
  }
}

final goodsFacetRepositoryProvider = Provider<GoodsFacetRepository?>((ref) {
  final repository = ref.watch(goodsRepositoryProvider);
  return repository is DioGoodsRepository
      ? GoodsFacetRepository(repository.api)
      : null;
});
