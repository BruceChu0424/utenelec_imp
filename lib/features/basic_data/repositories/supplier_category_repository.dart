// 供应商分类仓库：树/子树/详情/CRUD。
//
// 仿 DioMouldCategoryRepository，端点走 ApiEndpoints.supplierCategories 系列。
// 复用 ProductCategoryNode / ProductCategoryDetail 模型——分类节点形状与货品/模具/客户分类完全一致。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/product_category_node.dart';

abstract interface class SupplierCategoryRepository {
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

class DioSupplierCategoryRepository implements SupplierCategoryRepository {
  DioSupplierCategoryRepository(this.api);
  final ApiClient api;

  @override
  Future<List<ProductCategoryNode>> tree() async {
    final list = await api.getList(ApiEndpoints.supplierCategoryTree);
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<List<ProductCategoryNode>> subtree(String id) async {
    final list = await api.getList(ApiEndpoints.supplierCategorySubtree(id));
    return list.map(ProductCategoryNode.fromJson).toList();
  }

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.supplierCategory(id));
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) async {
    final json = await api.post(
      ApiEndpoints.supplierCategories,
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
      ApiEndpoints.supplierCategory(id),
      body: input.toJson(),
    );
    return ProductCategoryDetail.fromJson(json);
  }

  @override
  Future<void> delete(String id) =>
      api.delete(ApiEndpoints.supplierCategory(id));
}

final supplierCategoryRepositoryProvider = Provider<SupplierCategoryRepository>(
  (ref) => DioSupplierCategoryRepository(ref.watch(apiClientProvider)),
);
