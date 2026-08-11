// 颜色主档仓库：扁平分页列表（动态筛选）+ 字段 facets + 详情 + CRUD。
//
// 仿 DioGoodsRepository，去掉 categoryId（颜色扁平无分类）。
// filters 中值 == kMasterFilterNullValue 的字段名收集进 nullFields（空值筛选）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/models/paged_result.dart';
import '../models/color_node.dart';
import '../models/master_facet.dart';

abstract interface class ColorRepository {
  /// 颜色分页（全量，无分类范围）。
  ///
  /// [keyword] 模糊匹配名称/编号；[filters] 字段精确筛选，
  /// 值为 [kMasterFilterNullValue] 表示筛该字段为空。page 从 1 起。
  Future<PagedResult<ColorListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  });

  /// 字段 facet（各字段可选值 + 空值计数）。
  Future<ColorFacets> facets();

  /// 全量字典（货品编辑表单选颜色用）。
  Future<List<ColorListItem>> dict();

  Future<ColorDetail> detail(String id);

  /// 新建颜色：后端 POST 返回 ColorDetail（含 legacy_id），供货品编辑内联新建后自动选中。
  Future<ColorDetail> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);
}

class DioColorRepository implements ColorRepository {
  DioColorRepository(this.api);
  final ApiClient api;

  @override
  Future<PagedResult<ColorListItem>> list({
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

    final json = await api.get(ApiEndpoints.colors, query: query);
    return PagedResult.fromJson(json, ColorListItem.fromJson);
  }

  @override
  Future<ColorFacets> facets() async {
    final json = await api.get(ApiEndpoints.colorsFacets);
    return ColorFacets.fromJson(json);
  }

  @override
  Future<List<ColorListItem>> dict() async {
    final list = await api.getList(ApiEndpoints.colorsDict);
    return list.map(ColorListItem.fromJson).toList();
  }

  @override
  Future<ColorDetail> detail(String id) async {
    final json = await api.get(ApiEndpoints.color(id));
    return ColorDetail.fromJson(json);
  }

  @override
  Future<ColorDetail> create(Map<String, dynamic> body) async {
    final json = await api.post(ApiEndpoints.colors, body: body);
    return ColorDetail.fromJson(json);
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    await api.put(ApiEndpoints.color(id), body: body);
  }

  @override
  Future<void> delete(String id) async {
    await api.delete(ApiEndpoints.color(id));
  }
}

final colorRepositoryProvider = Provider<ColorRepository>(
  (ref) => DioColorRepository(ref.watch(apiClientProvider)),
);
