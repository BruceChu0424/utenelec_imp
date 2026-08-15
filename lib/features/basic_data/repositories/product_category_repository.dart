// 货品分类仓库：树/子树/详情/CRUD。
//
// 仿 DioDepartmentRepository，端点走 ApiEndpoints.materialCategories 系列。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/product_category_node.dart';

abstract interface class ProductCategoryRepository {
  Future<List<ProductCategoryNode>> tree();
  Future<List<ProductCategoryNode>> subtree(String id);
  Future<ProductCategoryDetail> detail(String id);
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  });
  Future<ProductCategoryDeletePreview> deletePreview(String id);
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input);
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  );
  Future<void> delete(String id);
}

class DioProductCategoryRepository implements ProductCategoryRepository {
  DioProductCategoryRepository(this.api);
  final ApiClient api;

  @override
  Future<List<ProductCategoryNode>> tree() async {
    final list = await api.getList(ApiEndpoints.materialCategoryTree);
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<List<ProductCategoryNode>> subtree(String id) async {
    final list = await api.getList(ApiEndpoints.materialCategorySubtree(id));
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.materialCategory(id));
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) async {
    final json = await api.get(
      ApiEndpoints.materialCategoryPrefixPreview(id),
      query: {'prefix': prefix, 'parentId': ?parentId},
    );
    return CategoryPrefixPreview.fromJson(json);
  }

  @override
  Future<ProductCategoryDeletePreview> deletePreview(String id) async {
    final json = await api.get(ApiEndpoints.materialCategoryDeletePreview(id));
    return ProductCategoryDeletePreview.fromJson(json);
  }

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) async {
    final json = await api.post(
      ApiEndpoints.materialCategories,
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
      ApiEndpoints.materialCategory(id),
      body: input.toJson(),
    );
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<void> delete(String id) =>
      api.delete(ApiEndpoints.materialCategory(id));
}

final productCategoryRepositoryProvider = Provider<ProductCategoryRepository>(
  (ref) => DioProductCategoryRepository(ref.watch(apiClientProvider)),
);
