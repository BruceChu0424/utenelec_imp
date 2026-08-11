// 模具分类仓库：树/子树/详情/CRUD。
//
// 仿 DioProductCategoryRepository，端点走 ApiEndpoints.mouldCategories 系列。
// 复用 ProductCategoryNode / ProductCategoryDetail 模型——分类节点形状（id/code/
// name/level/children/parentId/sortOrder/legacyId）与货品分类完全一致，无需另建一套。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/mould_node.dart';
import '../models/product_category_node.dart';

abstract interface class MouldCategoryRepository {
  Future<List<ProductCategoryNode>> tree();
  Future<List<ProductCategoryNode>> subtree(String id);
  Future<ProductCategoryDetail> detail(String id);
  Future<MouldCategoryDeletePreview> deletePreview(String id);
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input);
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  );
  Future<void> delete(String id);
}

class DioMouldCategoryRepository implements MouldCategoryRepository {
  DioMouldCategoryRepository(this.api);
  final ApiClient api;

  @override
  Future<List<ProductCategoryNode>> tree() async {
    final list = await api.getList(ApiEndpoints.mouldCategoryTree);
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<List<ProductCategoryNode>> subtree(String id) async {
    final list = await api.getList(ApiEndpoints.mouldCategorySubtree(id));
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.mouldCategory(id));
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<MouldCategoryDeletePreview> deletePreview(String id) async {
    final json = await api.get(ApiEndpoints.mouldCategoryDeletePreview(id));
    return MouldCategoryDeletePreview.fromJson(json);
  }

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) async {
    final json = await api.post(
      ApiEndpoints.mouldCategories,
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
      ApiEndpoints.mouldCategory(id),
      body: input.toJson(),
    );
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(ApiEndpoints.mouldCategory(id));
}

final mouldCategoryRepositoryProvider = Provider<MouldCategoryRepository>(
  (ref) => DioMouldCategoryRepository(ref.watch(apiClientProvider)),
);
