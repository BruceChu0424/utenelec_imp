// 基本单位主档模型（对应后端 UnitListItem / UnitDetail / UnitFacets）。
//
// 扁平主档（无分类树），3 个业务字段：编号/名称/状态 + nullable legacy_id（仅老库溯源；在线身份为 UUID）。
// 数值字段走 (json['x'] as num?)?.toInt()，避免后端 int 序列化成 String 时 cast 崩溃。

import 'master_facet.dart';

/// 计量维度的中文标签（COUNT 数量 / MASS 重量 / LENGTH 长度 / AREA 面积 /
/// VOLUME 体积 / OTHER 其他）；null/未知 → 未设置。
String unitDimensionLabel(String? dimension) => switch (dimension) {
  'COUNT' => '数量',
  'MASS' => '重量',
  'LENGTH' => '长度',
  'AREA' => '面积',
  'VOLUME' => '体积',
  'OTHER' => '其他',
  _ => '未设置',
};

/// 全部可选计量维度（编辑弹窗下拉用）。
const Map<String, String> kUnitMeasurementDimensions = {
  'COUNT': '数量',
  'MASS': '重量',
  'LENGTH': '长度',
  'AREA': '面积',
  'VOLUME': '体积',
  'OTHER': '其他',
};

/// 单位列表项。
class UnitListItem {
  const UnitListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.legacyId,
    this.measurementDimension,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  /// 计量维度（数量/重量/…；null = 未设置，落 unit_measurement_profiles）。
  final String? measurementDimension;

  factory UnitListItem.fromJson(Map<String, dynamic> json) => UnitListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    measurementDimension: json['measurementDimension'] as String?,
  );
}

/// 单位详情（与列表项同字段，保留独立模型与货品范式对齐）。
class UnitDetail {
  const UnitDetail({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.legacyId,
    this.measurementDimension,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  /// 计量维度（数量/重量/…；null = 未设置）。
  final String? measurementDimension;

  factory UnitDetail.fromJson(Map<String, dynamic> json) => UnitDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    measurementDimension: json['measurementDimension'] as String?,
  );
}

/// 字段 facet 结果：各筛选字段（编号/名称/状态）的可选值桶 + 各字段空值计数。
class UnitFacets {
  const UnitFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['code', 'name', 'status'];

  factory UnitFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
                .map(
                  (e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>),
                )
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
    return UnitFacets(fields: fields, nullCounts: nullCounts);
  }
}
