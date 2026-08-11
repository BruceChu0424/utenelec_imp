// 客户分类仓库：树/子树/详情/CRUD。
//
// 仿 DioMouldCategoryRepository，端点走 ApiEndpoints.clientCategories 系列。
// 复用 ProductCategoryNode / ProductCategoryDetail 模型——分类节点形状（id/code/
// name/level/children/parentId/sortOrder/legacyId）与货品/模具分类完全一致，无需另建一套。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/product_category_node.dart';

abstract interface class ClientCategoryRepository {
  Future<List<ProductCategoryNode>> tree();
  Future<List<ProductCategoryNode>> subtree(String id);
  Future<ProductCategoryDetail> detail(String id);
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input);
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  );
  Future<void> delete(String id);
}

class DioClientCategoryRepository implements ClientCategoryRepository {
  DioClientCategoryRepository(this.api);
  final ApiClient api;

  @override
  Future<List<ProductCategoryNode>> tree() async {
    final list = await api.getList(ApiEndpoints.clientCategoryTree);
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<List<ProductCategoryNode>> subtree(String id) async {
    final list = await api.getList(ApiEndpoints.clientCategorySubtree(id));
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.clientCategory(id));
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) async {
    final json = await api.post(
      ApiEndpoints.clientCategories,
      body: input.toJson(),
    );
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) async {
    final json = await api.put(
      ApiEndpoints.clientCategory(id),
      body: input.toJson(),
    );
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.clientCategory(id));
}

final clientCategoryRepositoryProvider = Provider<ClientCategoryRepository>(
  (ref) => DioClientCategoryRepository(ref.watch(apiClientProvider)),
);
