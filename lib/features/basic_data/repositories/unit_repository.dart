// 基本单位主档仓库：扁平分页列表（动态筛选）+ 字段 facets + 详情 + CRUD。
//
// 仿 DioGoodsRepository，去掉 categoryId（单位扁平无分类）。
// filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields（空值筛选）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/master_facet.dart';
import '../models/unit_node.dart';

abstract interface class UnitRepository {
  /// 单位分页（全量，无分类范围）。
  ///
  /// [keyword] 模糊匹配名称/编号；[filters] 字段精确筛选，
  /// 值为 [kMasterFilterNullValue] 表示筛该字段为空。page 从 1 起。
  Future<PagedResult<UnitListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  });

  /// 字段 facet（各字段可选值 + 空值计数）。
  Future<UnitFacets> facets();

  /// 全量字典（货品编辑表单选单位用）。
  Future<List<UnitListItem>> dict();

  Future<UnitDetail> detail(String id);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioUnitRepository implements UnitRepository {
  DioUnitRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<UnitListItem>> list({
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
    // 哨兵值 → nullFields；其余按 字段=值 发送。
    final nullFields = <String>[];
    filters.forEach((k, v) {
      if (v == kMasterFilterNullValue) {
        nullFields.add(k);
      } else {
        query[k] = v;
      }
    });
    if (nullFields.isNotEmpty) query['nullFields'] = nullFields;

    final json = await api.get(ApiEndpoints.units, query: query);
    return PagedResult.fromJson(json, UnitListItem.fromJson);
  }

  @override
  Future<UnitFacets> facets() async {
    final json = await api.get(ApiEndpoints.unitsFacets);
    return UnitFacets.fromJson(json);
  }

  @override
  Future<List<UnitListItem>> dict() async {
    final list = await api.getList(ApiEndpoints.unitsDict);
    return list.map(UnitListItem.fromJson).toList();
  }

  @override
  Future<UnitDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.unit(id));
    return UnitDetail.fromJson(json);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    await api.post(ApiEndpoints.units, body: body);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.unit(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.unit(id));
  }
}

final unitRepositoryProvider = Provider<UnitRepository>(
  (ref) => DioUnitRepository(ref.watch(apiClientProvider)),
);
