// 颜色主档模型（对应后端 ColorListItem / ColorDetail / ColorFacets）。
//
// 扁平主档（无分类树），3 个业务字段：编号/名称/状态 + legacy_id（老库溯源）。
// 数值字段走 (json['x'] as num?)?.toInt()，避免后端 int 序列化成 String 时 cast 崩溃。

import 'master_facet.dart';

/// 颜色列表项。
class ColorListItem {
  const ColorListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  factory ColorListItem.fromJson(Map<String, dynamic> json) => ColorListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 颜色详情（与列表项同字段，保留独立模型与货品范式对齐）。
class ColorDetail {
  const ColorDetail({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  factory ColorDetail.fromJson(Map<String, dynamic> json) => ColorDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 字段 facet 结果：各筛选字段（编号/名称/状态）的可选值桶 + 各字段空值计数。
class ColorFacets {
  const ColorFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['code', 'name', 'status'];

  factory ColorFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
              .map((e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>))
              .toList()
          : const [];
    }
    final ncRaw = json['nullCounts'];
    final nullCounts = <String, int>{};
    if (ncRaw is Map) {
      ncRaw.forEach((k, v) {
        nullCounts[k.toString()] = (v is num ? v.toInt() : 0);
      });
    }
    return ColorFacets(fields: fields, nullCounts: nullCounts);
  }
}
