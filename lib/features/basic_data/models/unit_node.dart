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

/// 重量维度的单位「等于哪种重量单位」(V745/ADR-135，与服务端 mass_unit_code 同一封闭目录)：
/// 以设了代码的单位为基本单位的货品，重量按数量精确折算，仓库不再另录实称重量。
const Map<String, String> kUnitMassUnitCodes = {
  'G': '克',
  'KG': '千克',
  'T': '吨',
  'JIN': '斤',
  'LB': '磅',
  'OZ': '盎司',
};

/// 「重量单位」展示文字：非重量维度 → 空串；重量维度没选 → 未指定；其余按代码取中文名
/// (与服务端导出「重量单位」列同口径)。
String unitMassUnitLabel(String? dimension, String? massUnitCode) {
  if (dimension != 'MASS') return '';
  if (massUnitCode == null || massUnitCode.isEmpty) return '未指定';
  return kUnitMassUnitCodes[massUnitCode] ?? massUnitCode;
}

/// 单位列表项。
class UnitListItem {
  const UnitListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.legacyId,
    this.measurementDimension,
    this.massUnitCode,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  /// 计量维度（数量/重量/…；null = 未设置，落 unit_measurement_profiles）。
  final String? measurementDimension;

  /// 等于哪种重量单位(G/KG/T/JIN/LB/OZ；仅重量维度，null = 未指定)。
  final String? massUnitCode;

  factory UnitListItem.fromJson(Map<String, dynamic> json) => UnitListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    measurementDimension: json['measurementDimension'] as String?,
    massUnitCode: json['massUnitCode'] as String?,
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
    this.massUnitCode,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final int? legacyId;

  /// 计量维度（数量/重量/…；null = 未设置）。
  final String? measurementDimension;

  /// 等于哪种重量单位(G/KG/T/JIN/LB/OZ；仅重量维度，null = 未指定)。
  final String? massUnitCode;

  factory UnitDetail.fromJson(Map<String, dynamic> json) => UnitDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    measurementDimension: json['measurementDimension'] as String?,
    massUnitCode: json['massUnitCode'] as String?,
  );
}

/// 字段 facet 结果：各筛选字段（编号/名称/状态/计量维度）的可选值桶 + 空值计数。
class UnitFacets {
  const UnitFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['code', 'name', 'status', 'dimension'];

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
