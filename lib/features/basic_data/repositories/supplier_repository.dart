// 供应商主档仓库：分类下分页列表 + 详情。
//
// 仿 DioMouldRepository，端点走 ApiEndpoints.suppliers 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/supplier_node.dart';

abstract interface class SupplierRepository {
  /// 某分类下的供应商分页（page 从 1 起，与后端 Pageables 约定一致）。
  Future<PagedResult<SupplierListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  });

  Future<SupplierDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioSupplierRepository implements SupplierRepository {
  DioSupplierRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<SupplierListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
  }) async {
    final json = await api.get(
      ApiEndpoints.suppliers,
      query: {
        'categoryId': categoryId,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, SupplierListItem.fromJson);
  }

  @override
  Future<SupplierDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.supplier(id));
    return SupplierDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.suppliers, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.supplier(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.supplier(id));
  }
}

final supplierRepositoryProvider = Provider<SupplierRepository>(
  (ref) => DioSupplierRepository(ref.watch(apiClientProvider)),
);
