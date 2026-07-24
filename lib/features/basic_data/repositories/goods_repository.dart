// 货品主档仓库：分类下分页列表 + 详情。
//
// 仿 DioProductCategoryRepository，端点走 ApiEndpoints.goods 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/goods_node.dart';

abstract interface class GoodsRepository {
  /// 某分类下的货品分页（page 从 1 起，与后端 Pageables 约定一致）。
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  });

  Future<GoodsDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioGoodsRepository implements GoodsRepository {
  DioGoodsRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<GoodsListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.goods,
      query: {
        'categoryId': categoryId,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, GoodsListItem.fromJson);
  }

  @override
  Future<GoodsDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.good(id));
    return GoodsDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.goods, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.good(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.good(id));
  }
}

final goodsRepositoryProvider = Provider<GoodsRepository>(
  (ref) => DioGoodsRepository(ref.watch(apiClientProvider)),
);
