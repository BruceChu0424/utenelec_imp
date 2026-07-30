// 仓库主档仓库：扁平分页列表（动态筛选）+ 字段 facets + 详情 + CRUD + 字典。
//
// 仿 DioColorRepository。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/warehouse_node.dart';

abstract interface class WarehouseRepository {
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  });

  Future<WarehouseFacets> facets();

  /// 全量字典（采购单据/库存选仓库用）。
  Future<List<WarehouseListItem>> dict();

  Future<WarehouseDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioWarehouseRepository implements WarehouseRepository {
  DioWarehouseRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<WarehouseListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      if (keyword != null && keyword.trim().isNotEmpty)
        'keyword': keyword.trim(),
    };
    final nullFields = <String>[];
    filters.forEach((k, v) {
      if (v == kMasterFilterNullValue) {
        nullFields.add(k);
      } else {
        query[k] = v;
      }
    });
    if (nullFields.isNotEmpty) query['nullFields'] = nullFields;

    final json = await api.get(ApiEndpoints.warehouses, query: query);
    return PagedResult.fromJson(json, WarehouseListItem.fromJson);
  }

  @override
  Future<WarehouseFacets> facets() async {
    final json = await api.get(ApiEndpoints.warehousesFacets);
    return WarehouseFacets.fromJson(json);
  }

  @override
  Future<List<WarehouseListItem>> dict() async {
    final list = await api.getList(ApiEndpoints.warehousesDict);
    return list.map(WarehouseListItem.fromJson).toList();
  }

  @override
  Future<WarehouseDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.warehouse(id));
    return WarehouseDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.warehouses, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.warehouse(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.warehouse(id));
  }
}

final warehouseRepositoryProvider = Provider<WarehouseRepository>(
  (ref) => DioWarehouseRepository(ref.watch(apiClientProvider)),
);
