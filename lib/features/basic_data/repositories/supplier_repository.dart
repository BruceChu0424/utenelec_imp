// 供应商主档仓库：分类（子树）下分页列表（动态筛选）+ 字段 facets + 详情。
//
// 仿 DioGoodsRepository，端点走 ApiEndpoints.suppliers 系列；
// 分页结果复用 PagedResult（对应后端 PageResponse）。
// filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields（空值筛选）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/supplier_node.dart';

abstract interface class SupplierRepository {
  /// 某分类（子树）下的供应商分页。
  ///
  /// [keyword] 模糊匹配名称/全称/联系人/法人/地区/手机；[filters] 字段精确筛选，
  /// 值为 [kMasterFilterNullValue] 表示筛该字段为空。page 从 1 起。
  Future<PagedResult<SupplierListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  });

  /// 全局搜供应商（供应商资料页"搜供应商定位分类"用；不限分类，按编号/简称/全称/联系人/法人/地区/手机模糊）。
  Future<PagedResult<SupplierListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
  });

  /// 某分类（子树）下的字段 facet（各字段可选值 + 空值计数）。
  Future<SupplierFacets> facets(String categoryId);

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
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'categoryId': categoryId,
      'page': page,
      'size': size,
      if (keyword != null && keyword.trim().isNotEmpty)
        'keyword': keyword.trim(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    // 哨兵值 → nullFields（Dio 把 List 序列化成重复 param，Spring Set<String> 绑定）；
    // 其余按 字段=值 发送。
    final nullFields = <String>[];
    filters.forEach((k, v) {
      if (v == kMasterFilterNullValue) {
        nullFields.add(k);
      } else {
        query[k] = v;
      }
    });
    if (nullFields.isNotEmpty) query['nullFields'] = nullFields;

    final json = await api.get(ApiEndpoints.suppliers, query: query);
    return PagedResult.fromJson(json, SupplierListItem.fromJson);
  }

  @override
  Future<PagedResult<SupplierListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
  }) async {
    // 后端 categoryId 可空：不传即全库搜索。
    final json = await api.get(
      ApiEndpoints.suppliers,
      query: {
        'page': page,
        'size': size,
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      },
    );
    return PagedResult.fromJson(json, SupplierListItem.fromJson);
  }

  @override
  Future<SupplierFacets> facets(String categoryId) async {
    final json = await api.get(
      ApiEndpoints.suppliersFacets,
      query: {'categoryId': categoryId},
    );
    return SupplierFacets.fromJson(json);
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
